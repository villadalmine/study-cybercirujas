# 1.3 Diferenciar los conceptos de AI, Machine Learning y Deep Learning

> **Peso en el examen:** 4.75%. NCA-AIIO evalúa si sabés ubicar correctamente un workload dentro de la jerarquía AI → ML → DL y derivar de esa ubicación las consecuencias de infraestructura: tipo de cómputo, memoria, almacenamiento, red y stack de software.

---

## 1. Motivación: por qué un operador de infraestructura tiene que entender esto bien

Los equipos de producto usan "AI" para todo: un motor de reglas de detección de fraude, un modelo de churn con gradient boosting, un chatbot LLM de 70B parámetros. Para un equipo de plataforma son tres workloads muy distintos. Cada uno tiene su propio perfil de recursos, sus modos de falla y su curva de costos.

| Workload según lo describe producto | Lo que realmente es | Lo que necesita de la plataforma |
|---|---|---|
| "Alertas de fraude con AI" | AI basada en reglas / simbólica (umbrales if/then, tablas de decisión) | Unos pocos núcleos de CPU, KV store de baja latencia, sin GPU |
| "Predicción de churn con ML" | ML clásico (XGBoost, random forest, regresión logística sobre datos tabulares) | Nodos CPU, u **opcionalmente** una GPU vía RAPIDS/XGBoost para datasets grandes |
| "Nuestro asistente de AI" | Deep learning (LLM transformer), AI generativa | Nodos multi-GPU, memoria GPU de alto ancho de banda, NVLink/InfiniBand, almacenamiento de alto throughput, runtime de inferencia optimizado (TensorRT, Triton, NIM) |

Errores comunes en producción que surgen de confundir estas categorías:

- **Sobreaprovisionamiento:** programar una regresión logística de scikit-learn en un nodo 8×H100. Las GPUs quedan ociosas al 0% de utilización mientras bloquean jobs de DL reales.
- **Subaprovisionamiento:** tratar la inferencia de un LLM como "un modelo de ML detrás de una API" y desplegarlo en nodos CPU. La latencia pasa de milisegundos a decenas de segundos, o directamente el modelo no entra en memoria.
- **Diseño de almacenamiento incorrecto:** dimensionar el almacenamiento para un CSV tabular de 2 GB cuando el equipo de DL va a leer en streaming 40 TB de imágenes por epoch y escribir checkpoints de 500 GB cada hora.
- **Diseño de red incorrecto:** comprar 10 GbE commodity para un clúster que va a correr entrenamiento data-parallel multinodo, donde el tráfico de all-reduce de gradientes satura el fabric.

La jerarquía conceptual que sigue es la base de toda decisión de dimensionamiento en el resto del temario de NCA-AIIO.

---

## 2. La jerarquía: AI ⊃ ML ⊃ DL ⊃ AI generativa / LLMs

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

**Regla clave para el examen:** todo sistema de DL es un sistema de ML, y todo sistema de ML es un sistema de AI. Lo inverso no es cierto. Un motor de ajedrez que usa búsqueda alpha-beta escrita a mano es AI pero no ML. Un random forest es ML pero no DL.

### 2.1 Artificial Intelligence (el paraguas)

La AI es el campo amplio de construir sistemas que realizan tareas que normalmente requieren inteligencia humana: percepción, razonamiento, planificación, comprensión del lenguaje, toma de decisiones.

Históricamente, gran parte de la AI era **simbólica** (Good Old-Fashioned AI). Las personas codifican el conocimiento de forma explícita como reglas (`IF temperature > 90 AND pressure_drop THEN alert`), ontologías o heurísticas de búsqueda. Propiedades:

- **Determinista y explicable:** podés señalar la regla que se disparó.
- **Sin fase de entrenamiento:** el comportamiento se escribe, no se aprende.
- **Frágil:** falla ante entradas que los autores de las reglas no anticiparon, y escala mal a medida que crece la cantidad de reglas.
- **Infraestructura:** servicios comunes en CPU. No hace falta ningún acelerador.

