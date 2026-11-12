# Ejercicios guiados — Tema 1.5: Explicar los casos de uso e industrias clave de la IA

> **Examen:** NCA-AIIO · **Peso:** 4.75%
> **Objetivo:** Ir más allá de memorizar "la industria X usa IA para Y". Para cada caso de uso, determiná qué le exige a la infraestructura: fase de la carga de trabajo, clase de latencia, huella de memoria, patrón de I/O de almacenamiento y stack de software de NVIDIA. El examen te pide *explicar* casos de uso. Los ingenieros de infraestructura los explican a través de los recursos que consumen.

**Fuentes oficiales usadas a lo largo del tema:**
- Guía del examen NCA-AIIO: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- Curso AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- Para qué se usan los LLMs: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- Escalar el almacenamiento para entrenamiento e inferencia de IA: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- NVIDIA GPU Operator: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes

**Qué necesitás:**

| Ejercicios | Requisitos |
|---|---|
| 1–3, 6, 7 | Cualquier máquina Linux/macOS con Python 3.9+ y `pyyaml`. Sin GPU. |
| 4–5 | Un cluster de Kubernetes con al menos un nodo con GPU NVIDIA y el NVIDIA GPU Operator instalado. Si no tenés ninguno, leé los pasos y la salida esperada, y después respondé las preguntas. |

```bash
mkdir -p ~/aiio-1.5 && cd ~/aiio-1.5
python3 -m pip install --user pyyaml
```

---

## Ejercicio 1 — Armar un catálogo de casos de uso por industria y clasificarlo por perfil de carga de trabajo

La misma técnica de IA tiene necesidades de infraestructura muy distintas según dónde se ejecuta. Un modelo de visión que inspecciona piezas en una línea de fábrica tiene un presupuesto estricto de tiempo real. La misma arquitectura revisando archivos médicos durante la noche es un job batch limitado por throughput. En este ejercicio codificás esa distinción como datos.

**Paso 1.** Creá el catálogo. Todo valor que contiene `: ` va entre comillas para que el archivo se pueda parsear.

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

**Paso 2.** Escribí el clasificador. Valida el archivo y agrupa los casos de uso por clase de latencia y por tipo de IA.

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

Salida esperada:

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

El grupo real-time tiene **6** entradas, no 5. Contalas y corregí el encabezado mentalmente. Mejor todavía, ejecutá el script y confirmá que el encabezado que imprime (calculado con `len()`) coincide con lo que ves. La salida esperada completa está en la sección de respuestas.

**Paso 3.** Rompé el YAML a propósito. Cambiá `use_case: "Autonomous driving perception (camera, radar, lidar)"` por un valor sin comillas que contenga dos puntos, por ejemplo `use_case: Perception: camera, radar, lidar`. Ejecutá el script de nuevo y después revertí el cambio.

**Preguntas — Ejercicio 1**

1.1. Cinco de los seis casos de uso real-time corren en *inferencia*. ¿Por qué tiene sentido? ¿Qué componente pondrías entre el modelo y la aplicación para cumplir un presupuesto de milisegundos?
1.2. La conducción autónoma aparece como `training+edge-inference`. ¿Dónde corre físicamente cada fase, y por qué la fase de inferencia no puede correr en un data center remoto?
1.3. ¿Qué error produjo el Paso 3, y por qué importa cuando este catálogo se usa como entrada de automatización?
1.4. El blog de NVIDIA sobre LLMs enumera generación, resumen, traducción, clasificación, generación de código y chatbots como usos de LLMs. ¿Qué entradas del catálogo están basadas en LLMs? ¿Cuáles son generativas pero *no* están basadas en LLMs?

---

## Ejercicio 2 — Dimensionar un caso de uso de inferencia de LLM (pesos + KV cache)

El caso de uso empresarial más común en el examen es la **IA generativa / inferencia de LLM** (chatbots, RAG, resumen). Su perfil de memoria determina qué GPU necesitás y cuántas. La memoria de la GPU guarda dos cosas:

