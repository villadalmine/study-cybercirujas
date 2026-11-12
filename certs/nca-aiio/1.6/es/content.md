# 1.6 — Propósito y casos de uso de las soluciones de NVIDIA

> **Peso en el examen:** 4.75 (NCA-AIIO, versión desconocida)
> **Perfil:** Platform Architect / SRE. El objetivo es mapear cada producto de NVIDIA al problema de producción que resuelve, a la capa del stack en la que vive y a las señales que te indican si está funcionando o no.

---

## 1. Motivación: el problema de producción

Una GPU por sí sola es un dispositivo PCIe que consume energía. Convertir un rack de GPUs en un servicio de IA funcional plantea varios problemas de ingeniería distintos, y cada uno se corresponde con un producto diferente de NVIDIA:

| Problema de producción | Qué se rompe sin una solución | Respuesta de NVIDIA |
|---|---|---|
| El silicio tiene que ser programable | No hay forma de ejecutar kernels en la GPU | Toolkit y driver de **CUDA** |
| Las primitivas de deep learning tienen que ser rápidas | Cada framework escribe a mano convoluciones y attention | **cuDNN**, **cuBLAS**, CUTLASS |
| El entrenamiento multi-GPU y multi-nodo tiene que comunicarse | El all-reduce se convierte en el cuello de botella y el escalado se aplana | **NCCL**, **NVLink/NVSwitch**, **InfiniBand Quantum**, **Spectrum-X** |
| Los datos tienen que llegar a la GPU lo suficientemente rápido | Las GPUs quedan ociosas esperando al storage y a los bounce buffers de la CPU | **Magnum IO**, **GPUDirect RDMA**, **GPUDirect Storage** |
| Kubernetes tiene que ver y gestionar las GPUs | Los drivers derivan, falta el device plugin, no hay métricas | **GPU Operator**, **Network Operator**, **DCGM** |
| Los clusters tienen que aprovisionarse y operarse | Las flotas bare-metal se vuelven snowflakes, no hay scheduling de jobs | **Base Command Manager**, **Run:ai**, integración con **Slurm** |
| Las flotas edge tienen que gestionarse de forma remota | Miles de sitios sin control central | **Fleet Command** |
| Los modelos entrenados tienen que servirse con baja latencia y alto throughput | La inferencia FP32 en modo eager desperdicia la mayor parte de la GPU | **TensorRT**, **TensorRT-LLM**, **Triton / Dynamo-Triton**, **Dynamo** |
| Los equipos necesitan IA generativa de nivel productivo sin construir el stack de serving | Meses de trabajo de integración por modelo | Microservicios **NIM** |
| Los modelos tienen que construirse, personalizarse y protegerse | Scripts de entrenamiento ad hoc, sin curación de datos, sin guardrails | **NeMo** (Curator, Customizer, Guardrails, Retriever) |
| El ETL y el ML clásico están limitados por la CPU | Pandas y scikit-learn tardan horas | **RAPIDS** (cuDF, cuML, cuGraph) |
| La empresa necesita soporte, parches de seguridad y certificación | Open source sin soporte y con exposición a CVEs | **NVIDIA AI Enterprise** |
| El software tiene que distribuirse de forma confiable y curada | Cada equipo construye sus propias imágenes CUDA | Catálogo **NGC** (`nvcr.io`) |
| Los problemas de dominio necesitan pipelines listos para usar | Cada hospital, retailer o SOC arranca desde cero | **Clara, Riva, Morpheus, Metropolis, Isaac, Merlin, Omniverse, Holoscan** |

El examen evalúa reconocimiento: dado un escenario, elegí el producto. La habilidad de producción que hay detrás es saber qué capa está fallando cuando algo sale mal.

---

## 2. El stack de NVIDIA: un modelo mental por capas

```
┌───────────────────────────────────────────────────────────────────────┐
│ APPLICATION / DOMAIN SDKs                                             │
│ Clara (health) · Riva (speech) · Morpheus (cyber) · Metropolis (video)│
│ Isaac (robotics) · Merlin (recsys) · Omniverse (3D/digital twin)      │
│ Holoscan (sensor/edge streaming) · Maxine (video/audio effects)       │
├───────────────────────────────────────────────────────────────────────┤
│ AI FRAMEWORKS & MICROSERVICES                                         │
│ NeMo (build/customize/guard LLMs) · NIM (prebuilt inference services) │
│ Triton / Dynamo-Triton (serving) · Dynamo (distributed LLM serving)   │
│ TensorRT · TensorRT-LLM (inference optimization) · RAPIDS (data sci)  │
├───────────────────────────────────────────────────────────────────────┤
│ NVIDIA AI ENTERPRISE (licensed, supported software suite)             │
│ distributed through NGC (containers, models, Helm charts)             │
├───────────────────────────────────────────────────────────────────────┤
│ ACCELERATION LIBRARIES (CUDA-X)                                       │
│ CUDA · cuDNN · cuBLAS · NCCL · cuFFT · Magnum IO · DALI               │
├───────────────────────────────────────────────────────────────────────┤
│ INFRASTRUCTURE MANAGEMENT & ORCHESTRATION                             │
│ GPU Operator · Network Operator · DCGM · Base Command Manager          │
│ Run:ai · Fleet Command · Kubernetes / Slurm                           │
├───────────────────────────────────────────────────────────────────────┤
│ NETWORKING & DATA MOVEMENT                                            │
│ NVLink/NVSwitch (scale-up) · Quantum InfiniBand · Spectrum-X Ethernet │
│ ConnectX SuperNIC · BlueField DPU (DOCA) · GPUDirect RDMA/Storage     │
├───────────────────────────────────────────────────────────────────────┤
│ COMPUTE PLATFORMS                                                     │
│ DGX (turnkey systems) · DGX BasePOD / SuperPOD (reference clusters)   │
│ HGX (OEM baseboard) · MGX (modular reference) · DGX Cloud (as-a-svc)  │
│ Jetson / IGX (edge) · data center GPUs (H100, H200, B200, L40S, L4…)  │
└───────────────────────────────────────────────────────────────────────┘
```

**Regla práctica para preguntas de escenario:** primero encontrá el verbo de la pregunta.

- *Entrenar / personalizar / curar / proteger* → NeMo
- *Optimizar un modelo para inferencia* → TensorRT o TensorRT-LLM
- *Servir muchos modelos de muchos frameworks* → Triton
- *Desplegar un LLM rápido con una API compatible con OpenAI* → NIM
- *Gestionar GPUs en Kubernetes* → GPU Operator
- *Monitorear la salud de las GPUs* → DCGM
- *Aprovisionar un cluster bare-metal* → Base Command Manager
- *Planificar y compartir GPUs de forma equitativa entre equipos* → Run:ai
- *Gestionar sitios edge* → Fleet Command
- *Descargar de la CPU el networking, el storage o la seguridad* → BlueField DPU
- *Acelerar dataframes y ML clásico* → RAPIDS

---

## 3. Plataformas de cómputo

### 3.1 DGX, HGX, MGX, DGX Cloud