### 2.2 Machine Learning

El ML es el subconjunto de la AI en el que el sistema **aprende patrones a partir de datos**. En la formulación clásica de Arthur Samuel, les da a las computadoras "the ability to learn without being explicitly programmed." En lugar de escribir la función de decisión, proporcionás ejemplos y un algoritmo de optimización ajusta los parámetros del modelo que minimizan una función de pérdida.

Paradigmas de aprendizaje:

| Paradigma | Señal de entrenamiento | Algoritmos típicos | Ejemplo |
|---|---|---|---|
| Supervisado | Pares etiquetados (x, y) | Regresión lineal/logística, SVM, random forest, XGBoost | Predecir churn a partir de atributos del cliente |
| No supervisado | Solo x sin etiquetar | k-means, DBSCAN, PCA | Segmentación de clientes, detección de anomalías |
| Semi/auto-supervisado | Etiquetas derivadas de los propios datos | Predicción de tokens enmascarados | Preentrenamiento de modelos de lenguaje (también DL) |
| Por refuerzo | Recompensa de un entorno | Q-learning, policy gradients | Robótica, scheduling de recursos |

El rasgo que define al ML **clásico** (no profundo) es la **ingeniería de features manual**. Un data scientist decide qué entradas importan, como "días desde el último login" o "valor promedio de la canasta", y las construye a mano. El modelo aprende pesos sobre esas features diseñadas por personas.

Perfil de infraestructura:

- Normalmente **datos tabulares/estructurados**, de megabytes a cientos de gigabytes.
- Los modelos son chicos: de kilobytes a unos pocos cientos de megabytes.
- El entrenamiento corre en CPU en minutos u horas. Las GPUs **pueden** acelerarlo significativamente vía NVIDIA RAPIDS (cuDF, cuML) o XGBoost con `device="cuda"`, sobre todo con datasets grandes y barridos de hiperparámetros. Acá la GPU es una optimización, no un requisito.
- Los modelos suelen ser más interpretables (feature importances, valores SHAP, caminos del árbol).

### 2.3 Deep Learning

El DL es el subconjunto del ML que usa **redes neuronales artificiales con muchas capas**. Cada capa aplica una transformación lineal (una multiplicación de matrices), seguida de una activación no lineal. Apilar capas permite que la red aprenda **representaciones jerárquicas directamente a partir de datos crudos**:

```
Raw pixels ──► edges ──► textures/corners ──► object parts ──► "cat"
 (input)     (layer 1)      (layers 2-3)       (layers 4-n)    (output)
```

Este es el diferenciador clave respecto del ML clásico. **El DL aprende las features por sí mismo (representation learning)** en lugar de depender de features hechas a mano. Por eso sobresale con **datos no estructurados**: imágenes, audio, video, texto libre.

Los trade-offs:

- **Hambriento de datos:** el rendimiento sigue mejorando con más datos, mientras que el ML clásico tiende a estancarse.
- **Hambriento de cómputo:** entrenar implica de miles de millones a billones de multiply-accumulates de punto flotante por muestra, repetidos para millones de muestras a lo largo de muchas epochs.
- **Menos interpretable:** millones o miles de millones de parámetros sin significado legible para una persona.
- **Hambriento de memoria:** pesos, gradientes, estado del optimizador y activaciones tienen que entrar todos en la memoria del acelerador.

### 2.4 AI generativa y Large Language Models

La AI generativa es una clase de modelos de DL que producen contenido nuevo en lugar de solo clasificar o predecir. Los LLMs son redes profundas basadas en transformers, entrenadas con auto-supervisión sobre corpus de texto masivos. Luego se adaptan mediante fine-tuning, alineamiento o retrieval-augmented generation (RAG). NVIDIA describe que sus usos incluyen generación de texto, resumen, traducción, generación de código, chatbots y creación de contenido en distintas industrias.