- **Pesos:** `parameters × bytes_per_parameter`. Es fijo por modelo y precisión.
- **KV cache:** `2 (K and V) × layers × kv_heads × head_dim × bytes × tokens_in_flight`. Crece con la longitud de contexto × las solicitudes concurrentes.

**Paso 1.** Creá el script de dimensionamiento. Usa cantidades nominales de parámetros y la arquitectura publicada de Llama 3 8B y 70B (Grouped-Query Attention con 8 KV heads).

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

Salida esperada:

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

**Paso 2.** Completá la tabla para tres casos de uso, cada uno apuntando a una sola GPU de 80 GB (por ejemplo, H100 80GB). Dejá aproximadamente un 10% de margen para activaciones y el contexto de CUDA.

| Caso de uso | Modelo / precisión | Pesos | KV cache | Total | ¿Entra en 1 × 80 GB? |
|---|---|---|---|---|---|
| Chatbot interno de RR. HH. | 8B / FP16 | ? | ? | ? | ? |
| Resumen de documentos legales | 70B / FP8 | ? | ? | ? | ? |
| Asistente de código | 70B / INT4 | ? | ? | ? | ? |

**Paso 3.** Editá `CONCURRENT_SEQS = 4` y volvé a ejecutar.

**Preguntas — Ejercicio 2**

2.1. Completá la tabla del Paso 2.
2.2. Para el caso 70B / FP8, dá tres palancas que lo hagan entrar o escalar, y el trade-off de cada una.
2.3. ¿Por qué la KV cache por token del modelo de 70B es solo 2.5× la del modelo de 8B, si el modelo de 70B tiene ~8.75× los parámetros?
2.4. TensorRT y TensorRT-LLM soportan cuantización FP8 e INT4. ¿Cuál de los dos componentes de memoria reduce la cuantización de pesos, y cuál deja sin cambios?

---

## Ejercicio 3 — Latencia vs throughput: asociar casos de uso con SLAs

La página de inferencia de NVIDIA plantea la inferencia en producción como un trade-off entre **latencia** (tiempo por solicitud) y **throughput** (solicitudes o tokens por segundo) a un costo dado. Las industrias se ubican en puntos distintos de esa curva. Vas a cuantificarlo con la Ley de Little: `concurrency = throughput × latency`.

**Paso 1.** Calculá a mano o en un REPL de Python:

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

Salida esperada:

```
A) required throughput: 50.0 req/s
B) wall time on 8 GPUs: 625 s = 10.4 min
C) requests in flight at budget: 500.0
```

**Preguntas — Ejercicio 3**

3.1. Para cada uno de A, B y C, indicá si optimizás principalmente por latencia o por throughput, y dá una técnica de serving que encaje.
3.2. El caso de uso B tarda 10.4 minutos en 8 GPUs. ¿Cuánto tarda en 1 GPU? ¿Por qué este caso de uso es un buen candidato para un cluster compartido y planificado en lugar de GPUs dedicadas?
3.3. En el caso de uso C, ¿por qué el dynamic batching (por ejemplo, en Triton Inference Server) ayudaría al throughput pero requeriría un retardo de cola cuidadosamente acotado?

---

## Ejercicio 4 — Confirmar la plataforma de GPU que sirve estos casos de uso (Kubernetes + GPU Operator)

Todos los casos de uso anteriores corren en GPUs que alguien tiene que exponer a las cargas de trabajo. El GPU Operator automatiza el driver, el NVIDIA Container Toolkit, el device plugin, GPU Feature Discovery (GFD) y el monitoreo con DCGM. Gracias a GFD podés elegir la GPU *correcta* para un caso de uso mediante labels de nodo.

**Paso 1.** Inspeccioná el operator y los labels de GPU.

```bash
kubectl get pods -n gpu-operator
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.memory,nvidia.com/gpu.count
```

Salida esperada (ilustrativa; los valores dependen de tu hardware):

```
NAME          STATUS   ROLES    AGE   VERSION   GPU.PRODUCT              GPU.MEMORY   GPU.COUNT
gpu-node-01   Ready    <none>   12d   v1.31.2   NVIDIA-H100-80GB-HBM3   81559        8
cpu-node-01   Ready    <none>   12d   v1.31.2
```

