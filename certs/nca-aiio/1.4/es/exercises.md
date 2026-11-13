# Ejercicios guiados — Tema 1.4: Factores que contribuyen a las recientes mejoras rápidas y a la adopción de la IA

**Certificación:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Peso en el examen:** 4.75%

## Qué cubren estos ejercicios

La IA no mejoró rápidamente gracias a un único avance. Varios factores se potencian entre sí:

| Factor | Qué cambió | Qué aporta a la adopción |
|---|---|---|
| **Cómputo acelerado** | GPUs con miles de núcleos y Tensor Cores | El entrenamiento pasa de años a días, y la inferencia se vuelve accesible |
| **Precisión reducida** | FP32 → FP16/BF16 → FP8 → FP4 | 2–8× menos memoria y más FLOPS por watt |
| **Algoritmos** | La arquitectura Transformer (self-attention) | El entrenamiento se puede paralelizar sobre toda una secuencia, y la calidad crece con la escala |
| **Datos** | Texto, imágenes, código y datos empresariales a escala web | Se vuelven posibles los grandes foundation models |
| **Stack de software** | CUDA, cuDNN, NCCL, TensorRT, PyTorch, Triton/NIM | Los desarrolladores no escriben kernels de GPU a mano |
| **Interconexión y almacenamiento** | NVLink/NVSwitch, InfiniBand/RoCE, sistemas de archivos paralelos | Entrenar en miles de GPUs se vuelve práctico |
| **Operaciones cloud-native** | Kubernetes con el GPU Operator, MLOps | Las GPUs se convierten en un recurso planificable y de autoservicio |
| **Modelos preentrenados y abiertos** | Foundation models, transfer learning, fine-tuning | Las empresas adaptan un modelo existente en lugar de entrenar uno desde cero |

Vas a medir, calcular e inspeccionar cada uno de estos factores por tu cuenta.

### Requisitos previos

- Linux con Python 3.10+ y `numpy` (`pip install numpy`).
- **Opcional:** un nodo con una GPU NVIDIA y PyTorch con CUDA (Ejercicios 1 y 5).
- **Opcional:** un cluster de Kubernetes con al menos un nodo con GPU, además de `kubectl` y `helm` (Ejercicio 6).
- Si no tenés GPU, ejecutá los pasos de CPU y de cálculo, y leé los pasos de GPU con sus salidas esperadas. Las preguntas se pueden responder de cualquiera de las dos formas.

> Las salidas marcadas como *ilustrativas* dependen de tu hardware y de las versiones. Tus números van a ser distintos. Lo que importa es la **proporción** entre ellos.

---

## Ejercicio 1 — Cómputo paralelo: multiplicación de matrices en CPU vs GPU

El deep learning es, en su mayor parte, multiplicación de matrices densas (GEMM). Multiplicar dos matrices de `n × n` cuesta alrededor de `2n³` operaciones de punto flotante. Las GPUs ejecutan miles de estas operaciones al mismo tiempo, y esa es la razón principal de la aceleración en IA.

### Pasos

1. Creá un directorio de trabajo y un script de benchmark:

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

2. Ejecutalo:

```bash
python3 gemm_bench.py
```

Salida esperada (*ilustrativa*, CPU de servidor más una H100):

```
Matrix size: 4096x4096  (137.4 GFLOP per multiply)
CPU numpy FP32 :      910.4 GFLOPS
GPU NVIDIA H100 80GB HBM3
GPU torch FP32 :    48210.7 GFLOPS
GPU torch FP16 :   612884.3 GFLOPS
```

3. Cambiá `n = 4096` por `n = 256` y ejecutalo de nuevo. Compará qué tan grande es la ventaja de la GPU en el tamaño chico y en el tamaño grande.

**Preguntas**

