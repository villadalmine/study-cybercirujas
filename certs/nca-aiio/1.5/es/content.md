# 1.5 — Casos de uso clave de IA e industrias

## 1. Motivación: por qué un ingeniero de infraestructura debe entender los casos de uso

El examen NCA-AIIO no espera que seas data scientist. Espera que mires un pedido de negocio, como "queremos detección de fraude en transacciones con tarjeta" o "queremos un chatbot sobre nuestra documentación interna", y lo traduzcas a un **perfil de infraestructura**:

- ¿Es **training**, **fine-tuning** o **inference**?
- ¿La inference es **en tiempo real** (limitada por latencia, p99 en milisegundos) o **batch** (limitada por throughput, medida en registros por hora)?
- ¿Cuál es la **modalidad de datos**? Texto, imagen o video, audio, tabular, grafo, o sensor/series temporales.
- ¿Dónde corre? Data center, cloud o **edge** (planta de fábrica, vehículo, dispositivo hospitalario).
- ¿Cuáles son las **restricciones regulatorias**? HIPAA, PCI-DSS, GDPR, soberanía de datos.

Las fallas en producción de las plataformas de IA rara vez vienen del modelo. Vienen de un desajuste entre el perfil del workload y la plataforma. Ejemplos comunes:

- Un servicio de inference sensible a la latencia se schedulea en un nodo compartido con un job de training que satura PCIe y NVLink.
- Las tablas de embeddings de un sistema de recomendación no entran en la memoria de la GPU.
- Un pipeline de video analytics queda con cuello de botella en el decode del lado de la CPU en lugar de NVDEC.
- Un clúster de training se frena porque el storage compartido no puede sostener el throughput de lectura de muchos data loaders, o porque las escrituras de checkpoints bloquean el loop de steps.

Este tema es el puente entre "lo que quiere el negocio" y "cómo tiene que ser el clúster". NVIDIA lo plantea como un stack end-to-end:

- **Hardware acelerado**: GPUs, DPUs, NVLink, InfiniBand/Spectrum-X.
- **Software de sistema**: drivers, CUDA, el GPU Operator.
- **Frameworks y SDKs de IA**: NeMo, RAPIDS, TensorRT, Triton, NIM.
- **Frameworks de aplicación específicos por industria** encima: Clara, Metropolis, Riva, Merlin, Morpheus, DRIVE, Isaac, Omniverse.

## 2. Taxonomía: caso de uso → perfil de workload

### 2.1 Categorías principales de workloads de IA

| Familia de casos de uso | Modelos típicos | Modalidad de datos | Fase dominante en producción | Restricción clave de infra |
|---|---|---|---|---|
| IA generativa / LLMs (chat, resumen, código, RAG) | Decoders Transformer (Llama, Nemotron, Mistral) | Texto, tokens | Inference (más fine-tuning periódico) | Memoria de GPU para pesos y KV cache; tokens/s; time-to-first-token |
| Computer vision (detección, segmentación, inspección) | CNNs, ViTs, familia YOLO | Imagen, streams de video | Inference en el edge y en el DC | Decode de video (NVDEC), latencia por stream, densidad de streams por GPU |
| Speech AI (ASR, TTS, traducción) | Conformer, Parakeet, FastPitch | Audio | Inference en streaming en tiempo real | Latencia end-to-end por debajo de ~300 ms para uso conversacional; streaming gRPC |
| Sistemas de recomendación | DLRM, two-tower, transformers4rec | Tabular más tablas de embeddings muy grandes | Training sobre datasets enormes; inference con QPS alto | Tamaño de las tablas de embeddings (escala TB), ancho de banda de memoria y red |
| Fraude / anomalías / ciberseguridad | GNNs, gradient boosted trees (XGBoost), autoencoders | Tabular, grafos, logs, paquetes | Scoring en tiempo real más reentrenamiento batch | Presupuestos de latencia ajustados en los caminos de transacción; throughput de ETL |
| Científico / descubrimiento de fármacos | Modelos de estructura de proteínas, química generativa, physics-ML | Secuencias, moléculas, mallas | Training más inference con batches grandes | Mezcla HPC FP64/FP32; datasets muy grandes; MPI más NCCL |
| Sistemas autónomos / robótica | Percepción, planificación, foundation models | Multisensor (cámara, lidar, radar) | Training en el DC; inference en el vehículo o robot; simulación | Cómputo de simulación, pipelines de datos a escala de petabytes, seguridad funcional |
| Digital twins / simulación | Modelos physics-informed, rendering | Escenas 3D (OpenUSD), datos de sensores | Simulación más generación de datos sintéticos | Mezcla de gráficos RTX y cómputo; sincronización |
| Data analytics / data science | RAPIDS cuDF/cuML, Spark con RAPIDS | Tabular | ETL batch y training | Throughput de storage, movimiento de datos CPU↔GPU |

### 2.2 Training vs inference: el perfil que define cada decisión

| Dimensión | Training / fine-tuning | Inference online | Inference batch |
|---|---|---|---|
| Métrica objetivo | Time-to-train, utilización de GPU (MFU) | Latencia p50/p99, TTFT, tokens/s por usuario | Throughput, costo por 1M de registros |
| Estilo de escalado | Scale-out entre nodos (paralelismo de datos, tensor y pipeline) | Réplicas detrás de un load balancer; autoscale por cola o latencia | Jobs paralelos; maximizar el tamaño de batch |
| Interconexión | Crítica: NVLink dentro del nodo, InfiniBand/RoCE entre nodos | Normalmente una sola GPU o un solo nodo (salvo LLMs muy grandes con tensor parallelism) | Baja importancia |
| Patrón de storage | Lecturas masivas secuenciales/aleatorias del dataset; escrituras grandes y en ráfagas de checkpoints | Carga del modelo al arrancar (cold start); poco I/O después | Leer el dataset de entrada, escribir resultados |
| Precisión | Mixed precision BF16/FP16/FP8 | FP8/INT8/INT4 después de la optimización con TensorRT | Igual que online, pero con batches más grandes |
| Impacto de una falla | Progreso perdido desde el último checkpoint | Caída visible para el usuario, incumplimiento de SLO | Reporte demorado o re-ejecución |
| Compartición de GPU | Rara vez; prefiere nodos completos | Particiones MIG para modelos chicos son comunes | Time-slicing aceptable |