**Paso 2.** Ejecutá un smoke test de GPU fijado al modelo de GPU que dimensionaste en el Ejercicio 2.

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

Reemplazá el valor de `nodeSelector` por el label de producto del Paso 1 antes de aplicarlo.

```bash
kubectl apply -f gpu-smoke.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke --timeout=120s
kubectl logs gpu-smoke
```

Salida esperada (ilustrativa):

```
name, memory.total [MiB], memory.used [MiB]
NVIDIA H100 80GB HBM3, 81559 MiB, 0 MiB
```

**Preguntas — Ejercicio 4**

4.1. ¿Qué componente del GPU Operator crea el label `nvidia.com/gpu.product`, y cuál hace que `nvidia.com/gpu: 1` sea planificable?
4.2. En el Ejercicio 2, el modelo 70B / FP8 necesitaba más de 80 GB. Sin cambiar el modelo, ¿qué cambiarías en esta especificación del Pod, y qué funcionalidad de serving tiene que usar entonces el motor de inferencia?
4.3. Un cliente de retail ejecuta un modelo de recomendación pequeño que usa 6 GB de memoria de GPU, junto con otros modelos pequeños. ¿Qué funcionalidad de GPU expuesta a través del operator evita dedicarle una H100 entera?

---

## Ejercicio 5 — Optimizar un modelo de inspección visual para manufactura con TensorRT

La inspección visual de defectos (manufactura) y la analítica de video (ciudades inteligentes) son casos de uso de percepción con presupuestos de tiempo real. TensorRT compila un modelo entrenado en un engine optimizado (fusión de capas, auto-tuning de kernels, precisión reducida). `trtexec` es la CLI de benchmarking que viene en el contenedor de TensorRT. Acá un clasificador ResNet-50 hace las veces del modelo de inspección.

**Paso 1.** Creá un Job que descargue un ResNet-50 en ONNX y lo mida con batch 1 (perfil de latencia) y batch 32 (perfil de throughput).

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

Si la descarga pesa apenas unos cientos de bytes, recibiste un puntero de Git LFS en lugar del modelo. Descargá el archivo desde la página del repositorio onnx/models y copialo adentro. Si `trtexec` informa que la entrada `data` es estática, quitá los flags `--shapes`.

Forma de la salida esperada (los números son **ilustrativos** y varían mucho según la GPU):

```
-rw-r--r-- 1 root root 98M ... /tmp/resnet50.onnx
=== batch 1, FP16 ===
[I] Throughput: 2450.13 qps
[I] Latency: min = 0.39 ms, max = 0.61 ms, mean = 0.41 ms, median = 0.40 ms, percentile(90%) = 0.42 ms, percentile(95%) = 0.43 ms, percentile(99%) = 0.47 ms
=== batch 32, FP16 ===
[I] Throughput: 410.55 qps
[I] Latency: min = 2.38 ms, max = 2.71 ms, mean = 2.43 ms, median = 2.42 ms, percentile(90%) = 2.46 ms, percentile(95%) = 2.48 ms, percentile(99%) = 2.55 ms
```

**Paso 2.** Registrá tus propios números y calculá `images/s = qps × batch` para cada ejecución.

**Preguntas — Ejercicio 5**

5.1. En `trtexec`, una "query" es un batch. Con los números ilustrativos, ¿cuántas imágenes por segundo procesa cada ejecución? ¿Qué configuración elegirías para una cámara de línea que debe rechazar una pieza defectuosa dentro de los 5 ms posteriores a la captura, y cuál para volver a escanear un mes de imágenes archivadas?
5.2. ¿Por qué los sistemas de inspección y de analítica de video suelen ejecutar este engine en el **edge** (en Jetson o en una PC industrial cerca de la línea) en lugar de en un data center central?
5.3. Construir el engine llevó un tiempo apreciable antes de que empezara el benchmark. ¿Qué implica eso para el despliegue en producción? ¿El engine debería construirse al iniciar el Pod, o por adelantado?

