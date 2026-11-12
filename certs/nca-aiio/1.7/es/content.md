# 1.7 — Componentes de software del ciclo de vida de desarrollo y despliegue de IA

> **Peso en el examen:** 4.75% · **Examen:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)

---

## 1. Motivación: por qué el stack de software es un problema de infraestructura

Un clúster de GPU sin el stack de software correcto es silicio caro y ocioso. En producción, la mayoría de los incidentes de IA no los causa el hardware. Vienen de **desajustes entre capas de software**:

- Un driver que no soporta la versión de CUDA incluida en un contenedor.
- Un framework de entrenamiento compilado contra otro cuDNN.
- Un servidor de inferencia que carga un engine de TensorRT compilado para otra arquitectura de GPU.
- Un nodo de Kubernetes que tiene GPUs pero ningún device plugin que las anuncie.

El problema de arquitectura es este: el ciclo de vida de la IA abarca **varios perfiles de usuario** (data engineers, data scientists, ML engineers, platform/SRE), **varios runtimes** (notebooks, entrenamiento batch, inferencia online) y **varios schedulers** (Slurm, Kubernetes). Cada etapa tiene perfiles de recursos distintos:

| Etapa | Recurso dominante | Cuello de botella típico | Modo de falla que ve SRE |
|---|---|---|---|
| Preparación de datos | CPU/GPU + throughput de almacenamiento | I/O, ETL en CPU | GPUs sin datos, `GPU_UTIL` bajo durante el entrenamiento |
| Entrenamiento / fine-tuning | Cómputo multi-GPU, multi-nodo + interconexión | Colectivas de NCCL, I/O de checkpoints | Cuelgues en all-reduce, OOM, errores Xid |
| Optimización | GPU única, jobs cortos | Datos de calibración, pérdida de precisión | Regresión de exactitud tras FP8/INT8 |
| Inferencia / serving | Memoria de GPU, latencia | KV cache, batching, arranque en frío | Picos de latencia p99, OOM con prompts largos |
| Monitoreo / reentrenamiento | Pipeline de telemetría | Métricas faltantes | Drift silencioso del modelo, degradación de GPU no detectada |

NVIDIA resuelve esto con un **stack de software en capas y en contenedores**. Cada capa se versiona y se valida en conjunto. La distribución pasa por el **catálogo NGC** y, para soporte empresarial, por **NVIDIA AI Enterprise**.

---

## 2. El stack en capas: un modelo mental

```
┌──────────────────────────────────────────────────────────────────────┐
│ Applications / Workflows: LLM chatbots, RAG, vision, recommender     │
├──────────────────────────────────────────────────────────────────────┤
│ Inference & Serving:  NVIDIA NIM │ Triton Inference Server │ Dynamo  │
│ Optimization:         TensorRT │ TensorRT-LLM │ Model Optimizer       │
├──────────────────────────────────────────────────────────────────────┤
│ Training & Customization: NeMo │ PyTorch │ TensorFlow │ JAX           │
│ Data Science / ETL:       RAPIDS (cuDF, cuML) │ DALI │ Spark-RAPIDS  │
├──────────────────────────────────────────────────────────────────────┤
│ CUDA-X libraries: cuDNN │ cuBLAS │ NCCL │ cuFFT │ GPUDirect Storage  │
├──────────────────────────────────────────────────────────────────────┤
│ CUDA Toolkit / CUDA runtime                                          │
├──────────────────────────────────────────────────────────────────────┤
│ Container runtime: NVIDIA Container Toolkit (containerd/CRI-O/Docker)│
├──────────────────────────────────────────────────────────────────────┤
│ Orchestration: Kubernetes + GPU Operator / Network Operator │ Slurm  │
│ Cluster mgmt:  Base Command Manager │ Run:ai (GPU scheduling)        │
├──────────────────────────────────────────────────────────────────────┤
│ NVIDIA Driver (kernel module) │ Fabric Manager │ DCGM │ MIG          │
├──────────────────────────────────────────────────────────────────────┤
│ Hardware: GPUs │ NVLink/NVSwitch │ InfiniBand/Ethernet │ DPUs        │
└──────────────────────────────────────────────────────────────────────┘
```

**Principio clave para el examen:** el **driver vive en el host**. Todo lo que va desde el runtime de CUDA hacia arriba vive **dentro del contenedor**. El NVIDIA Container Toolkit conecta ambos mundos: al iniciar el contenedor inyecta las bibliotecas del driver del host y los device nodes dentro del contenedor. Esa separación te permite correr un contenedor de PyTorch compilado para CUDA 12.x en cualquier host cuyo driver sea lo suficientemente nuevo. Aplican las reglas de compatibilidad forward/minor-version de CUDA.

---

## 3. Componente por componente, mapeado al ciclo de vida

### 3.1 Preparación e ingesta de datos

| Componente | Qué hace | Por qué importa en producción |
|---|---|---|
| **RAPIDS** (cuDF, cuML, cuGraph) | DataFrames y ML acelerados por GPU, con APIs tipo pandas/scikit-learn | Mueve el ETL de CPU a GPU; feature engineering órdenes de magnitud más rápido |
| **RAPIDS Accelerator for Apache Spark** | Plugin que ejecuta operaciones de Spark SQL/DataFrame en GPUs | Reutiliza pipelines de Spark existentes sin reescribirlos |
| **DALI** (Data Loading Library) | Pipeline de decodificación/aumentación acelerado por GPU para imágenes, video y audio | Elimina el cuello de botella del data loader en CPU que deja a las GPUs sin datos |
| **GPUDirect Storage (GDS)** | Ruta DMA directa entre almacenamiento (NVMe, NVMe-oF, FS paralelo) y memoria de GPU | Evita el bounce buffer de la CPU; baja la latencia y el uso de CPU |
| **NeMo Curator** | Curación de datos escalable para preentrenamiento de LLMs (deduplicación, filtrado, PII) | La calidad de los datos es el principal factor de la calidad de un LLM |

