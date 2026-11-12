# 1.4 — Factores que contribuyen a la reciente mejora y adopción acelerada de la IA

> **Peso en el examen: 4.75%.** Este es un objetivo conceptual. El examen NCA-AIIO no te pide ajustar un cluster. Sí espera que puedas nombrar las fuerzas detrás del boom de la IA y explicar cómo se refuerzan entre sí. Las preguntas suelen plantearse como "¿qué factor habilitó X?" o "¿por qué Y se volvió práctico?". Las secciones prácticas de abajo vuelven concretos esos factores, para que puedas reconocer cada uno en un stack de producción real.

---

## 1. Motivación: por qué "¿por qué ahora?" es una pregunta de infraestructura

Las redes neuronales no son nuevas. La backpropagation se popularizó en 1986, y las redes convolucionales ya leían cheques manuscritos en los años 90. Después, durante aproximadamente dos décadas, la IA siguió siendo un campo de nicho. A partir de 2012 se volvió mainstream de golpe, y después de noviembre de 2022 (ChatGPT) pasó a ser una prioridad a nivel directorio en la mayoría de las industrias.

El algoritmo no se volvió correcto de repente. Varias restricciones independientes se relajaron más o menos al mismo tiempo:

| Restricción antes de ~2012 | Qué la relajó | Efecto |
|---|---|---|
| Cómputo: entrenar una red profunda en CPUs llevaba semanas o meses | **Accelerated computing** con GPU (masivamente paralelo, alto ancho de banda de memoria) y más tarde **Tensor Cores** | El tiempo de iteración bajó de meses a días, y después a horas |
| Datos: los datasets etiquetados eran chicos | Datos a escala de internet, ImageNet (~1,2M de imágenes de entrenamiento etiquetadas para ILSVRC) y más tarde pre-training self-supervised sobre texto e imágenes sin etiquetar | Los modelos pudieron aprender representaciones generales |
| Algoritmos: las redes profundas eran difíciles de entrenar | ReLU, dropout, batch norm, residual connections, Adam y el **Transformer** (2017) | La profundidad y la escala se volvieron entrenables, y los Transformers paralelizan bien en GPUs |
| Software: cada laboratorio escribía sus propios kernels | CUDA, cuDNN, NCCL, PyTorch/TensorFlow/JAX, TensorRT, Triton | Un investigador escribe Python y el stack logra una utilización del hardware cercana al pico |
| Scale-out: una sola máquina era el límite | NVLink/NVSwitch, InfiniBand/RoCE con RDMA, GPUDirect | Miles de GPUs entrenan un solo modelo |
| Acceso: tenías que tener una supercomputadora propia | Instancias GPU en la nube, Kubernetes con el GPU Operator, contenedores NGC, servicios de IA gestionados | Cualquier equipo puede alquilar o schedulear GPUs on demand |
| Reutilización: cada modelo se entrenaba desde cero | **Foundation models** preentrenados, open weights, model hubs, fine-tuning (LoRA), RAG | El costo de adopción se desplazó del entrenamiento a la inferencia y la personalización |

El punto de inflexión de 2012 fue **AlexNet**. Ganó ILSVRC 2012 por amplio margen y se entrenó en **dos GPUs NVIDIA GTX 580 de consumo**. Este único evento combinó tres de los factores: un dataset etiquetado grande (ImageNet), cómputo en GPU (CUDA) y trucos algorítmicos (ReLU, dropout). La lección para un arquitecto es que **el progreso de la IA está limitado por cualquiera de estas restricciones que sea el cuello de botella en ese momento**. El mismo razonamiento aplica hoy dentro de tu propio cluster.

La conclusión para un SRE: estos factores "históricos" son las mismas capas que operás en producción. Si alguna de ellas es débil en tu entorno, tu plataforma de IA rinde por debajo de lo esperado. Algunos ejemplos: storage que no da abasto, un driver faltante, un interconnect lento o un modelo servido sin un runtime optimizado.

---

## 2. Los factores en profundidad

### 2.1 Accelerated computing: la GPU como motor

**Por qué las GPUs encajan.** El entrenamiento y la inferencia de redes neuronales están dominados por álgebra lineal densa, principalmente multiplicaciones de matrices (GEMMs) y convoluciones. Estas operaciones son:

- **Masivamente paralelas en datos.** La misma operación corre sobre millones de elementos.
- **Limitadas por throughput, no por latencia.** Importa más el trabajo total que la velocidad con la que se calcula un escalar individual.
- **Ávidas de ancho de banda.** Los pesos y las activaciones tienen que fluir desde la memoria constantemente.