| Producto | Qué es | Quién lo integra | Usalo cuando | Trade-off |
|---|---|---|---|---|
| **DGX** (p. ej., DGX H100/H200/B200) | Sistema llave en mano de NVIDIA: 8 GPUs, NVSwitch, NICs ConnectX, DGX OS, soporte | NVIDIA | Querés un nodo validado, con soporte y de comportamiento conocido, con performance predecible | Mayor costo, menos flexibilidad de hardware |
| **DGX BasePOD** | Arquitectura de referencia: nodos DGX, networking, partners de storage, Base Command Manager | NVIDIA y partners | Cluster empresarial desde decenas de nodos en adelante | Requiere un diseño de storage y red certificado |
| **DGX SuperPOD** | Arquitectura de referencia por unidades escalables para clusters de entrenamiento muy grandes (fabric InfiniBand o Spectrum-X) | NVIDIA | Entrenamiento de foundation models con cientos o miles de GPUs | El mayor capex, requisitos estrictos de instalaciones (energía, refrigeración, a menudo líquida) |
| **HGX** | Baseboard de GPUs (GPUs y NVSwitch) que se vende a OEMs (Dell, HPE, Supermicro, Lenovo…) | OEM | Querés un servidor OEM con el mismo complejo de GPUs que un DGX | El soporte se reparte entre el OEM y NVIDIA; la validación queda a tu cargo |
| **MGX** | Diseño de referencia modular de servidores (combinaciones de CPU, GPU y DPU, incluida Grace) | OEM | Factores de forma heterogéneos o personalizados, muchos SKUs a partir de un mismo diseño | Más variedad de diseños para validar |
| **DGX Cloud** | Infraestructura DGX como servicio gestionado en clouds de partners, con software y expertise de NVIDIA | NVIDIA y CSP | Hacer burst o arrancar sin capex; entorno NVIDIA consistente | Opex, data gravity, dependencia de la capacidad del proveedor |
| **Jetson / IGX** | Módulos edge y embebidos; IGX es de grado industrial y médico con seguridad funcional | NVIDIA y OEMs | Robots, cámaras, dispositivos médicos, edge de fábrica | Energía y memoria limitadas en comparación con las GPUs de data center |

### 3.2 Selección de GPU según la carga de trabajo

| Clase de GPU | Caso de uso típico | Por qué |
|---|---|---|
| H100 / H200 / B200 (SXM, NVLink) | Entrenamiento a gran escala, inferencia de LLMs grandes | Ancho de banda HBM, scale-up con NVLink, Transformer Engine (FP8; FP4 en Blackwell) |
| L40S | Inferencia mixta, gráficos, Omniverse, fine-tuning de modelos chicos | Buena inferencia FP8 más RT cores para rendering |
| L4 | Inferencia de alta densidad y eficiente en energía, IA de video | TDP bajo, motores de encode/decode de video |
| Grace Hopper / Grace Blackwell | Cargas limitadas por memoria donde el enlace CPU-GPU limita la performance | Memoria coherente entre CPU y GPU mediante NVLink-C2C |

---

## 4. Networking y movimiento de datos

### 4.1 Scale-up versus scale-out

| Tecnología | Alcance | Propósito | Señal de diagnóstico |
|---|---|---|---|
| **NVLink / NVSwitch** | Dentro de un nodo (o dominio de rack NVL72) | Ancho de banda GPU a GPU muy superior a PCIe para tensor parallelism y all-reduce | `nvidia-smi topo -m` muestra `NV#` entre GPUs |
| **Quantum InfiniBand** | Entre nodos | Fabric RDMA lossless y de baja latencia; reducción in-network SHARP para colectivas | `ibstat` muestra `State: Active`, rate 400/800 Gb/s |
| **Spectrum-X Ethernet** | Entre nodos | Ethernet ajustado para IA: adaptive routing y control de congestión (switches Spectrum-4 más SuperNICs BlueField-3) | Contadores de RoCE, telemetría de switches |
| **ConnectX SuperNIC** | NIC del nodo | Endpoint RDMA de alto ancho de banda para el tráfico este-oeste de GPUs | `ibdev2netdev`, `mlxlink` |
| **BlueField DPU** | NIC del nodo con cores Arm | Descarga y aísla el networking, el storage y la seguridad de la CPU del host; se programa con DOCA | La DPU corre su propio sistema operativo; el host ve las funciones descargadas |

**Por qué importa en producción:** en el entrenamiento distribuido cada step termina con un all-reduce de gradientes. Si el ancho de banda entre GPUs es bajo, agregar GPUs agrega tiempo de comunicación y la eficiencia de escalado colapsa. NCCL elige automáticamente el camino más rápido (NVLink, después PCIe, después la red vía GPUDirect RDMA). Solo puede usar caminos que estén físicamente presentes y correctamente configurados.

### 4.2 Magnum IO y GPUDirect

**Magnum IO** es el nombre paraguas del stack de aceleración de I/O de NVIDIA (NCCL, GPUDirect RDMA, GPUDirect Storage, NVSHMEM, integración con UCX).

- **GPUDirect RDMA**: la NIC lee y escribe la memoria de la GPU directamente por PCIe, evitando copias a la memoria del host. Es necesario para que NCCL multi-nodo sea eficiente.
- **GPUDirect Storage (GDS)**: DMA desde NVMe o desde sistemas de archivos NVMe-oF/paralelos directo a la memoria de la GPU, evitando el bounce buffer de la CPU. Reduce la carga de CPU y aumenta el throughput de I/O para la carga de datos y el checkpointing.

De la guía de NVIDIA sobre storage para entrenamiento e inferencia de IA, las prácticas principales son:

- Dimensionar el ancho de banda del storage para el patrón de lectura del entrenamiento (muchas epochs sobre el dataset) y para las ráfagas de checkpoint (grandes escrituras secuenciales de todos los ranks a la vez).
- Usar tiering: caché NVMe local, después un sistema de archivos paralelo o compartido, después object storage para el data lake.
- La inferencia suele estresar la latencia de carga del modelo al escalar horizontalmente, con muchas réplicas descargando pesos de varios GB al mismo tiempo. Cachear los pesos cerca de los nodos importa.

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  CPU Affinity  NUMA Affinity
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PXB   SYS   0-55          0
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  PXB   SYS   0-55          0
GPU2    NV18  NV18   X    NV18  NV18  NV18  NV18  NV18  SYS   SYS   0-55          0
GPU3    NV18  NV18  NV18   X    NV18  NV18  NV18  NV18  SYS   SYS   0-55          0
GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   PXB   56-111        1
GPU5    NV18  NV18  NV18  NV18  NV18   X    NV18  NV18  SYS   PXB   56-111        1
GPU6    NV18  NV18  NV18  NV18  NV18  NV18   X    NV18  SYS   SYS   56-111        1
GPU7    NV18  NV18  NV18  NV18  NV18  NV18  NV18   X    SYS   SYS   56-111        1

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  NV#  = Connection traversing a bonded set of # NVLinks
```

Leelo así: `NV18` significa 18 NVLinks agrupados entre cada par de GPUs, una malla NVSwitch completa. Si ves `SYS` o `PHB` entre GPUs en un nodo HGX/DGX, el fabric NVSwitch no está funcionando. La solución habitual es iniciar el servicio **Fabric Manager** (`nvidia-fabricmanager`). Sin él, las aplicaciones CUDA en sistemas con NVSwitch fallan al inicializarse.

---

## 5. Bibliotecas de aceleración (CUDA-X)

| Biblioteca | Propósito | Quién la usa directamente |
|---|---|---|
| **CUDA** (driver y toolkit) | Modelo de programación, compilador (`nvcc`), runtime | Desarrolladores de frameworks y kernels; todos, de forma indirecta |
| **cuDNN** | Primitivas optimizadas para redes neuronales profundas (conv, attention, normalización) | PyTorch, TensorFlow y JAX la llaman por debajo |
| **cuBLAS / cuBLASLt** | Álgebra lineal densa (GEMM) | Frameworks, TensorRT |
| **NCCL** | Comunicaciones colectivas (all-reduce, all-gather, broadcast) entre GPUs y nodos | PyTorch DDP/FSDP, Megatron, NeMo |
| **DALI** | Carga y aumentación de datos acelerada por GPU | Pipelines de entrenamiento de visión con preprocesamiento limitado por CPU |
| **RAPIDS** | Dataframes y ML en GPU (cuDF, cuML, cuGraph, cuVS para búsqueda vectorial) | Data engineers y data scientists |

**Compatibilidad driver/CUDA:** el driver es retrocompatible con runtimes de CUDA más viejos. Un contenedor construido para CUDA 12.x necesita un driver en el host que soporte 12.x. Por eso los contenedores de NGC indican una versión mínima de driver, y por eso el GPU Operator gestiona el driver como un componente versionado y contenerizado.

### RAPIDS en un ejemplo

RAPIDS cambia el paso de ETL, no el modelo. El modo acelerador `cudf.pandas` ejecuta código pandas sin modificar en la GPU y vuelve a la CPU para las operaciones no soportadas:

```
$ python -m cudf.pandas etl_job.py
```

**Caso de uso:** feature engineering sobre cientos de millones de filas, donde el job de entrenamiento en GPU de otro modo esperaría a un pipeline de pandas en CPU. **No encaja:** datos chicos que entran en la caché de la CPU, o UDFs de Python pesadas fila por fila.

---

## 6. Stack de inferencia: TensorRT, TensorRT-LLM, Triton, Dynamo, NIM

Esta es el área más evaluada del tema porque los productos se superponen.

### 6.1 TensorRT: un compilador optimizador, no un servidor

TensorRT toma una red entrenada (normalmente ONNX) y produce un **engine** serializado (`.plan`) optimizado para una arquitectura de GPU específica y una versión de TensorRT específica. Internamente:

1. **Parsea** el grafo y elimina capas muertas o no-op.
2. **Fusiona capas y tensores**, por ejemplo Conv, BiasAdd y ReLU en un solo kernel. Esto reduce los lanzamientos de kernels y los viajes de ida y vuelta a memoria.
3. **Reduce la precisión**: de FP32 a FP16, BF16, FP8 o INT8 (con calibración o quantization-aware training), y FP4 en Blackwell. Esto aumenta el throughput de los Tensor Cores y reduce el tráfico de memoria.
4. **Auto-ajusta los kernels**: mide los tiempos de kernels candidatos (tactics) en la GPU real y se queda con el más rápido.
5. **Planifica la memoria**: reutiliza los buffers de activaciones entre capas.

La consecuencia operativa es que **un engine no es portable**. Un engine construido en una L4 no se va a deserializar en una H100, y un engine de TensorRT 10.x no se va a cargar en otra versión mayor o menor. Construí los engines en CI sobre el tipo de GPU de destino, o dejá que NIM elija un perfil precompilado.

```
$ trtexec --onnx=resnet50.onnx --saveEngine=resnet50_fp16.plan --fp16 \
    --minShapes=input:1x3x224x224 --optShapes=input:32x3x224x224 --maxShapes=input:64x3x224x224