La guía de almacenamiento de NVIDIA hace explícito el punto operativo. El entrenamiento lee grandes datasets de forma repetida. Los checkpoints escriben ráfagas grandes. La inferencia necesita cargar modelos rápido. El almacenamiento debe dimensionarse por **throughput y paralelismo**, no solo por capacidad. El patrón habitual es un diseño por niveles:

- Un filesystem compartido paralelo/de red.
- Caché local en NVMe en cada nodo.
- Una ruta compatible con GDS donde esté soportada.

### 3.2 Desarrollo y entrenamiento de modelos

| Componente | Rol |
|---|---|
| **PyTorch / TensorFlow / JAX (contenedores NGC)** | Frameworks, entregados como contenedores NGC mensuales (`nvcr.io/nvidia/pytorch:YY.MM-py3`) validados con CUDA, cuDNN y NCCL compatibles |
| **NVIDIA NeMo Framework** | Framework end-to-end para construir, personalizar (SFT, PEFT/LoRA, RLHF/DPO) y escalar IA generativa / LLMs; usa Megatron-Core para paralelismo de tensor/pipeline/datos |
| **cuDNN** | Primitivas para redes neuronales profundas (convoluciones, attention, normalización) |
| **cuBLAS** | BLAS en GPU — la multiplicación de matrices es el corazón del entrenamiento |
| **NCCL** | Comunicaciones colectivas (all-reduce, all-gather) entre GPUs y nodos sobre NVLink, InfiniBand, RoCE |
| **Transformer Engine** | Entrenamiento con precisión mixta FP8 en Hopper/Blackwell |
| **Jupyter / NGC notebooks** | Desarrollo interactivo, a menudo sobre porciones más chicas de GPU (MIG) |

**¿Por qué contenedores NGC en lugar de `pip install`?** Los contenedores NGC se compilan, prueban y optimizan en rendimiento cada mes. Fijan una combinación probada de framework + CUDA + cuDNN + NCCL. Eso elimina la fuente más común de fallas del tipo "en mi laptop funciona". También hace que el entrenamiento sea reproducible entre workstation, DGX on-prem y la nube.

### 3.3 Optimización (entre entrenamiento y despliegue)

| Componente | Rol |
|---|---|
| **TensorRT** | SDK para inferencia de alto rendimiento: optimización de grafos, fusión de capas/tensores, auto-tuning de kernels, calibración de precisión (FP16, INT8, FP8, FP4 en GPUs compatibles). Produce un **engine/plan** serializado específico de la arquitectura de GPU y de la versión de TensorRT |
| **TensorRT-LLM** | Biblioteca open source para inferencia de LLMs: in-flight batching, paged KV cache, cuantización, paralelismo de tensor/pipeline, speculative decoding |
| **TensorRT Model Optimizer** | Cuantización (PTQ/QAT), pruning, destilación y sparsity para comprimir modelos antes del despliegue |
| **ONNX** | Formato de intercambio usado comúnmente para pasar un modelo entrenado a TensorRT |

**Trade-off crítico:** un engine de TensorRT **no es portable**. Un engine compilado en una A100 (Ampere, SM 8.0) no corre en una H100 (Hopper, SM 9.0), y está atado a la versión de TensorRT que lo compiló. Por eso los pipelines de producción compilan engines **por SKU de GPU**, idealmente en CI o al momento del despliegue.

### 3.4 Inferencia y serving

| Componente | Qué es | Mejor caso de uso |
|---|---|---|
| **Triton Inference Server** | Servidor de inferencia open source: múltiples backends (TensorRT, TensorRT-LLM, PyTorch, ONNX Runtime, OpenVINO, Python, FIL), dynamic batching, ejecución concurrente de modelos, ensembles, HTTP/gRPC, métricas de Prometheus | Flotas multi-framework y multi-modelo; pipelines a medida |
| **NVIDIA NIM** | **Microservicios** de inferencia preconstruidos y optimizados. Contenedor = modelo + engine optimizado (p. ej. TensorRT-LLM) + API estándar de la industria (compatible con OpenAI para LLMs). Selecciona automáticamente un perfil optimizado para la GPU detectada | El camino más rápido a producción para foundation models; soporte empresarial vía AI Enterprise |
| **NVIDIA Dynamo** | Framework open source de inferencia distribuida para IA generativa a gran escala: prefill/decode desagregados, routing consciente del KV cache, serving multi-nodo | Despliegues muy grandes de LLMs/modelos de razonamiento sobre muchas GPUs/nodos |
| **NeMo Retriever / NeMo Guardrails** | Microservicios para RAG (embedding, reranking) y guardrails de seguridad | RAG empresarial y aplicaciones LLM gobernadas |

### 3.5 Orquestación, scheduling y gestión de clúster