**Heurística para el examen:** la inference es donde se van la mayoría de las GPU-hours de producción a lo largo de la vida de un modelo. Un modelo se entrena una vez u ocasionalmente, pero se sirve de forma continua. Por eso NVIDIA invierte fuerte en TensorRT, Triton Inference Server y los microservicios NIM.

## 3. Industrias: casos de uso, plataformas NVIDIA e implicancias de infra

| Industria | Casos de uso representativos | Plataforma / SDK de NVIDIA | Implicancias de infra para el SRE |
|---|---|---|---|
| **Salud y ciencias de la vida** | Imágenes médicas (segmentación en radiología), genómica (variant calling), descubrimiento de fármacos (estructura de proteínas, generación de moléculas), documentación clínica con LLMs | **Clara** (imágenes, Parabricks para genómica), **BioNeMo** (foundation models de biología), MONAI | PHI/HIPAA: on-prem o clouds soberanas, cifrado en reposo y en tránsito, logs de auditoría. La genómica es muy batch (Parabricks convierte horas de trabajo en CPU en minutos en GPUs). La inference de imágenes suele estar en el edge, dentro del hospital. |
| **Servicios financieros** | Detección de fraude, AML, trading algorítmico, simulación de riesgo (Monte Carlo), inteligencia documental, LLMs de atención al cliente | **RAPIDS**, **Morpheus** (para seguridad), Triton, NIM, NeMo | Presupuestos de latencia estrictos en los caminos de autorización (milisegundos). Segmentación PCI-DSS. Explicabilidad y gobernanza de modelos. ETL pesado en GPU con RAPIDS/Spark. |
| **Retail y CPG** | Recomendadores, pronóstico de demanda, analítica en tienda (góndolas/prevención de pérdidas), asistentes de compra conversacionales | **Merlin** (recomendadores), **Metropolis** (visión), RAPIDS, NIM | QPS alto con inference cargada de tablas de embeddings. El tráfico estacional con picos requiere autoscaling. Muchos sitios edge chicos (tiendas) requieren gestión de flota. |
| **Manufactura e industria** | Inspección visual de calidad, mantenimiento predictivo, robótica, digital twins de fábrica | **Metropolis**, **Isaac** (robótica), **Omniverse** (digital twins), Jetson/IGX en el edge | Despliegues edge con conectividad intermitente. Streams de cámaras en tiempo real. Seguridad funcional. Separación de redes OT/IT. |
| **Automotriz y transporte** | Percepción y planificación ADAS/AV, simulación, asistentes en cabina, analítica de flotas | **DRIVE** (AGX en el vehículo, Sim), **Omniverse**, world models Cosmos | Ingesta de datos de sensores a escala de petabytes. Clústeres de training grandes. Simulación y generación de datos sintéticos. Certificación de seguridad (ISO 26262). |
| **Telecomunicaciones** | Optimización de red, AI-RAN, LLMs de atención al cliente, detección de anomalías | **Aerial** (vRAN 5G/6G), Morpheus, NIM, Riva | Edge distribuido (sitios celulares). Latencia estricta. Compartición de GPU entre el procesamiento de señal RAN y la IA. |
| **Sector público y smart cities** | Analítica de tránsito, video de seguridad pública, chatbots de atención ciudadana, LLMs soberanos | **Metropolis**, NeMo, NIM | Soberanía de datos, clústeres air-gapped, video con preservación de privacidad. |
| **Energía y clima / ciencias de la Tierra** | Interpretación sísmica, simulación de reservorios, optimización de la red eléctrica, clima/meteorología (Earth-2) | **Modulus/PhysicsNeMo**, **Earth-2**, Omniverse | Clústeres estilo HPC, requisitos de FP64, datasets enormes, scheduling MPI (Slurm junto a Kubernetes). |
| **Medios, entretenimiento y gaming** | Contenido generativo (imagen, video, voz), rendering, localización/doblaje, avatares | **Omniverse**, **Riva**, NeMo, **ACE** (digital humans) | GPUs mixtas de gráficos y cómputo. Render farms con ráfagas. Storage grande para assets. |
| **Ciberseguridad (transversal)** | Detección de phishing, digital fingerprinting, detección de anomalías en logs, SOC asistido por LLM | **Morpheus** (pipelines de seguridad acelerados por GPU), DPU BlueField | Inspección a velocidad de línea delegada a DPUs. Pipelines de streaming de alto volumen (Kafka). |
| **Atención al cliente (transversal)** | Agentes de contact center, voice bots, RAG sobre bases de conocimiento | **NIM**, **NeMo Retriever**, **NeMo Guardrails**, **Riva** | Pipelines de múltiples componentes: ASR → LLM → TTS más una vector DB. Presupuesto de latencia end-to-end repartido entre servicios. |

### 3.1 Casos de uso de LLMs en particular

Los LLMs son una capacidad horizontal que atraviesa todas las industrias anteriores. Los usos principales son:

1. **Generación de contenido.** Textos de marketing, descripciones de productos, reportes.
2. **Resumen.** Notas clínicas, contratos legales, earnings calls, post-mortems de incidentes.
3. **Traducción y localización.** Soporte multilingüe, pipelines de doblaje con Riva.
4. **Generación y asistencia de código.** Copilots para desarrolladores, borradores de infrastructure-as-code.
5. **Agentes conversacionales.** Atención al cliente, helpdesk interno de IT.
6. **Búsqueda y RAG (Retrieval-Augmented Generation).** Fundamentar respuestas en documentos de la empresa sin reentrenar el modelo.
7. **Modelos de dominio específico.** Biología (protein language models), química, finanzas, telecom.
8. **Workflows agénticos.** LLMs que llaman herramientas y APIs para completar tareas de varios pasos.

**Por qué RAG domina la adopción empresarial.** El fine-tuning mete el conocimiento dentro de los pesos. Eso lo hace caro de actualizar, y no podés quitar un documento fácilmente. RAG recupera documentos frescos en el momento de la consulta y los inyecta en el prompt. El trade-off mueve la complejidad del training al **pipeline de serving**: un modelo de embeddings, una vector database, un reranker, el LLM y guardrails.

| Enfoque | Costo de actualizar el conocimiento | Huella de infra | Control de alucinaciones | Uso típico |
|---|---|---|---|---|
| Prompting a un modelo base/instruct | Ninguno | 1 servicio de inference | Bajo | Asistentes genéricos |
| RAG | Reindexar documentos (minutos) | Embedder + vector DB + reranker + LLM | Medio–alto (las respuestas citan fuentes) | Conocimiento empresarial, soporte |
| Fine-tuning eficiente en parámetros (LoRA/PEFT) | Horas de GPU | Job de training + registro de adapters; adapters servidos juntos | Medio | Estilo, formato, jerga de dominio |
| Fine-tuning completo / pre-training continuado | Días a semanas en muchas GPUs | Clúster de training multinodo más storage de alto throughput | Medio | Foundation models soberanos o de dominio |

## 4. Del caso de uso a la arquitectura: storage, cómputo y serving

### 4.1 Patrones de storage por fase

La guía de NVIDIA sobre escalar storage para IA distingue fases con firmas de I/O muy distintas:

- **Preparación de datos / ETL.** Lecturas y escrituras secuenciales grandes. Se beneficia del ETL acelerado por GPU (RAPIDS) y de file systems paralelos u object storage.
- **Training.** Lecturas aleatorias sobre el dataset completo en cada epoch, desde muchos data loaders concurrentes. El objetivo es mantener alimentadas a las GPUs. Un caché NVMe local más un file system paralelo es el patrón común, y **GPUDirect Storage (GDS)** mueve datos desde NVMe o la red directamente a la memoria de la GPU, evitando el bounce buffer de la CPU.
- **Checkpointing.** Escrituras grandes, periódicas y en ráfagas (decenas a cientos de GB para modelos grandes). El ancho de banda de escritura determina cuánto tiempo quedan ociosas las GPUs durante un checkpoint sincrónico.
- **Inference.** Mayormente lectura única al cargar el modelo. El tiempo de cold start está dominado por la descarga de los pesos. Un caché de modelos en un volumen compartido rápido o un caché local del nodo reduce la latencia de scale-out.

| Fase | Patrón de lectura | Patrón de escritura | Qué falla primero |
|---|---|---|---|
| ETL | Secuencial, grande | Secuencial, grande | Ancho de banda de red hacia el storage |
| Training | Aleatorio, chico–mediano, alta concurrencia | Checkpoints: en ráfagas, muy grandes | Operaciones de metadata en el file system; GPUs sin datos |
| Inference (online) | Solo carga del modelo | Logs/métricas | Tiempo de cold start durante el autoscaling |
| Inference batch | Entrada secuencial | Salida secuencial | Límites de tasa de requests del object store |

### 4.2 Stack de optimización de inference

- **TensorRT.** SDK que optimiza modelos entrenados para inference. Hace fusión de capas y tensores, calibración de precisión (FP16, INT8, FP8), auto-tuning de kernels por arquitectura de GPU y memoria dinámica de tensores. La salida es un engine (plan) específico para una arquitectura de GPU y una versión de TensorRT.
- **TensorRT-LLM.** Optimizaciones específicas para LLMs: batching in-flight (continuo), paged KV cache, tensor y pipeline parallelism, cuantización.
- **Triton Inference Server.** Serving multi-framework (backends TensorRT, PyTorch, ONNX, Python, TensorRT-LLM). Ofrece dynamic batching, ejecución concurrente de modelos, ensembles de modelos y métricas de Prometheus en el puerto 8002.
- **NVIDIA NIM.** Microservicios de inference (containers) preconstruidos y optimizados para modelos específicos. Exponen APIs estándar de la industria, como la API compatible con OpenAI para LLMs, y seleccionan un perfil de engine optimizado para la GPU detectada.

Resumen de trade-offs:

| Opción | Tiempo a producción | Flexibilidad | Esfuerzo de tuning de performance | Ideal para |
|---|---|---|---|---|
| Serving nativo del framework (PyTorch plano) | Rápido | La más alta | Alto para llegar a buena perf | Prototipos, investigación |
| Triton + TensorRT | Medio | Alta (multimodelo, ensembles) | Medio | Visión, speech, recsys, pipelines a medida |
| NIM | El más rápido para modelos soportados | Menor (container específico por modelo) | Bajo (perfiles preoptimizados) | LLMs, embeddings, rerankers en la empresa |

## 5. Implementación de referencia en Kubernetes

El siguiente escenario combina tres casos de uso comunes de distintas industrias en un mismo clúster de GPUs, que es la típica "plataforma de IA" que opera un SRE:

1. **Inference de visión para retail/manufactura**: Triton sirviendo un modelo TensorRT, en tiempo real, con autoscaling según el tiempo en cola.
2. **Scoring batch de fraude financiero**: un Job de inference batch nocturno.
3. **Chatbot RAG empresarial**: un microservicio de inference LLM en una GPU dedicada.

### 5.1 Instalación del GPU Operator (base para todos los casos de uso)

El NVIDIA GPU Operator automatiza el stack de software de GPU en Kubernetes como containers y DaemonSets: driver, container toolkit, device plugin, GPU Feature Discovery, DCGM exporter y MIG manager. Después, los nodos anuncian `nvidia.com/gpu` y labels descriptivos.

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
"nvidia" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "nvidia" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --values gpu-operator-values.yaml --wait
NAME: gpu-operator
LAST DEPLOYED: Thu Nov 12 10:14:03 2026
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

`gpu-operator-values.yaml`:

```yaml
operator:
  defaultRuntime: containerd
driver:
  enabled: true
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
gfd:
  enabled: true
migManager:
  enabled: true
  config:
    name: default-mig-parted-config
mig:
  strategy: mixed
nodeStatusExporter:
  enabled: true
```

ConfigMap de time-slicing. Sobresuscribe las GPUs para casos de uso de dev y batch donde no se requiere aislamiento.

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

Elección del mecanismo de compartición de GPU según el caso de uso:

| Mecanismo | Aislamiento | Caso de uso adecuado |
|---|---|---|
| GPU completa | Total | Training, inference de LLMs grandes |
| MIG (GPUs de data center Ampere/Hopper/Blackwell) | Por hardware: SMs, memoria y caché dedicados | Inference multi-tenant con latencia predecible (modelos chicos de visión/speech) |
| Time-slicing | Ninguno (memoria compartida, cambio de contexto) | Notebooks, dev/test, jobs batch tolerantes |
| MPS | Parcial (límites del espacio de direcciones compartido) | Muchos procesos chicos de inference que cooperan |

### 5.2 Namespaces y quotas por unidad de negocio

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: retail-vision
  labels:
    team: retail
    workload-class: online-inference
---
apiVersion: v1
kind: Namespace
metadata:
  name: fin-fraud
  labels:
    team: finance
    workload-class: batch-inference
    compliance: pci
---
apiVersion: v1
kind: Namespace
metadata:
  name: genai-rag
  labels:
    team: platform
    workload-class: llm-inference
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: retail-vision
spec:
  hard:
    requests.nvidia.com/gpu: "4"
    limits.nvidia.com/gpu: "4"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: fin-fraud
spec:
  hard:
    requests.nvidia.com/gpu: "8"
    limits.nvidia.com/gpu: "8"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: genai-rag
spec:
  hard:
    requests.nvidia.com/gpu: "2"
    limits.nvidia.com/gpu: "2"
```

### 5.3 PriorityClasses: la inference online debe desalojar al batch

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: online-inference
value: 100000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Latency-sensitive user-facing inference"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch-inference
value: 1000
globalDefault: false
preemptionPolicy: Never
description: "Throughput-oriented batch scoring, preemptible"
```

### 5.4 Caso de uso A: inference de visión en tiempo real con Triton (retail / manufactura)

El repositorio de modelos vive en un volumen compartido. El engine de TensorRT tiene que estar construido para la **misma arquitectura de GPU** en la que corre, así que fijamos el producto de GPU con un node selector usando el label publicado por GPU Feature Discovery.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-repo
  namespace: retail-vision
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: nfs-models
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-vision
  namespace: retail-vision
  labels:
    app: triton-vision
spec:
  replicas: 2
  selector:
    matchLabels:
      app: triton-vision
  template:
    metadata:
      labels:
        app: triton-vision
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8002"
    spec:
      priorityClassName: online-inference
      nodeSelector:
        nvidia.com/gpu.product: NVIDIA-L4
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: triton
          image: nvcr.io/nvidia/tritonserver:24.08-py3
          command:
            - tritonserver
          args:
            - --model-repository=/models
            - --model-control-mode=explicit
            - --load-model=shelf_detector
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
              nvidia.com/gpu: "1"
            limits:
              memory: 16Gi
              nvidia.com/gpu: "1"
          readinessProbe:
            httpGet:
              path: /v2/health/ready
              port: http
            initialDelaySeconds: 20
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /v2/health/live
              port: http
            initialDelaySeconds: 60
            periodSeconds: 10
          startupProbe:
            httpGet:
              path: /v2/health/ready
              port: http
            failureThreshold: 60
            periodSeconds: 5
          volumeMounts:
            - name: models
              mountPath: /models
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: model-repo
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: triton-vision
  namespace: retail-vision
  labels:
    app: triton-vision
spec:
  selector:
    app: triton-vision
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

Configuración del modelo en Triton con dynamic batching. Es un archivo de texto protobuf, no YAML, y va en `/models/shelf_detector/config.pbtxt`:

```
name: "shelf_detector"
platform: "tensorrt_plan"
max_batch_size: 32
input [
  {
    name: "images"
    data_type: TYPE_FP16
    dims: [ 3, 640, 640 ]
  }
]
output [
  {
    name: "detections"
    data_type: TYPE_FP16
    dims: [ -1, 6 ]
  }
]
dynamic_batching {
  preferred_batch_size: [ 8, 16 ]
  max_queue_delay_microseconds: 2000
}
instance_group [
  {
    count: 2
    kind: KIND_GPU
  }
]
```

Hacer autoscaling según el tiempo en cola de inference es mejor que hacerlo según la CPU. Los servicios limitados por GPU pueden mostrar CPU baja mientras los requests se acumulan. Primero, la regla de prometheus-adapter (Helm values para `prometheus-community/prometheus-adapter`):