&&&& RUNNING TensorRT.trtexec [TensorRT v100x00] # trtexec --onnx=resnet50.onnx ...
[I] [TRT] ----------------------------------------------------------------
[I] [TRT] Input filename:   resnet50.onnx
[I] [TRT] ONNX IR version:  0.0.8
[I] [TRT] ----------------------------------------------------------------
[I] [TRT] Detected 1 inputs and 1 output network tensors.
[I] Engine built in 74.3 sec.
[I] === Performance summary ===
[I] Throughput: 4126.7 qps
[I] Latency: min = 7.41 ms, max = 8.12 ms, mean = 7.66 ms, median = 7.64 ms, percentile(99%) = 7.98 ms
[I] GPU Compute Time: min = 7.32 ms, max = 8.01 ms, mean = 7.55 ms, median = 7.53 ms, percentile(99%) = 7.86 ms
&&&& PASSED TensorRT.trtexec [TensorRT v100x00] # trtexec --onnx=resnet50.onnx ...
```

(Salida representativa. Los números absolutos dependen de la GPU, el batch size y la versión.)

### 6.2 TensorRT-LLM: optimizaciones específicas para LLMs

La compilación genérica de grafos no alcanza para los LLMs, porque el decoding autorregresivo está limitado por el ancho de banda de memoria y las requests tienen longitudes distintas. TensorRT-LLM agrega:

- **In-flight (continuous) batching**: las requests nuevas se suman al batch en cada step de token en lugar de esperar a que termine el batch completo.
- **KV cache paginada**: la KV cache se asigna en bloques, como en la paginación de memoria virtual, lo que reduce la fragmentación y aumenta la concurrencia.
- **Cuantización**: FP8, INT8/INT4 weight-only, AWQ y FP4 en Blackwell.
- **Tensor parallelism y pipeline parallelism**: reparte un modelo entre GPUs (vía NVLink) y nodos.
- **Speculative decoding** y kernels de attention optimizados.

### 6.3 Triton Inference Server (Dynamo-Triton)

Triton es un **servidor de inferencia open source y multi-framework**. En 2025 NVIDIA lo incorporó a la plataforma Dynamo como *NVIDIA Dynamo-Triton*; el servidor, las APIs y el concepto de model repository no cambian. Usalo cuando servís **muchos modelos de muchos frameworks** detrás de una sola API estándar (protocolo KServe v2 sobre HTTP/gRPC).

| Capacidad | Efecto en producción |
|---|---|
| Backends: TensorRT, TensorRT-LLM, ONNX Runtime, PyTorch (LibTorch), TensorFlow, OpenVINO, Python, vLLM, FIL (modelos de árboles) | Una sola plataforma de serving sin importar el framework de entrenamiento |
| **Dynamic batching** | Combina requests individuales del lado del servidor en batches, cambiando una demora de cola acotada por throughput |
| **Ejecución concurrente de modelos** | Varias instancias de uno o más modelos en la misma GPU (`instance_group`) |
| **Ensembles / BLS** | Pipeline de preprocesamiento, modelo y postprocesamiento dentro del servidor, sin saltos de red adicionales |
| **Model repository** | Ruta local, PVC, S3, GCS o Azure; soporta carga y descarga en caliente (`--model-control-mode`) |
| **Métricas en :8002** | Métricas Prometheus de tiempo en cola, tiempo de cómputo, cantidad de requests y utilización de GPU |

Estructura del model repository:

```
model_repository/
└── resnet50/
    ├── config.pbtxt
    └── 1/
        └── model.plan
```

`config.pbtxt` (formato de texto protobuf, no YAML):

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
instance_group [
  {
    count: 2
    kind: KIND_GPU
  }
]
dynamic_batching {
  preferred_batch_size: [ 16, 32 ]
  max_queue_delay_microseconds: 2000
}
```

### 6.4 NVIDIA Dynamo

**Dynamo** es el framework open source de NVIDIA para **inferencia de LLMs distribuida a escala de datacenter**, anunciado en 2025. Apunta a problemas que un único proceso de servidor no puede resolver:

- **Serving desagregado**: ejecuta el prefill (limitado por cómputo) y el decode (limitado por ancho de banda de memoria) en pools de GPUs separados que se dimensionan de forma independiente.
- **Routing consciente de la KV cache**: envía cada request al worker que ya tiene un prefijo coincidente en su KV cache.
- **Offloading de la KV cache** a niveles de memoria y storage más baratos.
- **Engines intercambiables**: TensorRT-LLM, vLLM, SGLang.

Usalo para flotas grandes de LLMs multi-nodo donde la eficiencia de GPU a escala es el principal factor de costo.

### 6.5 NIM: NVIDIA Inference Microservices

**NIM** empaqueta un modelo, un engine de inferencia optimizado (TensorRT-LLM, o vLLM/SGLang según el NIM), las dependencias de runtime y una **API estándar de la industria** (compatible con OpenAI para LLMs) en un solo contenedor de `nvcr.io/nim/...`. Al arrancar detecta la GPU y selecciona el **perfil** optimizado correspondiente: precisión, grado de tensor parallelism y engine.

- **Propósito:** time-to-production. Pasás de cero a un endpoint optimizado y con soporte en minutos, en lugar de construir vos mismo un engine de TensorRT-LLM y una configuración de Triton.
- **Licenciamiento:** el uso en producción queda cubierto por **NVIDIA AI Enterprise**; los miembros del NVIDIA Developer Program pueden usar NIM para desarrollo y pruebas.
- **Familias:** NIMs de LLM, NIMs de embedding y reranking (NeMo Retriever, usados para RAG), visión, speech (Riva), biología (BioNeMo) y otros.

### 6.6 Comparación de productos de inferencia