Una CPU gasta su presupuesto de transistores en pocos núcleos complejos, caches grandes, predicción de saltos y ejecución fuera de orden. Ese diseño optimiza la latencia de un solo hilo. Una GPU lo gasta en miles de núcleos más simples agrupados en Streaming Multiprocessors (SMs), más memoria de muy alto ancho de banda (HBM en las piezas de data center). Ese diseño optimiza el throughput agregado.

**Hitos de arquitectura que el examen puede mencionar:**

| Generación | Novedad relevante para IA |
|---|---|
| Pascal (P100, 2016) | NVLink (primera generación), HBM2, cómputo FP16 |
| Volta (V100, 2017) | **Tensor Cores**: unidades dedicadas de multiplicación-acumulación de matrices para precisión mixta |
| Ampere (A100, 2020) | TF32, BF16, structured sparsity, **MIG** (Multi-Instance GPU) |
| Hopper (H100, 2022) | **Transformer Engine** con **FP8**, NVLink de 4.ª generación, NVLink Switch |
| Blackwell (2024) | Transformer Engine de 2.ª generación, **FP4**, NVLink de 5.ª generación, sistemas NVL72 a escala de rack |

**La precisión reducida es un multiplicador oculto.** Cada paso de FP32 → FP16/BF16 → FP8 → FP4 aproximadamente duplica el throughput matemático por unidad de silicio y reduce a la mitad la memoria y el ancho de banda necesarios por parámetro. Los modelos lo toleran gracias a técnicas de precisión mixta:

- loss scaling
- master weights o acumuladores de mayor precisión
- calibración y métodos quantization-aware

Gran parte de la historia de "la IA se volvió más rápida" viene de este co-diseño entre formatos de hardware y técnicas numéricas, no solo de tener más transistores.

| Dimensión | CPU | GPU | Nota sobre el trade-off |
|---|---|---|---|
| Diseño de núcleos | Pocos, complejos, optimizados para latencia | Miles, simples, optimizados para throughput | Las GPUs pierden en código serial con muchas ramificaciones |
| Ancho de banda de memoria | Decenas a pocos cientos de GB/s por socket | TB/s con HBM | El ancho de banda suele limitar la inferencia de LLMs más que los FLOPS |
| Matemática matricial | SIMD/AVX, algo de AMX | Tensor Cores, precisión mixta | La mayor parte de la aceleración requiere precisión reducida |
| Programación | De propósito general | CUDA más librerías | La madurez del software es la ventaja competitiva (ver 2.4) |
| Mejor uso | Preprocesamiento, orquestación, control plane | Entrenamiento, inferencia por lotes | Los pipelines reales necesitan ambos: si la CPU no da abasto, las GPUs quedan ociosas |

### 2.2 Datos: de etiquetas escasas a la auto-supervisión

- **Volumen.** La digitalización, la web, los dispositivos móviles, los sensores y los logs producen datos a una escala que antes no existía.
- **Benchmarks curados.** ImageNet demostró que un dataset etiquetado grande más un benchmark compartido aceleran un campo entero.
- **Pre-training self-supervised.** Los LLMs aprenden prediciendo el siguiente token sobre texto sin etiquetar. Esto elimina el cuello de botella del etiquetado humano, así que el dataset utilizable pasa a ser "la mayor parte del texto público disponible", medido en billones de tokens.
- **Datos sintéticos.** La simulación (por ejemplo, robótica y vehículos autónomos en simuladores tipo Omniverse) y los datos generados por modelos complementan los datos reales donde son escasos o sensibles.

**Consecuencia para la infraestructura:** los pipelines de datos y el **storage** pasan a ser de primera clase. Una GPU esperando I/O es silicio caro ocioso. La guía de storage para IA de NVIDIA recomienda:

- perfilar el patrón de I/O (muchas lecturas aleatorias chicas en entrenamiento, escrituras secuenciales grandes en checkpoints)
- usar capas de caching y filesystems paralelos o distribuidos
- usar **GPUDirect Storage** para que los datos se muevan entre almacenamiento NVMe o de red y la memoria de la GPU sin pasar por un bounce buffer de la CPU

### 2.3 Algoritmos: el Transformer y las scaling laws