```yaml
rules:
  custom:
    - seriesQuery: 'nv_inference_queue_duration_us{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace:
            resource: namespace
          pod:
            resource: pod
      name:
        matches: "nv_inference_queue_duration_us"
        as: "triton_avg_queue_us"
      metricsQuery: |
        avg(
          rate(nv_inference_queue_duration_us{<<.LabelMatchers>>}[1m])
          /
          clamp_min(rate(nv_inference_request_success{<<.LabelMatchers>>}[1m]), 1)
        ) by (<<.GroupBy>>)
```

Después, el HorizontalPodAutoscaler que la consume:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: triton-vision
  namespace: retail-vision
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: triton-vision
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Pods
      pods:
        metric:
          name: triton_avg_queue_us
        target:
          type: AverageValue
          averageValue: "5000"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
```

### 5.5 Caso de uso B: scoring batch de fraude (servicios financieros)

Es una corrida de scoring nocturna sobre las transacciones del día. Está orientada a throughput, así que corre como un Job paralelo indexado, desalojable y que usa GPUs con time-slicing.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: fraud-batch-scoring
  namespace: fin-fraud
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      completionMode: Indexed
      completions: 16
      parallelism: 8
      backoffLimitPerIndex: 2
      maxFailedIndexes: 2
      podFailurePolicy:
        rules:
          - action: Ignore
            onPodConditions:
              - type: DisruptionTarget
          - action: FailIndex
            onExitCodes:
              containerName: scorer
              operator: In
              values:
                - 42
      template:
        metadata:
          labels:
            app: fraud-scorer
        spec:
          priorityClassName: batch-inference
          restartPolicy: Never
          tolerations:
            - key: nvidia.com/gpu
              operator: Exists
              effect: NoSchedule
          containers:
            - name: scorer
              image: registry.example.com/fin/fraud-scorer:2.3.1
              command:
                - python
                - /app/score.py
              args:
                - --input=s3://fin-txn/daily/$(RUN_DATE)/
                - --output=s3://fin-scores/daily/$(RUN_DATE)/
                - --shard=$(JOB_COMPLETION_INDEX)
                - --num-shards=16
                - --batch-size=65536
              env:
                - name: RUN_DATE
                  value: "latest"
                - name: AWS_ENDPOINT_URL
                  value: "https://s3.internal.example.com"
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: access-key
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: secret-key
              resources:
                requests:
                  cpu: "8"
                  memory: 32Gi
                  nvidia.com/gpu: "1"
                limits:
                  memory: 32Gi
                  nvidia.com/gpu: "1"
```

El `scorer` usa RAPIDS cuDF para el feature engineering y un modelo XGBoost o GNN en la GPU. En este caso de uso, la aceleración por GPU tiene tanto que ver con el **ETL** como con el modelo en sí.

### 5.6 Caso de uso C: LLM RAG empresarial (atención al cliente transversal)

Un microservicio de inference LLM expone una API compatible con OpenAI. El caché del modelo se persiste para que los reinicios y el scale-out no vuelvan a descargar decenas de GB de pesos.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ngc-api
  namespace: genai-rag
type: Opaque
stringData:
  NGC_API_KEY: "REPLACE_WITH_NGC_API_KEY"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: llm-cache
  namespace: genai-rag
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-nvme
  resources:
    requests:
      storage: 200Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-nim
  namespace: genai-rag
  labels:
    app: llm-nim
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: llm-nim
  template:
    metadata:
      labels:
        app: llm-nim
    spec:
      priorityClassName: online-inference
      imagePullSecrets:
        - name: ngc-registry
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
          image: nvcr.io/nim/meta/llama-3.1-8b-instruct:1.3.3
          ports:
            - name: http
              containerPort: 8000
          env:
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ngc-api
                  key: NGC_API_KEY
            - name: NIM_CACHE_PATH
              value: /opt/nim/.cache
          resources:
            requests:
              cpu: "8"
              memory: 64Gi
              nvidia.com/gpu: "1"
            limits:
              memory: 64Gi
              nvidia.com/gpu: "1"
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
            periodSeconds: 20
          volumeMounts:
            - name: cache
              mountPath: /opt/nim/.cache
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: cache
          persistentVolumeClaim:
            claimName: llm-cache
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 16Gi
---
apiVersion: v1
kind: Service
metadata:
  name: llm-nim
  namespace: genai-rag
spec:
  selector:
    app: llm-nim
  ports:
    - name: http
      port: 8000
      targetPort: http
```

Notas sobre estas decisiones:

- **`strategy: Recreate`** se usa porque el volumen de caché RWO no puede montarse en dos pods en nodos distintos durante un rolling update. El trade-off es un downtime breve. La alternativa es un caché ReadWriteMany con RollingUpdate.
- **`startupProbe` con un presupuesto largo**: acá 180 × 10 s = 30 min, lo que cubre una primera descarga de pesos. Sin ella, la liveness probe mata el pod durante la carga del modelo, lo que produce un CrashLoopBackOff que parece un bug de la aplicación.
- **Un `/dev/shm` grande** es necesario para runtimes de inference multiproceso y para NCCL cuando el tensor parallelism abarca varias GPUs.

### 5.7 Observabilidad de GPU (todos los casos de uso)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ai-workload-alerts
  namespace: monitoring
spec:
  groups:
    - name: gpu-health
      rules:
        - alert: GPUXidErrors
          expr: |
            increase(DCGM_FI_DEV_XID_ERRORS[5m]) > 0
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "XID error on {{ $labels.Hostname }} GPU {{ $labels.gpu }}"
        - alert: GPUUnderutilizedTraining
          expr: |
            avg_over_time(DCGM_FI_DEV_GPU_UTIL{namespace=~".*train.*"}[30m]) < 40
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Training GPU under 40% util: likely data loader or storage bottleneck"
        - alert: GPUMemoryNearFull
          expr: |
            DCGM_FI_DEV_FB_USED
              /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.95
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "GPU framebuffer above 95% on {{ $labels.Hostname }}"
    - name: inference-slo
      rules:
        - alert: TritonHighQueueTime
          expr: |
            sum(rate(nv_inference_queue_duration_us[5m])) by (model)
              /
            clamp_min(sum(rate(nv_inference_request_success[5m])) by (model), 1)
              > 20000
          for: 5m
          labels:
            severity: page
          annotations:
            summary: "Model {{ $labels.model }} avg queue time above 20ms"
```