| | TensorRT | TensorRT-LLM | Triton (Dynamo-Triton) | Dynamo | NIM |
|---|---|---|---|---|---|
| **Categoría** | SDK de compilador y runtime | Biblioteca y runtime de optimización de LLMs | Servidor de inferencia | Framework de serving distribuido de LLMs | Microservicio empaquetado |
| **Entrada** | ONNX o grafo de framework | Checkpoint de LLM | Model repository (cualquier backend) | Engines (TRT-LLM, vLLM, SGLang) | Nada; el modelo viene incluido |
| **Salida** | Engine `.plan` | Engine y runtime de LLM optimizados | Endpoints HTTP/gRPC, métricas | Serving, routing y desagregación a nivel de flota | Endpoint compatible con OpenAI |
| **Ideal para** | La menor latencia para un modelo en hardware conocido | El máximo de tokens/s de LLM por GPU | Plataformas multi-modelo y multi-framework | Despliegues muy grandes de LLMs multi-nodo | Despliegue de GenAI rápido y con soporte |
| **Esfuerzo** | Alto (build por GPU y versión) | Alto | Medio | Alto | Bajo |
| **Flexibilidad** | Total | Alta | Alta | Alta | Limitada al catálogo (o NIM "LLM-agnostic" para arquitecturas soportadas) |
| **Soporte** | SDK abierto; con soporte bajo AI Enterprise | Open source; con soporte bajo AI Enterprise | Open source; con soporte bajo AI Enterprise | Open source | AI Enterprise |

Se componen en lugar de competir. Un NIM contiene engines de TensorRT-LLM. Triton puede servir engines de TensorRT-LLM. Dynamo orquesta engines a escala de flota.

---

## 7. NeMo: construir y personalizar IA generativa

NVIDIA describe que los LLMs tienen casos de uso en generación de contenido, resumen, traducción, generación de código, búsqueda y RAG, agentes conversacionales y asistentes específicos de dominio en salud, finanzas y retail. **NeMo** es el framework y el conjunto de microservicios que se usa para **construir, personalizar, evaluar y proteger** esos modelos:

| Componente | Propósito |
|---|---|
| **NeMo Framework** | Entrenamiento y fine-tuning a escala (paralelismo basado en Megatron: tensor, pipeline, sequence, expert); pretraining, SFT, PEFT/LoRA, RLHF/DPO |
| **NeMo Curator** | Curación de datos acelerada por GPU: deduplicación, filtrado por calidad, eliminación de PII |
| **NeMo Customizer** | Microservicio para fine-tuning (p. ej., LoRA) a través de una API |
| **NeMo Evaluator** | Benchmarks y evaluación LLM-as-judge |
| **NeMo Guardrails** | Rails programables para control de temas, chequeos de jailbreak y seguridad, verificación de hechos contra el contexto recuperado |
| **NeMo Retriever** | NIMs de embedding, reranking y extracción para pipelines de RAG |

El ciclo de vida típico es: curar (Curator), entrenar o personalizar (Framework o Customizer), evaluar (Evaluator), optimizar (TensorRT-LLM), desplegar (NIM), proteger (Guardrails), fundamentar (Retriever).

---

## 8. Software de plataforma: AI Enterprise y NGC

### 8.1 NVIDIA AI Enterprise

Es una **plataforma de software end-to-end y licenciada** que incluye NIM, NeMo, Triton, TensorRT, RAPIDS, los GPU y Network Operators, y más. Pagás por:

- **Soporte empresarial** con SLAs.
- **Seguridad**: escaneo de CVEs, parches y contenedores firmados.
- **Estabilidad de API mediante branches**: Feature Branches (lo último), Production Branches (unos 9 meses de estabilidad) y Long-Term Support Branches (varios años, para entornos regulados).
- **Certificación** en NVIDIA-Certified Systems, los principales hipervisores (vGPU), distribuciones de Kubernetes y clouds.

Señal de examen: *"la empresa necesita software de IA con soporte, seguro y listo para producción"* → **NVIDIA AI Enterprise**.

### 8.2 NGC

**NGC** es el hub de NVIDIA para software optimizado para GPU: contenedores (`nvcr.io`), modelos preentrenados, Helm charts y recursos. Los contenedores se prueban contra combinaciones específicas de CUDA/driver y se publican mensualmente (tags `YY.MM`, p. ej., `tritonserver:24.12-py3`).

La autenticación contra `nvcr.io` usa el nombre de usuario literal `$oauthtoken` y una API key de NGC como contraseña:

```
$ export NGC_API_KEY=nvapi-xxxxxxxxxxxxxxxxxxxx
$ echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin
Login Succeeded
```

---

## 9. Gestión y orquestación de infraestructura

### 9.1 NVIDIA GPU Operator

**Problema:** cada nodo GPU de Kubernetes necesita un driver compatible, el NVIDIA Container Toolkit, el device plugin, labels de features, monitoreo y, opcionalmente, configuración de MIG. Gestionar todo eso a mano en una flota causa drift y caídas durante los upgrades.

**Solución:** el GPU Operator (Operator Framework, CRD `ClusterPolicy`) despliega y gestiona el ciclo de vida de todo eso como contenedores:

| Componente | Rol |
|---|---|
| `nvidia-driver-daemonset` | Driver de kernel contenerizado (se puede deshabilitar cuando el driver del host ya está preinstalado) |
| `nvidia-container-toolkit-daemonset` | Configura containerd o CRI-O para inyectar GPUs en los contenedores |
| `nvidia-device-plugin-daemonset` | Anuncia `nvidia.com/gpu` (o recursos MIG) al kubelet |
| `gpu-feature-discovery` | Etiqueta los nodos (`nvidia.com/gpu.product`, `gpu.memory`, `cuda.driver.major`…) |
| `nvidia-dcgm-exporter` | Métricas Prometheus desde DCGM |
| `nvidia-mig-manager` | Aplica la geometría MIG a partir del label de nodo `nvidia.com/mig.config` |
| `nvidia-operator-validator` | Valida de punta a punta driver, toolkit, CUDA y plugin |
| Node Feature Discovery | Detecta los dispositivos PCI de NVIDIA para que el operator apunte a los nodos correctos |

El **Network Operator** hace lo mismo del lado del networking: drivers MOFED/DOCA, RDMA shared device plugin, SR-IOV y Multus. Combinado con el GPU Operator, habilita GPUDirect RDMA dentro de Kubernetes.

**Valores de Helm para una instalación de producción** (`gpu-operator-values.yaml`):

```yaml
operator:
  defaultRuntime: containerd
driver:
  enabled: true
  rdma:
    enabled: false
  upgradePolicy:
    autoUpgrade: true
    maxParallelUpgrades: 1
    maxUnavailable: "25%"
    drain:
      enable: true
      force: false
      timeoutSeconds: 300
toolkit:
  enabled: true
devicePlugin:
  enabled: true
  config:
    name: time-slicing-config
    default: any
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 15s
gfd:
  enabled: true
mig:
  strategy: single
migManager:
  enabled: true
nfd:
  enabled: true
validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "true"
```

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
"nvidia" has been added to your repositories
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --version "${GPU_OPERATOR_VERSION}" \
    -f gpu-operator-values.yaml --wait
NAME: gpu-operator
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

Fijá `GPU_OPERATOR_VERSION` a una release que figure en las release notes del GPU Operator y en su matriz de plataformas soportadas (kernel, sistema operativo, versión de Kubernetes, GPU).

```
$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xkqp                                   1/1     Running     0          6m
gpu-operator-6d8f9c7b5-hl2rm                                  1/1     Running     0          7m
gpu-operator-node-feature-discovery-gc-5f7d8c6b9-qv4tn        1/1     Running     0          7m
gpu-operator-node-feature-discovery-master-7c9f6d5b8-k2zrx    1/1     Running     0          7m
gpu-operator-node-feature-discovery-worker-9mbvd              1/1     Running     0          7m
nvidia-container-toolkit-daemonset-jw8tt                      1/1     Running     0          6m
nvidia-cuda-validator-p6v9c                                   0/1     Completed   0          4m
nvidia-dcgm-exporter-8lq2n                                    1/1     Running     0          6m
nvidia-device-plugin-daemonset-r5hcz                          1/1     Running     0          6m
nvidia-driver-daemonset-tz7fw                                 1/1     Running     0          7m
nvidia-mig-manager-cx4wd                                      1/1     Running     0          5m
nvidia-operator-validator-wqm4s                               1/1     Running     0          6m
```

El orden de arranque es driver, después toolkit, después device plugin. Cada uno depende del anterior, y el validator controla la cadena. Cuando algo está trabado, mirá el **primer** componente que no esté en Running en ese orden.