- **Q1.1** ¿Por qué la ventaja de la GPU crece con el tamaño de la matriz? ¿Qué te dice esto sobre por qué las GPUs se adaptan bien a modelos *grandes* y a cargas de trabajo *en lotes* (batched)?
- **Q1.2** El resultado en FP16 es muchas veces más alto que el resultado en FP32 en la misma GPU. ¿Qué unidad de hardware explica esto?
- **Q1.3** ¿Por qué el script llama a `torch.cuda.synchronize()` antes de leer el reloj?

---

## Ejercicio 2 — Precisión reducida y huella de memoria

El tamaño de un modelo en la memoria de la GPU es aproximadamente *parámetros × bytes por parámetro*. Una precisión más baja permite que modelos más grandes entren en menos GPUs. También aumenta los FLOPS útiles y el ancho de banda de memoria por GPU.

### Pasos

1. Creá la calculadora:

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

Salida esperada (determinística):

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

**Preguntas**

- **Q2.1** Un modelo de 70B en FP8 necesita "min 1 × 80GB GPU". ¿Por qué esa única GPU seguiría siendo una mala elección para servirlo en producción?
- **Q2.2** El script modela Grouped-Query Attention con 8 KV heads en lugar de las 64 query heads completas. ¿Cuánto reduce eso el KV cache? ¿Por qué este es un factor *algorítmico* de adopción y no uno de hardware?
- **Q2.3** Nombrá las generaciones de GPU que trajeron soporte de Tensor Cores para FP8 y para FP4. En términos generales, ¿qué significa cada paso para el costo por inferencia?

---

## Ejercicio 3 — Leyes de escalado y cómputo: por qué importa la generación de GPU

Una estimación común del cómputo necesario para entrenar un Transformer denso es **FLOPs ≈ 6 × N × D**, donde `N` es la cantidad de parámetros y `D` es la cantidad de tokens de entrenamiento. El resultado de Chinchilla sugiere un `D` óptimo en cómputo de alrededor de 20 tokens por parámetro. Las leyes de escalado mostraron que la pérdida (loss) baja de forma *predecible* a medida que crece el cómputo. Esa previsibilidad es la razón por la que las organizaciones estuvieron dispuestas a invertir en clusters de GPU muy grandes.

### Pasos

1. Creá el estimador:

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

Salida esperada (determinística):

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

2. Cambiá `MFU = 0.40` por `MFU = 0.20` y ejecutalo de nuevo. Observá cómo cambia el tiempo de entrenamiento.

**Preguntas**

- **Q3.1** En el caso de 70B, pasar de V100 a H100 convierte unos 4 meses en unas 2 semanas. Explicá cómo afecta esto a la frecuencia con la que un equipo puede iterar, y por qué impulsa la adopción.
- **Q3.2** Reducir el MFU a la mitad duplica el tiempo de entrenamiento. Nombrá tres factores de infraestructura *fuera* del chip de la GPU que bajan el MFU en un cluster de 1.024 GPUs.
- **Q3.3** Según la regla práctica de Chinchilla, ¿cuántos tokens son óptimos en cómputo para un modelo de 70B? ¿Por qué la disponibilidad de datos es en sí misma un factor del progreso de la IA?

---

## Ejercicio 4 — El Transformer: por qué encaja con las GPUs

Las redes recurrentes (RNNs/LSTMs) procesan los tokens uno tras otro, porque cada paso depende del hidden state del paso anterior. Self-attention calcula la relación entre todos los tokens con unas pocas multiplicaciones de matrices. Esa es exactamente la carga de trabajo del Ejercicio 1.

### Pasos

1. Compará los dos enfoques en NumPy:

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

Salida esperada (*ilustrativa*):

```
RNN       : 512 dependent steps,    9.84 ms
Attention : 5 matrix multiplies,     3.12 ms, output (512, 256)
Attention score matrix: (512, 512) -> memory grows with seq^2
```

2. Cambiá `seq` a `4096` y ejecutalo de nuevo. Observá el tiempo de attention y el tamaño de la matriz de scores.