| Componente | Rol |
|---|---|
| **NVIDIA GPU Operator** | Operator de Kubernetes que automatiza todo el software de los nodos GPU como contenedores: driver, Container Toolkit, device plugin, GPU Feature Discovery, DCGM/DCGM Exporter, MIG Manager, validator |
| **NVIDIA Network Operator** | La misma idea para networking: drivers MOFED/DOCA, RDMA shared device plugin, SR-IOV, GPUDirect RDMA |
| **Kubernetes device plugin** | Anuncia `nvidia.com/gpu` como recurso extendido al kubelet |
| **Slurm** | Scheduler batch de HPC; dominante en entrenamiento multi-nodo a gran escala (a menudo con Pyxis/Enroot para contenedores) |
| **NVIDIA Run:ai** | Orquestación/scheduling de GPU sobre Kubernetes: cuotas, fair share, GPUs fraccionales, preemption |
| **NVIDIA Base Command Manager** | Aprovisionamiento y gestión de clústeres DGX/HPC/K8s (imaging de nodos, monitoreo, despliegue de Slurm/K8s) |
| **Kubeflow / MLflow** | MLOps: pipelines, operators de entrenamiento distribuido, tracking de experimentos, registro de modelos |

### 3.6 Monitoreo y operaciones

| Componente | Rol |
|---|---|
| **nvidia-smi** | CLI por nodo para estado de GPU, procesos, MIG, clocks, ECC |
| **DCGM** (Data Center GPU Manager) | Health checks, diagnósticos (`dcgmi diag`), políticas y telemetría a escala de flota |
| **DCGM Exporter** | Expone las métricas de DCGM en formato Prometheus (`DCGM_FI_*`) |
| **Métricas de Triton/NIM** | Latencia de requests, tiempo en cola, tamaño de batch, throughput, uso del KV cache |

### 3.7 El envoltorio empresarial: NVIDIA AI Enterprise

**NVIDIA AI Enterprise** es la suite de software licenciada y con soporte. Incluye:

- Los frameworks, NIM, Triton, TensorRT, RAPIDS y NeMo.
- Software de infraestructura: GPU Operator, Network Operator, drivers vGPU.
- Ramas de producción con soporte a largo plazo, parches de seguridad (escaneo de CVEs) y certificación sobre los principales hipervisores, distribuciones de Kubernetes y nubes.

En el examen, "soporte empresarial, seguridad y estabilidad para el stack de software de IA" apunta a **NVIDIA AI Enterprise**. "¿De dónde saco contenedores y modelos optimizados?" apunta a **NGC**.

---

## 4. Comparaciones técnicas y trade-offs

### 4.1 Opciones de serving

| Criterio | Nativo del framework (p. ej. TorchServe / PyTorch directo) | Triton Inference Server | NVIDIA NIM | NVIDIA Dynamo |
|---|---|---|---|---|
| Tiempo a producción | Medio | Medio (escribís `config.pbtxt`, compilás engines) | **El más bajo** (pull & run) | Alto (diseño distribuido) |
| Rendimiento | Línea base | Alto (backend TensorRT, dynamic batching) | Alto (engine preoptimizado por GPU) | **El más alto a escala** (desagregación, routing por KV) |
| Flexibilidad de modelos | Un framework | **Cualquier** backend soportado, ensembles | Modelos del catálogo + custom/LoRA soportados | Enfocado en LLMs, múltiples engines |
| API | A medida | Protocolo KServe v2 (HTTP/gRPC) | Estándar de la industria (compatible con OpenAI para LLMs) | Frontend compatible con OpenAI |
| Carga operativa | Alta | Media | Baja | Media–Alta |
| Uso típico | Prototipos | Flotas mixtas CV/NLP/tabulares | GenAI empresarial, adopción rápida | Serving de LLMs multi-nodo, modelos de razonamiento |

### 4.2 Trade-offs de precisión (TensorRT / Model Optimizer)

| Precisión | Memoria vs FP32 | Throughput | Riesgo de exactitud | Requisito |
|---|---|---|---|---|
| FP32 | 1x | Línea base | Ninguno | Cualquier GPU |
| FP16 / BF16 | 0.5x | ~2x+ (Tensor Cores) | Muy bajo | Volta+ (BF16: Ampere+) |
| INT8 | 0.25x | Alto | Requiere calibración (PTQ) o QAT | Dataset de calibración |
| FP8 | 0.25x | Alto | Bajo con Transformer Engine / scaling | Hopper/Ada/Blackwell |
| FP4 (NVFP4) | 0.125x | El más alto | Requiere cuantización cuidadosa | Blackwell |

### 4.3 Elección de scheduler para entrenamiento

| Criterio | Slurm | Kubernetes (+ GPU Operator, Kubeflow, Run:ai) |
|---|---|---|
| Gang scheduling de jobs multi-nodo | Nativo | Requiere add-ons (Kueue, Volcano, Run:ai, Kubeflow Training Operator) |
| Conciencia de topología (IB, NVLink) | Madura | En mejora (scheduling consciente de topología vía add-ons) |
| Workloads de serving | Mal encaje | **Nativo** (Deployments, autoscaling, Services) |
| Soporte de contenedores | Pyxis/Enroot, Apptainer | Nativo |
| Perfil típico | Equipos de HPC/investigación | Equipos de plataforma/SRE con entrenamiento + serving mixtos |

### 4.4 Drivers instalados en el host vs GPU Operator

| Aspecto | Driver incluido en la imagen del SO | GPU Operator (driver en contenedor) |
|---|---|---|
| Aprovisionamiento día 0 | Build de imagen por versión de driver | Helm install; driver desplegado como DaemonSet |
| Upgrades | Reimagen / gestión de configuración | Rolling upgrade controlado por el operator (`upgradePolicy`) |
| SO inmutable (p. ej. RHCOS, Talos) | Difícil | Diseñado para eso (o usar driver preinstalado con `driver.enabled=false`) |
| Drift entre nodos | Común | Declarativo vía `ClusterPolicy` |
| Facilidad de depuración | Familiar | Requiere conocer los pods del operator y su orden |