### 9.2 Compartir GPUs: MIG versus time-slicing versus vGPU versus MPS

| Mecanismo | Aislamiento | Granularidad | Caso de uso | Trade-off |
|---|---|---|---|---|
| **MIG** (Multi-Instance GPU; A100, H100, H200, B200…) | **Hardware**: SMs dedicados, slices de L2, controladores de memoria, aislamiento de fallas | Perfiles fijos (p. ej., hasta 7 instancias) | Inferencia multi-tenant con garantías de QoS | Geometría fija; reconfigurar requiere que la GPU esté ociosa |
| **Time-slicing** (device plugin) | **Ninguno**: memoria compartida, sin aislamiento de fallas | Cualquier cantidad de réplicas | Dev/test, notebooks, cargas en ráfagas y de baja utilización | Noisy neighbors; un OOM puede afectar a todos; sin límites de memoria |
| **vGPU** (AI Enterprise sobre hipervisores) | A nivel de hipervisor; con time-slicing o respaldado por MIG | Perfiles por VM | Empresas con VMware/VDI o basadas en VMs | Requiere licenciamiento vGPU y un hipervisor soportado |
| **MPS** (Multi-Process Service) | Parcial (límites de cómputo por cliente), dominio de fallas compartido | Por proceso | Muchos procesos CUDA chicos de tenants que cooperan | Un crash puede afectar a todos los clientes |

Perfiles MIG en una H100 80GB:

| Perfil | Instancias por GPU | Memoria de cada una |
|---|---|---|
| `1g.10gb` | 7 | 10 GB |
| `1g.20gb` | 4 | 20 GB |
| `2g.20gb` | 3 | 20 GB |
| `3g.40gb` | 2 | 40 GB |
| `4g.40gb` | 1 | 40 GB |
| `7g.80gb` | 1 | 80 GB |

**Configuración de time-slicing** (referenciada desde los valores de Helm de arriba):

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
        renameByDefault: false
        failRequestsGreaterThanOne: true
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```

**Aplicar MIG** con el MIG Manager es declarativo, mediante un label de nodo:

```
$ kubectl label node gpu-node-01 nvidia.com/mig.config=all-1g.10gb --overwrite
node/gpu-node-01 labeled

$ kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}'
success

$ kubectl describe node gpu-node-01 | grep -E 'nvidia.com/(gpu|mig)'
  nvidia.com/gpu:     56
  nvidia.com/gpu:     56
```

Con `mig.strategy: single`, cada instancia MIG se anuncia como `nvidia.com/gpu` (8 GPUs × 7 = 56). Con `mixed`, aparecen como `nvidia.com/mig-1g.10gb` y nombres de recursos similares.

### 9.3 DCGM: Data Center GPU Manager

DCGM es la capa de **salud, telemetría, políticas y diagnóstico** de las GPUs de data center. Corre como `nv-hostengine` y se expone mediante `dcgmi`, APIs y `dcgm-exporter` para Prometheus.

```
$ dcgmi discovery -l
8 GPUs found.
+--------+----------------------------------------------------------------------+
| GPU ID | Device Information                                                   |
+--------+----------------------------------------------------------------------+
| 0      | Name: NVIDIA H100 80GB HBM3                                          |
|        | PCI Bus ID: 00000000:18:00.0                                         |
|        | Device UUID: GPU-3b1f6f2a-1c2d-4e5f-8a9b-0c1d2e3f4a5b                |
+--------+----------------------------------------------------------------------+
...

$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 4.x.x                                          |
| Number of GPUs Detected   | 8                                              |
|-----  Deployment  --------+------------------------------------------------|
| Denylist                  | Pass                                           |
| NVML Library              | Pass                                           |
| CUDA Main Library         | Pass                                           |
| Permissions and OS Blocks | Pass                                           |
| Persistence Mode          | Pass                                           |
| Environment Variables     | Pass                                           |
| Page Retirement/Row Remap | Pass                                           |
| Graphics Processes        | Pass                                           |
| Inforom                   | Pass                                           |
+-----  Integration  -------+------------------------------------------------+
| PCIe                      | Pass - All                                     |
+-----  Hardware  ----------+------------------------------------------------+
| GPU Memory                | Pass - All                                     |
+---------------------------+------------------------------------------------+
```

Niveles de diagnóstico: `-r 1` tarda segundos (sanidad del despliegue), `-r 2` tarda unos 2 minutos (agrega PCIe y memoria), `-r 3` tarda decenas de minutos (agrega estrés, targeted power y burn-in). Corré `-r 3` (o el nivel 4 en DCGM más nuevos) en la aceptación del nodo y después de reemplazos de hardware, nunca en un nodo que esté sirviendo tráfico de producción.

### 9.4 Base Command Manager, Run:ai, Fleet Command

| Producto | Capa | Propósito | Usalo cuando |
|---|---|---|---|
| **Base Command Manager** (antes Bright Cluster Manager) | Gestión de clusters bare-metal | Aprovisionamiento (imágenes PXE), categorías de nodos, monitoreo, health checks, despliegue de Slurm o Kubernetes, accounting de cargas | Operás clusters DGX/HGX on-prem (BasePOD/SuperPOD) |
| **Run:ai** | Orquestación de cargas de IA en Kubernetes | Scheduler consciente de GPUs: cuotas, préstamo por encima de la cuota, fair share, preemption, GPUs fraccionales, gang scheduling, dashboards de utilización | Muchos equipos compiten por un pool compartido de GPUs y la utilización es baja |
| **Fleet Command** | Gestión edge (control plane SaaS) | Aprovisionamiento zero-touch, despliegue y actualización remota de apps de IA, acceso remoto seguro en muchos sitios edge | Tiendas de retail, fábricas, hospitales: muchos sitios chicos sin personal de IT |
| **Slurm** (no es de NVIDIA, se integra habitualmente) | Scheduler batch de HPC | Jobs de entrenamiento multi-nodo con gang scheduling | Clusters de entrenamiento al estilo HPC clásico |

Cómo se combinan: Base Command Manager construye el cluster, Kubernetes corre encima con los GPU y Network Operators, Run:ai planifica por arriba y DCGM vigila todo. Fleet Command es el stack equivalente para sitios edge.

---

## 10. SDKs de dominio y frameworks de aplicación

| SDK | Dominio | Caso de uso típico | Palabra clave del examen |
|---|---|---|---|
| **Clara** (incl. MONAI, Parabricks, BioNeMo) | Salud y ciencias de la vida | IA para imágenes médicas, aceleración de genómica, descubrimiento de fármacos | "radiology", "genomics", "protein" |
| **Riva** | Speech AI | ASR, TTS, traducción automática neuronal, en tiempo real y personalizable | "speech recognition", "voice assistant", "transcription" |
| **Morpheus** | Ciberseguridad | Pipelines acelerados por GPU para detección de anomalías, phishing, detección de datos sensibles, telemetría de alto volumen | "detect threats in real time", "SOC" |
| **Metropolis** (incl. DeepStream) | Vision AI / espacios inteligentes | Analítica de video multi-cámara: tránsito, retail, inspección en fábrica | "video analytics", "smart city", "cameras" |
| **Isaac** (Sim, ROS, Lab) | Robótica | Simulación, percepción y manipulación para AMRs y brazos | "robot", "AMR", "sim-to-real" |
| **Merlin** | Sistemas de recomendación | Recomendadores con embeddings grandes, feature engineering y serving | "recommendations", "personalization" |
| **Omniverse** | Simulación 3D y digital twins (OpenUSD) | Digital twins de fábricas y depósitos, datos sintéticos, 3D colaborativo | "digital twin", "USD", "synthetic data" |
| **Holoscan** | Streaming de sensores / edge AI | Dispositivos médicos y pipelines de sensores de baja latencia (sobre IGX) | "medical device", "real-time sensor" |
| **Maxine** | Efectos de video y audio | Eliminación de ruido, contacto visual, super-resolución para videoconferencias | "video conferencing quality" |
| **cuOpt** | Optimización | Ruteo de vehículos y logística | "route optimization" |

---

## 11. Manifiestos de producción de punta a punta

### 11.1 Smoke test: ¿el cluster realmente les da GPUs a los pods?

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
  namespace: default
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-vectoradd
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
      resources:
        limits:
          nvidia.com/gpu: 1
```