Para la infraestructura, los LLMs están en el extremo del espectro del DL:

- Cantidad de parámetros de miles de millones a cientos de miles de millones.
- El entrenamiento exige miles de GPUs, interconexión de alta velocidad y sistemas de archivos paralelos.
- La inferencia exige mucha memoria GPU, gestión del KV cache, batching y un runtime optimizado (TensorRT-LLM, Triton, NIM).

---

## 3. Por qué el Deep Learning se mapea a GPUs: la mecánica interna

### 3.1 El workload es álgebra lineal densa

Una capa fully connected calcula:

```
Y = activation(X · W + b)

X: [batch, in_features]     e.g. [256, 4096]
W: [in_features, out_feat]  e.g. [4096, 4096]
FLOPs ≈ 2 × 256 × 4096 × 4096 ≈ 8.6 GFLOP for ONE layer, ONE forward pass
```

Las convoluciones y la atención de los transformers también se reducen a General Matrix Multiplications (**GEMM**). GEMM es masivamente paralelo: cada elemento de salida es un producto punto independiente. Esa es exactamente la forma de trabajo que una GPU maneja bien:

| Propiedad | CPU | GPU (clase data center) |
|---|---|---|
| Diseño de núcleos | Decenas de núcleos complejos, optimizados para latencia | Miles de núcleos simples, optimizados para throughput |
| Unidades especializadas | Unidades vectoriales AVX-512 / AMX | **Tensor Cores** (multiply-accumulate de matrices dedicado) |
| Ancho de banda de memoria | ~100-500 GB/s (DDR5) | ~2-8 TB/s (HBM2e/HBM3/HBM3e) |
| Ideal para | Lógica con muchas ramas, código serial, modelos chicos, reglas | Matemática paralela densa, entrenamiento e inferencia de DL |

### 3.2 Entrenamiento vs inferencia

Ambas fases existen en ML y en DL, pero sus perfiles de infraestructura divergen marcadamente en DL:

| Dimensión | Entrenamiento | Inferencia |
|---|---|---|
| Objetivo | Aprender parámetros (forward pass, backward pass, paso del optimizador) | Aplicar parámetros fijos a entradas nuevas (solo forward pass) |
| Cómputo | Muy alto, sostenido durante horas o meses | Menor por request, pero continuo y escalado según el tráfico |
| Memoria por parámetro | Pesos + gradientes + estado del optimizador (p. ej. Adam: ~16 bytes/param en precisión mixta) | Solo pesos (2 bytes FP16/BF16, 1 byte FP8/INT8) + KV cache en LLMs |
| Precisión | FP32/TF32, precisión mixta BF16/FP16, FP8 en GPUs recientes | FP16, FP8, INT8, INT4 vía cuantización (TensorRT) |
| Métrica clave | Time-to-train, throughput (muestras/s), utilización de GPU | Latencia (p50/p99), throughput (requests/s, tokens/s), costo por inferencia |
| Patrón de escalado | Scale-up (NVLink) + scale-out (InfiniBand/RoCE) para all-reduce | Réplicas horizontales, dynamic batching, autoscaling |
| Patrón de almacenamiento | Lecturas repetidas de alto throughput del dataset, escrituras de checkpoints grandes y en ráfagas | Carga rápida del modelo al iniciar, poco I/O continuo |
| Stack de NVIDIA | Contenedores PyTorch/NGC, NCCL, NeMo, DALI, Magnum IO GPUDirect Storage | TensorRT, TensorRT-LLM, Triton Inference Server, NIM |

### 3.3 Ejemplo resuelto de dimensionamiento (memoria)

Razonamiento estilo examen para un modelo de 7B parámetros:

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