- **Trucos habilitantes (década de 2010):** activaciones ReLU, dropout, batch/layer normalization, residual connections (ResNet, 2015) y optimizadores adaptativos (Adam). En conjunto, hicieron entrenables las redes muy profundas.
- **El Transformer (Vaswani et al., 2017, "Attention Is All You Need")** reemplazó la recurrencia por self-attention. Las RNNs procesan tokens secuencialmente, lo cual es hostil para las GPUs. La atención sobre una secuencia se expresa como grandes multiplicaciones de matrices, así que **paraleliza extremadamente bien en GPUs**. Eso hizo viable entrenar con muchísimos más datos. Hoy el Transformer es la base de los LLMs, los vision transformers, los modelos de voz y los modelos multimodales.
- **Scaling laws.** Kaplan et al. (2020) y Hoffmann et al. ("Chinchilla", 2022) mostraron empíricamente que la loss baja de forma predecible como una ley de potencia en función del tamaño del modelo, los datos y el cómputo. El resultado de Chinchilla es que, para un presupuesto de cómputo fijo, los parámetros y los tokens de entrenamiento deben escalarse juntos, a aproximadamente 20 tokens por parámetro. Esto convirtió el progreso de la IA en un **problema de planificación de capital**: más cómputo da modelos predeciblemente mejores. Por eso explotó la inversión en infraestructura de GPU.
- **Innovaciones de eficiencia** siguen estirando el hardware:
  - FlashAttention (kernels de atención IO-aware)
  - Mixture-of-Experts (solo una fracción de los parámetros está activa por token)
  - quantization
  - speculative decoding
  - gestión de KV-cache (paged attention)

### 2.4 El stack de software: aceleración full-stack

El hardware por sí solo no explica la adopción. El ecosistema CUDA (desde 2006) hace que un data scientist que escribe `model.cuda()` en PyTorch obtenga un rendimiento cercano al del hardware sin hacer ingeniería de kernels.

```
┌──────────────────────────────────────────────────────────────┐
│ Applications / AI services (chatbots, copilots, RAG, vision) │
├──────────────────────────────────────────────────────────────┤
│ Frameworks & SDKs: PyTorch, TensorFlow, JAX, NeMo, RAPIDS    │
│ Serving: Triton Inference Server, TensorRT-LLM, NIM          │
├──────────────────────────────────────────────────────────────┤
│ Libraries: cuDNN, cuBLAS, NCCL, TensorRT, DALI, cuDF         │
├──────────────────────────────────────────────────────────────┤
│ CUDA runtime + driver                                        │
├──────────────────────────────────────────────────────────────┤
│ GPU / NVLink / NIC (InfiniBand, Ethernet RoCE) / DPU         │
└──────────────────────────────────────────────────────────────┘
```

| Componente | Rol en el boom de la IA |
|---|---|
| **CUDA** | Modelo de programación de GPU de propósito general; la base de todo lo que está encima |
| **cuDNN / cuBLAS** | Primitivas optimizadas (convolución, atención, GEMM) que llaman los frameworks |
| **NCCL** | Comunicación colectiva (all-reduce, all-gather) entre GPUs y nodos; hace práctico el entrenamiento distribuido |
| **Frameworks** (PyTorch, TF, JAX) | Ocultan el hardware; autograd; APIs distribuidas |
| **TensorRT** | Optimizador y runtime de inferencia: fusión de capas y tensores, auto-tuning de kernels, quantization FP16/INT8/FP8, construcción de un engine optimizado para una GPU específica |
| **TensorRT-LLM** | Optimizaciones de inferencia específicas para LLMs (in-flight batching, paged KV cache, quantization) |
| **Triton Inference Server** | Serving de modelos multi-framework con dynamic batching, ejecución concurrente de modelos, métricas |
| **NGC / NIM** | Contenedores y microservicios preconstruidos y probados, que acortan el time-to-production |

### 2.5 Interconnect y scale-out

Los modelos modernos superan la memoria de una GPU y el cómputo de un nodo. Las corridas de entrenamiento se dividen de tres formas, y cada división genera un tráfico GPU-a-GPU intenso:

- **data parallelism**
- **tensor/model parallelism**
- **pipeline parallelism**

| Fabric | Alcance | Propósito | Trade-off |
|---|---|---|---|
| PCIe | Dentro de un nodo | GPU ↔ CPU/NIC/NVMe | De propósito general, ancho de banda mucho menor que NVLink |
| **NVLink / NVSwitch** | Dentro de un nodo o rack (NVL72) | GPU ↔ GPU, ancho de banda muy alto | Propietario, dominio físico limitado |
| **InfiniBand** (Quantum) | Entre nodos | RDMA, baja latencia, reducción en la red (SHARP) | Fabric separado, operación especializada |
| **Ethernet con RoCE** (Spectrum-X) | Entre nodos | RDMA sobre Ethernet, operación conocida | Requiere ajuste lossless/de congestión para igualar a IB |
| **GPUDirect RDMA** | NIC ↔ GPU | Evita la memoria del host | Requiere NIC, driver y topología compatibles |