---

## Ejercicio 6 — Perfiles de almacenamiento: casos de uso de entrenamiento vs inferencia

El blog de almacenamiento de NVIDIA enfatiza que el entrenamiento y la inferencia exigen el almacenamiento de formas distintas. El entrenamiento lee datasets grandes repetidamente (a lo largo de las épocas) y escribe checkpoints grandes periódicamente. La inferencia necesita sobre todo cargar modelos rápido y, en el caso de RAG, servir búsquedas de baja latencia desde un vector store.

**Paso 1.** Estimá el costo de checkpoint de hacer fine-tuning de un modelo de 70B con precisión mixta y Adam. Suponé que se guardan ~14 bytes por parámetro: pesos FP16 (2), pesos maestros FP32 (4) y dos momentos de Adam en FP32 (4 + 4).

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

Salida esperada:

```
checkpoint size: 980 GB
write at  1 GB/s:   980.0 s  -> 27.2% of each hour if synchronous & hourly
write at 10 GB/s:    98.0 s  ->   2.7% of each hour if synchronous & hourly
write at 50 GB/s:    19.6 s  ->   0.5% of each hour if synchronous & hourly
```

**Paso 2.** Hacé vos la comparación del lado de la inferencia. Un chatbot con autoescalado arranca en frío una réplica que tiene que cargar 70 GB de pesos FP8. Calculá el tiempo de carga desde (a) almacenamiento de objetos a 1 GB/s y (b) una caché NVMe local a 7 GB/s.

**Preguntas — Ejercicio 6**

6.1. ¿Cuáles son los tiempos de carga del Paso 2 (a) y (b)? ¿Qué métrica visible para el usuario se ve afectada en el caso (a)?
6.2. Un equipo de imágenes médicas entrena sobre 400 TB de estudios DICOM durante 100 épocas. ¿Su patrón de almacenamiento dominante son lecturas secuenciales/grandes, lecturas aleatorias pequeñas o escrituras grandes? ¿Qué recomienda NVIDIA para mantener alimentadas las GPUs en ese caso?
6.3. Nombrá dos técnicas que reduzcan el 27.2% de overhead de checkpoint sin comprar almacenamiento más rápido.

---

## Ejercicio 7 — Asociar industrias con plataformas de NVIDIA

El examen espera que reconozcas las plataformas específicas de dominio de NVIDIA y la industria a la que sirve cada una.

**Paso 1.** Asociá cada plataforma (izquierda) con el caso de uso que mejor le corresponde (derecha). Escribí tus respuestas como pares, por ejemplo `1-c`.

| # | Plataforma | | Letra | Caso de uso |
|---|---|---|---|---|
| 1 | Clara / MONAI | | a | Pipeline de ciberseguridad que inspecciona el tráfico de red en busca de amenazas |
| 2 | BioNeMo | | b | Sistemas de recomendación a gran escala para e-commerce |
| 3 | DRIVE | | c | IA para imágenes médicas y dispositivos médicos |
| 4 | Isaac | | d | IA de voz: ASR, TTS, traducción |
| 5 | Metropolis | | e | Construir, personalizar y servir LLMs |
| 6 | Omniverse | | f | IA generativa para descubrimiento de fármacos y biología |
| 7 | Morpheus | | g | Desarrollo de vehículos autónomos, del data center al auto |
| 8 | Merlin | | h | Simulación, entrenamiento y despliegue de robótica |
| 9 | Riva | | i | IA de visión para ciudades, retail y fábricas |
| 10 | NeMo | | j | Simulación 3D y gemelos digitales industriales |
| 11 | cuOpt | | k | Ciencia de datos acelerada por GPU (APIs similares a pandas/scikit-learn) |
| 12 | RAPIDS | | l | Optimización de rutas y logística |

**Paso 2.** Verificá tus respuestas contra tu `use_cases.yaml` del Ejercicio 1. Cada plataforma debería aparecer en el `nvidia_stack` de al menos una entrada, excepto BioNeMo, que aparece una sola vez.

**Preguntas — Ejercicio 7**