Así, una sola GPU de 80 GB puede **servir** cómodamente un modelo de 7B. **Entrenarlo** requiere sharding (ZeRO/FSDP, tensor parallelism) entre varias GPUs. Un modelo XGBoost clásico en la misma plataforma podría ocupar 50 MB. Es una diferencia de más de tres órdenes de magnitud (112 GB / 50 MB ≈ 2,240×), y por eso la jerarquía le importa a los operadores.

---

## 4. Tablas comparativas de trade-offs

### 4.1 AI basada en reglas vs ML clásico vs deep learning

| Criterio | AI basada en reglas | ML clásico | Deep Learning |
|---|---|---|---|
| Cómo se produce el comportamiento | Reglas/lógica escritas a mano | Aprendido de datos sobre **features diseñadas** | Aprendido de datos, **features aprendidas automáticamente** |
| Datos requeridos | Ninguno (conocimiento experto) | De cientos a millones de filas | De millones a miles de millones de muestras |
| Tipo de dato ideal | Lógica de negocio bien definida | Estructurado/tabular | No estructurado: imágenes, audio, texto, video |
| Ingeniería de features | N/A | Manual, guiada por expertos del dominio | Mínima; la red aprende las representaciones |
| Cómputo de entrenamiento | Ninguno | Bajo-moderado (CPU alcanza; GPU opcional vía RAPIDS) | Muy alto (GPUs prácticamente obligatorias a escala) |
| Cómputo de inferencia | Trivial | Bajo (CPU suele alcanzar) | Moderado-alto (GPU fuertemente preferida por latencia/throughput) |
| Tamaño del modelo | Tablas de reglas | KB-MB | MB-TB |
| Interpretabilidad | Alta | Media-alta | Baja (requiere herramientas de explicabilidad) |
| Precisión en percepción/lenguaje | Pobre | Limitada | Estado del arte |
| Modo de falla | Entradas no anticipadas | Features pobres, data drift | Data drift, alucinación (GenAI), entradas adversarias |
| Ejemplos | Sistemas expertos, umbrales, búsqueda en ajedrez | Credit scoring, churn, pronóstico de demanda | Clasificación de imágenes, reconocimiento de voz, LLMs, embeddings para recomendadores |
| Aceleración de NVIDIA | Ninguna | RAPIDS cuDF/cuML, XGBoost GPU | CUDA, cuDNN, NCCL, TensorRT, Triton, NeMo, NIM |

### 4.2 Elegir un enfoque: flujo de decisión

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

### 4.3 Consecuencias de infraestructura por categoría

| Capa | ML clásico | Deep Learning (entrenamiento) | Deep Learning (inferencia) |
|---|---|---|---|
| Cómputo | Nodos CPU; GPU única opcional | Nodos multi-GPU (p. ej. 8 GPUs + NVLink/NVSwitch) | 1-N GPUs por réplica, posiblemente slices MIG |
| Red | Ethernet estándar | InfiniBand o RoCE, GPUDirect RDMA para all-reduce | Ethernet front-end estándar; tráfico este-oeste solo para modelos sharded multi-GPU |
| Almacenamiento | Data lake / object store, throughput modesto | FS paralelo o NFS/object de alto rendimiento con caché; GPUDirect Storage; ancho de banda para checkpoints | Repositorio de modelos rápido; caché NVMe local para reducir el cold-start |
| Scheduler | Kubernetes estándar | Gang scheduling, conciencia de topología | Autoscaling HPA/KEDA según profundidad de cola o utilización de GPU |
| Observabilidad | CPU/memoria, métricas del modelo | Métricas DCGM (utilización de SM, memoria, NVLink, errores XID) | Percentiles de latencia, métricas de Triton, DCGM |

---

## 5. Manifests de producción: el mismo clúster, tres clases de workload