Sin estos fabrics, agregar GPUs da rendimientos decrecientes, porque domina la comunicación. El networking de scale-out es una causa directa del salto de modelos de millones de parámetros a modelos de billones de parámetros.

### 2.6 Nube, Kubernetes y madurez operativa

- **La elasticidad de la nube** convirtió capex en opex. Una startup puede alquilar cientos de GPUs por una semana.
- **Los contenedores y Kubernetes** les dieron a las cargas de IA el mismo modelo de despliegue que al resto del negocio.
- El **NVIDIA GPU Operator** automatiza los componentes que necesita un nodo GPU, para que los nodos GPU se puedan gestionar como cualquier otro nodo:
  - driver
  - container toolkit
  - device plugin
  - GPU Feature Discovery
  - DCGM exporter
  - MIG manager
- Las herramientas de **MLOps** (experiment tracking, model registries, CI/CD para modelos, Kubeflow, KServe) hicieron que los modelos fueran reproducibles y auditables.
- **Compartir GPUs** (MIG, time-slicing) subió la utilización en cargas chicas de inferencia y desarrollo, lo que mejoró la economía.

### 2.7 Modelos preentrenados, ecosistemas abiertos y caída del costo de inferencia

- **Los foundation models** se entrenan una vez y se adaptan muchas veces. Caminos de adaptación comunes:
  - prompt engineering
  - **RAG** (retrieval-augmented generation)
  - fine-tuning o métodos parameter-efficient (LoRA)
- **Las open weights y los model hubs** permiten a las empresas arrancar desde una base sólida en lugar de entrenar desde cero.
- **La optimización de inferencia** (TensorRT/TensorRT-LLM, quantization, batching) redujo el costo por token. La inferencia es donde escala la adopción: corre de forma continua, para cada usuario, mientras que el entrenamiento es periódico.
- **Las interfaces en lenguaje natural** (LLMs) derrumbaron la barrera de habilidades. Los usuarios interactúan sin escribir código, lo que impulsó la curva de adopción de consumo más rápida de la historia del software tras el lanzamiento de ChatGPT en noviembre de 2022.

### 2.8 El flywheel

Los factores se refuerzan entre sí:

```
 better hardware ──► larger models trainable ──► better capability
       ▲                                                │
       │                                                ▼
 investment / R&D ◄── revenue & adoption ◄── useful products
       ▲                                                │
       └──── more data & feedback ◄─────────────────────┘
```

En el examen, "mejora acelerada" suele significar esta combinación: **cómputo acelerado + big data + mejores algoritmos + un stack de software full-stack maduro + infraestructura de scale-out + accesibilidad vía nube/MLOps**. Las respuestas que citan un solo factor suelen estar incompletas.

---

## 3. Ver los factores en un cluster de producción

El siguiente lab mapea los factores abstractos sobre un cluster Kubernetes con GPUs:

| Paso del lab | Factor que demuestra |
|---|---|
| GPU Operator | Madurez operativa |
| Pod con GPU | Accelerated computing |
| Engine de TensorRT | Stack de software |
| Triton | Adopción de la inferencia |
| Alertas de DCGM | Observabilidad SRE |

### 3.1 Instalar el GPU Operator (accesibilidad operativa)

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
"nvidia" has been added to your repositories
$ helm repo update
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈
```

En producción, fijá la versión del chart. Revisá las release notes del GPU Operator para encontrar la versión que soporta tu sistema operativo y tu kernel.

```yaml
# gpu-operator-values.yaml
driver:
  enabled: true
toolkit:
  enabled: true
devicePlugin:
  enabled: true
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
gfd:
  enabled: true
migManager:
  enabled: true
nodeStatusExporter:
  enabled: true
operator:
  defaultRuntime: containerd
```

```
$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --values gpu-operator-values.yaml --wait
NAME: gpu-operator
LAST DEPLOYED: Wed Nov 11 10:14:02 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