```
$ kubectl apply -f cuda-vectoradd.yaml
pod/cuda-vectoradd created

$ kubectl logs cuda-vectoradd
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

### 11.2 Despliegue de un NIM LLM en Kubernetes

Primero creá el pull secret y el secret de la API key:

```
$ kubectl create namespace nim
namespace/nim created

$ kubectl -n nim create secret docker-registry ngc-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NGC_API_KEY"
secret/ngc-secret created

$ kubectl -n nim create secret generic ngc-api \
    --from-literal=NGC_API_KEY="$NGC_API_KEY"
secret/ngc-api created
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nim-cache
  namespace: nim
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-nvme
  resources:
    requests:
      storage: 100Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama31-8b-nim
  namespace: nim
  labels:
    app.kubernetes.io/name: llama31-8b-nim
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: llama31-8b-nim
  template:
    metadata:
      labels:
        app.kubernetes.io/name: llama31-8b-nim
    spec:
      imagePullSecrets:
        - name: ngc-secret
      nodeSelector:
        nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: nim
          # Pin an explicit tag from the NGC catalog in production; latest is shown for brevity.
          image: nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
          imagePullPolicy: IfNotPresent
          env:
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ngc-api
                  key: NGC_API_KEY
            - name: NIM_CACHE_PATH
              value: /opt/nim/.cache
          ports:
            - name: http-openai
              containerPort: 8000
              protocol: TCP
          resources:
            requests:
              cpu: "8"
              memory: 32Gi
              nvidia.com/gpu: 1
            limits:
              memory: 64Gi
              nvidia.com/gpu: 1
          startupProbe:
            httpGet:
              path: /v1/health/ready
              port: http-openai
            periodSeconds: 10
            failureThreshold: 180
          readinessProbe:
            httpGet:
              path: /v1/health/ready
              port: http-openai
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /v1/health/live
              port: http-openai
            periodSeconds: 15
            failureThreshold: 3
          volumeMounts:
            - name: nim-cache
              mountPath: /opt/nim/.cache
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: nim-cache
          persistentVolumeClaim:
            claimName: nim-cache
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 16Gi
---
apiVersion: v1
kind: Service
metadata:
  name: llama31-8b-nim
  namespace: nim
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: llama31-8b-nim
  ports:
    - name: http-openai
      port: 8000
      targetPort: http-openai
      protocol: TCP
```

Notas de diseño:

- **`startupProbe` con un margen de 30 minutos** (180 × 10 s): el primer arranque descarga los pesos. Sin ella, la liveness probe mata el pod a mitad de la descarga y entrás en un loop de reinicios.
- **Caché en PVC**: los reinicios siguientes evitan la descarga de varios GB. Para muchas réplicas, usá `ReadWriteMany` o los CRDs de caché del NIM Operator.
- **`/dev/shm` en memoria**: los perfiles multi-GPU (tensor-parallel) usan memoria compartida para NCCL. El shm por defecto de 64 MiB del contenedor provoca fallas.
- **Estrategia `Recreate`**: con una GPU por nodo, un rolling update necesitaría una segunda GPU libre.
- Para operar a nivel de flota, el **NIM Operator** provee los CRDs `NIMCache` y `NIMService`, que automatizan la caché y el despliegue.

Verificación:

```
$ kubectl -n nim get pods
NAME                              READY   STATUS    RESTARTS   AGE
llama31-8b-nim-7b9d6c5f4d-xk2vq   1/1     Running   0          9m

$ kubectl -n nim logs deploy/llama31-8b-nim | grep -iE 'profile|ready|Uvicorn'
INFO ... Selected profile: tensorrt_llm-h100-fp8-tp1-throughput
INFO ... Model llama-3.1-8b-instruct loaded
INFO ... Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)

$ kubectl -n nim port-forward svc/llama31-8b-nim 8000:8000 &
Forwarding from 127.0.0.1:8000 -> 8000

$ curl -s localhost:8000/v1/models
{"object":"list","data":[{"id":"meta/llama-3.1-8b-instruct","object":"model","created":1762934400,"owned_by":"system","root":"meta/llama-3.1-8b-instruct","parent":null,"max_model_len":131072}]}

$ curl -s localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"What does MIG do in one sentence?"}],"max_tokens":64}'
{"id":"chat-5f1c...","object":"chat.completion","created":1762934460,"model":"meta/llama-3.1-8b-instruct","choices":[{"index":0,"message":{"role":"assistant","content":"MIG partitions a single GPU into isolated instances, each with dedicated compute, cache, and memory."},"finish_reason":"stop"}],"usage":{"prompt_tokens":19,"completion_tokens":21,"total_tokens":40}}
```

El nombre del perfil te dice el backend, la GPU, la precisión y el paralelismo. Para ver qué perfiles son compatibles antes de desplegar:

```
$ docker run --rm --gpus all -e NGC_API_KEY \
    nvcr.io/nim/meta/llama-3.1-8b-instruct:latest list-model-profiles
SYSTEM INFO
- Free GPUs:
  -  [2330:10de] (0) NVIDIA H100 80GB HBM3 (H100 80GB) [current utilization: 0%]
MODEL PROFILES
- Compatible with system and runnable:
  - <profile-id> (tensorrt_llm-h100-fp8-tp1-throughput)
  - <profile-id> (tensorrt_llm-h100-bf16-tp1-throughput)
  - <profile-id> (vllm-bf16-tp1)
- Incompatible with system:
  - <profile-id> (tensorrt_llm-h100-fp8-tp2-latency)
  ...
```

Forzá un perfil con la variable de entorno `NIM_MODEL_PROFILE` cuando la selección automática no es la que querés.

### 11.3 Despliegue de Triton Inference Server

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton
  namespace: inference
  labels:
    app.kubernetes.io/name: triton
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: triton
  template:
    metadata:
      labels:
        app.kubernetes.io/name: triton
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
    spec:
      imagePullSecrets:
        - name: ngc-secret
      containers:
        - name: triton
          image: nvcr.io/nvidia/tritonserver:24.12-py3
          command:
            - tritonserver
          args:
            - --model-repository=/models
            - --model-control-mode=poll
            - --repository-poll-secs=30
            - --strict-readiness=true
            - --log-verbose=0
          ports:
            - name: http
              containerPort: 8000
            - name: grpc
              containerPort: 8001
            - name: metrics
              containerPort: 8002
          resources:
            requests:
              cpu: "4"
              memory: 16Gi
              nvidia.com/gpu: 1
            limits:
              memory: 32Gi
              nvidia.com/gpu: 1
          startupProbe:
            httpGet:
              path: /v2/health/ready
              port: http
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /v2/health/ready
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: http
            periodSeconds: 15
          volumeMounts:
            - name: model-repo
              mountPath: /models
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: model-repo
          persistentVolumeClaim:
            claimName: triton-model-repo
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton
  namespace: inference
spec:
  selector:
    app.kubernetes.io/name: triton
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

Los archivos `.plan` del repositorio tienen que haberse construido para el tipo de GPU de los nodos donde cae este Deployment. Fijá los nodos con un `nodeSelector` sobre `nvidia.com/gpu.product` cuando el cluster mezcla generaciones de GPU.

```
$ curl -s localhost:8000/v2/models/resnet50/ready -o /dev/null -w '%{http_code}\n'
200

$ curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|queue_duration_us|compute_infer_duration_us)'
nv_inference_request_success{model="resnet50",version="1"} 184223
nv_inference_queue_duration_us{model="resnet50",version="1"} 92311842
nv_inference_compute_infer_duration_us{model="resnet50",version="1"} 1380225511

$ perf_analyzer -m resnet50 -u localhost:8001 -i grpc --concurrency-range 1:16:4
*** Measurement Settings ***
  Batch size: 1
  Service Kind: TRITON
  Using "time_windows" mode for stabilization
  Measurement window: 5000 msec
  Latency limit: 0 msec
  Concurrency limit: 16 concurrent requests