Estos manifests modelan una plataforma Kubernetes realista. Los nodos GPU están gestionados por el **NVIDIA GPU Operator**, que instala el driver, el container toolkit, el device plugin, GPU Feature Discovery y el DCGM exporter. GPU Feature Discovery etiqueta los nodos GPU con `nvidia.com/gpu.present=true`, y el device plugin anuncia el extended resource `nvidia.com/gpu`.

### 5.1 Instalar el GPU Operator (prerrequisito para workloads de DL)

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

### 5.2 Namespace y recursos compartidos

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

### 5.3 ML clásico en nodos CPU (mantenido explícitamente fuera de los nodos GPU)

La node affinity usa `DoesNotExist`, de modo que este workload barato nunca cae en capacidad GPU costosa ni la bloquea.

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

### 5.4 ML clásico acelerado en una GPU (RAPIDS cuML)

Esto demuestra un matiz del examen: **las GPUs no son exclusivas del DL**. RAPIDS acelera el ML clásico y el procesamiento de datos, pero normalmente una sola GPU alcanza.

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

### 5.5 Entrenamiento de deep learning en un nodo multi-GPU

Detalles de producción que solo importan para DL:

- Varias GPUs por Pod.
- NCCL para el all-reduce de gradientes.
- Un `/dev/shm` ampliado, porque los workers del DataLoader de PyTorch y NCCL usan memoria compartida, y los 64 MiB por defecto provocan caídas con `Bus error`.
- Un contenedor NGC con versión fija, para que las versiones de CUDA, cuDNN y NCCL estén validadas en conjunto.

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

### 5.6 Inferencia de deep learning: engine de TensorRT servido por Triton

El entrenamiento produce un modelo de framework (PyTorch). Para la inferencia en producción, normalmente se exporta a ONNX, se compila en un **engine de TensorRT** con fusión de capas, auto-tuning de kernels y precisión FP16/FP8/INT8, y luego se sirve con **Triton Inference Server**. Triton agrega dynamic batching, ejecución concurrente de modelos y métricas de Prometheus.

Construir el engine. Tiene que construirse sobre la misma arquitectura de GPU y la misma versión de TensorRT que lo van a servir:

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

Configuración del modelo en Triton (`config.pbtxt`, formato de texto protobuf, **no** YAML), con la estructura de repositorio de modelos `models/resnet50/config.pbtxt` y `models/resnet50/1/model.plan`:

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

Recursos de Kubernetes para el serving:

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

## 6. Recorrido por la CLI: observar la diferencia

### 6.1 Inspeccionar las capacidades de los nodos

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

### 6.2 Ejecutar las tres clases de workload

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

### 6.3 Comparar las salidas

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

Interpretación:

- **El ML clásico en CPU** termina en bastante menos de un minuto y expone **feature importances**, lo que ayuda a la interpretabilidad.
- **El mismo algoritmo en una GPU vía RAPIDS** es aproximadamente un orden de magnitud más rápido. Vale la pena con datos grandes o barridos de hiperparámetros, pero el workload nunca necesitó ocho GPUs.
- **El deep learning** usa las ocho GPUs y aproximadamente 22 GiB de HBM por GPU para una CNN de tamaño medio. Un entrenamiento real de ResNet-50 sobre ImageNet repite esto durante ~90 epochs.

### 6.4 Inspeccionar la utilización de GPU durante el entrenamiento de DL

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

`NV18` significa 18 conexiones NVLink entre cada par de GPUs, a través de NVSwitch. El tráfico de all-reduce intra-nodo del entrenamiento de DL viaja por NVLink, no por PCIe. Es el tipo de topología que un job de ML clásico nunca usa.

### 6.5 Verificar la inferencia de DL

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

Hacé una prueba de carga con `perf_analyzer` de Triton (incluido en la imagen `-py3-sdk`) para ver el beneficio del dynamic batching:

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

El throughput escala mucho más rápido de lo que crece la latencia, porque Triton agrupa los requests en batches eficientes para la GPU.

---

## 7. Verificación y diagnóstico de fallas