7.1. Dá tus 12 pares.
7.2. Un banco quiere un chatbot que responda preguntas sobre sus propios documentos de políticas sin reentrenar un modelo. ¿Cómo se llama este patrón, y qué dos componentes de NVIDIA de la tabla y del catálogo usaría?
7.3. ¿Por qué NVIDIA ofrece plataformas *específicas de dominio* en lugar de solo bibliotecas CUDA genéricas? Respondé desde la perspectiva de un equipo de infraestructura.

---

## Respuestas

<details>
<summary>Hacé clic para expandir las respuestas</summary>

### Ejercicio 1

Salida esperada completa:

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

**1.1.** Los presupuestos de tiempo real se aplican al momento en que se toma una decisión: aprobar una transacción, frenar, rechazar una pieza. Ese momento siempre es inferencia. El entrenamiento ocurre offline, antes. Para cumplir presupuestos de milisegundos ponés un runtime optimizado en el medio: un engine compilado con TensorRT, servido por un servidor de inferencia como Triton, con dynamic batching acotado y el modelo residente en la memoria de la GPU.

**1.2.** El entrenamiento corre en el data center sobre grandes clusters de GPUs, usando datos de sensores recolectados por la flota y simulación (Omniverse / DRIVE Sim). La inferencia corre en el vehículo, en una computadora DRIVE embebida. Un viaje de ida y vuelta a un data center remoto agrega latencia de red y jitter, y depende de la conectividad. Un lazo de percepción crítico para la seguridad no puede tolerar ninguna de las dos cosas.

**1.3.** PyYAML lanza un `ScannerError` ("mapping values are not allowed here"), porque un `: ` sin comillas dentro de un valor se interpreta como un nuevo mapping. Si este catálogo alimenta automatización (checks de CI, planificación de capacidad, Helm values), un solo dos puntos sin comillas frena todo el pipeline. Poner esos valores entre comillas es obligatorio.

**1.4.** La entrada basada en LLM es el chatbot RAG de telecomunicaciones (NeMo/NIM). El reconocimiento de voz y la traducción (Riva) es IA generativa construida sobre modelos de voz; la traducción puede estar asistida por LLMs, pero los modelos ASR de Riva no son LLMs. El descubrimiento de fármacos (BioNeMo) es generativo pero usa foundation models de biología/química (modelos de proteínas y moléculas), no LLMs de texto.

### Ejercicio 2

**2.1.**

| Caso de uso | Modelo / precisión | Pesos | KV cache | Total | ¿Entra en 1 × 80 GB? |
|---|---|---|---|---|---|
| Chatbot de RR. HH. | 8B / FP16 | 16.0 GB | 17.2 GB | ~33 GB | Sí, con margen de sobra. También entraría en una GPU de 48 GB como la L40S. |
| Resumen legal | 70B / FP8 | 70.0 GB | 42.9 GB | ~113 GB | **No** |
| Asistente de código | 70B / INT4 | 35.0 GB | 42.9 GB | ~78 GB | Técnicamente sí, pero sin margen (necesita ~72 GB utilizables). Reducí la concurrencia o el contexto. |

Con `CONCURRENT_SEQS = 4` (Paso 3), la KV cache baja a 4.3 GB (8B) y 10.7 GB (70B). El caso 70B / FP8 queda en ~81 GB, todavía un poco por encima. El caso 70B / INT4 queda en ~46 GB y entra holgadamente.

**2.2.**
- **Tensor parallelism en 2 GPUs** (TP=2). Cada GPU guarda la mitad de los pesos y la mitad de los KV heads. Costo: una segunda GPU, más la necesidad de una interconexión rápida (NVLink).
- **Menor concurrencia o contexto máximo más corto.** Costo: menos throughput por GPU, o documentos largos truncados. Esto perjudica a un caso de uso de resumen.
- **Cuantizar la KV cache a FP8.** Esto la reduce a la mitad, a ~21.5 GB, para un total de ~92 GB, así que todavía necesita más reducción. Costo: una posible pequeña pérdida de precisión.