**Preguntas**

- **Q4.1** Attention hace *más* aritmética que la RNN y, sin embargo, escala mejor en una GPU. ¿Por qué?
- **Q4.2** ¿Qué implica la matriz de scores de `seq²` para contextos largos? Nombrá un kernel optimizado que aborde este problema.
- **Q4.3** ¿Qué año y qué paper introdujeron el Transformer? Nombrá las tres familias de modelos que hizo posibles (encoder-only, decoder-only, encoder-decoder) con un ejemplo de cada una.

---

## Ejercicio 5 — El stack de software: del driver al engine optimizado

El hardware solo no causó el boom de la IA. Un stack de software maduro permite que un data scientist escriba `model.to("cuda")` y obtenga kernels optimizados sin escribirlos. En este ejercicio inspeccionás ese stack capa por capa.

### Pasos

1. Inspeccioná el driver y la GPU (en un nodo con GPU):

```bash
nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv
```

Salida esperada (*ilustrativa*):

```
name, driver_version, memory.total [MiB], compute_cap
NVIDIA H100 80GB HBM3, 560.35.03, 81559 MiB, 9.0
```

2. Inspeccioná las versiones de CUDA y de las bibliotecas que usa el framework:

```bash
python3 -c "import torch; print('torch', torch.__version__); print('CUDA', torch.version.cuda); print('cuDNN', torch.backends.cudnn.version()); print('NCCL', torch.cuda.nccl.version())"
```

Salida esperada (*ilustrativa*):

```
torch 2.5.1+cu124
CUDA 12.4
cuDNN 90100
NCCL (2, 21, 5)
```

3. Optimizá un modelo con TensorRT. Exportá un modelo ONNX chico y después construí un engine con `trtexec`. Podés ejecutarlo dentro del contenedor TensorRT de NGC, que ya incluye `trtexec`:

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

Final esperado de la salida (*ilustrativo*):

```
[I] === Performance summary ===
[I] Throughput: 2873.41 qps
[I] Latency: min = 0.33 ms, max = 0.52 ms, mean = 0.35 ms, median = 0.35 ms, percentile(99%) = 0.41 ms
...
&&&& PASSED TensorRT.trtexec [TensorRT v100500] # trtexec --onnx=resnet50.onnx --saveEngine=resnet50_fp16.engine --fp16
```

4. Construí el engine de nuevo sin `--fp16` (esto da FP32/TF32) y compará el `Throughput`.

**Preguntas**

- **Q5.1** Ordená estos componentes desde el hardware hasta la aplicación, e indicá el rol de cada uno: CUDA, el driver de NVIDIA, cuDNN, PyTorch, TensorRT, NCCL.
- **Q5.2** Nombrá tres optimizaciones que aplica TensorRT cuando construye un engine.
- **Q5.3** Un engine de TensorRT normalmente se construye *en el mismo modelo de GPU* donde se va a ejecutar. ¿Por qué?

---

## Ejercicio 6 — Adopción cloud-native: las GPUs como recurso de Kubernetes

Las empresas adoptan la IA más rápido cuando las GPUs se comportan como cualquier otro recurso de la plataforma que ya operan. El NVIDIA GPU Operator automatiza el driver, el container toolkit, el device plugin, el etiquetado de nodos y el monitoreo en los nodos de Kubernetes.

### Pasos

1. Instalá el GPU Operator:

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm install --wait --generate-name -n gpu-operator --create-namespace nvidia/gpu-operator
```

2. Verificá los componentes:

```bash
kubectl get pods -n gpu-operator
```

Salida esperada (*ilustrativa*, nombres acortados):

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

3. Verificá que el nodo ahora anuncie GPUs:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
```

Salida esperada (*ilustrativa*):

```
NODE          GPUS   PRODUCT
gpu-node-01   8      NVIDIA-H100-80GB-HBM3
```

4. Guardá este manifiesto como `cuda-vectoradd.yaml`. Solicita una GPU:

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