---

## 5. Implementación de referencia end-to-end en Kubernetes

El recorrido de abajo va desde nodos GPU pelados hasta un endpoint de inferencia monitoreado.

### 5.1 Instalar el GPU Operator

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
"nvidia" has been added to your repositories

$ helm repo update
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ kubectl create namespace gpu-operator
namespace/gpu-operator created

$ kubectl label --overwrite ns gpu-operator pod-security.kubernetes.io/enforce=privileged
namespace/gpu-operator labeled
```

El archivo de values de abajo hace explícitas las decisiones importantes de producción:

```yaml
# gpu-operator-values.yaml
operator:
  defaultRuntime: containerd
driver:
  enabled: true
  upgradePolicy:
    autoUpgrade: true
    maxParallelUpgrades: 1
    maxUnavailable: "25%"
    drain:
      enable: true
      force: false
      timeoutSeconds: 300
      deleteEmptyDir: true
toolkit:
  enabled: true
devicePlugin:
  enabled: true
  config:
    name: time-slicing-config
    default: any
dcgm:
  enabled: true
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 15s
gfd:
  enabled: true
migManager:
  enabled: true
  config:
    name: default-mig-parted-config
mig:
  strategy: single
nfd:
  enabled: true
validator:
  plugin:
    env:
      - name: WITH_WORKLOAD
        value: "true"
```

Configuración de time-slicing referenciada por el device plugin. Usala solo en nodos de desarrollo/notebooks, porque el time-slicing **no da aislamiento de memoria**:

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

$ helm install gpu-operator nvidia/gpu-operator \
    -n gpu-operator \
    -f gpu-operator-values.yaml \
    --wait
NAME: gpu-operator
LAST DEPLOYED: Thu Nov 12 10:14:02 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
```

Estado estable esperado. Lo que importa es el orden: driver → toolkit → device plugin → validators.

```
$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xk2p                                   1/1     Running     0          6m
gpu-operator-6b8c9d7f5-q2wlz                                  1/1     Running     0          7m
gpu-operator-node-feature-discovery-gc-5d8f6c7b9-tm4cx        1/1     Running     0          7m
gpu-operator-node-feature-discovery-master-7c9f7d8b6-hz7rd    1/1     Running     0          7m
gpu-operator-node-feature-discovery-worker-9qk5m              1/1     Running     0          7m
nvidia-container-toolkit-daemonset-l8v2n                      1/1     Running     0          6m
nvidia-cuda-validator-x7d4f                                   0/1     Completed   0          4m
nvidia-dcgm-exporter-c5hnm                                    1/1     Running     0          6m
nvidia-dcgm-z2b8r                                             1/1     Running     0          6m
nvidia-device-plugin-daemonset-tq6wj                          1/1     Running     0          6m
nvidia-driver-daemonset-6p8vj                                 1/1     Running     0          7m
nvidia-mig-manager-48sjd                                      1/1     Running     0          5m
nvidia-operator-validator-kn2xr                               1/1     Running     0          6m
```

```
$ kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable}' | jq
{
  "cpu": "127500m",
  "ephemeral-storage": "1729724637044",
  "memory": "2112342360Ki",
  "nvidia.com/gpu": "8",
  "pods": "110"
}

$ kubectl get node gpu-node-01 --show-labels | tr ',' '\n' | grep nvidia.com/gpu
nvidia.com/gpu.count=8
nvidia.com/gpu.family=hopper
nvidia.com/gpu.memory=81559
nvidia.com/gpu.present=true
nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
nvidia.com/gpu.replicas=1
```

Las etiquetas `nvidia.com/gpu.*` vienen de **GPU Feature Discovery**. Te permiten fijar workloads a una familia de GPU. Esto es esencial porque los engines de TensorRT son específicos de la arquitectura.

### 5.2 Credenciales del registry de NGC

```
$ export NGC_API_KEY='<your-ngc-api-key>'

$ kubectl create namespace ai-platform
namespace/ai-platform created

$ kubectl -n ai-platform create secret docker-registry ngc-registry \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="${NGC_API_KEY}"
secret/ngc-registry created

$ kubectl -n ai-platform create secret generic ngc-api \
    --from-literal=NGC_API_KEY="${NGC_API_KEY}"
secret/ngc-api created
```

El username es literalmente el string `$oauthtoken`, no una variable.

### 5.3 Almacenamiento compartido para datasets, checkpoints y repositorio de modelos

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ai-shared
  namespace: ai-platform
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: parallel-fs
  resources:
    requests:
      storage: 10Ti