## 6. Verificación por CLI

### 6.1 Verificar la plataforma de GPU

```
$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7hx2k                                   1/1     Running     0          12m
gpu-operator-6d8f9c7b5-qwz4m                                  1/1     Running     0          13m
gpu-operator-node-feature-discovery-gc-5c9d7f8b6-lm2tq        1/1     Running     0          13m
gpu-operator-node-feature-discovery-master-7f6c9d5d4-8vjxp    1/1     Running     0          13m
gpu-operator-node-feature-discovery-worker-4tqzn              1/1     Running     0          13m
nvidia-container-toolkit-daemonset-r8m5v                      1/1     Running     0          12m
nvidia-cuda-validator-9wq7d                                   0/1     Completed   0          10m
nvidia-dcgm-exporter-b2x9n                                    1/1     Running     0          12m
nvidia-device-plugin-daemonset-k6p4s                          1/1     Running     0          12m
nvidia-driver-daemonset-xz7lm                                 1/1     Running     0          12m
nvidia-mig-manager-n5c8f                                      1/1     Running     0          11m
nvidia-operator-validator-tj8gh                               1/1     Running     0          12m

$ kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/mig.strategy
NAME        STATUS   ROLES    AGE   VERSION   GPU.PRODUCT              GPU.COUNT   MIG.STRATEGY
gpu-h100-1  Ready    <none>   41d   v1.31.4   NVIDIA-H100-80GB-HBM3    8           mixed
gpu-l4-1    Ready    <none>   41d   v1.31.4   NVIDIA-L4                4           mixed
gpu-l4-2    Ready    <none>   41d   v1.31.4   NVIDIA-L4                4           mixed

$ kubectl describe node gpu-l4-1 | grep -A6 "Allocatable:"
Allocatable:
  cpu:                63500m
  ephemeral-storage:  1729936476Ki
  hugepages-1Gi:      0
  memory:             263403040Ki
  nvidia.com/gpu:     16
  pods:               110
```

`nvidia.com/gpu: 16` en un nodo de 4 GPUs confirma que el time-slicing con `replicas: 4` está activo.

### 6.2 Inspeccionar la GPU desde dentro de un workload

```
$ kubectl exec -n retail-vision deploy/triton-vision -- nvidia-smi
Thu Nov 12 10:42:17 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|=========================================+========================+======================|
|   0  NVIDIA L4                      On  |   00000000:41:00.0 Off |                    0 |
| N/A   58C    P0             52W /   72W |    6142MiB /  23034MiB |     71%      Default |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI        PID   Type   Process name                              GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
+-----------------------------------------------------------------------------------------+
```

Una lista de procesos vacía dentro de un container es normal, por el aislamiento del PID namespace. Usá las métricas de DCGM o `nvidia-smi` en el host para atribuir el uso.

### 6.3 Verificar el servicio de visión en Triton

```
$ kubectl port-forward -n retail-vision svc/triton-vision 8000:8000 8002:8002 &
$ curl -s -o /dev/null -w "%{http_code}\n" localhost:8000/v2/health/ready
200

$ curl -s localhost:8000/v2/models/shelf_detector | python3 -m json.tool
{
    "name": "shelf_detector",
    "versions": [
        "1"
    ],
    "platform": "tensorrt_plan",
    "inputs": [
        {
            "name": "images",
            "datatype": "FP16",
            "shape": [-1, 3, 640, 640]
        }
    ],
    "outputs": [
        {
            "name": "detections",
            "datatype": "FP16",
            "shape": [-1, -1, 6]
        }
    ]
}

$ curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|queue_duration_us|exec_count)'
nv_inference_request_success{model="shelf_detector",version="1"} 184223
nv_inference_queue_duration_us{model="shelf_detector",version="1"} 211873402
nv_inference_exec_count{model="shelf_detector",version="1"} 15931
```

El cociente `request_success / exec_count` (alrededor de 11,6 acá) es el **tamaño de batch efectivo promedio**. Muestra que el dynamic batching está funcionando.

Prueba de carga con `perf_analyzer` desde el container del SDK de Triton:

```
$ perf_analyzer -m shelf_detector -u triton-vision.retail-vision:8001 -i grpc \
    --concurrency-range 4:16:4 --shape images:3,640,640
*** Measurement Settings ***
  Batch size: 1
  Service Kind: Triton
  Using "time_windows" mode for stabilization
  Measurement window: 5000 msec
  Latency limit: 0 msec
  Concurrency limit: 16 concurrent requests
  Using synchronous calls for inference
  Stabilizing using average latency

Request concurrency: 4
  Client:
    Request count: 9214
    Throughput: 511.8 infer/sec
    Avg latency: 7802 usec (standard deviation 611 usec)
    p50 latency: 7710 usec
    p90 latency: 8512 usec
    p95 latency: 8801 usec
    p99 latency: 9640 usec
...
Inferences/Second vs. Client Average Batch Latency
Concurrency: 4, throughput: 511.8 infer/sec, latency 7802 usec
Concurrency: 8, throughput: 902.4 infer/sec, latency 8851 usec
Concurrency: 12, throughput: 1121.7 infer/sec, latency 10690 usec
Concurrency: 16, throughput: 1168.3 infer/sec, latency 13689 usec
```