Salida esperada:

```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

5. Limpiá:

```bash
kubectl delete pod cuda-vectoradd
```

**Preguntas**

- **Q6.1** Sin el GPU Operator, ¿qué pasos manuales tendría que realizar un administrador en cada nodo con GPU? ¿Qué daemonset reemplaza cada paso?
- **Q6.2** ¿Por qué `nvidia.com/gpu` aparece bajo `limits`, y por qué no se puede sobreasignar (overcommit) como la CPU?
- **Q6.3** ¿Qué componente exporta las métricas de GPU a Prometheus? Nombrá dos métricas sobre las que configurarías alertas.

---

## Ejercicio 7 — Economía de la inferencia: por qué la optimización impulsa la adopción

Muchas organizaciones deciden adoptar IA en función del **costo por unidad de trabajo**, como el costo por millón de tokens. Optimizaciones como una precisión más baja, el in-flight batching y los kernels optimizados aumentan el throughput sobre el mismo hardware. Eso baja directamente el costo unitario.

### Pasos

1. Modelá el costo (los precios son hipotéticos):

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

Salida esperada (determinística):

```
Baseline (BF16, static batching)
  2500 tok/s/GPU -> $0.333 per 1M tokens, 4.63 GPUs, $333/day
Optimized (FP8 + in-flight batching)
  6250 tok/s/GPU -> $0.133 per 1M tokens, 1.85 GPUs, $133/day