### 7.1 Síntoma → causa → verificación → solución

| Síntoma | Causa probable | Cómo verificarlo | Solución |
|---|---|---|---|
| Pod de DL en `Pending`, evento `0/4 nodes are available: 4 Insufficient nvidia.com/gpu` | Todas las GPUs asignadas, o el device plugin no está corriendo | `kubectl describe pod`; `kubectl get pods -n gpu-operator` | Liberar GPUs, arreglar el operator o ajustar el request al tamaño correcto |
| El Pod del Job nunca se crea; evento del Job `exceeded quota: gpu-quota, requested: requests.nvidia.com/gpu=…` | el `ResourceQuota` del namespace está agotado: la cuota se verifica en la admisión, así que el Pod se rechaza, no queda en `Pending` | `kubectl describe resourcequota -n ai-workloads`; `kubectl describe job <name>` | Esperar a que terminen los Pods de GPU en ejecución, aumentar la cuota o ajustar el request al tamaño correcto |
| El nodo muestra `nvidia.com/gpu: 0` allocatable | Driver/toolkit no listos, o falló el validator | `kubectl logs -n gpu-operator -l app=nvidia-operator-validator`; `kubectl logs ds/nvidia-driver-daemonset -n gpu-operator` | Revisar la compatibilidad kernel/driver y la firma de módulos con Secure Boot, luego reiniciar el Pod del driver |
| `RuntimeError: CUDA out of memory` | La memoria del entrenamiento de DL (pesos + gradientes + optimizador + activaciones) excede la HBM | memory.used de `nvidia-smi`; `torch.cuda.max_memory_allocated()` | Bajar el batch size, habilitar precisión mixta/activation checkpointing, hacer sharding (FSDP/ZeRO), usar GPUs con más memoria |
| `ERROR: Unexpected bus error encountered in worker` / `Bus error (core dumped)` | `/dev/shm` tiene 64 MiB por defecto en los contenedores | `kubectl exec ... -- df -h /dev/shm` | Montar un `emptyDir` con `medium: Memory` en `/dev/shm` (ver 5.5) |
| Utilización de GPU oscilando entre 20-40% durante el entrenamiento | **Data starvation:** el almacenamiento o el preprocesamiento en CPU no alcanzan a alimentar las GPUs | DCGM `DCGM_FI_DEV_GPU_UTIL` vs throughput de lectura del almacenamiento; saturación de CPU en el Pod | Tier de almacenamiento más rápido, caché NVMe local, más workers del DataLoader, decodificación en GPU con NVIDIA DALI, GPUDirect Storage |
| El entrenamiento multi-GPU se cuelga al arrancar o hay timeouts `NCCL WARN` | NCCL no puede formar rings/trees (topología, red, shm) | Logs con `NCCL_DEBUG=INFO`; `nvidia-smi topo -m`; disponibilidad de dispositivos RDMA | Corregir el tamaño de shm, habilitar la NIC correcta (`NCCL_SOCKET_IFNAME`, RDMA/GPUDirect), revisar la salud de IB/RoCE |
| Pod `classical-ml` ubicado en un nodo GPU con 0% de utilización | Falta la affinity, así que el scheduler puso un workload de CPU en capacidad GPU | `kubectl get pods -o wide -L workload-class` | Agregar affinity `nvidia.com/gpu.present DoesNotExist`; aplicar el taint `nvidia.com/gpu=present:NoSchedule` a los nodos GPU |
| El Pod de Triton nunca queda Ready; el log muestra `failed to load 'resnet50'` | Engine de TensorRT construido para otra arquitectura de GPU u otra versión de TensorRT, o un `config.pbtxt` incorrecto | `kubectl logs deploy/triton-resnet50`; `curl /v2/repository/index -X POST` | Reconstruir el engine con la misma versión del contenedor de TensorRT en el tipo de GPU de destino; corregir nombres y dimensiones de entrada/salida |
| Latencia p99 de inferencia alta con baja utilización de GPU | Sin batching, o una única instancia del modelo serializando los requests | Métricas de Triton: duración en cola vs cómputo | Habilitar `dynamic_batching`, aumentar `instance_group.count`, usar engines de TensorRT FP16/INT8 |
| El tiempo por paso de entrenamiento salta después de un checkpoint | Las escrituras de checkpoints saturan el almacenamiento y bloquean el loop de entrenamiento | Ancho de banda de escritura del almacenamiento alrededor de los intervalos de checkpoint | Checkpointing asíncrono/sharded, tier de mayor throughput, escalonar las escrituras |

