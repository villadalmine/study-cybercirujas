# Ejercicios guiados — Tema 1.7: Componentes de software del ciclo de vida de desarrollo y despliegue de IA

**Certificación:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Peso del objetivo:** 4.75%

Estos ejercicios siguen a un modelo pequeño a lo largo del stack de software de NVIDIA:

**preparación de datos → framework de entrenamiento → formato de intercambio → optimización → serving → orquestación → monitoreo**

Vas a ver la función de cada componente y en qué punto le pasa el trabajo al siguiente. Varios pasos corren en una laptop sin GPU, así que igual podés razonar qué aporta una GPU.

## Tracks del lab

| Track | Requisitos | Ejercicios |
|---|---|---|
| **A — Solo CPU** | Docker, Python 3.10+, `curl`, ~25 GB de disco libre para imágenes de NGC | 1, 3 (parcialmente), 4, 5, 7, 10 |
| **B — Host con GPU** | Track A más una GPU NVIDIA, el driver de NVIDIA y el NVIDIA Container Toolkit | 1–7, 9, 10 |
| **C — Kubernetes** | Un cluster con al menos un worker node con GPU, `kubectl`, `helm`, `jq` | 8 |

Los tags de los contenedores de NGC siguen el esquema de releases `YY.MM`, por ejemplo `24.08`. Elegí **un** release actual del catálogo de NGC (https://catalog.ngc.nvidia.com) y usalo en todos lados:

```bash
export NGC_TAG=24.08          # replace with a current release; keep it identical across images
mkdir -p ~/lab-1.7 && cd ~/lab-1.7
```

Todas las imágenes de NGC de un mismo release comparten las mismas versiones de CUDA / cuDNN / TensorRT. Mezclar tags es la forma más común de romper el Ejercicio 6.

**Referencias oficiales usadas a lo largo del lab:**
- Guía de estudio NVIDIA AI Infrastructure and Operations: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- Curso AI Infrastructure & Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- TensorRT: https://developer.nvidia.com/tensorrt
- Panorama de inferencia de IA: https://developer.nvidia.com/topics/ai/ai-inference
- Escalar el almacenamiento para IA: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- Casos de uso de LLM: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- GPU Operator: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- Guía de usuario de Triton Inference Server: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/
- Documentación del GPU Operator: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/
- Documentación de NVIDIA NIM: https://docs.nvidia.com/nim/

---

## Ejercicio 1 — Mapear el stack sobre el ciclo de vida (ejercicio en papel, todos los tracks)

El examen espera que ubiques un componente nombrado en la fase correcta del ciclo de vida. También tenés que distinguir componentes que se parecen, como TensorRT vs. Triton o Triton vs. NIM.

**Paso 1.1** Copiá esta tabla en un archivo `~/lab-1.7/lifecycle.md`. Para cada componente, completá la **fase** y un **rol en una línea**. Usá estas fases:

- **P1** Preparación y curado de datos
- **P2** Desarrollo, entrenamiento y fine-tuning del modelo
- **P3** Optimización del modelo
- **P4** Serving de inferencia y despliegue
- **P5** Orquestación y scheduling de infraestructura
- **P6** Monitoreo y gestión
- **X** Transversal: distribución, licenciamiento o soporte

| # | Componente | Fase | Rol (una línea) |
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

**Paso 1.2** Dibujá los traspasos como una cadena de flechas. Etiquetá cada flecha con el **artefacto** que pasa entre los dos componentes, por ejemplo un "dataset Parquet" o un "checkpoint".

**Preguntas**

1.1. TensorRT y Triton aparecen los dos en diagramas de "inferencia". En una oración cada uno, ¿qué hace cada uno? ¿Se puede usar uno sin el otro?

1.2. NIM empaqueta varios componentes de tu tabla en un solo contenedor. ¿Cuáles, y qué agrega NIM por encima?

1.3. ¿Qué dos componentes de la tabla importan principalmente cuando **un job abarca muchas GPUs o muchos nodos**? ¿Por qué importan a esa escala?

1.4. Un colega dice: "NVIDIA AI Enterprise es un framework, como PyTorch." ¿Qué está mal en esa afirmación?

---

## Ejercicio 2 — Inspeccionar las capas de software del host con GPU (Track B)

La base del stack es el driver del kernel. Encima está la integración con el container runtime, y las bibliotecas de CUDA en espacio de usuario van al final. En un nodo de producción, las bibliotecas de espacio de usuario normalmente viven dentro del contenedor, no en el host.

**Paso 2.1** Consultá el driver:

```bash
nvidia-smi
```

Salida esperada (encabezado; los valores van a diferir):

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

**Paso 2.2** Verificá si hay un CUDA toolkit instalado en el host:

```bash
nvcc --version || echo "no CUDA toolkit on host"
```

**Paso 2.3** Verificá la capa de integración con contenedores:

```bash
nvidia-ctk --version
docker info 2>/dev/null | grep -i -A2 runtimes
```

**Paso 2.4** Ejecutá `nvidia-smi` desde una imagen de Ubuntu pelada que no contiene ningún software de NVIDIA:

```bash
docker run --rm --gpus all ubuntu:22.04 nvidia-smi -L
```

Salida esperada:

```
GPU 0: NVIDIA L4 (UUID: GPU-3f0c...)
```

**Preguntas**

2.1. `nvidia-smi` imprimió `CUDA Version: 12.4`, pero puede que `nvcc` no exista en el host. ¿Qué significa realmente el campo "CUDA Version"?

2.2. En el Paso 2.4, la imagen `ubuntu:22.04` no contiene el binario `nvidia-smi` ni las bibliotecas del driver. ¿Cómo funcionó el comando?

2.3. ¿Por qué es práctica común mantener el host mínimo (solo driver más Container Toolkit) y distribuir CUDA, cuDNN y los frameworks dentro de contenedores?

2.4. Un contenedor construido con CUDA 12.6 falla en este host con `CUDA driver version is insufficient for CUDA runtime version`. ¿Qué capa tiene que cambiar, y en qué dirección?

---

## Ejercicio 3 — Contenedores de frameworks de NGC como entorno de entrenamiento (Track A parcial, Track B completo)

Los contenedores de frameworks de NGC son bundles validados mensualmente. Cada uno contiene un framework, CUDA, cuDNN, NCCL y otras bibliotecas ajustadas para funcionar juntas. Son el punto de partida por defecto para P2.

**Paso 3.1** Descargá el contenedor de PyTorch. Es grande; esperá varios GB.

```bash
docker pull nvcr.io/nvidia/pytorch:${NGC_TAG}-py3
```

**Paso 3.2** Imprimí las versiones de las bibliotecas incluidas en la imagen:

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

En el Track A, sacá `--gpus all`. Salida esperada en el Track B (valores ilustrativos):

```
torch 2.5.0a0+872d972e41.nv24.08
cuda 12.6
cudnn 90300
nccl (2, 22, 3)
gpus 1
```

**Paso 3.3** Ejecutá un paso de entrenamiento mínimo en la GPU para confirmar el camino completo, del framework a cuDNN/cuBLAS y al driver:

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

Salida esperada (los valores de loss varían):

```
step=0 device=cuda loss=1.0832
step=1 device=cuda loss=1.0410
step=2 device=cuda loss=1.0057
```

**Preguntas**

3.1. El string de versión de torch termina en `.nv24.08`. ¿Qué te dice eso, y dónde buscarías las versiones exactas de CUDA / cuDNN / NCCL antes de actualizar?

3.2. ¿Por qué la documentación de NGC recomienda `--ipc=host` (o un `--shm-size` grande) para los contenedores de PyTorch?

3.3. NCCL apareció en la lista de versiones aunque el script de entrenamiento nunca lo llama. ¿Cuándo se vuelve crítico NCCL, y qué caminos de hardware aprovecha?

3.4. Supongamos que el equipo tiene que hacer fine-tuning de un LLM en lugar de un MLP chico. ¿Qué framework de NVIDIA del Ejercicio 1 usaría en lugar de PyTorch pelado, y qué aporta?

---

## Ejercicio 4 — Producir un artefacto de modelo portable (Tracks A y B)

El traspaso del entrenamiento (P2) a la optimización y el serving (P3/P4) suele ser un artefacto neutral respecto del framework, como **ONNX**. Acá construís directamente un modelo ONNX mínimo. Calcula `OUTPUT0 = INPUT0 · W + B`, así que cada resultado posterior se puede verificar a mano.

**Paso 4.1** Creá un entorno de Python aislado:

```bash
cd ~/lab-1.7
python3 -m venv .venv && . .venv/bin/activate
pip install --quiet numpy onnx onnxruntime
```

**Paso 4.2** Creá `make_model.py`:

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

**Paso 4.3** Validá el modelo localmente con ONNX Runtime antes de pasárselo a cualquier servidor:

```bash
python - <<'EOF'
import numpy as np, onnxruntime as ort
s = ort.InferenceSession("model.onnx", providers=["CPUExecutionProvider"])
x = np.array([[1, 2, 3, 4], [0, 0, 0, 1]], dtype=np.float32)
print(s.get_inputs()[0].name, s.get_inputs()[0].shape)
print(s.run(None, {"INPUT0": x})[0])
EOF
```

Salida esperada:

```
INPUT0 ['batch', 4]
[[12.5  0.5]
 [ 2.5 -1.5]]
```

**Preguntas**

4.1. Verificá a mano la primera fila de salida `[12.5, 0.5]`.

4.2. ¿Por qué el modelo declara la primera dimensión como `"batch"` en lugar de un `1` fijo? ¿Qué se rompería en el Ejercicio 5 si fuera fija?

4.3. ¿Cuál es el beneficio de exportar a ONNX en lugar de servir el checkpoint nativo de PyTorch, y cuál es un riesgo de la conversión?

---

## Ejercicio 5 — Servir el modelo con Triton Inference Server (Tracks A y B)

Triton es un servidor de inferencia multi-framework. Carga modelos desde un **model repository** y expone endpoints HTTP/REST y gRPC usando el protocolo KServe v2, además de métricas de Prometheus. También agrega funcionalidades de scheduling como dynamic batching e instancias concurrentes de modelos.

**Paso 5.1** Armá la estructura del model repository:

```bash
cd ~/lab-1.7
mkdir -p model_repository/tiny_linear/1
cp model.onnx model_repository/tiny_linear/1/model.onnx
```

Árbol resultante:

```
model_repository/
└── tiny_linear/
    ├── config.pbtxt
    └── 1/
        └── model.onnx
```

**Paso 5.2** Creá `model_repository/tiny_linear/config.pbtxt`. Esto es formato de texto de protobuf, no YAML:

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

**Paso 5.3** Iniciá Triton. En el Track B podés agregar `--gpus all`. El instance group igual fija este modelo a la CPU.

```bash
docker run -d --name triton --rm \
  -p 8000:8000 -p 8001:8001 -p 8002:8002 \
  -v "$PWD/model_repository:/models" \
  nvcr.io/nvidia/tritonserver:${NGC_TAG}-py3 \
  tritonserver --model-repository=/models

sleep 15; docker logs triton 2>&1 | grep -A5 "Model  "
```

Fragmento de log esperado:

```
+-------------+---------+--------+
| Model       | Version | Status |
+-------------+---------+--------+
| tiny_linear | 1       | READY  |
+-------------+---------+--------+
```

**Paso 5.4** Verificá el health y la metadata del modelo:

```bash
curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/v2/health/ready
curl -s localhost:8000/v2/models/tiny_linear | python3 -m json.tool
```

Salida esperada:

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

**Paso 5.5** Enviá un request de inferencia usando el protocolo KServe v2:

```bash
curl -s -X POST localhost:8000/v2/models/tiny_linear/infer \
  -H 'Content-Type: application/json' \
  -d '{"inputs":[{"name":"INPUT0","shape":[2,4],"datatype":"FP32","data":[1,2,3,4,0,0,0,1]}]}'
echo
```

Salida esperada:

```
{"model_name":"tiny_linear","model_version":"1","outputs":[{"name":"OUTPUT0","datatype":"FP32","shape":[2,2],"data":[12.5,0.5,2.5,-1.5]}]}
```

**Paso 5.6** Leé el endpoint de métricas de Prometheus:

```bash
curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|count|exec_count)'
```

Salida esperada:

```
nv_inference_request_success{model="tiny_linear",version="1"} 1
nv_inference_count{model="tiny_linear",version="1"} 2
nv_inference_exec_count{model="tiny_linear",version="1"} 1
```

**Preguntas**

5.1. ¿Qué sirve cada uno de los tres puertos (8000, 8001, 8002)?

5.2. Con `max_batch_size: 8`, ¿por qué los `dims` en `config.pbtxt` dicen `[ 4 ]` mientras que la metadata reporta `[-1, 4]`?

5.3. Después del Paso 5.5, `nv_inference_count` es 2 pero `nv_inference_request_success` es 1. Explicá la diferencia.

5.4. ¿Para qué sirve el directorio `1/`? ¿Cómo desplegarías una nueva versión del modelo sin downtime?

5.5. ¿Qué cambiarías en `config.pbtxt` para correr dos copias de este modelo en la GPU 0?

---

## Ejercicio 6 — Optimizar con TensorRT (Track B)

TensorRT es un SDK que compila una red entrenada en un **engine** optimizado para una GPU específica. Lo hace mediante fusión de capas y tensores, auto-tuning de kernels, calibración de precisión (FP16/INT8/FP8) y planificación de memoria. Después Triton sirve ese engine a través de su backend de TensorRT.

**Paso 6.1** Construí un engine FP16 con `trtexec`. Usá el **mismo `NGC_TAG`** que la imagen de Triton para que coincidan las versiones de TensorRT.

```bash
cd ~/lab-1.7
docker run --rm --gpus all -v "$PWD:/work" -w /work \
  nvcr.io/nvidia/tensorrt:${NGC_TAG}-py3 \
  trtexec --onnx=model.onnx --saveEngine=model.plan --fp16 \
          --minShapes=INPUT0:1x4 --optShapes=INPUT0:4x4 --maxShapes=INPUT0:8x4
```

Final esperado de la salida (números ilustrativos):

```
[I] === Performance summary ===
[I] Throughput: 41235.6 qps
[I] Latency: min = 0.0141 ms, max = 0.0712 ms, mean = 0.0182 ms, median = 0.0175 ms
...
&&&& PASSED TensorRT.trtexec [TensorRT v100300] # trtexec --onnx=model.onnx --saveEngine=model.plan --fp16 ...
```

**Paso 6.2** Agregá el engine como un segundo modelo en el repository:

```bash
mkdir -p model_repository/tiny_linear_trt/1
cp model.plan model_repository/tiny_linear_trt/1/model.plan
```

Creá `model_repository/tiny_linear_trt/config.pbtxt`:

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

**Paso 6.3** Reiniciá Triton con acceso a la GPU y probá el engine:

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

Salida esperada. La aritmética FP16 puede introducir diferencias mínimas en modelos reales; en este es exacta.

```
{"model_name":"tiny_linear_trt","model_version":"1","outputs":[{"name":"OUTPUT0","datatype":"FP32","shape":[1,2],"data":[12.5,0.5]}]}
```

**Preguntas**

6.1. Copiás `model.plan` a un servidor con otra arquitectura de GPU, o a una imagen de Triton construida sobre otra versión de TensorRT. ¿Qué pasa, y cuál es la práctica correcta?

6.2. ¿Por qué `trtexec` necesitó `--minShapes/--optShapes/--maxShapes`? ¿Cómo se relacionan con `max_batch_size: 8`?

6.3. El engine se construyó con `--fp16`, pero la config de Triton igual declara I/O `TYPE_FP32`. ¿Es una contradicción?

6.4. INT8 normalmente necesita algo que FP16 no necesita. ¿Qué es, y por qué?

6.5. Para LLMs, ¿qué biblioteca de NVIDIA extiende TensorRT? Nombrá dos optimizaciones específicas para LLMs que agrega.

---

## Ejercicio 7 — Medir el rendimiento del serving con `perf_analyzer` (Tracks A y B)

`perf_analyzer` viene en la imagen **SDK** de Triton. Genera carga y reporta throughput y latencia. Así es como validás una configuración de serving antes de producción.

**Paso 7.1** Hacé un barrido de concurrencia contra el modelo ONNX/CPU. Usá `--net=host` para que el cliente llegue a `localhost:8000`.

```bash
docker run --rm --net=host nvcr.io/nvidia/tritonserver:${NGC_TAG}-py3-sdk \
  perf_analyzer -m tiny_linear -u localhost:8000 --concurrency-range 1:8:1
```

Resumen esperado (números ilustrativos):

```
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 2850.4 infer/sec, latency 349 usec
Concurrency: 2, throughput: 4105.7 infer/sec, latency 486 usec
...
Concurrency: 8, throughput: 6920.1 infer/sec, latency 1155 usec
```

**Paso 7.2** Verificá si realmente ocurrió dynamic batching:

```bash
curl -s localhost:8002/metrics | grep -E '^nv_inference_(count|exec_count)\{model="tiny_linear"'
```

Salida esperada (conteos ilustrativos; lo que importa es la proporción):

```
nv_inference_count{model="tiny_linear",version="1"} 412880
nv_inference_exec_count{model="tiny_linear",version="1"} 98311
```

**Paso 7.3** (Track B) Repetí el Paso 7.1 con `-m tiny_linear_trt` y compará.

**Preguntas**

7.1. Calculá el tamaño de batch promedio que ejecutó el servidor en el Paso 7.2. ¿Qué demuestra un valor mayor a 1?

7.2. El throughput crece con la concurrencia mientras que la latencia también crece. ¿Qué trade-off controla `max_queue_delay_microseconds`?

7.3. En este modelo de juguete el engine de TensorRT puede apenas superar a ONNX Runtime, o incluso perder. ¿Por qué? ¿Qué tipo de modelo muestra las grandes ganancias de TensorRT?

---

## Ejercicio 8 — Orquestar GPUs en Kubernetes con el GPU Operator (Track C)

En Kubernetes, el GPU Operator automatiza el software por nodo que el Ejercicio 2 instaló a mano. Gestiona el driver, el Container Toolkit, el device plugin, GPU Feature Discovery, DCGM Exporter, MIG Manager y los validadores, y se configura mediante un único custom resource `ClusterPolicy`.

**Paso 8.1** Instalá el operator. Si los nodos ya tienen un driver instalado, agregá `--set driver.enabled=false`.

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm install --wait --generate-name \
  -n gpu-operator --create-namespace \
  nvidia/gpu-operator
```

**Paso 8.2** Mirá cómo convergen los componentes:

```bash
kubectl get pods -n gpu-operator
```

Salida esperada (nombres abreviados, hashes de los pods omitidos):

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

**Paso 8.3** Confirmá que el nodo ahora anuncia GPUs como extended resource, junto con labels de GPU Feature Discovery:

```bash
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name)\t\(.status.allocatable["nvidia.com/gpu"] // "0")"'
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count
```

Salida esperada (ilustrativa):

```
gpu-worker-1	1
NAME           STATUS   ROLES    AGE   VERSION   GPU.PRODUCT   GPU.COUNT
gpu-worker-1   Ready    <none>   20d   v1.30.4   NVIDIA-L4     1
```

**Paso 8.4** Programá un workload con GPU. Guardalo como `cuda-vectoradd.yaml`:

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

Salida esperada:

```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

**Paso 8.5** Leé la telemetría de GPU desde DCGM Exporter:

```bash
kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
sleep 2
curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_UTIL|FB_USED|GPU_TEMP|POWER_USAGE)' | head
kill %1
```

Salida esperada (labels recortados):

```
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-3f0c...",modelName="NVIDIA L4",Hostname="gpu-worker-1"} 0
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-3f0c...",modelName="NVIDIA L4",Hostname="gpu-worker-1"} 0
DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-3f0c...",modelName="NVIDIA L4",Hostname="gpu-worker-1"} 37
DCGM_FI_DEV_POWER_USAGE{gpu="0",UUID="GPU-3f0c...",modelName="NVIDIA L4",Hostname="gpu-worker-1"} 16.2
```

**Paso 8.6** Inspeccioná la única fuente de configuración:

```bash
kubectl get clusterpolicy -o jsonpath='{.items[0].status.state}{"\n"}'
kubectl get clusterpolicy -o yaml | grep -E '^\s+(driver|toolkit|devicePlugin|dcgmExporter|migManager|gfd):' -A1 | head -30
```

Primera línea esperada: `ready`.

**Preguntas**

8.1. Mapeá cada pod del Paso 8.2 a su función. ¿Cuál hace que `nvidia.com/gpu` aparezca en `allocatable`?

8.2. ¿Por qué `nvidia.com/gpu` se especifica bajo `limits`? ¿Puede un pod pedir media GPU de esta forma? ¿Qué mecanismos permiten compartir GPUs?

8.3. Sin el GPU Operator, ¿qué tendría que hacer un admin en cada nodo con GPU nuevo? ¿Por qué eso se vuelve un problema a escala de flota?

8.4. DCGM Exporter reporta métricas a nivel de dispositivo, mientras que Triton reporta `nv_inference_*`. ¿Por qué necesitás las dos en un dashboard de producción?

8.5. ¿Cuándo elegirías Slurm, o Base Command Manager con Slurm, en lugar de Kubernetes para la fase de entrenamiento? ¿Dónde encaja Run:ai?

---

## Ejercicio 9 — Desplegar un LLM como microservicio NVIDIA NIM (Track B, opcional)

NIM empaqueta un modelo, un engine de inferencia optimizado (para LLMs, típicamente TensorRT-LLM, con otros runtimes como alternativa) y una capa de serving en un solo contenedor. Expone una API estándar de la industria; para LLMs, esa API es compatible con OpenAI. Necesitás una API key de NGC y una GPU con memoria suficiente para el modelo elegido.

**Paso 9.1** Detené Triton (se reutiliza el puerto 8000) y después iniciá sesión en NGC:

```bash
docker stop triton
export NGC_API_KEY="<your-ngc-api-key>"
echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin
```

**Paso 9.2** Ejecutá el contenedor de NIM:

```bash
mkdir -p ~/.cache/nim
docker run -d --name nim --rm --gpus all --shm-size=16GB \
  -e NGC_API_KEY \
  -v ~/.cache/nim:/opt/nim/.cache \
  -p 8000:8000 \
  nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
docker logs -f nim      # wait until the server reports it is listening, then Ctrl+C
```

**Paso 9.3** Consultalo con la API compatible con OpenAI:

```bash
curl -s localhost:8000/v1/models | python3 -m json.tool | grep '"id"'
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "meta/llama-3.1-8b-instruct",
  "messages": [{"role": "user", "content": "In one sentence, what does TensorRT do?"}],
  "max_tokens": 64
}' | python3 -m json.tool | grep -A2 '"content"'
```

Salida esperada (el texto generado va a variar):

```
        "id": "meta/llama-3.1-8b-instruct",
            "content": "TensorRT is an NVIDIA SDK that optimizes trained neural networks for high-performance, low-latency inference on NVIDIA GPUs.",
            "role": "assistant"
```

**Preguntas**

9.1. En el primer arranque, NIM tarda un rato antes de empezar a servir. ¿Qué está haciendo? ¿Por qué es importante el volumen `~/.cache/nim`?

9.2. Compará el Ejercicio 5 (Triton más un modelo que construiste vos) con el Ejercicio 9 (NIM). ¿Qué tuviste que hacer vos en cada caso?

9.3. El blog sobre LLMs enumera casos de uso como asistentes de chat, generación de código, resumen y búsqueda/RAG. Para una aplicación RAG, ¿qué otros componentes de software se suman al ciclo de vida además del NIM del LLM?

---

## Ejercicio 10 — Escenarios estilo examen (todos los tracks)

Respondé cada escenario con el/los **componente(s)** y una **justificación de una oración**.

10.1. Los data scientists pasan el 70% de cada epoch esperando el ETL con pandas limitado por CPU y la decodificación de JPEG. Las GPUs están al 30% de utilización.

10.2. Un job de entrenamiento multi-nodo escala mal más allá de 4 nodos. El equipo de storage informa que el filesystem compartido se satura cada vez que todos los ranks escriben checkpoints al mismo tiempo.

10.3. Un equipo tiene que servir un modelo de TensorFlow, uno de PyTorch y uno de XGBoost desde un único endpoint, con métricas y batching por modelo.

10.4. Una empresa quiere versiones con soporte, parches de seguridad y certificadas para producción del stack de software de IA de NVIDIA, con ramas de largo plazo.

10.5. Un equipo de computer vision quiere hacer fine-tuning de un modelo de detección preentrenado con sus propias imágenes, con un mínimo de código.

10.6. Operaciones necesita alertar cuando una GPU muestra errores XID o ECC en aumento, antes de que fallen los jobs.

10.7. No se está cumpliendo un SLA de latencia para un chatbot basado en un LLM. El modelo actualmente corre en PyTorch en modo eager.

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

Tabla completa:

| # | Componente | Fase | Rol |
|---|---|---|---|
| 1 | RAPIDS | P1 (también ML clásico en P2) | Dataframes (cuDF), ML (cuML) y analítica de grafos acelerados por GPU; APIs tipo pandas/scikit-learn |
| 2 | DALI | P1 / P2 | Pipeline de carga y aumentación de datos acelerado por GPU que alimenta entrenamiento e inferencia |
| 3 | NeMo Curator | P1 | Curado acelerado por GPU de grandes datasets de texto/multimodales para LLMs (dedup, filtrado, eliminación de PII) |
| 4 | PyTorch / TF / JAX | P2 | Frameworks de deep learning usados para definir y entrenar modelos |
| 5 | CUDA, cuDNN, cuBLAS | P2–P4 (base) | Modelo de programación y bibliotecas de primitivas aceleradas por GPU que llaman los frameworks |
| 6 | NCCL | P2 | Colectivas multi-GPU/multi-nodo (all-reduce, all-gather) sobre NVLink, PCIe, InfiniBand/RoCE |
| 7 | NeMo framework | P2 | Framework de punta a punta para construir, preentrenar, personalizar y alinear IA generativa/LLMs |
| 8 | TAO Toolkit | P2 | Transfer learning / fine-tuning low-code de modelos preentrenados (principalmente de visión) |
| 9 | TensorRT | P3 | Compila modelos entrenados en engines de inferencia optimizados (fusión, precisión, auto-tuning de kernels) |
| 10 | TensorRT-LLM | P3 / P4 | Biblioteca basada en TensorRT para inferencia de LLMs (in-flight batching, paged KV cache, cuantización, tensor parallelism) |
| 11 | Triton | P4 | Servidor de inferencia multi-framework: model repository, HTTP/gRPC, dynamic batching, métricas |
| 12 | NIM | P4 | Microservicios de inferencia preconstruidos y optimizados por modelo, con APIs estándar |
| 13 | GPU Operator | P5 | Automatiza el stack de software de los nodos con GPU en Kubernetes |
| 14 | Network Operator | P5 | Automatiza componentes de red (RDMA, SR-IOV, drivers de GPUDirect RDMA) en Kubernetes |
| 15 | Slurm | P5 | Scheduler batch de HPC, común para entrenamiento multi-nodo a gran escala |
| 16 | Run:ai | P5 | Capa de orquestación/scheduling de GPUs sobre Kubernetes: cuotas, GPUs fraccionales, fair-share, pooling |
| 17 | Base Command Manager | P5 / P6 | Aprovisionamiento y gestión de clusters de IA (despliega Kubernetes y/o Slurm, monitorea nodos) |
| 18 | DCGM / Exporter | P6 | Salud, diagnósticos y telemetría de GPUs; el exporter lo expone a Prometheus |
| 19 | NGC Catalog | X | Registro de contenedores optimizados para GPU, modelos preentrenados, Helm charts, SDKs |
| 20 | NVIDIA AI Enterprise | X | Suite de software licenciada, con soporte y mantenimiento de seguridad (frameworks, Triton, TensorRT, NIM, operators) |
| 21 | Container Toolkit | P5 (base) | Permite que los container runtimes (Docker, containerd, CRI-O) expongan GPUs y bibliotecas del driver a los contenedores |

Cadena de traspasos de ejemplo:
datos crudos → **(Parquet limpio / shards tokenizados)** → entrenamiento con el framework → **(checkpoint)** → export → **(ONNX)** → TensorRT → **(engine `.plan`)** → Triton/NIM → **(endpoint HTTP/gRPC)** → clientes. Las métricas de DCGM y Triton alimentan Prometheus a lo largo de toda la cadena.

**1.1** TensorRT es un *optimizador/compilador y runtime* que produce un engine rápido para una GPU específica. Triton es un *sistema de serving* que expone modelos por red y gestiona batching, versiones e instancias. Son independientes. Triton puede servir modelos ONNX, PyTorch o Python sin TensorRT, y un engine de TensorRT se puede embeber directamente en una aplicación C++/Python sin Triton. En producción suelen combinarse, como en el Ejercicio 6.

**1.2** Un NIM de LLM típicamente incluye un engine optimizado (TensorRT-LLM, con otros runtimes como alternativa), una capa de serving (Triton o un servidor equivalente) y los pesos del modelo o referencias a ellos, sobre las bibliotecas de CUDA. Por encima de eso, NIM agrega:
- selección automática de un perfil optimizado para la GPU detectada,
- una API estándar de la industria (compatible con OpenAI para LLMs),
- endpoints de health/métricas,
- empaquetado y soporte empresarial a través de NVIDIA AI Enterprise.

**1.3** NCCL y el Network Operator (con el fabric InfiniBand/RoCE subyacente). El entrenamiento data-parallel y model-parallel sincroniza gradientes o activaciones en cada paso. NCCL elige el camino más rápido teniendo en cuenta la topología (NVLink dentro de un nodo, GPUDirect RDMA entre nodos), y el Network Operator pone esos caminos RDMA a disposición de los pods. Colectivas deficientes hacen que las GPUs queden esperando la comunicación.

**1.4** NVIDIA AI Enterprise no es un framework. Es una **suite de software y oferta de licencia/soporte**: un conjunto curado, probado y con parches de seguridad de frameworks, SDKs y operators (incluidos NIM, Triton, TensorRT y el GPU Operator), con soporte empresarial y ramas de producción de largo plazo.

### Ejercicio 2

**2.1** Es la **versión más alta del runtime de CUDA que soporta este driver**. No significa que haya un CUDA toolkit instalado. El driver es retrocompatible con runtimes de CUDA más viejos.

**2.2** El NVIDIA Container Toolkit se engancha en el runtime. Cuando se usa `--gpus`, inyecta en el contenedor al momento de arrancar los device nodes de la GPU (`/dev/nvidia*`), las bibliotecas del driver en espacio de usuario (`libcuda.so`, `libnvidia-ml.so`) y utilidades como `nvidia-smi`.

**2.3** El driver tiene que coincidir con el kernel y es compartido, así que pertenece al host. El CUDA toolkit, cuDNN y los frameworks cambian mucho más rápido, y distintos workloads necesitan distintas versiones. Los contenedores permiten que muchas combinaciones de versiones convivan en un mismo host. Además son reproducibles entre dev y prod, y actualizar un workload nunca pone en riesgo el host.

**2.4** Hay que actualizar el **driver del host** a una versión que soporte CUDA 12.6. Como alternativa, usá un contenedor construido contra un CUDA más viejo o, en GPUs de datacenter soportadas, el paquete de forward-compatibility de CUDA. El driver tiene que ser al menos tan nuevo como lo exija el runtime de CUDA.

### Ejercicio 3

**3.1** Es un PyTorch construido por NVIDIA a partir del release `24.08` de NGC, con parches y validación de NVIDIA. Las versiones exactas de los componentes están en las **release notes / support matrix de los contenedores de frameworks de NGC** para ese release.

**3.2** Los workers del `DataLoader` de PyTorch comparten tensores mediante memoria compartida (`/dev/shm`). El `/dev/shm` por defecto de Docker, de 64 MB, es demasiado chico y provoca caídas de los workers ("bus error") o lentitud. NCCL también puede usar memoria compartida para la comunicación dentro del nodo.

**3.3** NCCL se vuelve crítico en cuanto el entrenamiento usa más de una GPU, por ejemplo con DDP o FSDP (all-reduce de gradientes) o con tensor/pipeline parallelism. Usa NVLink/NVSwitch dentro de un nodo, PCIe como alternativa, e InfiniBand o RoCE con GPUDirect RDMA entre nodos.

**3.4** El **NVIDIA NeMo framework**. Aporta recetas y estrategias de paralelismo (tensor/pipeline/sequence parallelism a través de Megatron Core), métodos PEFT como LoRA, SFT y alineación (por ejemplo, RLHF/DPO), conversión de checkpoints y caminos de export hacia TensorRT-LLM y NIM. NeMo Curator cubre el lado de los datos.

### Ejercicio 4

**4.1** `[1,2,3,4] · W`:
- columna 1: 1·1 + 2·0 + 3·1 + 4·2 = 12
- columna 2: 1·0 + 2·1 + 3·1 + 4·(−1) = 1

Sumando B = [0.5, −0.5] da **[12.5, 0.5]**.

**4.2** Una dimensión de batch dinámica permite que un modelo ejecute de 1 a N requests a la vez. El `max_batch_size: 8` de Triton y el dynamic batching requieren que el modelo acepte una dimensión inicial variable. Si estuviera fija en `1`, Triton no podría cargar el modelo (desajuste de configuración) o no podría hacer batching, y los requests de varias filas como el del Paso 5.5 serían rechazados.

**4.3** Beneficios: el artefacto es neutral respecto del framework, es una entrada estándar para TensorRT y ONNX Runtime, y desacopla las dependencias de entrenamiento del serving. Riesgos: operadores no soportados o custom, diferencias numéricas y flujo de control dinámico que no se exporta limpiamente. Validá siempre las salidas contra el modelo original, como hace el Paso 4.3.

### Ejercicio 5

**5.1**
- 8000: HTTP/REST (protocolo de inferencia KServe v2, health, metadata).
- 8001: gRPC (mismo protocolo, menos overhead).
- 8002: métricas de Prometheus.

**5.2** Cuando `max_batch_size > 0`, la dimensión de batch es implícita, y `dims` describe la forma de **un** ítem. Triton antepone una dimensión de batch variable, reportada como `-1`.

**5.3** `request_success` cuenta **requests** (una llamada HTTP). `nv_inference_count` cuenta **inferencias**, es decir, ítems del batch. El único request llevaba 2 filas (`shape [2,4]`). `exec_count` = 1 significa que corrió como una sola ejecución del modelo.

**5.4** Cada subdirectorio numérico es una **versión del modelo**. Agregás `2/model.onnx`. Según la `version_policy` (por defecto: latest) y el modo de control del repository (polling, o carga explícita mediante la API de model-control), Triton carga la versión 2 y después descarga la 1. Los requests en curso terminan en la versión vieja, así que los clientes no ven downtime.

**5.5** Usá:
```
instance_group [ { count: 2 kind: KIND_GPU gpus: [ 0 ] } ]
```
Iniciá Triton con `--gpus all`. Para este modelo ONNX, la inferencia pasa entonces a usar el CUDA execution provider de ONNX Runtime.

### Ejercicio 6

**6.1** La carga falla, típicamente con un error de serialización del engine o de incompatibilidad de versión, o el rendimiento queda indefinido. Los engines de TensorRT están atados a la **versión de TensorRT** y, por defecto, a la **arquitectura de GPU / compute capability**, porque los kernels se auto-tunean para ese hardware. Mantené ONNX como artefacto portable y construí el engine por plataforma destino, en el pipeline de CI/CD o de despliegue, usando la misma versión de TensorRT que la imagen de serving.

**6.2** La entrada ONNX tiene una dimensión dinámica. TensorRT necesita un **optimization profile**: las formas mínima y máxima que tiene que soportar, más la forma para la que tunear los kernels. El batch máximo de 8 tiene que ser ≥ al `max_batch_size: 8` de Triton; si no, Triton va a rechazar o fallar los requests que superen el perfil.

**6.3** No. `--fp16` le permite a TensorRT ejecutar **capas internas** en FP16 donde convenga. Los bindings de entrada/salida del engine siguen en FP32 salvo que cambies explícitamente los formatos de I/O, así que la config de Triton declara FP32 correctamente.

**6.4** **Datos de calibración**, o un modelo ya cuantizado con nodos Q/DQ (quantization-aware training o el Model Optimizer). INT8 tiene un rango dinámico estrecho, así que TensorRT tiene que aprender factores de escala por tensor a partir de datos representativos para evitar pérdida de precisión. El rango de FP16 es lo suficientemente amplio para una conversión directa.

**6.5** **TensorRT-LLM**. Ejemplos de lo que agrega:
- in-flight (continuous) batching,
- paged KV cache,
- cuantización de pesos FP8/INT4,
- tensor y pipeline parallelism entre GPUs,
- speculative decoding,
- kernels de attention optimizados.

### Ejercicio 7

**7.1** 412880 / 98311 ≈ **4.2 inferencias por ejecución**. Un valor mayor a 1 demuestra que el dynamic batcher combinó requests independientes de clientes en batches más grandes, lo que sube el throughput.

**7.2** Es el tiempo máximo que un request puede esperar en la cola a que lleguen otros para formar un batch más grande. Valores más grandes dan batches más grandes y mayor throughput, a costa de latencia adicional. Valores más chicos hacen lo contrario. Ajustalo contra el SLA de latencia usando `perf_analyzer`.

**7.3** El modelo es un único MatMul de 4×2, así que el tiempo de ejecución está dominado por HTTP, la serialización y el overhead de lanzamiento/copia en la GPU, no por el cómputo. Mover los datos a la GPU puede incluso costar más que la cuenta. Las ganancias de TensorRT aparecen en redes con cómputo pesado: CNNs, transformers y LLMs, con muchas capas fusionables y tensores grandes, sobre todo cuando la menor precisión activa los Tensor Cores.

### Ejercicio 8

**8.1**
- **driver-daemonset**: instala el driver del kernel en un contenedor.
- **container-toolkit-daemonset**: configura containerd/CRI-O para GPUs.
- **device-plugin-daemonset**: **registra `nvidia.com/gpu` con el kubelet**, lo que hace que aparezca en `allocatable`.
- **gpu-feature-discovery**: agrega labels como producto, memoria y capacidad MIG.
- **node-feature-discovery**: labels de hardware genéricos que el operator usa para encontrar los nodos con GPU.
- **dcgm-exporter**: métricas de GPU para Prometheus.
- **cuda-validator / operator-validator**: verifican el stack de punta a punta.
- **gpu-operator**: el controller que reconcilia la `ClusterPolicy`.
- **mig-manager**, cuando está habilitado: aplica las particiones MIG.

**8.2** Los extended resources son enteros y no admiten overcommit, así que el request tiene que ser igual al limit; alcanza con especificar el limit. No podés pedir `0.5`. Mecanismos para compartir:
- **MIG** (particiones de hardware con aislamiento en GPUs soportadas),
- **time-slicing** (configurado en el device plugin; sin aislamiento de memoria),
- **MPS**,
- schedulers de más alto nivel como **Run:ai** que ofrecen GPUs fraccionales.

**8.3** En cada nodo: instalar un driver que coincida con el kernel, instalar y configurar el Container Toolkit, desplegar el device plugin, configurar el monitoreo con DCGM, configurar MIG, y repetir todo después de cada actualización del kernel/SO. A escala esto genera drift de configuración, alta lenta de nodos y upgrades frágiles. El operator lo convierte en una `ClusterPolicy` declarativa y reconciliada.

**8.4** Responden preguntas distintas. DCGM cubre **salud y saturación de la infraestructura**: utilización, memoria, temperatura, consumo, errores XID/ECC, throttling. Triton cubre el **comportamiento del servicio**: tasa de requests, tiempo en cola, tiempo de cómputo, eficiencia del batching, fallas por modelo. Por ejemplo, baja utilización de GPU con alto tiempo en cola apunta a un problema de configuración del serving, mientras que alta temperatura más throttling apunta a un problema de hardware o de refrigeración.

**8.5** Slurm conviene para entrenamiento multi-nodo grande, de larga duración y fuertemente acoplado en clusters estilo HPC. Sus fortalezas son el gang scheduling, la conciencia de topología, la asignación exclusiva de nodos y un flujo de trabajo `sbatch`/`srun` conocido. Base Command Manager aprovisiona y gestiona esos clusters y puede desplegar Slurm, Kubernetes o ambos. Kubernetes es más fuerte para servicios, inferencia y workloads mixtos. **Run:ai** se monta sobre Kubernetes para aportar scheduling estilo HPC: cuotas, fair-share, gang scheduling, pooling de GPUs y GPUs fraccionales.

### Ejercicio 9

**9.1** Detecta la GPU, selecciona un perfil optimizado (engine) que corresponda, descarga los pesos/engines del modelo desde NGC y arranca el servidor. El volumen de caché conserva esos artefactos para que los reinicios sean rápidos y no vuelvan a descargar decenas de GB. La misma idea aplica a los almacenes de modelos compartidos que describe la guía de NVIDIA sobre escalado de storage.

**9.2** **Triton (Ej. 5/6):** produjiste el artefacto, escribiste `config.pbtxt`, elegiste el backend y la precisión, construiste el engine de TensorRT, gestionaste la compatibilidad de versiones y definiste las entradas/salidas de la API. **NIM (Ej. 9):** aportaste una key y una GPU. El modelo, la selección del engine, la configuración del servidor y una API compatible con OpenAI vienen preconstruidos. El trade-off es flexibilidad vs. tiempo hasta producción; NIM se limita a los modelos y perfiles publicados más sus opciones de personalización.

**9.3** Componentes adicionales:
- Un **modelo de embeddings** (por ejemplo, un NIM de embeddings) para vectorizar documentos y consultas.
- Una **base de datos vectorial** (por ejemplo, Milvus, que puede usar índices cuVS acelerados por GPU).
- Opcionalmente un modelo de **reranking**.
- Un pipeline de ingesta/curado (NeMo Curator o RAPIDS para el preprocesamiento).
- **Guardrails** (NeMo Guardrails).
- Orquestación en Kubernetes con el GPU Operator.
- Monitoreo con DCGM más métricas de la aplicación.

### Ejercicio 10

**10.1** **RAPIDS cuDF** para el ETL y **DALI** para la decodificación y aumentación de imágenes acelerada por GPU. Ambos pasan el preprocesamiento limitado por CPU a la GPU, así las GPUs dejan de quedarse sin datos.

**10.2** El cuello de botella es la capa de storage. Siguiendo la guía de NVIDIA sobre escalado de storage:
- usá un filesystem paralelo/de alto throughput o storage por niveles dimensionado para las ráfagas de checkpoints,
- usá checkpointing asíncrono o distribuido (sharded),
- usá NVMe local como nivel de staging,
- usá **GPUDirect Storage** (vía `cuFile`) para eliminar los bounce buffers de la CPU.

Verificá también que **NCCL** corra sobre RDMA con el Network Operator, para que la comunicación no sea el límite oculto.

**10.3** **Triton Inference Server**, usando sus múltiples backends: TensorFlow, PyTorch/LibTorch y el backend FIL para modelos de árboles como XGBoost. Un único servidor aporta versiones por modelo, dynamic batching y métricas de Prometheus.

**10.4** **NVIDIA AI Enterprise**, que ofrece ramas de producción, ramas de soporte de largo plazo, parches de seguridad y soporte empresarial de NVIDIA.

**10.5** **NVIDIA TAO Toolkit**, un flujo de transfer learning low-code sobre modelos preentrenados, con export hacia TensorRT/Triton/DeepStream.

**10.6** **DCGM** (health watches, diagnósticos `dcgmi diag`, campos XID/ECC) exportado mediante **DCGM Exporter** a Prometheus/Alertmanager. En Kubernetes lo despliega el GPU Operator; fuera de Kubernetes, usá DCGM directamente o a través del monitoreo de Base Command Manager.

**10.7** Optimizá el modelo con **TensorRT-LLM**: in-flight batching, paged KV cache, cuantización FP8/INT4 y tensor parallelism. Servilo a través de **Triton** con el backend de TensorRT-LLM, o desplegá el **NIM** preconstruido equivalente. Validá el resultado con pruebas de carga (`perf_analyzer`/GenAI-Perf) contra objetivos de time-to-first-token y de latencia entre tokens.

</details>