Cómo leer la curva: el throughput se aplana entre concurrencia 12 y 16 mientras la latencia sigue creciendo. Ese es el punto de saturación (la "rodilla"). Configurá el target del HPA y la concurrencia por réplica por debajo de ese punto.

### 6.4 Verificar el servicio LLM

```
$ kubectl logs -n genai-rag deploy/llm-nim | grep -iE "profile|ready|uvicorn" | tail -5
INFO 2026-11-12 10:31:02 ngc_injector.py:152] Selected profile: tensorrt_llm-h100-fp8-tp1-throughput
INFO 2026-11-12 10:31:02 ngc_injector.py:160] Profile metadata: precision: fp8
INFO 2026-11-12 10:33:47 server.py:82] Model loaded, warming up
INFO 2026-11-12 10:34:05 server.py:91] Service ready
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)

$ kubectl port-forward -n genai-rag svc/llm-nim 8080:8000 &
$ curl -s localhost:8080/v1/models | python3 -m json.tool
{
    "object": "list",
    "data": [
        {
            "id": "meta/llama-3.1-8b-instruct",
            "object": "model",
            "owned_by": "system"
        }
    ]
}

$ curl -s localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"meta/llama-3.1-8b-instruct","messages":[{"role":"user","content":"Summarize in one sentence: GPU Operator automates driver, toolkit and device plugin lifecycle."}],"max_tokens":60}' \
    | python3 -m json.tool | grep -A2 '"content"'
                "content": "The GPU Operator automates the installation and lifecycle management of NVIDIA drivers, the container toolkit, and the device plugin on Kubernetes nodes.",
                "role": "assistant"
            },
```

El perfil seleccionado (`h100-fp8-tp1-throughput`) te dice que el microservicio detectó la H100 y eligió un engine TensorRT-LLM en FP8 con tensor parallelism 1. Eso es optimización consciente del hardware, sin ningún build manual de TensorRT.

### 6.5 Verificar el scoring batch de fraude

```
$ kubectl create job -n fin-fraud --from=cronjob/fraud-batch-scoring fraud-manual-001
job.batch/fraud-manual-001 created

$ kubectl get job -n fin-fraud fraud-manual-001 -w
NAME               STATUS    COMPLETIONS   DURATION   AGE
fraud-manual-001   Running   0/16          12s        12s
fraud-manual-001   Running   8/16          6m31s      6m31s
fraud-manual-001   Complete  16/16         12m58s     12m58s

$ kubectl get pods -n fin-fraud -l job-name=fraud-manual-001 \
    -o custom-columns=POD:.metadata.name,INDEX:.metadata.annotations.batch\\.kubernetes\\.io/job-completion-index,NODE:.spec.nodeName,STATUS:.status.phase | head -5
POD                          INDEX   NODE       STATUS
fraud-manual-001-0-7wzxk     0       gpu-l4-2   Succeeded
fraud-manual-001-1-q9plm     1       gpu-l4-2   Succeeded
fraud-manual-001-2-h4c8n     2       gpu-l4-1   Succeeded
fraud-manual-001-3-zk2rt     3       gpu-l4-2   Succeeded
```

## 7. Guía de diagnóstico de fallas

### 7.1 Síntoma → causa → acción

| Síntoma | Causa probable | Cómo confirmarlo | Solución |
|---|---|---|---|
| Pod `Pending` con `0/3 nodes are available: 3 Insufficient nvidia.com/gpu` | GPUs agotadas, quota que no coincide, o device plugin que no está corriendo | `kubectl describe pod`; `kubectl get pods -n gpu-operator`; `kubectl describe node \| grep nvidia.com/gpu` | Liberar capacidad, habilitar MIG o time-slicing para workloads chicos, revisar el `ResourceQuota` |
| El nodo no muestra `nvidia.com/gpu` en Allocatable | Falló el DaemonSet del driver (kernel headers, Secure Boot) o hay conflicto con un driver preinstalado en el host | `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset`; `kubectl get pods -n gpu-operator \| grep validator` | Instalar los kernel headers correspondientes, poner `driver.enabled=false` si el driver del host ya está preinstalado, firmar los módulos para Secure Boot |
| Pod LLM en CrashLoopBackOff durante el primer arranque, los logs muestran progreso de descarga | La liveness probe mata el pod durante la descarga de pesos | `kubectl describe pod` muestra `Liveness probe failed` antes de estar ready | Agregar un `startupProbe` con un presupuesto largo; persistir el caché del modelo |
| Modelo de Triton `UNAVAILABLE`: falla al deserializar el engine | Plan de TensorRT construido para otra arquitectura de GPU u otra versión de TensorRT | `kubectl logs` muestra un mismatch de serialización/versión | Reconstruir el engine por tipo de GPU, fijar `nodeSelector` sobre `nvidia.com/gpu.product` |
| `CUDA out of memory` en inference | Modelo más KV cache exceden la memoria de la GPU, o el batch es demasiado grande, o la GPU está con time-slicing compartida con un vecino | `DCGM_FI_DEV_FB_USED`; `nvidia-smi` en el host | Cuantizar (FP8/INT8), reducir el batch máximo o el largo de contexto, usar un perfil MIG con suficiente memoria, no usar time-slicing con modelos que consumen mucha memoria |
| La utilización de GPU en training oscila entre 0% y 100% | Cuello de botella en el data loader o el storage; la GPU espera datos | Patrón en serrucho de `DCGM_FI_DEV_GPU_UTIL`; iowait alto en el nodo; latencia de storage | Más workers en el data loader, caché local en NVMe, GPUDirect Storage, un file system paralelo más rápido, optimizar el formato de datos |
| Frenadas periódicas de varios minutos en training | Las escrituras sincrónicas de checkpoints saturan el storage | Las frenadas coinciden con los intervalos de checkpoint | Checkpointing asíncrono, escribir en NVMe local y después copiar, aumentar el ancho de banda de escritura del storage |
| Picos de p99 en la inference online durante la noche | Jobs batch compartiendo las mismas GPUs (time-slicing) | Correlacionar con el schedule del CronJob; utilización por GPU en DCGM | Node pools separados, aislamiento con MIG, PriorityClass con preemption |
| El HPA nunca escala Triton | La métrica custom no está expuesta a través de prometheus-adapter | `kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/retail-vision/pods/*/triton_avg_queue_us"` | Corregir el `seriesQuery` y los labels de la regla del adapter; revisar el ServiceMonitor |
| Pipeline de visión con baja utilización de GPU pero CPU alta | Decode de video y preprocesamiento del lado de la CPU | `top` en el pod; `nvidia-smi dmon -s u` muestra dec en 0% | Usar NVDEC (DeepStream), preprocesamiento en GPU (DALI), ensembles de Triton |
| XID 79 "GPU has fallen off the bus" / XID 48 ECC de doble bit | Falla de hardware o térmica | `DCGM_FI_DEV_XID_ERRORS`; `dmesg \| grep -i xid` en el host | Hacer cordon y drain del nodo, correr diagnósticos de DCGM, RMA si persiste |