...
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 612.4 infer/sec, latency 1630 usec
Concurrency: 5, throughput: 2718.9 infer/sec, latency 1836 usec
Concurrency: 9, throughput: 3870.2 infer/sec, latency 2322 usec
Concurrency: 13, throughput: 4011.6 infer/sec, latency 3238 usec
```

Cómo leerlo: cuando el throughput se aplana mientras la latencia sigue subiendo, llegaste a la saturación de la GPU. Dividí `queue_duration_us` por la cantidad de requests para obtener el tiempo medio en cola. Si crece, aumentá `instance_group.count`, ajustá el dynamic batching o agregá réplicas.

### 11.4 Alertas de GPU a partir de métricas de DCGM

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-health
  namespace: gpu-operator
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu.health
      rules:
        - alert: GPUXidErrorDetected
          expr: DCGM_FI_DEV_XID_ERRORS > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} reported XID {{ $value }}"
            runbook: "Check dmesg for NVRM Xid lines and run dcgmi diag -r 2 after draining the node"
        - alert: GPUFramebufferNearlyFull
          expr: |
            DCGM_FI_DEV_FB_USED
              /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
              > 0.95
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} framebuffer above 95 percent"
        - alert: GPUAllocatedButIdle
          expr: |
            avg_over_time(DCGM_FI_PROF_GR_ENGINE_ACTIVE[30m]) < 0.05
              and on (Hostname, gpu)
            DCGM_FI_DEV_FB_USED > 1024
          for: 30m
          labels:
            severity: info
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} holds memory but is nearly idle"
        - alert: GPUHighTemperature
          expr: DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} temperature {{ $value }} C"
```

`DCGM_FI_DEV_XID_ERRORS` contiene el **valor del último XID** reportado, no un contador. `GPUAllocatedButIdle` es la alerta de FinOps: es la señal que justifica MIG, time-slicing o las GPUs fraccionales de Run:ai.

---

## 12. Verificación y diagnóstico de fallas

### 12.1 Secuencia de verificación de abajo hacia arriba

```
$ nvidia-smi
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 570.xx.xx              Driver Version: 570.xx.xx      CUDA Version: 12.8     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
| N/A   34C    P0            118W /  700W |   61234MiB /  81559MiB |     87%      Default |
|                                         |                        |             Disabled |
+-----------------------------------------+------------------------+----------------------+
...
+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|    0   N/A  N/A           48213      C   /opt/nim/llm/.venv/bin/python3        61210MiB |
+-----------------------------------------------------------------------------------------+
```

`CUDA Version` en el encabezado es la **versión máxima de CUDA que soporta el driver**, no el toolkit instalado. Volatile Uncorr. ECC debería ser `0`. `Persistence-M On` evita la latencia de reinicialización del driver.

Checklist completo, capa por capa:

| # | Capa | Comando | Resultado sano |
|---|---|---|---|
| 1 | Hardware y driver | `nvidia-smi` | Todas las GPUs listadas, ECC 0, driver esperado |
| 2 | Fabric NVSwitch | `systemctl status nvidia-fabricmanager`, `nvidia-smi topo -m` | Active; `NV#` entre GPUs |
| 3 | Fabric de red | `ibstat`, `ibdev2netdev` | Puertos `Active`, `LinkUp`, rate esperado |
| 4 | Salud | `dcgmi diag -r 2` | Todo `Pass` |
| 5 | Operator de K8s | `kubectl get pods -n gpu-operator` | Todo en Running o Completed |
| 6 | Recursos de K8s | `kubectl describe node <n> \| grep nvidia.com/gpu` | Capacity y Allocatable > 0 |
| 7 | Camino de la carga de trabajo | Pod `cuda-vectoradd` | `Test PASSED` |
| 8 | Comunicaciones colectivas | `all_reduce_perf` (nccl-tests) | Bus bandwidth cercano a la especificación del fabric |
| 9 | Serving | `/v1/health/ready` (NIM), `/v2/health/ready` (Triton) | HTTP 200 |
| 10 | Telemetría | `curl :9400/metrics` (dcgm-exporter) | Series `DCGM_FI_*` presentes |

```
$ ./build/all_reduce_perf -b 8 -e 8G -f 2 -g 8
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
  8589934592    2147483648     float     sum      -1    37210  230.85  403.99      0    37198  230.92  404.11      0
# Avg bus bandwidth    : 3xx.xx
```

(Salida representativa para un nodo NVSwitch de 8 GPUs. Compará `busbw` con tamaños de mensaje grandes contra el valor publicado para tu plataforma. Un resultado mucho más bajo apunta a la topología, al Fabric Manager o a la configuración de PCIe/ACS.)

### 12.2 Síntoma → causa → solución

| Síntoma | Causa probable | Verificación | Solución |
|---|---|---|---|
| `nvidia-driver-daemonset` en `CrashLoopBackOff` | Driver ya instalado en el host, faltan kernel headers, Secure Boot bloquea módulos sin firmar, o kernel no soportado | `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset -c nvidia-driver-ctr` | Configurá `driver.enabled=false` cuando usás el driver del host; usá un kernel soportado; usá drivers firmados o precompilados |
| Pods en `Pending`: `Insufficient nvidia.com/gpu` | Device plugin sin correr, todas las GPUs asignadas, o estrategia MIG que no coincide | `kubectl describe node`; logs del device plugin | Arreglá el plugin; hacé coincidir el nombre del recurso (`nvidia.com/gpu` vs `nvidia.com/mig-*`); agregá capacidad |
| `mig.config.state=failed` | Procesos de GPU todavía corriendo durante la reconfiguración, o un perfil no válido para esta GPU | `kubectl logs -n gpu-operator ds/nvidia-mig-manager` | Drená las cargas de la GPU; usá un perfil de la lista de perfiles MIG de la GPU |
| Una app CUDA falla en HGX/DGX con `system not yet initialized` | Fabric Manager no está corriendo o su versión no coincide con la del driver | `systemctl status nvidia-fabricmanager` | Instalá un Fabric Manager que coincida con la versión del driver e inicialo |
| `ImagePullBackOff` desde `nvcr.io` con `401` | Secret incorrecto: el usuario no es literalmente `$oauthtoken`, o la key expiró | Eventos de `kubectl describe pod` | Recreá el secret con `'$oauthtoken'` entre comillas simples y una key válida |
| Loop de reinicios del NIM durante el primer arranque | La liveness probe mata el pod durante la descarga del modelo | Los logs muestran el progreso de la descarga y después el contenedor se reinicia | Agregá una `startupProbe` con un margen amplio; persistí la caché |
| NIM: ningún perfil compatible, o un fallback lento a vLLM | GPU no soportada para un perfil optimizado, o no alcanzan las GPUs/memoria para TP | `list-model-profiles` | Usá una GPU soportada, pedí más GPUs o configurá `NIM_MODEL_PROFILE` |
| TensorRT: `Serialization assertion ... failed` o error de deserialización del engine | Engine construido en otra arquitectura de GPU u otra versión de TensorRT | Compará la GPU y la versión de TRT de build y de runtime | Reconstruí el engine en el hardware de destino; fijá las versiones de las imágenes |
| Triton: modelo `UNAVAILABLE` | Error en `config.pbtxt`, dims o nombre incorrectos, falta el directorio de versión, backend que no coincide | `curl :8000/v2/repository/index -X POST`; logs de arranque | Corregí la config; asegurate de que la estructura sea `<model>/<version>/model.*` |
| Baja utilización de GPU durante el entrenamiento | Cuello de botella en el data loader (CPU, storage) o limitado por comunicación | `DCGM_FI_PROF_GR_ENGINE_ACTIVE`, uso de CPU, I/O wait | DALI, RAPIDS, GPUDirect Storage, más workers del loader, caché NVMe local |
| El entrenamiento multi-nodo escala mal | NCCL usa sockets TCP en lugar de IB/RoCE, o GPUDirect RDMA no está disponible | Logs con `NCCL_DEBUG=INFO` (`NET/IB` vs `NET/Socket`) | Network Operator, RDMA device plugin, `NCCL_IB_HCA` correcto, módulo de peer memory |
| XID 79 | La GPU se cayó del bus (energía, temperatura, PCIe) | `dmesg \| grep -i xid` | Drená el nodo; revisá energía y refrigeración; RMA si se repite |
| XID 48 / 94 / 95 | Errores ECC (DBE, contenidos o no contenidos) | `nvidia-smi -q -d ECC,ROW_REMAPPER` | 94: reiniciá la app afectada; 95 o 48 repetido: reseteá la GPU o drená y hacé RMA |
| XID 13 / 31 / 43 | Normalmente fallas de la aplicación (acceso ilegal a memoria, falla de MMU) | Logs de la app, `compute-sanitizer` | Corregí la aplicación; normalmente no es hardware |