```

### 5.4 Entrenamiento distribuido con un contenedor PyTorch de NGC (Kubeflow Training Operator)

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: resnet50-ddp
  namespace: ai-platform
spec:
  runPolicy:
    cleanPodPolicy: None
    backoffLimit: 2
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          imagePullSecrets:
            - name: ngc-registry
          nodeSelector:
            nvidia.com/gpu.family: hopper
          containers:
            - name: pytorch
              image: nvcr.io/nvidia/pytorch:24.08-py3
              command:
                - torchrun
              args:
                - "--nproc_per_node=8"
                - /workspace/train/train_ddp.py
                - "--data=/data/imagenet"
                - "--checkpoint-dir=/data/checkpoints/resnet50"
                - "--amp"
                - "--dali"
              env:
                - name: NCCL_DEBUG
                  value: WARN
                - name: NCCL_IB_DISABLE
                  value: "0"
              resources:
                limits:
                  nvidia.com/gpu: 8
                  memory: 512Gi
                  cpu: "64"
              volumeMounts:
                - name: shared
                  mountPath: /data
                - name: dshm
                  mountPath: /dev/shm
          volumes:
            - name: shared
              persistentVolumeClaim:
                claimName: ai-shared
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 64Gi
    Worker:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          imagePullSecrets:
            - name: ngc-registry
          nodeSelector:
            nvidia.com/gpu.family: hopper
          containers:
            - name: pytorch
              image: nvcr.io/nvidia/pytorch:24.08-py3
              command:
                - torchrun
              args:
                - "--nproc_per_node=8"
                - /workspace/train/train_ddp.py
                - "--data=/data/imagenet"
                - "--checkpoint-dir=/data/checkpoints/resnet50"
                - "--amp"
                - "--dali"
              env:
                - name: NCCL_DEBUG
                  value: WARN
                - name: NCCL_IB_DISABLE
                  value: "0"
              resources:
                limits:
                  nvidia.com/gpu: 8
                  memory: 512Gi
                  cpu: "64"
              volumeMounts:
                - name: shared
                  mountPath: /data
                - name: dshm
                  mountPath: /dev/shm
          volumes:
            - name: shared
              persistentVolumeClaim:
                claimName: ai-shared
            - name: dshm
              emptyDir:
                medium: Memory
                sizeLimit: 64Gi
```

Notas de producción:

- **`/dev/shm` como `emptyDir` respaldado en memoria** es obligatorio. El shm por defecto del contenedor, de 64 MiB, hace que el DataLoader de PyTorch y NCCL fallen con bus errors.
- **`NCCL_DEBUG=INFO`** es lo primero que hay que activar cuando un job multi-nodo se cuelga en el primer all-reduce. Imprime el transporte seleccionado (NVLink, `NET/IB` o `NET/Socket`). Caer a `Socket` sobre TCP plano es un asesino silencioso de rendimiento muy común.
- **Hacé checkpoints seguido** en el almacenamiento compartido. La falla de un nodo (Xid 79, "GPU has fallen off the bus") a escala es una cuestión de *cuándo*.

```
$ kubectl -n ai-platform get pytorchjob resnet50-ddp
NAME           STATE     AGE
resnet50-ddp   Running   3m

$ kubectl -n ai-platform logs resnet50-ddp-master-0 | grep -E "NCCL INFO (Using|Channel 00)" | head -3
resnet50-ddp-master-0:52:52 [0] NCCL INFO Using network IB
resnet50-ddp-master-0:52:52 [0] NCCL INFO Channel 00/32 :    0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
resnet50-ddp-master-0:52:52 [0] NCCL INFO Channel 00/0 : 0[0] -> 1[1] via P2P/NVL
```

(Esa salida aparece con `NCCL_DEBUG=INFO`.)

### 5.5 Optimizar: ONNX → engine de TensorRT

Ejecutalo en la **misma arquitectura de GPU y versión de TensorRT** que va a usar Triton. Usar la misma release de NGC (`24.08`) para el contenedor de TensorRT y el de Triton garantiza lo segundo.

```
$ docker run --rm --gpus all -v /data:/data nvcr.io/nvidia/tensorrt:24.08-py3 \
    trtexec --onnx=/data/models/resnet50.onnx \
            --saveEngine=/data/models/resnet50.plan \
            --fp16 \
            --minShapes=input:1x3x224x224 \
            --optShapes=input:16x3x224x224 \
            --maxShapes=input:64x3x224x224
...
[I] === Performance summary ===
[I] Throughput: 4127.63 qps
[I] Latency: min = 3.71 ms, max = 4.42 ms, mean = 3.86 ms, median = 3.85 ms, percentile(90%) = 3.93 ms, percentile(95%) = 3.97 ms, percentile(99%) = 4.11 ms
...
&&&& PASSED TensorRT.trtexec [TensorRT v100300] # trtexec --onnx=/data/models/resnet50.onnx --saveEngine=/data/models/resnet50.plan --fp16 ...
```

Los valores de throughput y latencia son ilustrativos y dependen de la GPU y del modelo. La línea a verificar es `&&&& PASSED`.

### 5.6 Servir con Triton Inference Server

Estructura del repositorio de modelos en el volumen compartido:

```
/data/model_repository/
└── resnet50_trt/
    ├── config.pbtxt
    └── 1/
        └── model.plan
```

`config.pbtxt` (formato de texto protobuf):

```
name: "resnet50_trt"
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

Deployment y Service:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton
  namespace: ai-platform
  labels:
    app: triton
spec:
  replicas: 2
  selector:
    matchLabels:
      app: triton
  template:
    metadata:
      labels:
        app: triton
    spec:
      imagePullSecrets:
        - name: ngc-registry
      nodeSelector:
        nvidia.com/gpu.family: hopper
      containers:
        - name: tritonserver
          image: nvcr.io/nvidia/tritonserver:24.08-py3
          command:
            - tritonserver
          args:
            - "--model-repository=/data/model_repository"
            - "--strict-model-config=false"
            - "--log-verbose=0"
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
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: http
            initialDelaySeconds: 30
            periodSeconds: 15
          resources:
            limits:
              nvidia.com/gpu: 1
              memory: 32Gi
              cpu: "8"
          volumeMounts:
            - name: shared
              mountPath: /data
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: shared
          persistentVolumeClaim:
            claimName: ai-shared
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 4Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton
  namespace: ai-platform
  labels:
    app: triton
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

```
$ kubectl -n ai-platform logs deploy/triton | grep -A4 "Model "
+--------------+---------+--------+
| Model        | Version | Status |
+--------------+---------+--------+
| resnet50_trt | 1       | READY  |
+--------------+---------+--------+

