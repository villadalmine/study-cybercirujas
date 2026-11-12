# 1.5 — Key AI Use Cases and Industries

## 1. Motivation: why an infrastructure engineer must understand use cases

The NCA-AIIO exam does not expect you to be a data scientist. It expects you to look at a business request such as "we want fraud detection on card transactions" or "we want a chatbot over our internal documentation" and translate it into an **infrastructure profile**:

- Is this **training**, **fine-tuning**, or **inference**?
- Is inference **real-time** (latency-bound, p99 in milliseconds) or **batch** (throughput-bound, measured in records per hour)?
- What is the **data modality**? Text, image or video, audio, tabular, graph, or sensor/time-series.
- Where does it run? Data center, cloud, or **edge** (factory floor, vehicle, hospital device).
- What are the **regulatory constraints**? HIPAA, PCI-DSS, GDPR, data sovereignty.

Production failures in AI platforms rarely come from the model. They come from a mismatch between the workload profile and the platform. Common examples:

- A latency-sensitive inference service is scheduled on a node shared with a training job that saturates PCIe and NVLink.
- A recommender system's embedding tables don't fit in GPU memory.
- A video analytics pipeline is bottlenecked on CPU-side decode instead of NVDEC.
- A training cluster stalls because shared storage cannot sustain the read throughput of many data loaders, or because checkpoint writes block the step loop.

This topic is the bridge between "what the business wants" and "what the cluster must look like." NVIDIA frames it as an end-to-end stack:

- **Accelerated hardware**: GPUs, DPUs, NVLink, InfiniBand/Spectrum-X.
- **System software**: drivers, CUDA, the GPU Operator.
- **AI frameworks and SDKs**: NeMo, RAPIDS, TensorRT, Triton, NIM.
- **Industry-specific application frameworks** on top: Clara, Metropolis, Riva, Merlin, Morpheus, DRIVE, Isaac, Omniverse.

## 2. Taxonomy: use case → workload profile

### 2.1 Core AI workload categories

| Use case family | Typical models | Data modality | Dominant phase in production | Key infra constraint |
|---|---|---|---|---|
| Generative AI / LLMs (chat, summarization, code, RAG) | Transformer decoders (Llama, Nemotron, Mistral) | Text, tokens | Inference (plus periodic fine-tuning) | GPU memory for weights and KV cache; tokens/s; time-to-first-token |
| Computer vision (detection, segmentation, inspection) | CNNs, ViTs, YOLO-family | Image, video streams | Inference at the edge and in the DC | Video decode (NVDEC), per-stream latency, stream density per GPU |
| Speech AI (ASR, TTS, translation) | Conformer, Parakeet, FastPitch | Audio | Real-time streaming inference | End-to-end latency under ~300 ms for conversational use; gRPC streaming |
| Recommender systems | DLRM, two-tower, transformers4rec | Tabular plus very large embedding tables | Training on huge datasets; high-QPS inference | Embedding table size (TB scale), memory and network bandwidth |
| Fraud / anomaly / cybersecurity | GNNs, gradient boosted trees (XGBoost), autoencoders | Tabular, graphs, logs, packets | Real-time scoring plus batch retraining | Tight latency budgets in transaction paths; ETL throughput |
| Scientific / drug discovery | Protein structure models, generative chemistry, physics-ML | Sequences, molecules, meshes | Training plus large-batch inference | FP64/FP32 HPC mix; very large datasets; MPI plus NCCL |
| Autonomous systems / robotics | Perception, planning, foundation models | Multi-sensor (camera, lidar, radar) | Training in the DC; inference in the vehicle or robot; simulation | Simulation compute, petabyte-scale data pipelines, functional safety |
| Digital twins / simulation | Physics-informed models, rendering | 3D scenes (OpenUSD), sensor data | Simulation plus synthetic data generation | RTX graphics and compute mix; synchronization |
| Data analytics / data science | RAPIDS cuDF/cuML, Spark with RAPIDS | Tabular | Batch ETL and training | Storage throughput, CPU↔GPU data movement |