```
$ kubectl get pods -n gpu-operator
NAME                                                   READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-x7k2p                            1/1     Running     0          4m
gpu-operator-6d9c8b7f5c-q2lzm                          1/1     Running     0          5m
gpu-operator-node-feature-discovery-master-5b8f-hk4    1/1     Running     0          5m
gpu-operator-node-feature-discovery-worker-mx9tq       1/1     Running     0          5m
nvidia-container-toolkit-daemonset-7rjzf               1/1     Running     0          4m
nvidia-cuda-validator-l2m8d                            0/1     Completed   0          3m
nvidia-dcgm-exporter-9pq4w                             1/1     Running     0          4m
nvidia-device-plugin-daemonset-bt6vn                   1/1     Running     0          4m
nvidia-driver-daemonset-sx5kd                          1/1     Running     0          5m
nvidia-operator-validator-wq7zr                        1/1     Running     0          4m
```

GPU Feature Discovery etiqueta el nodo, para que tanto el scheduler como vos puedan ver las capacidades del acelerador:

```
$ kubectl get node gpu-node-01 -o json | jq '.metadata.labels | with_entries(select(.key | startswith("nvidia.com/gpu")))'
{
  "nvidia.com/gpu.count": "8",
  "nvidia.com/gpu.family": "hopper",
  "nvidia.com/gpu.memory": "81559",
  "nvidia.com/gpu.product": "NVIDIA-H100-80GB-HBM3",
  "nvidia.com/gpu.present": "true"
}

$ kubectl describe node gpu-node-01 | grep -A1 -E "^(Capacity|Allocatable):" ; kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
8
```

### 3.2 Inspeccionar los factores de hardware en el nodo

```
$ nvidia-smi
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 570.xx.xx              Driver Version: 570.xx.xx      CUDA Version: 12.8     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
| N/A   34C    P0             72W /  700W |       1MiB /  81559MiB |      0%      Default |
...
```

La topología del interconnect muestra por qué importa NVLink (`NV18` = 18 enlaces NVLink entre el par):

```
$ nvidia-smi topo -m
        GPU0    GPU1    GPU2    GPU3    NIC0    CPU Affinity    NUMA Affinity
GPU0     X      NV18    NV18    NV18    PXB     0-55            0
GPU1    NV18     X      NV18    NV18    PXB     0-55            0
GPU2    NV18    NV18     X      NV18    SYS     56-111          1
GPU3    NV18    NV18    NV18     X      SYS     56-111          1
NIC0    PXB     PXB     SYS     SYS      X

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  PXB  = Connection traversing multiple PCIe bridges
  NV#  = Connection traversing a bonded set of # NVLinks
```

```
$ nvidia-smi nvlink -s -i 0
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-...)
         Link 0: 26.562 GB/s
         Link 1: 26.562 GB/s
         ...
```

### 3.3 Factor del stack de software: optimización con TensorRT