$ kubectl -n ai-platform port-forward svc/triton 8000:8000 8002:8002 &
$ curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/v2/health/ready
200

$ curl -s localhost:8000/v2/models/resnet50_trt | jq '.platform, .versions'
"tensorrt_plan"
[
  "1"
]
```

Prueba de carga con `perf_analyzer`. Viene en la imagen `-py3-sdk`.

```
$ docker run --rm --net=host nvcr.io/nvidia/tritonserver:24.08-py3-sdk \
    perf_analyzer -m resnet50_trt -u localhost:8001 -i grpc \
    --concurrency-range 1:8:2 --shape input:3,224,224
...
Inferences/Second vs. Client Average Batch Latency
Concurrency: 1, throughput: 512.4 infer/sec, latency 1950 usec
Concurrency: 3, throughput: 1398.7 infer/sec, latency 2143 usec
Concurrency: 5, throughput: 2104.9 infer/sec, latency 2374 usec
Concurrency: 7, throughput: 2617.3 infer/sec, latency 2672 usec
```

Los números son ilustrativos. Lo que enseña es la forma de la curva. El throughput sube con la concurrencia porque el **dynamic batching** agrupa requests, mientras la latencia sube despacio. Cuando la latencia empieza a crecer más rápido que el throughput, encontraste el punto de saturación. Usalo para definir los targets del HPA.

### 5.7 Servir un LLM con NVIDIA NIM

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nim-cache
  namespace: ai-platform
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: parallel-fs
  resources:
    requests:
      storage: 200Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nim-llama
  namespace: ai-platform
  labels:
    app: nim-llama
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nim-llama
  template:
    metadata:
      labels:
        app: nim-llama
    spec:
      imagePullSecrets:
        - name: ngc-registry
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: nim
          image: nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
          env:
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ngc-api
                  key: NGC_API_KEY
            - name: NIM_CACHE_PATH
              value: /opt/nim/.cache
          ports:
            - name: http
              containerPort: 8000
          startupProbe:
            httpGet:
              path: /v1/health/ready
              port: http
            periodSeconds: 10
            failureThreshold: 180
          readinessProbe:
            httpGet:
              path: /v1/health/ready
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /v1/health/live
              port: http
            periodSeconds: 15
          resources:
            limits:
              nvidia.com/gpu: 1
          volumeMounts:
            - name: cache
              mountPath: /opt/nim/.cache
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: cache
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
  name: nim-llama
  namespace: ai-platform
spec:
  selector:
    app: nim-llama
  ports:
    - name: http
      port: 8000
      targetPort: http
```

En producción, fijá un tag de versión específico de NIM en lugar de `latest`.

¿Por qué un `startupProbe` tan largo? En el primer arranque, NIM descarga los pesos y el perfil de engine optimizado para la GPU detectada en `NIM_CACHE_PATH`. Eso puede tardar muchos minutos. Una caché persistente hace que los arranques siguientes del pod sean rápidos, lo cual importa para el autoscaling y los SLOs de arranque en frío.

```
$ kubectl -n ai-platform logs deploy/nim-llama | grep -iE "profile|Uvicorn"
INFO ... Selected profile: <profile-id> (tensorrt_llm-h100-bf16-tp1-throughput)
INFO ... Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)

$ kubectl -n ai-platform port-forward svc/nim-llama 8080:8000 &
$ curl -s localhost:8080/v1/models | jq -r '.data[].id'
meta/llama-3.1-8b-instruct

$ curl -s localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"What does the GPU Operator install?"}],"max_tokens":64}' \
    | jq -r '.choices[0].message.content'
The NVIDIA GPU Operator installs and manages the NVIDIA driver, container toolkit, device plugin, ...
```

El formato de la línea del perfil varía según la versión de NIM. Usá `list-model-profiles` dentro del contenedor para ver qué perfiles son compatibles con tu GPU.

### 5.8 Monitoreo: DCGM Exporter + Prometheus

Un ServiceMonitor para Triton. El ServiceMonitor de DCGM Exporter lo crea el operator vía `dcgmExporter.serviceMonitor.enabled`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: triton
  namespace: ai-platform
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: triton
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics
```

Reglas de alertas que cubren hardware, utilización y serving:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ai-platform-gpu
  namespace: ai-platform
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu-health
      rules:
        - alert: GPUXidErrors
          expr: |
            DCGM_FI_DEV_XID_ERRORS > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} reported Xid {{ $value }}"
        - alert: GPUTemperatureHigh
          expr: |
            DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} above 85C"
        - alert: GPUStarvedDuringTraining
          expr: |
            avg by (Hostname) (DCGM_FI_DEV_GPU_UTIL{namespace="ai-platform"}) < 40
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Low GPU utilization on {{ $labels.Hostname }}: check data pipeline / storage throughput"
        - alert: GPUFramebufferNearlyFull
          expr: |
            DCGM_FI_DEV_FB_USED
              /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.95
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "GPU {{ $labels.gpu }} memory above 95%"
    - name: inference-slo
      rules:
        - alert: TritonQueueTimeHigh
          expr: |
            rate(nv_inference_queue_duration_us[5m])
              /
            clamp_min(rate(nv_inference_request_success[5m]), 1) > 50000
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Triton average queue time above 50ms for {{ $labels.model }}: scale out or tune batching"
```