### 2.2 Training vs inference: the profile that shapes every decision

| Dimension | Training / fine-tuning | Online inference | Batch inference |
|---|---|---|---|
| Goal metric | Time-to-train, GPU utilization (MFU) | p50/p99 latency, TTFT, tokens/s per user | Throughput, cost per 1M records |
| Scaling style | Scale-out across nodes (data, tensor, and pipeline parallel) | Replicas behind a load balancer; autoscale on queue or latency | Parallel Jobs; maximize batch size |
| Interconnect | Critical: NVLink inside the node, InfiniBand/RoCE between nodes | Usually single-GPU or single-node (except very large LLMs with tensor parallelism) | Low importance |
| Storage pattern | Massive sequential/random reads of the dataset; bursty large checkpoint writes | Model load at start (cold start); little I/O afterwards | Read input dataset, write results |
| Precision | BF16/FP16/FP8 mixed precision | FP8/INT8/INT4 after TensorRT optimization | Same as online, but larger batches |
| Failure impact | Lost progress since last checkpoint | User-facing outage, SLO breach | Delayed report or re-run |
| GPU sharing | Rarely; prefers whole nodes | MIG partitions for small models are common | Time-slicing acceptable |

**Exam heuristic:** inference is where most production GPU-hours go over a model's lifetime. A model is trained once or occasionally, but served continuously. That is why NVIDIA invests heavily in TensorRT, Triton Inference Server, and NIM microservices.

## 3. Industries: use cases, NVIDIA platforms, and infra implications

| Industry | Representative use cases | NVIDIA platform / SDK | Infra implications for the SRE |
|---|---|---|---|
| **Healthcare & life sciences** | Medical imaging (radiology segmentation), genomics (variant calling), drug discovery (protein structure, molecule generation), clinical documentation with LLMs | **Clara** (imaging, Parabricks for genomics), **BioNeMo** (biology foundation models), MONAI | PHI/HIPAA: on-prem or sovereign clouds, encryption at rest and in transit, audit logs. Genomics is batch-heavy (Parabricks turns hours of CPU work into minutes on GPUs). Imaging inference is often on the edge, inside the hospital. |
| **Financial services** | Fraud detection, AML, algorithmic trading, risk simulation (Monte Carlo), document intelligence, customer-service LLMs | **RAPIDS**, **Morpheus** (for security), Triton, NIM, NeMo | Hard latency budgets in authorization paths (milliseconds). PCI-DSS segmentation. Explainability and model governance. Heavy GPU ETL with RAPIDS/Spark. |
| **Retail & CPG** | Recommenders, demand forecasting, store analytics (shelf/loss prevention), conversational shopping assistants | **Merlin** (recommenders), **Metropolis** (vision), RAPIDS, NIM | High QPS with embedding-table-heavy inference. Peaky seasonal traffic needs autoscaling. Many small edge sites (stores) need fleet management. |
| **Manufacturing & industrial** | Visual quality inspection, predictive maintenance, robotics, factory digital twins | **Metropolis**, **Isaac** (robotics), **Omniverse** (digital twins), Jetson/IGX at the edge | Edge deployments with intermittent connectivity. Real-time camera streams. Functional safety. OT/IT network separation. |
| **Automotive & transportation** | ADAS/AV perception and planning, simulation, in-cabin assistants, fleet analytics | **DRIVE** (AGX in-vehicle, Sim), **Omniverse**, Cosmos world models | Petabyte-scale sensor data ingestion. Large training clusters. Simulation and synthetic data generation. Safety certification (ISO 26262). |
| **Telecommunications** | Network optimization, AI-RAN, customer-care LLMs, anomaly detection | **Aerial** (5G/6G vRAN), Morpheus, NIM, Riva | Distributed edge (cell sites). Strict latency. GPU sharing between RAN signal processing and AI. |
| **Public sector & smart cities** | Traffic analytics, public safety video, citizen-service chatbots, sovereign LLMs | **Metropolis**, NeMo, NIM | Data sovereignty, air-gapped clusters, privacy-preserving video. |
| **Energy & climate / earth sciences** | Seismic interpretation, reservoir simulation, grid optimization, weather/climate (Earth-2) | **Modulus/PhysicsNeMo**, **Earth-2**, Omniverse | HPC-style clusters, FP64 requirements, huge datasets, MPI scheduling (Slurm alongside Kubernetes). |
| **Media, entertainment & gaming** | Generative content (image, video, voice), rendering, localization/dubbing, avatars | **Omniverse**, **Riva**, NeMo, **ACE** (digital humans) | Mixed graphics and compute GPUs. Bursty render farms. Large asset storage. |
| **Cybersecurity (cross-industry)** | Phishing detection, digital fingerprinting, log anomaly detection, LLM-assisted SOC | **Morpheus** (GPU-accelerated security pipelines), BlueField DPU | Line-rate inspection offloaded to DPUs. High-volume streaming pipelines (Kafka). |
| **Customer service (cross-industry)** | Contact-center agents, voice bots, RAG over knowledge bases | **NIM**, **NeMo Retriever**, **NeMo Guardrails**, **Riva** | Multi-component pipelines: ASR → LLM → TTS plus a vector DB. End-to-end latency budget split across services. |