Pasar los pesos a INT4 también ayuda, a un costo de calidad que hay que validar para textos legales.

**2.3.** El tamaño de la KV cache depende de `layers × kv_heads × head_dim`, no del total de parámetros. Ambos modelos usan GQA con 8 KV heads de dimensión 128, así que la única diferencia es la cantidad de capas: 80 / 32 = 2.5×. La mayoría de los parámetros extra están en matrices de MLP y de proyección de atención más anchas, y esas no agregan caché por token.

**2.4.** La cuantización de pesos achica el componente de **pesos**. La KV cache no cambia a menos que habilites por separado la cuantización de la KV cache. Por eso los casos de uso de contexto largo y alta concurrencia pueden quedarse sin memoria aun después de cuantizar los pesos.

### Ejercicio 3

**3.1.**
- **A (chatbot):** principalmente latencia (time to first token y tiempo por token de salida), con un throughput de 50 req/s. Técnica: in-flight (continuous) batching con respuestas en streaming, como en TensorRT-LLM / NIM.
- **B (virtual screening):** throughput. Nadie espera por una sola molécula. Técnica: tamaños de batch grandes y muchas GPUs ejecutándose como un job batch planificado.
- **C (fraude):** latencia de cola estricta (p99 ≤ 10 ms) con tasas de solicitudes muy altas. Técnica: engines de batch pequeño y baja latencia (TensorRT) y dynamic batching con un retardo máximo de cola ajustado, más suficientes réplicas para absorber las 500 solicitudes en vuelo.

**3.2.** 10,000,000 / 2,000 = 5,000 s ≈ 83 minutos en 1 GPU. El job es elástico y tolerante a plazos. Un cluster compartido con un scheduler batch puede llenar con él la capacidad ociosa de GPU y hacerle preemption a favor del trabajo interactivo. Las GPUs dedicadas quedarían ociosas entre campañas de screening.

**3.3.** El batching amortiza los lanzamientos de kernels y las lecturas de pesos entre solicitudes, lo que sube la utilización de la GPU y las transacciones/s. Sin embargo, cada solicitud puede esperar en la cola a que se forme el batch, y esa espera se suma directamente a la latencia. El retardo máximo de cola tiene que quedar bien por debajo del presupuesto p99 de 10 ms.

### Ejercicio 4

**4.1.** **GPU Feature Discovery** (junto con Node Feature Discovery) crea los labels `nvidia.com/gpu.*`. El **NVIDIA device plugin** anuncia el extended resource `nvidia.com/gpu` al kubelet para que el scheduler pueda asignarlo. El operator también instala el driver y el Container Toolkit, que hacen que la GPU sea utilizable dentro del contenedor.

**4.2.** Pedí `nvidia.com/gpu: 2` (o más) en un nodo cuyas GPUs estén conectadas por NVLink. El engine tiene que ejecutar entonces **tensor parallelism** (o pipeline parallelism), para que el modelo se reparta entre las GPUs del Pod.

**4.3.** **Multi-Instance GPU (MIG)**, configurado a través del MIG manager del operator. Divide una H100 en instancias aisladas por hardware (por ejemplo `1g.10gb`). Cada instancia tiene su propia porción de memoria y cómputo, así que varios modelos pequeños pueden compartir una GPU con aislamiento de rendimiento. El time-slicing es la alternativa, pero no da aislamiento de memoria ni de fallos.

### Ejercicio 5

**5.1.** Con los números ilustrativos:
- Batch 1: 2,450 qps × 1 = **~2,450 imágenes/s**, con ~0.4 ms de latencia.
- Batch 32: 410.55 qps × 32 = **~13,138 imágenes/s**, con ~2.4 ms por batch.

La cámara de línea necesita una decisión de punta a punta en 5 ms que incluye captura, preprocesamiento y actuación, y ve una pieza a la vez. Usá **batch 1** (o un batch pequeño que coincida con la cantidad de cámaras). El re-escaneo del archivo es puro throughput, así que usá **batch 32** o más.

Tus números reales van a ser distintos. El patrón se mantiene: los batches más grandes suben el throughput total y suben la latencia por solicitud.