```

**Preguntas**

- **Q7.1** La optimización es puramente de software y corre sobre el mismo hardware. ¿Cuánto baja el costo? Dá una razón por la que esto importa más para la inferencia que para el entrenamiento a lo largo de la vida de un modelo.
- **Q7.2** Aumentar el tamaño de batch aumenta el throughput. ¿Qué métrica que percibe el usuario suele empeorar, y cómo equilibran los equipos ambas cosas?
- **Q7.3** Nombrá las ofertas de NVIDIA que empaquetan inferencia optimizada para que una empresa no tenga que ajustarla a mano.

---

## Ejercicio 8 — Datos y almacenamiento: dónde está realmente el cuello de botella de I/O

Los datasets enormes hicieron posible la IA moderna. Sin embargo, los requisitos de almacenamiento de los grandes trabajos de entrenamiento suelen depender más del **checkpointing** y de los datos multimodales que de la lectura de texto tokenizado.

### Pasos

1. Estimá el I/O:

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

Salida esperada (determinística):

```
Tokens/s per GPU  : 9,419
Text read rate    : 38.6 MB/s for the whole cluster
Checkpoint 112 GB in 600s -> 0.19 GB/s write
Checkpoint 112 GB in  60s -> 1.87 GB/s write
Vision: 3,072,000 img/s x 110 KB = 338 GB/s read
```

**Preguntas**

- **Q8.1** Leer tokens de texto necesita solo unos 39 MB/s. ¿Por qué los clusters de entrenamiento igual necesitan almacenamiento compartido de alto rendimiento?
- **Q8.2** ¿Por qué importa una ventana de checkpoint corta? Relacionalo con la utilización de GPU y con el costo de las fallas a escala.
- **Q8.3** Nombrá dos técnicas de la guía de almacenamiento de NVIDIA que reducen la presión sobre el sistema de archivos compartido durante el entrenamiento.

---

## Ejercicio 9 — Síntesis: un escenario estilo examen

> Una empresa de retail intentó construir en 2018 un chatbot de recomendación de productos con LSTMs sobre servidores con CPU. Abandonó el proyecto porque el entrenamiento tardaba semanas y las respuestas eran malas. En 2025 lanza un chatbot en seis semanas. El chatbot usa un LLM abierto de 8B, tiene fine-tuning con datos de productos, se sirve con TensorRT-LLM en FP8 sobre un cluster de Kubernetes con el GPU Operator, y funciona con un costo por consulta aceptable.

### Pasos

1. Armá una tabla con una fila por cada factor de la introducción. En cada fila, escribí el elemento concreto del proyecto de 2025 que corresponde a ese factor.
2. Elegí los **dos** factores que consideres decisivos para *esta* empresa. Justificá la elección en no más de tres oraciones.

**Preguntas**

- **Q9.1** ¿Por qué la empresa no necesitó entrenar un modelo desde cero? ¿Qué factor muestra esto?
- **Q9.2** Si mañana se duplicaran los precios de las GPUs, ¿qué factor del stack de 2025 amortiguaría más el impacto, y por qué?
- **Q9.3** Para cada uno, indicá si es principalmente un factor de *mejora* (mejores modelos) o de *adopción* (más fácil o más barato de usar): GPU Operator, Transformer, FP8, NIM, leyes de escalado.

---

## Respuestas

<details>
<summary>Hacé clic para mostrar las respuestas</summary>

### Ejercicio 1

- **Q1.1** El cómputo crece como `n³`, mientras que los costos fijos (lanzamiento del kernel, movimiento de datos, sincronización) se mantienen aproximadamente constantes. Las matrices chicas no pueden mantener ocupados a miles de núcleos de GPU. Las grandes los saturan. Por eso las GPUs brillan con modelos grandes y con solicitudes en lotes, y por eso los motores de serving agrupan las solicitudes.
- **Q1.2** **Tensor Cores.** Son unidades especializadas en multiply-accumulate de matrices en precisión mixta. Ofrecen muchas veces el throughput de los CUDA cores generales para FP16/BF16 (y FP8/FP4 en las generaciones más nuevas).
- **Q1.3** Los lanzamientos de kernels CUDA son **asíncronos**: la llamada de Python retorna antes de que la GPU termine. Sin `synchronize()`, medirías solo el tiempo de lanzamiento y no el tiempo de cómputo.

### Ejercicio 2

- **Q2.1** Quedarían solo unos 10 GB para el KV cache, las activaciones y el overhead del runtime. El script muestra que el KV cache por sí solo puede llegar a unos 86 GB para 32 secuencias concurrentes de 8K tokens. Tendrías muy poca concurrencia o contextos muy cortos. Un despliegue de producción usa más GPUs (tensor parallelism) o GPUs con más memoria.
- **Q2.2** El KV cache es 64/8 = **8× más chico**. GQA es un cambio en la arquitectura del modelo (un algoritmo) que reduce la memoria por token. Permite que el *mismo* hardware atienda a más usuarios o contextos más largos, lo que baja el costo de la inferencia.
- **Q2.3** FP8 llegó con **Hopper** (H100, Transformer Engine). FP4 llegó con **Blackwell** (B200/GB200). Cada reducción a la mitad de la precisión aproximadamente duplica el throughput de los Tensor Cores y reduce a la mitad la memoria y el ancho de banda por parámetro. El resultado es más tokens por segundo por GPU y menor costo por inferencia, siempre que la precisión del modelo se mantenga mediante calibración y escalado.

### Ejercicio 3

- **Q3.1** Corridas de entrenamiento más cortas permiten que un equipo pruebe más arquitecturas, mezclas de datos e hiperparámetros en el mismo tiempo calendario. Una iteración más rápida produce mejores modelos, y el ROI llega antes. Ambas cosas hacen que la inversión y la adopción sean más fáciles de justificar.
- **Q3.2** Respuestas posibles: interconexión lenta entre nodos (ancho de banda y latencia de InfiniBand o RoCE) para el all-reduce de gradientes; falta de NVLink/NVSwitch dentro del nodo; bloqueos de almacenamiento al cargar datos o escribir checkpoints; stragglers y fallas, con reinicios desde un checkpoint; una mala estrategia de paralelismo, con pipeline bubbles; cuellos de botella de CPU o del data loader.
- **Q3.3** Alrededor de **1,4 billones** de tokens (20 × 70B). Los mejores modelos necesitan más datos de alta calidad. La disponibilidad de texto, código e imágenes a escala web, junto con las herramientas para curarlos, es lo que hizo posible hacer crecer los modelos de forma útil.

### Ejercicio 4

- **Q4.1** La RNN tiene una **dependencia secuencial**: el paso *t* no puede empezar hasta que termine el paso *t-1*, así que no se puede paralelizar a lo largo de la secuencia. Attention convierte toda la secuencia en unas pocas GEMMs grandes. Estas son totalmente paralelas y se mapean directamente a los Tensor Cores. En una GPU, la estructura paralela importa más que la cantidad total de FLOPs.
- **Q4.2** La memoria y el cómputo de la attention ingenua crecen de forma cuadrática con la longitud del contexto. **FlashAttention** calcula la attention en bloques (tiles) dentro de la SRAM del chip y nunca materializa la matriz completa de `seq × seq`. (La gestión paginada del KV cache, como en vLLM o TensorRT-LLM, aborda la memoria usada durante el serving.)
- **Q4.3** "Attention Is All You Need", Vaswani et al., **2017**. Las familias son: encoder-only (BERT), decoder-only (GPT, Llama) y encoder-decoder (T5).

### Ejercicio 5

- **Q5.1** Desde el hardware hacia arriba:
  1. **Driver de NVIDIA** — expone la GPU al sistema operativo.
  2. **CUDA** — el modelo de programación y el runtime.
  3. **cuDNN** — primitivas de deep learning optimizadas, como convoluciones y attention.
  4. **NCCL** — operaciones colectivas multi-GPU y multi-nodo, como all-reduce.
  5. **PyTorch** — el framework que llama a estas bibliotecas.
  6. **TensorRT** — un optimizador y runtime de inferencia que toma el modelo entrenado (a menudo exportado como ONNX) y produce un engine optimizado.
- **Q5.2** Respuestas posibles: fusión de capas y tensores; calibración de precisión (FP16/FP8/INT8); auto-tuning de kernels por GPU; reutilización dinámica de memoria de tensores; ejecución multi-stream.
- **Q5.3** Durante el build, TensorRT **elige los kernels más rápidos para la arquitectura de GPU específica** (auto-tuning) y para la versión de TensorRT. Un engine no es portable entre arquitecturas, y no está garantizado que sea óptimo en una GPU distinta.

### Ejercicio 6

- **Q6.1** Cada paso manual y el daemonset que lo reemplaza:

  | Paso manual | Reemplazado por |
  |---|---|
  | Instalar el driver del kernel | `nvidia-driver-daemonset` |
  | Configurar el container runtime | `nvidia-container-toolkit-daemonset` |
  | Desplegar el device plugin para anunciar `nvidia.com/gpu` | `nvidia-device-plugin-daemonset` |
  | Etiquetar los nodos por modelo de GPU y capacidades | `gpu-feature-discovery` (con NFD) |
  | Configurar el monitoreo | `nvidia-dcgm-exporter` |
  | Validar el stack | `nvidia-operator-validator` |

  Hacer esto a mano en cada nodo, y de nuevo en cada actualización, frena la adopción.
- **Q6.2** Los recursos extendidos como las GPUs son **solo enteros y no se pueden sobreasignar**. Si definís un request, tiene que ser igual al limit, y el limit solo alcanza. Se asigna una GPU entera al contenedor. El uso compartido se hace de forma explícita con MIG, time-slicing o MPS.
- **Q6.3** El **DCGM Exporter**. Métricas posibles: `DCGM_FI_DEV_GPU_UTIL` (utilización), `DCGM_FI_DEV_FB_USED` (memoria de frame buffer usada), `DCGM_FI_DEV_GPU_TEMP` (temperatura), `DCGM_FI_DEV_XID_ERRORS` (errores Xid), `DCGM_FI_DEV_POWER_USAGE` (consumo de energía).

### Ejercicio 7

- **Q7.1** **2,5× más barato** ($0.333 → $0.133 por 1M de tokens), y de unas 4,6 GPUs a unas 1,9 GPUs. El entrenamiento es un costo grande que se paga una sola vez. La inferencia corre de forma continua y crece con los usuarios, así que a lo largo de la vida de un modelo el costo total de inferencia suele superar al costo de entrenamiento.
- **Q7.2** La **latencia**, como el time to first token o la latencia entre tokens, empeora. Los equipos definen un SLO (por ejemplo, una latencia P99) y ajustan el batching (in-flight o continuous batching, tamaño máximo de batch) para obtener el mayor throughput que todavía cumpla el SLO.
- **Q7.3** **NVIDIA NIM** (microservicios de inferencia preempaquetados), **Triton Inference Server** y **TensorRT-LLM**, todos parte de **NVIDIA AI Enterprise**.

### Ejercicio 8

- **Q8.1** Por varias razones:
  - Las escrituras de checkpoints son grandes y se producen en ráfagas.
  - Los datos multimodales (imágenes, video, audio) necesitan cientos de GB/s.
  - Miles de clientes abren y leen archivos al mismo tiempo.
  - La primera epoch, o los datos que no se pueden cachear, se tienen que leer del almacenamiento compartido.
  - La carga de modelos para inferencia (cold start) y el almacenamiento detrás de RAG también necesitan almacenamiento compartido rápido.
- **Q8.2** Mientras se escribe un checkpoint, las GPUs a menudo quedan ociosas o se ralentizan. A la escala de miles de GPUs, las fallas son frecuentes, así que hay que tomar checkpoints seguido. Una ventana corta mantiene alta la utilización de GPU (y el MFU), y limita el trabajo perdido cuando un job tiene que reiniciarse.
- **Q8.3** Respuestas posibles: cachear el dataset en NVMe local de cada nodo después de la primera lectura; GPUDirect Storage (un camino directo desde el almacenamiento a la memoria de la GPU, sin rebotar por la CPU); checkpointing asíncrono o por niveles (escribir primero en almacenamiento local y después volcar al almacenamiento compartido); un sistema de archivos paralelo que escale su ancho de banda con más nodos; redes separadas para almacenamiento y cómputo.

### Ejercicio 9

- **Q9.1** Gracias a los **foundation models preentrenados y al transfer learning (fine-tuning)**, la empresa reutilizó el conocimiento general de un LLM abierto de 8B y solo lo adaptó a sus datos de productos. Eso cuesta órdenes de magnitud menos de cómputo y de datos que el preentrenamiento.
- **Q9.2** La **optimización de la inferencia** (FP8 con TensorRT-LLM e in-flight batching), junto con la elección de un modelo chico de 8B. Más tokens por GPU-hora significa menos GPUs para la misma carga, lo que compensa un precio más alto por GPU.
- **Q9.3**
  - **GPU Operator** — adopción (simplicidad operativa).
  - **Transformer** — mejora (modelos mejores y más escalables).
  - **FP8** — ambos: mejora (más cómputo para el entrenamiento) y adopción (inferencia más barata).
  - **NIM** — adopción (despliegue empaquetado).
  - **Leyes de escalado** — mejora (predicen mejores modelos), con un efecto indirecto en la adopción porque justificaron la inversión.

</details>

---

## Fuentes

- NVIDIA, *NCA-AIIO Exam Study Guide*: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, *AI Infrastructure and Operations Fundamentals*: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- *Tips on Scaling Storage for AI Training and Inferencing*: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- *What Are Large Language Models Used For?*: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- *NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes*: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- Vaswani et al., *Attention Is All You Need* (2017): https://arxiv.org/abs/1706.03762
- Hoffmann et al., *Training Compute-Optimal Large Language Models* (Chinchilla, 2022): https://arxiv.org/abs/2203.15556