### 3.1 LLM use cases specifically

LLMs are a horizontal capability that cuts across all of the industries above. The main uses are:

1. **Content generation.** Marketing copy, product descriptions, reports.
2. **Summarization.** Clinical notes, legal contracts, earnings calls, incident post-mortems.
3. **Translation and localization.** Multilingual support, dubbing pipelines with Riva.
4. **Code generation and assistance.** Developer copilots, infrastructure-as-code drafting.
5. **Conversational agents.** Customer service, internal IT helpdesk.
6. **Search and RAG (Retrieval-Augmented Generation).** Grounding answers in enterprise documents without retraining the model.
7. **Domain-specific models.** Biology (protein language models), chemistry, finance, telecom.
8. **Agentic workflows.** LLMs that call tools and APIs to complete multi-step tasks.

**Why RAG dominates enterprise adoption.** Fine-tuning bakes knowledge into weights. That makes it expensive to update, and you cannot easily remove a document. RAG retrieves fresh documents at query time and injects them into the prompt. The trade-off moves complexity from training to the **serving pipeline**: an embedding model, a vector database, a reranker, the LLM, and guardrails.

| Approach | Cost to update knowledge | Infra footprint | Hallucination control | Typical use |
|---|---|---|---|---|
| Prompting a base/instruct model | None | 1 inference service | Low | Generic assistants |
| RAG | Re-index documents (minutes) | Embedder + vector DB + reranker + LLM | Medium–high (answers cite sources) | Enterprise knowledge, support |
| Parameter-efficient fine-tuning (LoRA/PEFT) | Hours of GPU time | Training job + adapter registry; adapters served together | Medium | Style, format, domain jargon |
| Full fine-tuning / continued pre-training | Days to weeks on many GPUs | Multi-node training cluster plus high-throughput storage | Medium | Sovereign or domain foundation models |

## 4. From use case to architecture: storage, compute, and serving

### 4.1 Storage patterns by phase

NVIDIA's guidance on scaling storage for AI distinguishes phases with very different I/O signatures:

- **Data preparation / ETL.** Large sequential reads and writes. Benefits from GPU-accelerated ETL (RAPIDS) and parallel file systems or object storage.
- **Training.** Random reads over the full dataset on every epoch, from many concurrent data loaders. The goal is to keep the GPUs fed. A local NVMe cache plus a parallel file system is the common pattern, and **GPUDirect Storage (GDS)** moves data from NVMe or the network directly into GPU memory, bypassing the CPU bounce buffer.
- **Checkpointing.** Periodic, bursty large writes (tens to hundreds of GB for large models). Write bandwidth determines how long GPUs sit idle during a synchronous checkpoint.
- **Inference.** Mostly read-once at model load. Cold-start time is dominated by pulling weights. A model cache on a fast shared volume or a node-local cache reduces scale-out latency.