```
$ sudo dmesg -T | grep -i xid
[Wed Nov 12 09:14:27 2026] NVRM: Xid (PCI:0000:9a:00): 79, pid='<unknown>', name=<unknown>, GPU has fallen off the bus.
```

### 12.3 Mapa rápido escenario → solución (práctica para el examen)

| Escenario | Respuesta |
|---|---|
| Desplegar rápido un endpoint de LLM con soporte, con una API compatible con OpenAI | **NIM** |
| Servir modelos de TensorFlow, PyTorch y ONNX detrás de una sola API con dynamic batching | **Triton** |
| Maximizar el throughput de inferencia de una CNN en una GPU dada | **TensorRT** |
| Maximizar los tokens/s de un LLM con in-flight batching y KV cache paginada | **TensorRT-LLM** |
| Prefill/decode desagregado en una flota grande de LLMs | **Dynamo** |
| Hacer fine-tuning de un LLM con datos de la empresa y agregar rails de seguridad | **NeMo** (Customizer + Guardrails) |
| Construir un pipeline de RAG con embedding y reranking | NIMs de **NeMo Retriever** |
| Acelerar el ETL en pandas sin reescribir código | **RAPIDS** (`cudf.pandas`) |
| Automatizar driver, toolkit y device plugin en nodos GPU de Kubernetes | **GPU Operator** |
| Habilitar RDMA / GPUDirect en Kubernetes | **Network Operator** |
| Monitorear la salud de las GPUs y correr diagnósticos | **DCGM** (+ dcgm-exporter) |
| Aprovisionar y gestionar un cluster DGX on-prem | **Base Command Manager** |
| Compartir un pool de GPUs entre equipos con cuotas y fair share | **Run:ai** |
| Gestionar apps de IA en cientos de tiendas de retail | **Fleet Command** |
| Particiones de GPU aisladas por hardware para inferencia multi-tenant | **MIG** |
| GPUs dentro de VMs de VMware | **vGPU** (AI Enterprise) |
| Descargar el procesamiento de red, storage y seguridad y aislar la infraestructura | **BlueField DPU** (DOCA) |
| Fabric lossless de baja latencia para entrenamiento a gran escala | **Quantum InfiniBand** |
| Fabric Ethernet optimizado para IA | **Spectrum-X** |
| Cargar datos desde el storage directamente a la memoria de la GPU | **GPUDirect Storage** |
| Software de IA empresarial con soporte, seguro y certificado | **NVIDIA AI Enterprise** |
| Descargar contenedores, modelos y Helm charts optimizados | **NGC** |
| Diseño de referencia de supercomputadora de IA llave en mano | **DGX SuperPOD** |
| Infraestructura de IA sin capex | **DGX Cloud** |
| Reconocimiento de voz y TTS | **Riva** |
| Imágenes médicas y genómica | **Clara** (MONAI, Parabricks) |
| Detección de amenazas de ciberseguridad en tiempo real | **Morpheus** |
| Analítica de video multi-cámara | **Metropolis / DeepStream** |
| Simulación y percepción de robots | **Isaac** |
| Sistemas de recomendación | **Merlin** |
| Digital twin industrial sobre OpenUSD | **Omniverse** |

---

## 13. Conclusiones clave

1. **Conocé la capa.** La mayoría de las preguntas de "qué producto" se responden identificando la capa: hardware, red, gestión, bibliotecas, frameworks o aplicaciones.
2. **Los productos de inferencia se componen.** TensorRT optimiza, TensorRT-LLM especializa para LLMs, Triton sirve, Dynamo distribuye y NIM empaqueta todo con soporte.
3. **El GPU Operator convierte los nodos GPU en ganado gestionado.** Su cadena de dependencias (driver, toolkit, plugin, validator) es el primer lugar donde mirar cuando las GPUs desaparecen de Kubernetes.
4. **DCGM es la fuente de verdad sobre la salud de las GPUs.** Los códigos XID separan los bugs de aplicación (13, 31, 43) de las fallas de hardware (48, 79, 95).
5. **Compartir es un trade-off.** MIG da aislamiento, time-slicing da densidad sin aislamiento, vGPU cubre las VMs y Run:ai agrega políticas por encima.
6. **AI Enterprise es el envoltorio comercial.** Aporta soporte, seguridad y estabilidad de branches para los componentes abiertos, y es la licencia que cubre NIM en producción.

---

## Referencias

- Guía de estudio del examen NVIDIA AI Infrastructure and Operations (NCA-AIIO): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy — AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- Plataforma NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- Documentación de NVIDIA GPU Operator: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- GPU Operator — GPU time-slicing: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html
- GPU Operator — soporte de MIG: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-mig.html
- NVIDIA Network Operator: https://docs.nvidia.com/networking/display/kubernetes2410/index.html
- NVIDIA Multi-Instance GPU User Guide: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/
- Documentación de NVIDIA DCGM: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- Errores XID de NVIDIA: https://docs.nvidia.com/deploy/xid-errors/index.html
- NVIDIA Fabric Manager User Guide: https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/index.html
- Documentación de NVIDIA NIM for LLMs: https://docs.nvidia.com/nim/large-language-models/latest/introduction.html
- NVIDIA NIM Operator: https://docs.nvidia.com/nim-operator/latest/index.html
- Documentación de NVIDIA Triton Inference Server: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- NVIDIA Dynamo: https://developer.nvidia.com/dynamo
- TensorRT-LLM: https://github.com/NVIDIA/TensorRT-LLM
- NVIDIA NeMo: https://developer.nvidia.com/nemo-framework
- NeMo Guardrails: https://docs.nvidia.com/nemo/guardrails/latest/index.html
- NVIDIA AI Enterprise: https://docs.nvidia.com/ai-enterprise/index.html
- Catálogo NGC: https://catalog.ngc.nvidia.com/
- RAPIDS: https://rapids.ai/
- NCCL: https://developer.nvidia.com/nccl
- nccl-tests: https://github.com/NVIDIA/nccl-tests
- Magnum IO: https://developer.nvidia.com/magnum-io
- GPUDirect Storage: https://docs.nvidia.com/gpudirect-storage/index.html
- NVIDIA Base Command Manager: https://docs.nvidia.com/base-command-manager/index.html
- Documentación de NVIDIA Run:ai: https://run-ai-docs.nvidia.com/
- NVIDIA Fleet Command: https://docs.nvidia.com/fleet-command/index.html
- Arquitectura de referencia NVIDIA DGX SuperPOD: https://docs.nvidia.com/dgx-superpod/index.html
- NVIDIA BlueField DPU / DOCA: https://docs.nvidia.com/doca/sdk/index.html
- NVIDIA Spectrum-X: https://www.nvidia.com/en-us/networking/spectrumx/
- NVIDIA Quantum InfiniBand: https://www.nvidia.com/en-us/networking/products/infiniband/
- NVIDIA Clara: https://developer.nvidia.com/clara
- NVIDIA Riva: https://developer.nvidia.com/riva
- NVIDIA Morpheus: https://developer.nvidia.com/morpheus-cybersecurity
- NVIDIA Metropolis: https://developer.nvidia.com/metropolis
- NVIDIA Isaac: https://developer.nvidia.com/isaac
- NVIDIA Merlin: https://developer.nvidia.com/merlin
- NVIDIA Omniverse: https://developer.nvidia.com/omniverse