### 7.2 Comandos de diagnóstico

```
$ kubectl describe pod -n genai-rag -l app=llm-nim | sed -n '/Events:/,$p'
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  2m    default-scheduler  0/3 nodes are available: 1 Insufficient nvidia.com/gpu, 2 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.

$ kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/retail-vision/pods/*/triton_avg_queue_us" | python3 -m json.tool | grep -E '"name"|"value"'
                "name": "triton-vision-6b9c7d8f4-2kx8p",
            "value": "3412",
                "name": "triton-vision-6b9c7d8f4-9mzqw",
            "value": "3907",

$ kubectl debug node/gpu-l4-1 -it --image=busybox -- chroot /host dmesg | grep -i xid
[1823411.902113] NVRM: Xid (PCI:0000:41:00): 13, pid=88213, name=tritonserver, Graphics SM Warp Exception on (GPC 2, TPC 1, SM 0): Out Of Range Address

$ kubectl exec -n gpu-operator ds/nvidia-dcgm-exporter -- dcgmi diag -r 1
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.7                                          |
| Driver Version Detected   | 550.90.07                                      |
| GPU Device IDs Detected   | 27b8,27b8,27b8,27b8                            |
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
```

Cómo leer el XID 13 en esta salida: el XID 13 (Graphics Engine Exception), atribuido a un proceso de aplicación, normalmente indica un **bug de la aplicación/kernel o un engine defectuoso**, no un problema de hardware. Contrastalo con los XID 48, 79 o 94/95, que apuntan a fallas de hardware o de memoria.

```
$ kubectl exec -n retail-vision deploy/triton-vision -- nvidia-smi dmon -s u -c 5
# gpu     sm    mem    enc    dec    jpg    ofa
# Idx      %      %      %      %      %      %
    0     72     41      0      0      0      0
    0     69     39      0      0      0      0
    0     74     43      0      0      0      0
    0     70     40      0      0      0      0
    0     71     42      0      0      0      0
```

En un caso de uso de analítica de **video**, `dec 0%` con CPU alta en el nodo significa que el decode se está haciendo en la CPU. Movelo a la GPU con DeepStream/NVDEC.

## 8. Resumen orientado al examen

- **Asociá cada industria con su framework insignia de NVIDIA:**
  - Salud → Clara, BioNeMo
  - Recomendadores de retail → Merlin
  - Video y espacios inteligentes → Metropolis/DeepStream
  - Speech → Riva
  - Ciberseguridad → Morpheus
  - Automotriz → DRIVE
  - Robótica → Isaac
  - Digital twins y simulación → Omniverse
  - Data science → RAPIDS
  - LLMs → NeMo (construir y personalizar) y NIM (desplegar)
  - Optimización de inference → TensorRT / TensorRT-LLM
  - Serving → Triton
- **Casos de uso de IA generativa y LLMs**: generación de contenido, resumen, traducción, código, chatbots, búsqueda/RAG, modelos de dominio específico (biología, química) y agentes.
- **Training vs inference**:
  - El training necesita cómputo scale-out, interconexión rápida y storage de alto throughput.
  - La inference necesita baja latencia, alto throughput por dólar y engines optimizados.
  - A lo largo de la vida de un modelo, la inference domina el consumo de GPU.
- **Edge vs data center**: visión, robótica, automotriz e imágenes dentro del hospital empujan la inference al edge (Jetson, IGX, DRIVE AGX). El training y el serving de LLMs grandes se quedan en el data center o en la cloud.
- **Compartición de GPU**: GPU completa para training y LLMs grandes, MIG para inference multi-tenant aislada, time-slicing para dev y batch.
- **Las industrias reguladas** (salud, finanzas, sector público) impulsan despliegues de IA on-prem y soberanos, además de confidential computing.

## Referencias

- NVIDIA AI Infrastructure and Operations (NCA-AIIO) exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- NVIDIA GPU Operator documentation: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- GPU sharing with time-slicing: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html
- Triton Inference Server documentation: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- NVIDIA NIM for LLMs documentation: https://docs.nvidia.com/nim/large-language-models/latest/introduction.html
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/index.html
- NVIDIA XID errors reference: https://docs.nvidia.com/deploy/xid-errors/index.html
- Kubernetes Indexed Jobs and Pod failure policy: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- Kubernetes HorizontalPodAutoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/