| Phase | Read pattern | Write pattern | What fails first |
|---|---|---|---|
| ETL | Sequential, large | Sequential, large | Network bandwidth to storage |
| Training | Random, small–medium, high concurrency | Checkpoints: bursty, very large | Metadata ops on the file system; GPU starvation |
| Inference (online) | Model load only | Logs/metrics | Cold start time during autoscaling |
| Batch inference | Sequential input | Sequential output | Object store request rate limits |

### 4.2 Inference optimization stack

- **TensorRT.** SDK that optimizes trained models for inference. It does layer and tensor fusion, precision calibration (FP16, INT8, FP8), kernel auto-tuning per GPU architecture, and dynamic tensor memory. The output is an engine (plan) specific to a GPU architecture and TensorRT version.
- **TensorRT-LLM.** LLM-specific optimizations: in-flight (continuous) batching, paged KV cache, tensor and pipeline parallelism, quantization.
- **Triton Inference Server.** Multi-framework serving (TensorRT, PyTorch, ONNX, Python, TensorRT-LLM backends). It provides dynamic batching, concurrent model execution, model ensembles, and Prometheus metrics on port 8002.
- **NVIDIA NIM.** Prebuilt, optimized inference microservices (containers) for specific models. They expose industry-standard APIs, such as the OpenAI-compatible API for LLMs, and select an optimized engine profile for the detected GPU.

Trade-off summary:

| Option | Time to production | Flexibility | Performance tuning effort | Best for |
|---|---|---|---|---|
| Framework-native serving (plain PyTorch) | Fast | Highest | High to reach good perf | Prototypes, research |
| Triton + TensorRT | Medium | High (multi-model, ensembles) | Medium | Vision, speech, recsys, custom pipelines |
| NIM | Fastest for supported models | Lower (model-specific container) | Low (pre-optimized profiles) | LLMs, embeddings, rerankers in enterprise |

## 5. Reference implementation on Kubernetes

The following scenario combines three common industry use cases on one GPU cluster, which is the typical "AI platform" an SRE operates:

1. **Retail/manufacturing vision inference**: Triton serving a TensorRT model, real-time, autoscaled on queue time.
2. **Financial batch fraud scoring**: a nightly batch inference Job.
3. **Enterprise RAG chatbot**: an LLM inference microservice on a dedicated GPU.

### 5.1 GPU Operator installation (foundation for all use cases)

The NVIDIA GPU Operator automates the GPU software stack on Kubernetes as containers and DaemonSets: driver, container toolkit, device plugin, GPU Feature Discovery, DCGM exporter, and MIG manager. Nodes then advertise `nvidia.com/gpu` and descriptive labels.

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

Time-slicing ConfigMap. This oversubscribes GPUs for dev and batch use cases where isolation is not required.

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

GPU sharing choice per use case:

| Mechanism | Isolation | Use case fit |
|---|---|---|
| Whole GPU | Full | Training, large LLM inference |
| MIG (Ampere/Hopper/Blackwell data center GPUs) | Hardware: dedicated SMs, memory, cache | Multi-tenant inference with predictable latency (small vision/speech models) |
| Time-slicing | None (shared memory, context switching) | Notebooks, dev/test, tolerant batch jobs |
| MPS | Partial (shared address space limits) | Many small cooperative inference processes |

### 5.2 Namespaces and quotas per business unit

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

### 5.3 PriorityClasses: online inference must preempt batch

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

### 5.4 Use case A: real-time vision inference with Triton (retail / manufacturing)

The model repository lives on a shared volume. The TensorRT engine must be built for the **same GPU architecture** it runs on, so we pin the GPU product with a node selector using the label published by GPU Feature Discovery.

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