Este paso toma un modelo ONNX exportado y construye un engine optimizado. Este es un Job que ejecuta `trtexec` desde el contenedor TensorRT de NGC:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: trt-build-resnet50
  namespace: ai-inference
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        app: trt-build
    spec:
      restartPolicy: Never
      containers:
        - name: trtexec
          image: nvcr.io/nvidia/tensorrt:25.01-py3
          command: ["/bin/bash", "-c"]
          args:
            - >-
              trtexec --onnx=/models/onnx/resnet50.onnx
              --saveEngine=/models/repo/resnet50_trt/1/model.plan
              --fp16 --minShapes=input:1x3x224x224
              --optShapes=input:16x3x224x224
              --maxShapes=input:32x3x224x224
          resources:
            limits:
              nvidia.com/gpu: 1
          volumeMounts:
            - name: models
              mountPath: /models
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: model-repo
```

Las partes relevantes del log:

```
$ kubectl logs -n ai-inference job/trt-build-resnet50 | grep -E "Throughput|Latency|PASSED"
[I] Throughput: 4873.21 qps
[I] Latency: min = 3.12 ms, max = 3.61 ms, mean = 3.24 ms, median = 3.23 ms, percentile(99%) = 3.48 ms
&&&& PASSED TensorRT.trtexec [TensorRT v100700] # trtexec --onnx=/models/onnx/resnet50.onnx ...
```

Los números son ilustrativos; medí en tu propia GPU. Lo que importa es el método. Compará el mismo modelo en FP32 nativo del framework, después como engine TensorRT FP16, y después en INT8/FP8. La diferencia de throughput es el "factor software" expresado en números. Un engine `.plan` es específico de la arquitectura de GPU y de la versión de TensorRT, así que reconstruilo cuando cambie cualquiera de las dos.

### 3.4 Factor de adopción: serving con Triton

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton
  namespace: ai-inference
  labels:
    app: triton
spec:
  replicas: 1
  selector:
    matchLabels:
      app: triton
  template:
    metadata:
      labels:
        app: triton
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      containers:
        - name: tritonserver
          image: nvcr.io/nvidia/tritonserver:25.01-py3
          args:
            - tritonserver
            - --model-repository=/models/repo
            - --strict-model-config=false
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
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: http
            initialDelaySeconds: 30
            periodSeconds: 15
          resources:
            requests:
              cpu: "4"
              memory: 16Gi
            limits:
              nvidia.com/gpu: 1
              memory: 32Gi
          volumeMounts:
            - name: models
              mountPath: /models
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: model-repo
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton
  namespace: ai-inference
spec:
  selector:
    app: triton
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

Configuración del modelo con dynamic batching. Este archivo está en formato de texto protobuf, no YAML, así que no lleva etiqueta:

```
# /models/repo/resnet50_trt/config.pbtxt
name: "resnet50_trt"
platform: "tensorrt_plan"
max_batch_size: 32
dynamic_batching {
  preferred_batch_size: [ 8, 16, 32 ]
  max_queue_delay_microseconds: 200
}
instance_group [
  {
    count: 2
    kind: KIND_GPU
  }
]
```

```
$ kubectl port-forward -n ai-inference svc/triton 8000:8000 8002:8002 &
$ curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/v2/health/ready
200
$ curl -s localhost:8000/v2/models/resnet50_trt | jq '{name, platform, versions}'
{
  "name": "resnet50_trt",
  "platform": "tensorrt_plan",
  "versions": [
    "1"
  ]
}
```

Hacé una prueba de carga con `perf_analyzer` (del contenedor del SDK de Triton) para ver cómo el dynamic batching sube el throughput:

```
$ perf_analyzer -m resnet50_trt -u localhost:8001 -i grpc --concurrency-range 1:8:2 --shape input:3,224,224
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 610.4 infer/sec, latency 1636 usec
Concurrency: 3, throughput: 1702.9 infer/sec, latency 1760 usec
Concurrency: 5, throughput: 2641.1 infer/sec, latency 1891 usec
Concurrency: 7, throughput: 3388.6 infer/sec, latency 2063 usec
```

El throughput sube mucho más rápido que la latencia a medida que crece la concurrencia. Eso es el batching amortizando el overhead por request, y es una razón central por la que la inferencia se volvió económicamente viable a escala.

### 3.5 Economía de la utilización: time-slicing de GPU

Para cargas de desarrollo e inferencia liviana, una GPU física se puede anunciar como múltiples recursos scheduleables:

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

```
$ kubectl apply -f time-slicing-config.yaml
configmap/time-slicing-config created
$ kubectl patch clusterpolicies.nvidia.com/cluster-policy -n gpu-operator --type merge \
    -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched
$ kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
32
$ kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.replicas}{"\n"}'
4
```

| Método de compartición | Aislamiento | Caso de uso | Trade-off |
|---|---|---|---|
| GPU completa | Total | Entrenamiento, inferencia de modelos grandes | Baja utilización para jobs chicos |
| **MIG** (Ampere en adelante, GPUs de data center) | Hardware: SMs, memoria y porciones de cache dedicados | Inferencia multi-tenant con QoS | Perfiles de partición fijos, reconfigurar drena la GPU |
| **Time-slicing** | Ninguno (memoria compartida, cambio de contexto) | Desarrollo, notebooks, inferencia liviana con ráfagas | Sin aislamiento de memoria ni de fallas, noisy neighbors |
| MPS | Parcial (kernels concurrentes) | Procesos cooperativos de un mismo tenant | Aislamiento de fallas limitado |

### 3.6 Observabilidad: detectar el factor que es cuello de botella

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-efficiency
  namespace: gpu-operator
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu.efficiency
      rules:
        - alert: GPUAllocatedButIdle
          expr: |
            avg by (Hostname, gpu, exported_pod) (
              avg_over_time(DCGM_FI_DEV_GPU_UTIL[30m])
            ) < 10
            and on (Hostname, gpu)
            avg by (Hostname, gpu) (DCGM_FI_DEV_FB_USED) > 1024
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} allocated but under 10% utilized"
            description: "Likely input pipeline, storage or CPU bottleneck in pod {{ $labels.exported_pod }}."
        - alert: GPUXidError
          expr: |
            max by (Hostname, gpu) (DCGM_FI_DEV_XID_ERRORS) > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "XID error {{ $value }} on GPU {{ $labels.gpu }} ({{ $labels.Hostname }})"
            description: "Check dmesg on the node and the NVIDIA XID error catalogue."
        - alert: GPUMemoryNearlyFull
          expr: |
            DCGM_FI_DEV_FB_USED
              /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.95
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "GPU framebuffer above 95% on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
```