```
$ kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
$ curl -s localhost:9400/metrics | grep -E "^DCGM_FI_DEV_(GPU_UTIL|FB_USED|GPU_TEMP)" | head -3
DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-8f1c...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",container="tritonserver",namespace="ai-platform",pod="triton-5f8d6c9b7-2xk4p"} 54
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-8f1c...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",container="tritonserver",namespace="ai-platform",pod="triton-5f8d6c9b7-2xk4p"} 87
DCGM_FI_DEV_FB_USED{gpu="0",UUID="GPU-8f1c...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-01",container="tritonserver",namespace="ai-platform",pod="triton-5f8d6c9b7-2xk4p"} 21734
```

Las etiquetas `pod`/`namespace` son las que hacen útil a DCGM Exporter en Kubernetes: atribuyen la telemetría de GPU a los workloads.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 Secuencia de verificación de abajo hacia arriba

Diagnosticá siempre **desde la base del stack hacia arriba**. Una falla en una capa inferior aparece como un error confuso en una superior.

```
# 1. Driver: is the kernel module loaded and talking to the GPUs?
$ kubectl -n gpu-operator exec ds/nvidia-driver-daemonset -- nvidia-smi
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
| N/A   34C    P0             71W /  700W |       0MiB /  81559MiB |      0%      Default |
...

# 2. Container toolkit: can an arbitrary container see the GPU?
$ kubectl run cuda-smoke --rm -it --restart=Never \
    --image=nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 \
    --overrides='{"spec":{"containers":[{"name":"cuda-smoke","image":"nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04","command":["nvidia-smi","-L"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'
GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-8f1c...)
pod "cuda-smoke" deleted

# 3. Device plugin: is the resource advertised?
$ kubectl describe node gpu-node-01 | grep -A2 "nvidia.com/gpu"
  nvidia.com/gpu:     8
  ...

# 4. Health/diagnostics via DCGM (level 1 = quick, 3 = long)
$ kubectl -n gpu-operator exec ds/nvidia-dcgm -- dcgmi diag -r 1
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.x                                          |
| Driver Version Detected   | 550.90.07                                      |
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
+---------------------------+------------------------------------------------+

# 5. Kernel-level hardware errors
$ kubectl debug node/gpu-node-01 -it --image=busybox -- chroot /host dmesg -T | grep -i xid
[Thu Nov 12 09:41:17 2026] NVRM: Xid (PCI:0000:18:00): 79, pid=..., GPU has fallen off the bus.
```

Notas:
- La `CUDA Version` que muestra `nvidia-smi` es la **versión máxima de CUDA que soporta el driver**, no la que está instalada en los contenedores.
- Si el DaemonSet `nvidia-dcgm` está deshabilitado en tu setup, DCGM corre embebido en el exporter. Usá `nvidia-smi` y las métricas de DCGM Exporter en su lugar.

### 6.2 Síntoma → causa → solución

| Síntoma | Capa | Causa probable | Diagnóstico | Solución |
|---|---|---|---|---|
| Pod `Pending`: `Insufficient nvidia.com/gpu` | Scheduling | Device plugin sin correr, GPUs ya asignadas o validator sin terminar | `kubectl describe node`, `kubectl -n gpu-operator get pods` | Esperar/reparar el device plugin; revisar los requests de otros pods; revisar taints |
| `nvidia-driver-daemonset` en `CrashLoopBackOff` | Driver | Headers del kernel no disponibles, módulo sin firmar con Secure Boot, driver preinstalado en el host en conflicto | `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset -c nvidia-driver-ctr` | Usar driver precompilado / kernel compatible; o setear `driver.enabled=false` si el driver ya está preinstalado en el host |
| `CUDA driver version is insufficient for CUDA runtime version` | Driver ↔ contenedor | CUDA del contenedor más nuevo que el que soporta el driver del host | `nvidia-smi` (CUDA máximo) vs CUDA de la imagen | Actualizar el driver o usar una release anterior del contenedor NGC (ver la matriz de soporte de NGC) |
| Modelo de Triton `UNAVAILABLE`: error de deserialización del engine | Optimización ↔ serving | Engine de TensorRT compilado con otra versión de TRT u otra arquitectura de GPU | Logs de Triton con `--log-verbose=1` | Recompilar el engine con la versión de TensorRT de la release de Triton, en la GPU destino |
| El entrenamiento se cuelga en el primer paso en multi-nodo | Comunicación | NCCL no alcanza a los peers, interfaz equivocada, IB no expuesto | Logs con `NCCL_DEBUG=INFO`, revisar `NET/Socket` vs `NET/IB` | Setear `NCCL_SOCKET_IFNAME`, desplegar Network Operator / RDMA device plugin, corregir el firewall |
| `Bus error` / worker del DataLoader terminado | Configuración del contenedor | `/dev/shm` demasiado chico | `df -h /dev/shm` en el pod | Montar un `emptyDir` respaldado en memoria en `/dev/shm` |
| Utilización de GPU baja (<40%) durante el entrenamiento | Pipeline de datos / almacenamiento | Decodificación en CPU, FS compartido lento, archivos chicos | `GPU_UTIL` de DCGM, CPU del nodo, throughput de almacenamiento | DALI, RAPIDS, caché local en NVMe, GDS, shards más grandes (WebDataset/TFRecord) |
| El pod de NIM se reinicia durante el primer arranque | Serving | La liveness mata el pod mientras descarga los pesos | `kubectl describe pod` (fallas de probes) | Agregar `startupProbe` con umbral largo; `NIM_CACHE_PATH` persistente |
| NIM: no hay perfil compatible | Serving | La GPU no está soportada por ningún perfil optimizado para ese modelo | `list-model-profiles` en el contenedor | Usar una GPU soportada, o recurrir a un perfil genérico (p. ej. basado en vLLM) donde se ofrezca |
| `CUDA out of memory` en inferencia con prompts largos | Serving | Crecimiento del KV cache, tamaño de batch demasiado grande | `DCGM_FI_DEV_FB_USED`, logs del servidor | Limitar longitud máxima de secuencia/batch, cuantizar (FP8/INT4), usar una GPU más grande o tensor parallelism |
| `DCGM_FI_DEV_XID_ERRORS` con Xid 48/63/64/79/94/95 | Hardware | Errores ECC, row remap, GPU caída del bus | `dmesg`, `nvidia-smi -q -d ECC`, `dcgmi diag -r 3` | Drenar el nodo (`kubectl drain`), reset/RMA según la guía de NVIDIA |
| Los recursos MIG no aparecen | Particionado | Etiqueta de configuración de MIG Manager sin setear o GPU en uso | `kubectl get node -L nvidia.com/mig.config,nvidia.com/mig.config.state` | Etiquetar el nodo con `nvidia.com/mig.config=all-1g.10gb`, asegurar que no haya workloads de GPU durante la reconfiguración |