Triton model configuration with dynamic batching. This is a protobuf text file, not YAML, and it goes in `/models/shelf_detector/config.pbtxt`:

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

Autoscaling on inference queue time is better than autoscaling on CPU. GPU-bound services can show low CPU while requests pile up. First, the prometheus-adapter rule (Helm values for `prometheus-community/prometheus-adapter`):

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

Then the HorizontalPodAutoscaler that consumes it:

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

### 5.5 Use case B: batch fraud scoring (financial services)

This is a nightly scoring run over the day's transactions. It is throughput-oriented, so it runs as an indexed parallel Job that is preemptible and uses time-sliced GPUs.

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

The `scorer` uses RAPIDS cuDF for feature engineering and an XGBoost or GNN model on the GPU. GPU acceleration in this use case is as much about **ETL** as about the model itself.

### 5.6 Use case C: enterprise RAG LLM (cross-industry customer service)

An LLM inference microservice exposes an OpenAI-compatible API. The model cache is persisted so that restarts and scale-out don't re-download tens of GB of weights.

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

Notes on these choices:

- **`strategy: Recreate`** is used because the RWO cache volume cannot be mounted by two pods on different nodes during a rolling update. The trade-off is brief downtime. The alternative is a ReadWriteMany cache with RollingUpdate.
- **`startupProbe` with a long budget**: here 180 × 10 s = 30 min, covering a first-time weight download. Without it, the liveness probe kills the pod during model load, producing a CrashLoopBackOff that looks like an application bug.
- **Large `/dev/shm`** is needed for multi-process inference runtimes and NCCL when tensor parallelism spans multiple GPUs.

### 5.7 GPU observability (all use cases)

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

## 6. CLI verification

### 6.1 Verify the GPU platform

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

`nvidia.com/gpu: 16` on a 4-GPU node confirms that time-slicing with `replicas: 4` is active.

### 6.2 Inspect the GPU from inside a workload

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

An empty process list inside a container is normal, because of PID namespace isolation. Use DCGM metrics or `nvidia-smi` on the host to attribute usage.

### 6.3 Verify the Triton vision service

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

The ratio `request_success / exec_count` (about 11.6 here) is the **average effective batch size**. It shows that dynamic batching is working.

Load test with `perf_analyzer` from the Triton SDK container:

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

How to read the curve: throughput flattens between concurrency 12 and 16 while latency keeps growing. That is the saturation knee. Set the HPA target and the per-replica concurrency below it.

### 6.4 Verify the LLM service

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

The selected profile (`h100-fp8-tp1-throughput`) tells you that the microservice detected the H100 and chose an FP8 TensorRT-LLM engine with tensor parallelism 1. That is hardware-aware optimization, with no manual TensorRT build.

### 6.5 Verify the batch fraud scoring

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

## 7. Failure diagnosis guide