```
$ kubectl port-forward -n gpu-operator svc/nvidia-dcgm-exporter 9400:9400 &
$ curl -s localhost:9400/metrics | grep -E "^DCGM_FI_DEV_(GPU_UTIL|FB_USED|POWER_USAGE)" | head -3
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-3f2a...",Hostname="gpu-node-01",modelName="NVIDIA H100 80GB HBM3"} 87
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-3f2a...",Hostname="gpu-node-01",modelName="NVIDIA H100 80GB HBM3"} 41230
DCGM_FI_DEV_POWER_USAGE{gpu="0",UUID="GPU-3f2a...",Hostname="gpu-node-01",modelName="NVIDIA H100 80GB HBM3"} 512.4
```

Los nombres de las labels (`exported_pod`, `Hostname`) dependen de la configuración de tu DCGM exporter y del relabeling de Prometheus. Verificalos con el `curl` de arriba antes de confiar en la alerta.

---

## 4. Verificación y diagnóstico de fallas

Cada factor histórico tiene un modo de falla en producción. Cuando una plataforma de IA anda lenta, preguntate cuál de los factores es el cuello de botella actual.

| Síntoma | Factor responsable | Causa probable | Verificación |
|---|---|---|---|
| El nodo muestra `nvidia.com/gpu: 0` asignable | Stack operativo | Falla el pod del driver o del device plugin; Secure Boot bloquea un módulo de kernel sin firmar; faltan los kernel headers | `kubectl get pods -n gpu-operator`; `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset`; `mokutil --sb-state` en el nodo |
| Pod en `Pending`, `Insufficient nvidia.com/gpu` | Capacidad / compartición | Todas las GPUs asignadas; perfil MIG que no coincide | `kubectl describe pod <p>`; `kubectl describe node \| grep -A8 Allocated` |
| `CUDA driver version is insufficient for CUDA runtime version` | Stack de software | El CUDA del contenedor es más nuevo de lo que soporta el driver del host | `nvidia-smi` (la "CUDA Version" arriba a la derecha = máxima soportada); elegí una imagen NGC más vieja o actualizá el driver |
| Utilización de GPU baja (<30%) durante el entrenamiento | Datos / storage | El dataloader, la decodificación o el filesystem no alcanzan a alimentar la GPU | `nvidia-smi dmon -s u`; `iostat -x 5` en el storage; subí `num_workers`, usá DALI, agregá una capa de caching o GPUDirect Storage |
| El entrenamiento multi-nodo escala mal | Interconnect | NCCL cae a sockets TCP; no se usa RDMA; topología no alineada con NUMA | Corré con `NCCL_DEBUG=INFO`, buscá `NET/IB` vs `NET/Socket`; `ibstat`; `nvidia-smi topo -m` |
| El entrenamiento se frena periódicamente | Storage | Escrituras síncronas de checkpoints saturan el storage | Correlacioná los frenos con los intervalos de checkpoint; usá checkpointing asíncrono/sharded, una capa de escritura más rápida |
| Latencia de inferencia alta, GPU subutilizada | Software / serving | Sin batching, corriendo el modelo FP32 del framework en lugar de un engine optimizado | `perf_analyzer`; habilitá `dynamic_batching`; convertí con TensorRT / TensorRT-LLM |
| El engine de TensorRT no carga después de un upgrade | Stack de software | El `.plan` se construyó para otra versión de TRT u otra arquitectura de GPU | Los logs de Triton muestran un error de deserialización; reconstruí el engine con el Job de 3.3 |
| Errores Xid, la GPU se cae del bus | Hardware | Falla térmica, de alimentación, de PCIe o de memoria (ECC) | `dmesg -T \| grep -i xid`; `nvidia-smi -q -d ECC,TEMPERATURE,POWER`; `dcgmi diag -r 2` |
| OOM en la GPU con un LLM | Algoritmo / precisión | El modelo más el KV cache no entran en la HBM | `nvidia-smi --query-gpu=memory.used,memory.total --format=csv`; cuantizá (FP8/INT4), tensor parallelism, paged KV cache |

Comandos útiles a nivel de nodo:

```
$ dmesg -T | grep -i xid
[Wed Nov 11 09:58:12 2026] NVRM: Xid (PCI:0000:18:00): 79, pid=..., GPU has fallen off the bus.

$ dcgmi diag -r 2
Successfully ran diagnostic for group.
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
| Graphics Processes        | Pass                                           |
+-----  Integration  -------+------------------------------------------------+
| PCIe                      | Pass - All                                     |
+-----  Hardware  ----------+------------------------------------------------+
| GPU Memory                | Pass - All                                     |
+---------------------------+------------------------------------------------+

$ nvidia-smi dmon -s um -c 5
# gpu    sm   mem   enc   dec    fb  bar1
# Idx     %     %     %     %    MB    MB
    0    12     4     0     0 41230     8
    0    95    61     0     0 41230     8
    0    10     3     0     0 41230     8
    0    97    63     0     0 41230     8
    0    11     4     0     0 41230     8
```

El patrón de `dmon` de arriba, donde la utilización de SM alterna entre alrededor de 10% y alrededor de 95%, es la firma clásica de un job **limitado por el input pipeline**. La GPU termina cada batch y después espera el siguiente. La solución está en el factor de datos y storage, no en comprar más GPUs.

Verificar qué transporte eligió NCCL:

```
$ kubectl logs train-worker-0 | grep -E "NCCL INFO (NET|Using network)"
NCCL INFO NET/IB : Using [0]mlx5_0:1/IB [1]mlx5_1:1/IB ; OOB eth0:10.0.3.14<0>
NCCL INFO Using network IB
```

Si acá ves `NET/Socket` en un cluster que tiene InfiniBand o RoCE, no se está usando RDMA. Revisá el device plugin de RDMA o el network operator, los resource requests `rdma/*` del pod y que `/dev/infiniband` esté disponible dentro del contenedor.

---

## 5. Resumen orientado al examen

- **No hay una única causa.** El progreso acelerado de la IA resulta de la **convergencia** de:
  - accelerated computing (GPUs, Tensor Cores, precisión reducida)
  - datos masivos
  - avances algorítmicos (trucos de deep learning, el Transformer, scaling laws)
  - un stack de software full-stack maduro (CUDA, cuDNN, NCCL, frameworks, TensorRT, Triton)
  - interconnect de alta velocidad (NVLink, InfiniBand/RoCE)
  - accesibilidad vía nube y Kubernetes
  - foundation models preentrenados
- **Las GPUs encajan con la IA** porque las redes neuronales son matemática matricial masivamente paralela y necesitan alto ancho de banda de memoria.
- **AlexNet (2012)** marca la inflexión del deep learning: datos de ImageNet más entrenamiento en GPU.
- **El Transformer (2017)** habilitó los LLMs porque la atención es paralelizable en GPUs, a diferencia de las RNNs secuenciales.
- **La adopción de la IA generativa** se aceleró con las interfaces en lenguaje natural (ChatGPT, nov. 2022), los modelos preentrenados y una inferencia más barata.
- **La inferencia es donde escala la adopción.** Los runtimes optimizados (TensorRT, TensorRT-LLM), el batching (Triton) y la quantization bajan el costo por consulta.
- **Las herramientas operativas** (GPU Operator, contenedores NGC, MIG y time-slicing, DCGM) hicieron que la infraestructura de GPU fuera gestionable por equipos de plataforma comunes.
- **El storage y los pipelines de datos** ahora son de primera clase: las GPUs ociosas esperando I/O desperdician el recurso más caro del data center.

---

## Referencias

- NVIDIA, *AI Infrastructure and Operations Fundamentals* (curso): https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA, guía de estudio del examen NCA-AIIO (PDF): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA Technical Blog, *Tips on Scaling Storage for AI Training and Inferencing*: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- NVIDIA Blog, *What Are Large Language Models Used For?*: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA Technical Blog, *NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes*: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- Documentación del NVIDIA GPU Operator (time-slicing, MIG, ClusterPolicy): https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- Documentación de NVIDIA Triton Inference Server: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- Documentación de NVIDIA DCGM: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- Documentación de NVIDIA NCCL: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/index.html
- Vaswani et al., *Attention Is All You Need* (2017): https://arxiv.org/abs/1706.03762
- Krizhevsky, Sutskever, Hinton, *ImageNet Classification with Deep Convolutional Neural Networks* (2012): https://papers.nips.cc/paper/2012/hash/c399862d3b9d6b76c8436e924a68c45b-Abstract.html
- Kaplan et al., *Scaling Laws for Neural Language Models* (2020): https://arxiv.org/abs/2001.08361
- Hoffmann et al., *Training Compute-Optimal Large Language Models* (2022): https://arxiv.org/abs/2203.15556