**5.2.** Latencia y determinismo: no hay viaje de ida y vuelta por la WAN en el lazo de rechazo. Ancho de banda: transmitir video crudo de alta resolución desde muchas cámaras a un data center es caro. Resiliencia: la línea sigue funcionando si se cae el enlace. La residencia de los datos y la privacidad también importan, especialmente para el video de ciudades inteligentes. El data center sigue entrenando y reentrenando los modelos.

**5.3.** La construcción del engine ejecuta auto-tuning y puede tardar de segundos a minutos. Construirlo al iniciar el Pod infla el tiempo de arranque en frío y agrega carga de CPU/GPU al escalar. Construí el engine por adelantado en CI, para cada arquitectura de GPU y versión de TensorRT objetivo, guardalo como artefacto, y hacé que los Pods de serving solo lo carguen. Los engines son específicos de la arquitectura de GPU y de la versión de TensorRT, así que la matriz de builds tiene que coincidir con la flota.

### Ejercicio 6

**6.1.** (a) 70 GB / 1 GB/s = **70 s**. (b) 70 / 7 = **10 s**. En el caso (a), el escalado reacciona lento. Durante un pico de tráfico, las réplicas nuevas tardan más de un minuto en quedar Ready. Las colas crecen, y el **time to first token / latencia p99** se degrada para los usuarios. Pre-descargar o cachear los pesos en NVMe local, o mantener réplicas calientes, lo mitiga.

**6.2.** Entrenar sobre 400 TB durante 100 épocas es un patrón **intensivo en lectura**: el dataset se lee completo en cada época. Para imágenes, las lecturas suelen ser muchos archivos de tamaño mediano accedidos en orden mezclado (aleatorio). La recomendación del blog: usar un nivel de almacenamiento paralelo/de alto throughput dimensionado para el ancho de banda de lectura agregado de todos los nodos con GPU, cachear los datos calientes cerca de las GPUs (NVMe local) y usar data loaders eficientes. GPUDirect Storage evita los bounce buffers de CPU en el camino de los datos. El objetivo es que las GPUs nunca esperen por I/O.

**6.3.** Cualquiera de estas dos:
- **Checkpointing asíncrono:** tomar un snapshot en la memoria del host o en NVMe local y después volcarlo al almacenamiento compartido en segundo plano mientras el entrenamiento continúa.
- **Checkpoints fragmentados/distribuidos:** cada rank escribe su fragmento en paralelo, lo que aprovecha el ancho de banda agregado.
- **Hacer checkpoints con menos frecuencia**, eligiendo el intervalo según la tasa de fallos medida.
- **Guardar solo los pesos** en hitos intermedios, cuando no hace falta una reanudación exacta.

### Ejercicio 7

**7.1.** `1-c, 2-f, 3-g, 4-h, 5-i, 6-j, 7-a, 8-b, 9-d, 10-e, 11-l, 12-k`

**7.2.** **Retrieval-Augmented Generation (RAG).** Los documentos se convierten en embeddings y se indexan. En el momento de la consulta, se recuperan los pasajes relevantes y se agregan al prompt, así el LLM responde a partir de datos privados actuales sin reentrenamiento. Componentes: **NeMo** (con sus herramientas de retriever/guardrails) y los microservicios **NIM** para el LLM y los modelos de embeddings, servidos sobre **Triton** / TensorRT-LLM.

**7.3.** Las plataformas de dominio empaquetan modelos preentrenados, pipelines optimizados y arquitecturas de referencia para una vertical: formatos de imágenes médicas en Clara, fusión de sensores en DRIVE, decodificación de video en Metropolis/DeepStream. Para un equipo de infraestructura esto significa menos stacks a medida para construir y validar, imágenes de contenedor probadas (desde NGC) con perfiles de recursos predecibles, y menor tiempo hasta producción. El trade-off es un acoplamiento más estrecho con el ecosistema de software de NVIDIA. Todas estas plataformas siguen corriendo sobre la misma base: GPUs expuestas a través del driver, el Container Toolkit y el GPU Operator.

</details>