### 7.1 Symptom → cause → action

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| Pod `Pending` with `0/3 nodes are available: 3 Insufficient nvidia.com/gpu` | GPUs exhausted, quota mismatch, or device plugin not running | `kubectl describe pod`; `kubectl get pods -n gpu-operator`; `kubectl describe node \| grep nvidia.com/gpu` | Free capacity, enable MIG or time-slicing for small workloads, check `ResourceQuota` |
| Node shows no `nvidia.com/gpu` in Allocatable | Driver DaemonSet failed (kernel headers, Secure Boot) or a pre-installed host driver conflicts | `kubectl logs -n gpu-operator ds/nvidia-driver-daemonset`; `kubectl get pods -n gpu-operator \| grep validator` | Install matching kernel headers, set `driver.enabled=false` if the host driver is preinstalled, sign modules for Secure Boot |
| LLM pod CrashLoopBackOff during first start, logs show download progress | Liveness probe kills the pod during weight download | `kubectl describe pod` shows `Liveness probe failed` before ready | Add a `startupProbe` with a long budget; persist the model cache |
| Triton model `UNAVAILABLE`: engine deserialization failure | TensorRT plan built for another GPU architecture or TensorRT version | `kubectl logs` shows a serialization/version mismatch | Rebuild the engine per GPU type, pin `nodeSelector` on `nvidia.com/gpu.product` |
| `CUDA out of memory` on inference | Model plus KV cache exceed GPU memory, or batch is too large, or the GPU is time-sliced with a neighbor | `DCGM_FI_DEV_FB_USED`; `nvidia-smi` on the host | Quantize (FP8/INT8), reduce max batch or context length, use a MIG profile with enough memory, don't time-slice memory-heavy models |
| Training GPU util oscillates between 0% and 100% | Data loader or storage bottleneck; GPU waits for data | `DCGM_FI_DEV_GPU_UTIL` sawtooth; high iowait on the node; storage latency | More data loader workers, local NVMe caching, GPUDirect Storage, a faster parallel file system, data format optimization |
| Periodic multi-minute training stalls | Synchronous checkpoint writes saturate storage | Stalls align with checkpoint intervals | Async checkpointing, write to local NVMe then copy, raise storage write bandwidth |
| Online inference p99 spikes at night | Batch jobs sharing the same GPUs (time-slicing) | Correlate with CronJob schedule; DCGM per-GPU util | Separate node pools, MIG isolation, PriorityClass with preemption |
| HPA never scales Triton | Custom metric not exposed through prometheus-adapter | `kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/retail-vision/pods/*/triton_avg_queue_us"` | Fix the adapter rule's `seriesQuery` and labels; check the ServiceMonitor |
| Vision pipeline has low GPU util but high CPU | CPU-side video decode and preprocessing | `top` in the pod; `nvidia-smi dmon -s u` shows dec at 0% | Use NVDEC (DeepStream), GPU preprocessing (DALI), Triton ensembles |
| XID 79 "GPU has fallen off the bus" / XID 48 double-bit ECC | Hardware or thermal fault | `DCGM_FI_DEV_XID_ERRORS`; `dmesg \| grep -i xid` on the host | Cordon and drain the node, run DCGM diagnostics, RMA if persistent |

### 7.2 Diagnostic commands

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

How to read the XID 13 in this output: XID 13 (Graphics Engine Exception), attributed to an application process, usually indicates an **application/kernel bug or a bad engine**, not hardware. Contrast it with XID 48, 79, or 94/95, which point to hardware or memory faults.

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

In a **video** analytics use case, `dec 0%` with high CPU on the node means decode is happening on the CPU. Move it to the GPU with DeepStream/NVDEC.

## 8. Exam-oriented summary

- **Map each industry to its flagship NVIDIA framework:**
  - Healthcare → Clara, BioNeMo
  - Retail recommenders → Merlin
  - Video and smart spaces → Metropolis/DeepStream
  - Speech → Riva
  - Cybersecurity → Morpheus
  - Automotive → DRIVE
  - Robotics → Isaac
  - Digital twins and simulation → Omniverse
  - Data science → RAPIDS
  - LLMs → NeMo (build and customize) and NIM (deploy)
  - Inference optimization → TensorRT / TensorRT-LLM
  - Serving → Triton
- **Generative AI and LLM use cases**: content generation, summarization, translation, code, chatbots, search/RAG, domain-specific models (biology, chemistry), and agents.
- **Training vs inference**:
  - Training needs scale-out compute, fast interconnect, and high-throughput storage.
  - Inference needs low latency, high throughput per dollar, and optimized engines.
  - Over a model's lifetime, inference dominates GPU consumption.
- **Edge vs data center**: vision, robotics, automotive, and in-hospital imaging push inference to the edge (Jetson, IGX, DRIVE AGX). Training and large LLM serving stay in the data center or cloud.
- **GPU sharing**: whole GPU for training and large LLMs, MIG for isolated multi-tenant inference, time-slicing for dev and batch.
- **Regulated industries** (healthcare, finance, public sector) drive on-prem and sovereign AI deployments, plus confidential computing.

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