### 6.3 Verificación de reconfiguración MIG

```
$ kubectl label node gpu-node-02 nvidia.com/mig.config=all-1g.10gb --overwrite
node/gpu-node-02 labeled

$ kubectl get node gpu-node-02 -L nvidia.com/mig.config.state
NAME          STATUS   ROLES    AGE   VERSION   MIG.CONFIG.STATE
gpu-node-02   Ready    <none>   41d   v1.31.2   pending

$ kubectl get node gpu-node-02 -L nvidia.com/mig.config.state
NAME          STATUS   ROLES    AGE   VERSION   MIG.CONFIG.STATE
gpu-node-02   Ready    <none>   41d   v1.31.2   success

$ kubectl get node gpu-node-02 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
56
```

Con `mig.strategy: single` y 8 GPUs × 7 porciones `1g.10gb`, el nodo anuncia 56 `nvidia.com/gpu`. Este es el patrón correcto para muchos workloads chicos de inferencia/notebooks que necesitan memoria y cómputo **aislados por hardware**. El time-slicing no da ese aislamiento.

---

## 7. Resumen orientado al examen

| Si la pregunta es sobre… | La respuesta suele ser… |
|---|---|
| Distribución de contenedores/modelos de IA optimizados y validados | **Catálogo NGC** |
| Suite de software de IA con soporte, segura y de nivel empresarial | **NVIDIA AI Enterprise** |
| Ciencia de datos / ETL acelerados por GPU | **RAPIDS** (cuDF, cuML), **RAPIDS Accelerator for Spark** |
| Carga/aumentación de datos acelerada por GPU para entrenamiento | **DALI** |
| Ruta de datos directa de almacenamiento a GPU | **GPUDirect Storage** (Magnum IO) |
| Construir/personalizar LLMs e IA generativa | **NeMo** |
| Comunicación multi-GPU/multi-nodo | **NCCL** |
| Optimizar un modelo entrenado para inferencia (fusión, cuantización) | **TensorRT** / **TensorRT-LLM** / **Model Optimizer** |
| Servir muchos modelos de muchos frameworks con dynamic batching | **Triton Inference Server** |
| Microservicio de inferencia preconstruido, optimizado y con API estándar | **NVIDIA NIM** |
| Inferencia de LLMs distribuida/desagregada a gran escala | **NVIDIA Dynamo** |
| Automatizar driver, toolkit, device plugin y monitoreo en Kubernetes | **GPU Operator** |
| Automatizar RDMA/networking de alta velocidad en Kubernetes | **Network Operator** |
| Salud, diagnóstico y telemetría de GPU | **DCGM** / **DCGM Exporter** |
| Exponer GPUs a contenedores | **NVIDIA Container Toolkit** |
| Aprovisionamiento/gestión de clústeres | **Base Command Manager** |
| Scheduling consciente de GPU, cuotas y GPUs fraccionales en K8s | **Run:ai** |

El ciclo de vida en una línea: **Preparación de datos** (RAPIDS, DALI, GDS) → **Entrenar/personalizar** (PyTorch/NeMo + CUDA-X + NCCL, en contenedores NGC, sobre Slurm o K8s) → **Optimizar** (TensorRT/TensorRT-LLM/Model Optimizer) → **Desplegar** (Triton, NIM, Dynamo sobre K8s con GPU Operator) → **Monitorear** (DCGM, Prometheus) → realimentar el drift y el feedback hacia la preparación de datos y el reentrenamiento.

---

## Referencias

- NVIDIA NCA-AIIO Exam Study Guide (official): https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy — AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference (Triton, NIM, TensorRT-LLM, Dynamo): https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html
- Triton Inference Server documentation: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- NVIDIA NIM for LLMs documentation: https://docs.nvidia.com/nim/large-language-models/latest/introduction.html
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- NGC Catalog: https://catalog.ngc.nvidia.com/
- NVIDIA AI Enterprise: https://www.nvidia.com/en-us/data-center/products/ai-enterprise/
- NVIDIA NeMo Framework: https://docs.nvidia.com/nemo-framework/user-guide/latest/overview.html
- RAPIDS: https://rapids.ai/
- NVIDIA DALI: https://docs.nvidia.com/deeplearning/dali/user-guide/docs/index.html
- NVIDIA GPUDirect Storage: https://docs.nvidia.com/gpudirect-storage/index.html
- NCCL documentation: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/index.html
- TensorRT-LLM: https://github.com/NVIDIA/TensorRT-LLM
- NVIDIA Dynamo: https://github.com/ai-dynamo/dynamo
- Kubeflow Training Operator (PyTorchJob): https://www.kubeflow.org/docs/components/trainer/