### 7.2 Secuencia de health-check para una plataforma GPU nueva

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

### 7.3 Diagnosticar un workload mal clasificado

Cuando un equipo pide GPUs, hacé estas preguntas antes de otorgar la capacidad:

1. **¿Aprende a partir de datos?** Si no, es AI basada en reglas y va en CPU.
2. **¿El modelo es una red neuronal con muchas capas?** Si no, es ML clásico: primero CPU, y una GPU vía RAPIDS solo si el volumen de datos o el tamaño del barrido lo justifican.
3. **¿Es entrenamiento o inferencia?** El entrenamiento necesita multi-GPU, interconexión y throughput de almacenamiento. La inferencia necesita SLOs de latencia, un runtime optimizado (TensorRT/Triton/NIM) y autoscaling.
4. **¿Qué precisión y qué tamaño de modelo?** Parámetros × bytes por parámetro te dice si entra en una GPU, en un slice MIG o si necesita sharding.

---

## 8. Resumen orientado al examen

- **AI** es el término más amplio: cualquier comportamiento de una máquina que imita la inteligencia humana, incluidos los sistemas basados en reglas que no aprenden.
- **ML** es un subconjunto de la AI: los algoritmos aprenden patrones a partir de datos en lugar de seguir reglas explícitas. El ML clásico depende de **features diseñadas por personas** y se adapta a **datos estructurados**.
- **DL** es un subconjunto del ML: **redes neuronales multicapa** que **aprenden features automáticamente** a partir de **datos no estructurados** crudos. Necesitan **datasets grandes** y **cómputo paralelo masivo**, por eso dominan las GPUs y los Tensor Cores.
- **La AI generativa y los LLMs** son un subconjunto del DL: modelos transformer que generan contenido. Son los workloads más exigentes en memoria, cómputo, red y almacenamiento.
- **El entrenamiento** es intensivo en cómputo y corre como workload batch que escala entre GPUs y nodos. **La inferencia** es serving de producción sensible a latencia y throughput, optimizado con **TensorRT** y servido con **Triton/NIM**.
- Las GPUs **también** aceleran el ML clásico y la ciencia de datos (RAPIDS), pero el DL es el workload que las vuelve imprescindibles.
- Distractores típicos del examen:
  - "Toda la AI requiere GPUs" es falso.
  - "El deep learning requiere ingeniería de features manual" es falso.
  - "El ML es más amplio que la AI" es falso.
  - "La inferencia tiene el mismo perfil de recursos que el entrenamiento" es falso.

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
- Documentación de NVIDIA GPU Operator: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html
- Guía de usuario de NVIDIA Triton Inference Server: https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/index.html
- Documentación de NVIDIA TensorRT: https://docs.nvidia.com/deeplearning/tensorrt/
- NVIDIA DCGM Exporter: https://docs.nvidia.com/datacenter/cloud-native/gpu-telemetry/latest/dcgm-exporter.html
- Documentación de RAPIDS (cuDF, cuML): https://docs.rapids.ai/
- NGC Catalog (contenedores PyTorch, Triton, TensorRT): https://catalog.ngc.nvidia.com/
- Kubernetes, Device Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/
- Kubernetes, Schedule GPUs: https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/