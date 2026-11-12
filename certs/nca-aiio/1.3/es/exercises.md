# Ejercicios guiados — Tema 1.3: Diferenciar los conceptos de AI, machine learning y deep learning

**Certificación:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Peso de este tema en el examen:** 4.75%

## Qué vas a construir

En estos ejercicios resolvés problemas relacionados de tres maneras, para que puedas ver dónde están los límites entre los tres conceptos:

| Capa | Qué implementás | Quién diseña la lógica de decisión |
|---|---|---|
| **AI** (el paraguas) | Un filtro de spam basado en reglas | Una persona escribe reglas explícitas |
| **Machine Learning** (un subconjunto de AI) | Un clasificador de dígitos con regresión logística, primero sobre features diseñadas a mano y después sobre píxeles crudos | El algoritmo aprende los pesos; una persona suele diseñar las features |
| **Deep Learning** (un subconjunto de ML) | Una red neuronal convolucional (CNN) pequeña sobre los mismos dígitos | La red aprende tanto las features como la frontera de decisión, capa por capa |

Después conectás los conceptos con la infraestructura: por qué el deep learning impulsa la demanda de GPU, en qué se diferencia el entrenamiento de la inferencia, cómo TensorRT optimiza un modelo entrenado y cómo Kubernetes programa cargas de trabajo con GPU a través del NVIDIA GPU Operator.

## Requisitos previos

- Linux o macOS con Python 3.10 o posterior.
- **Opcional:** una GPU NVIDIA con un driver funcionando. Todos los pasos corren en CPU. Los pasos que requieren GPU están marcados con **[GPU]**.
- **Opcional:** un cluster de Kubernetes con el NVIDIA GPU Operator, para el Paso 8.

---

## Paso 1 — Preparar el entorno del laboratorio

1. Creá un directorio de trabajo aislado y un entorno virtual:

   ```bash
   mkdir -p ~/aiio-1.3 && cd ~/aiio-1.3
   python3 -m venv .venv
   source .venv/bin/activate
   python -m pip install --upgrade pip
   ```

2. Instalá las bibliotecas. `scikit-learn` cubre el ML clásico, `torch` cubre el deep learning, y `onnx`/`onnxscript` se necesitan más adelante para exportar el modelo:

   ```bash
   pip install numpy scikit-learn torch onnx onnxscript
   ```

3. Verificá la instalación y comprobá si PyTorch puede ver una GPU:

   ```bash
   python -c "import sklearn, torch; print('sklearn', sklearn.__version__); print('torch', torch.__version__); print('CUDA available:', torch.cuda.is_available())"
   ```

   Salida esperada (las versiones van a variar):

   ```
   sklearn 1.5.2
   torch 2.5.1+cu124
   CUDA available: True
   ```

   En una máquina sin GPU NVIDIA la última línea dice `CUDA available: False`. Está bien.

4. **[GPU]** Inspeccioná la GPU desde el punto de vista del driver:

   ```bash
   nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
   ```

   Salida de ejemplo:

   ```
   name, memory.total [MiB], driver_version
   NVIDIA A100-SXM4-80GB, 81920 MiB, 550.90.07
   ```

**Preguntas de comprensión — Paso 1**

- **Q1.1** Instalaste dos bibliotecas distintas, `scikit-learn` y `torch`. Según la tabla del principio, ¿a qué capa conceptual sirve principalmente cada una?
- **Q1.2** `torch.cuda.is_available()` devolvió `False`, pero el resto del laboratorio igual funciona. ¿Qué te dice esto sobre la relación entre el deep learning y las GPU: es un requisito funcional o un requisito de rendimiento?

---

## Paso 2 — AI sin aprendizaje: un sistema basado en reglas

La Inteligencia Artificial es el campo amplio que busca que las máquinas realicen tareas que normalmente requieren inteligencia humana. La AI temprana, a menudo llamada AI simbólica o sistemas expertos, codificaba el conocimiento humano como reglas explícitas. No se usan datos para aprender nada.

1. Creá `rules_ai.py`:

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

2. Ejecutalo:

   ```bash
   python rules_ai.py
   ```

   Salida esperada:

   ```
   SPAM score=9 rules=["mentions 'free money'", "mentions 'winner'", "contains 'click here'", 'more than 3 exclamation marks', 'mostly uppercase']
         'Congratulations WINNER!!!! Click here to claim your FREE MONEY'
   HAM  score=0 rules=[]
         'Hi team, the GPU cluster maintenance window moves to Friday.'
   SPAM score=4 rules=["mentions 'winner'", "contains 'click here'"]
         'You are a winner, click here now'
   HAM  score=0 rules=[]
         'Get fr33 m0ney today, totally legit'
   ```

3. Mirá el último mensaje. Es obviamente spam, pero el sistema lo clasificó como `HAM`.

**Preguntas de comprensión — Paso 2**

- **Q2.1** ¿Este programa es AI? ¿Es machine learning? Justificá ambas respuestas usando las definiciones.
- **Q2.2** Para detectar `fr33 m0ney` tenés que agregar una regla nueva a mano. ¿Qué revela esto sobre cómo escalan los sistemas basados en reglas a medida que crece el espacio del problema?
- **Q2.3** Nombrá una ventaja que este sistema basado en reglas tiene sobre los modelos de ML y DL que vas a construir a continuación. Pensá en la explicabilidad y el costo de cómputo.

---

## Paso 3 — Machine learning: aprender pesos a partir de datos

Machine Learning es un subconjunto de AI en el que un sistema mejora en una tarea aprendiendo patrones a partir de datos, en lugar de seguir reglas programadas explícitamente. En el ML clásico, normalmente una persona decide **qué features** ve el modelo (feature engineering), y el algoritmo aprende **cómo ponderarlas**.

Vas a usar el dataset `digits` de scikit-learn: 1.797 imágenes en escala de grises de dígitos manuscritos, cada una de 8×8 píxeles (64 valores de 0 a 16).

1. Creá `classic_ml.py`:

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

2. Ejecutalo:

   ```bash
   python classic_ml.py
   ```

   Salida esperada (la accuracy y los tiempos varían levemente según la versión de la biblioteca y la CPU):

   ```
   dataset shape (samples, features): (1797, 64)
   [A] engineered features (16): accuracy=0.880 train_time=0.05s
   [B] raw pixels (64):          accuracy=0.971 train_time=0.08s
   learned parameters in [B]: 650 -> (10, 64) weights + (10,) biases
   ```

   Deberías ver que el modelo con features diseñadas a mano obtiene un resultado notablemente inferior al modelo con píxeles crudos. Con esta configuración, la diferencia suele ser de alrededor de 0.85–0.90 contra alrededor de 0.96–0.98.

**Preguntas de comprensión — Paso 3**

- **Q3.1** Compará este programa con `rules_ai.py`. ¿Qué parte escribió una persona en cada caso y qué parte se derivó de los datos?
- **Q3.2** El modelo [A] rindió peor que el [B]. ¿Qué te dice esto sobre el riesgo del feature engineering, que es el paso humano que define al ML clásico?
- **Q3.3** Explicá de dónde sale el número 650. ¿Por qué este modelo se sigue considerando "shallow" (poco profundo)?
- **Q3.4** El entrenamiento tardó una fracción de segundo en una CPU. ¿Ayudaría mucho una GPU acá? ¿Por qué sí o por qué no?

---

## Paso 4 — Deep learning: aprender también las features

Deep Learning es un subconjunto de ML que usa redes neuronales artificiales de múltiples capas (profundas). La diferencia que lo define es el **representation learning**. Las primeras capas aprenden features de bajo nivel, como bordes y trazos, y las capas posteriores las combinan en conceptos de más alto nivel. Esto reemplaza la mayor parte del feature engineering manual. El costo es más parámetros, más datos y muchísimo más cómputo. Ese cómputo consiste mayoritariamente en multiplicaciones de matrices, que las GPU paralelizan muy bien.

1. Creá `deep_learning.py`:

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

2. Ejecutalo:

   ```bash
   python deep_learning.py
   ```

   Salida esperada (la loss, la accuracy y el tiempo varían según el hardware y la versión):

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

**Preguntas de comprensión — Paso 4**

- **Q4.1** En este script no existe ninguna función `engineer()`, y sin embargo la CNN iguala o supera a la regresión logística. ¿Qué parte de la red reemplaza el feature engineering manual?
- **Q4.2** La CNN tiene 13.706 parámetros contra 650 de la regresión logística, unas 21 veces más, para una tarea así de pequeña. Extrapolá: ¿qué pasa con las necesidades de cómputo y memoria cuando los modelos llegan a miles de millones de parámetros, como los large language models?
- **Q4.3** Nombrá las tres operaciones dentro del loop de entrenamiento que se ejecutan en cada mini-batch. ¿Cuáles de ellas existen solo durante el entrenamiento?
- **Q4.4** ¿Esta CNN también es "machine learning"? ¿También es "AI"? Describí con palabras, como si fuera un diagrama, la relación entre los tres términos.

---

## Paso 5 — Por qué el deep learning impulsa la infraestructura de GPU

La carga de trabajo del Paso 4 es demasiado pequeña para mostrar la ventaja de la GPU. Acá medís la operación que domina el deep learning: la multiplicación densa de matrices (GEMM).

1. Creá `gemm_bench.py`:

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

2. Ejecutalo:

   ```bash
   python gemm_bench.py
   ```

   Salida de ejemplo en un servidor con una GPU de data center. Tus números van a ser distintos, a menudo en un orden de magnitud según el hardware:

   ```
   CPU  fp32 4096x4096:     1.10 TFLOPS
   GPU  fp32 4096x4096:    17.80 TFLOPS
   GPU  fp16 4096x4096:   210.40 TFLOPS
   ```

3. **[GPU]** Mientras corre el benchmark, abrí una segunda terminal y observá la utilización:

   ```bash
   nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw --format=csv -l 1
   ```

**Preguntas de comprensión — Paso 5**

- **Q5.1** ¿Por qué el script llama a `torch.cuda.synchronize()` antes de leer el timer? ¿Qué mostraría la medición sin esa llamada?
- **Q5.2** FP16 es mucho más rápido que FP32 en la GPU. ¿Qué unidades de hardware especializadas de las GPU NVIDIA son responsables, y por qué esto importa más para el deep learning que para el sistema basado en reglas del Paso 2?
- **Q5.3** En una oración, para un stakeholder no técnico: ¿por qué fue el auge del deep learning, y no la AI en general, lo que creó demanda de data centers acelerados por GPU?

---

## Paso 6 — Entrenamiento vs. inferencia

El entrenamiento construye el modelo: forward pass, backward pass y actualización de pesos, repetidos sobre grandes datasets. La inferencia usa el modelo entrenado para hacer predicciones sobre datos nuevos: solo forward pass. Estas dos fases tienen perfiles de infraestructura muy distintos. El entrenamiento necesita throughput, memoria para activaciones y gradientes, y almacenamiento rápido para alimentar los datos. La inferencia necesita baja latencia, alto throughput por watt y escalar a usuarios concurrentes.

1. Creá `inference.py`:

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

   > Importar `deep_learning` vuelve a ejecutar su código de entrenamiento, porque ese script no tiene un guard `if __name__ == "__main__":`. Para este laboratorio es aceptable. En proyectos reales, mantené las definiciones de modelos en su propio módulo.

2. Ejecutalo:

   ```bash
   python inference.py
   ```

   Salida esperada, después del log de entrenamiento que genera el import. Los números son ilustrativos:

   ```
   batch=    1 latency=  0.210 ms  throughput=      4762 img/s
   batch=   64 latency=  0.320 ms  throughput=    200000 img/s
   batch= 1024 latency=  1.900 ms  throughput=    538947 img/s
   first 10 predictions: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
   first 10 labels:      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
   exported digits_cnn.onnx
   ```

3. **[GPU]** Optimizá el modelo exportado con NVIDIA TensorRT, el SDK para inferencia de deep learning de alto rendimiento. Ejecutalo desde un contenedor de NGC, eligiendo un tag actual del catálogo de NGC:

   ```bash
   docker run --rm --gpus all -v "$PWD":/work \
     nvcr.io/nvidia/tensorrt:24.08-py3 \
     trtexec --onnx=/work/digits_cnn.onnx \
             --saveEngine=/work/digits_cnn.plan \
             --fp16
   ```

   Cerca del final del log, buscá las líneas del resumen de rendimiento, por ejemplo:

   ```
   [I] Latency: min = 0.0213 ms, max = 0.0451 ms, mean = 0.0236 ms, median = 0.0232 ms
   [I] Throughput: 39871.2 qps
   &&&& PASSED TensorRT.trtexec [TensorRT v100300] # trtexec --onnx=/work/digits_cnn.onnx ...
   ```

**Preguntas de comprensión — Paso 6**

- **Q6.1** ¿Qué desactiva `torch.inference_mode()`, y por qué eso reduce el uso de memoria en comparación con el entrenamiento?
- **Q6.2** La latencia por llamada creció con el tamaño del batch, pero el throughput subió muchísimo. ¿Qué métrica importa más para un chatbot interactivo y cuál importa más para el scoring por lotes nocturno de millones de registros?
- **Q6.3** TensorRT optimiza un modelo que ya fue entrenado. ¿Se aplica a la AI basada en reglas (Paso 2), al ML clásico (Paso 3) o al deep learning (Paso 4)? ¿Por qué?
- **Q6.4** El engine `.plan` se construye para una GPU y una versión de TensorRT específicas. ¿Qué consecuencia operativa tiene esto cuando actualizás la flota de GPU?

---

## Paso 7 — Clasificar escenarios del mundo real

Usá solo las definiciones. Para cada escenario, anotá la etiqueta correcta **más específica** (solo AI, ML pero no DL, o DL), más una justificación de una línea.

| # | Escenario |
|---|---|
| a | Un firewall que bloquea el tráfico que coincide con una lista de firmas escritas a mano |
| b | Un modelo random forest que predice fallas de disco en servidores a partir de contadores SMART elegidos por un SRE |
| c | Un large language model (LLM) que resume tickets de incidentes |
| d | Un motor de ajedrez que usa búsqueda minimax con una función de evaluación ajustada a mano |
| e | Un modelo basado en transformers que transcribe notas de voz de técnicos del data center |
| f | Una regresión lineal que pronostica la demanda de horas de GPU del mes próximo a partir del uso pasado |
| g | Una CNN de detección de objetos que cuenta personas en una sala de servidores a partir de video de CCTV |
| h | Un termostato que enciende la refrigeración por encima de 27 °C |

**Preguntas de comprensión — Paso 7**

- **Q7.1** ¿Qué escenarios son **AI pero no ML**?
- **Q7.2** ¿Cuáles son **ML pero no DL**?
- **Q7.3** ¿Cuáles son **DL**? ¿Qué característica arquitectónica comparten todos?
- **Q7.4** El escenario (h) es discutible. Argumentá si un termostato de un solo umbral debería contar como AI.

---

## Paso 8 — Mapear los conceptos a la infraestructura de GPU en Kubernetes (cluster opcional)

En producción, las cargas de trabajo de deep learning corren en clusters, y Kubernetes necesita una forma de exponer las GPU como recursos programables. El NVIDIA GPU Operator automatiza los componentes necesarios: el driver, NVIDIA Container Toolkit, el device plugin de Kubernetes, GPU Feature Discovery y el monitoreo basado en DCGM. Una vez que corre, los nodos anuncian el extended resource `nvidia.com/gpu`.

1. Comprobá qué nodos exponen GPU:

   ```bash
   kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
   ```

   Salida de ejemplo:

   ```
   NAME          GPUS
   cpu-node-01   <none>
   gpu-node-01   8
   gpu-node-02   8
   ```

2. Inspeccioná los componentes del GPU Operator. El namespace puede ser distinto en tu instalación:

   ```bash
   kubectl get pods -n gpu-operator
   ```

   Salida de ejemplo, abreviada:

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

3. Creá `gpu-smoke-test.yaml`:

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

4. Aplicalo y leé los logs:

   ```bash
   kubectl apply -f gpu-smoke-test.yaml
   kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke-test --timeout=120s
   kubectl logs gpu-smoke-test
   ```

   Salida esperada:

   ```
   pod/gpu-smoke-test created
   pod/gpu-smoke-test condition met
   GPU 0: NVIDIA A100-SXM4-80GB (UUID: GPU-3f1c9a2e-8d4b-4c71-b0e2-5a6d9e1f7c30)
   ```

5. Limpiá:

   ```bash
   kubectl delete pod gpu-smoke-test
   ```

**Preguntas de comprensión — Paso 8**

- **Q8.1** No pedirías `nvidia.com/gpu` para el filtro basado en reglas del Paso 2. ¿Lo pedirías para el modelo de ML clásico del Paso 3? ¿Para el job de entrenamiento de la CNN? ¿Para un servicio de inferencia de LLM en producción? Justificá cada caso.
- **Q8.2** ¿Por qué `nvidia.com/gpu` se define bajo `limits`, y qué le pasa al Pod si ningún nodo tiene una GPU libre?
- **Q8.3** ¿Qué componente del GPU Operator hace que `nvidia.com/gpu` aparezca en los recursos allocatable del nodo, y qué componente usarías para enviar métricas de utilización de GPU a Prometheus?

---

## Tabla resumen para guardar para el examen

| Dimensión | AI (campo amplio) | Machine Learning | Deep Learning |
|---|---|---|---|
| Relación | Término paraguas | Subconjunto de AI | Subconjunto de ML |
| Cómo se obtiene el comportamiento | Reglas, búsqueda, lógica o aprendizaje | Aprendido a partir de datos | Aprendido a partir de datos con redes neuronales de múltiples capas |
| Feature engineering | No aplica en sistemas basados en reglas | Generalmente manual | Aprendido automáticamente (representation learning) |
| Volumen de datos típico | Nulo a pequeño | Pequeño a mediano | Grande a masivo |
| Cómputo típico | CPU | Mayormente CPU, a veces GPU | GPU/aceleradores, a menudo multinodo |
| Explicabilidad | Alta | Media | Menor; requiere herramientas específicas |
| Ejemplos | Sistemas expertos, motores de reglas, AI de juegos basada en búsqueda | Regresión lineal/logística, árboles de decisión, random forests, SVM, gradient boosting | CNNs, RNNs, transformers, LLMs, modelos de difusión |

---

## Respuestas

<details>
<summary>Hacé clic para ver las respuestas</summary>

### Paso 1

- **A1.1** `scikit-learn` sirve al **machine learning clásico**: modelos lineales, árboles, SVMs y clustering. `torch` sirve al **deep learning**: redes neuronales, autograd y tensores en GPU. Ninguna de las dos bibliotecas es necesaria para la AI basada en reglas del Paso 2, que usa Python puro.
- **A1.2** La GPU es un requisito de **rendimiento**, no funcional. Las redes neuronales son matemática y corren en cualquier procesador. Las GPU hacen que la aritmética matricial masivamente paralela del deep learning sea lo bastante rápida como para ser práctica a escala.

### Paso 2

- **A2.1** Es **AI**, en el sentido clásico y simbólico: automatiza un juicio que de otro modo haría una persona. **No es ML**, porque no se aprende nada a partir de datos. Cada regla, peso y umbral fue escrito por una persona, y el comportamiento nunca cambia salvo que alguien edite el código.
- **A2.2** Los sistemas basados en reglas escalan mal. Cada variante nueva (errores de ortografía, otros idiomas, nuevos patrones de estafa) necesita una nueva regla escrita a mano, y las reglas empiezan a interactuar y entrar en conflicto. El costo de mantenimiento crece con el espacio del problema. Esta limitación motivó el machine learning.
- **A2.3** Cualquiera de estas: es totalmente **explicable**, ya que podés ver exactamente qué reglas se activaron; es **determinista**; no necesita **datos de entrenamiento**; y tiene un costo de cómputo despreciable, sin necesidad de GPU.

### Paso 3

- **A3.1** En `rules_ai.py` una persona escribió tanto las features (los predicados) como los pesos de decisión y el umbral. En `classic_ml.py` una persona eligió las features (sumas de filas y columnas en [A], o píxeles crudos en [B]) y la familia de modelos. **Los pesos y biases se aprendieron a partir de datos etiquetados** mediante optimización.
- **A3.2** La calidad de un modelo de ML clásico está limitada por las features que le da una persona. Las sumas de filas y columnas descartan información espacial. Por ejemplo, el 6 y el 9 pueden tener perfiles de tinta similares. Un mal diseño de features pone un techo a la accuracy, sea cual sea el algoritmo.
- **A3.3** La regresión logística para 10 clases aprende un peso por feature por clase (64 × 10 = 640) más un bias por clase (10), lo que da 650 parámetros. Es "shallow" porque mapea entradas a salidas con una **única transformación lineal**, sin capas ocultas apiladas que construyan representaciones intermedias.
- **A3.4** No de forma significativa. La carga de trabajo es mínima: 1.347 muestras de entrenamiento y 650 parámetros. El overhead de lanzamiento de kernels y de transferencia de datos a la GPU superaría cualquier aceleración. Las GPU rinden cuando la aritmética es grande y altamente paralela.

### Paso 4

- **A4.1** Las **capas convolucionales (`self.features`)**. Sus filtros de 3×3 se aprenden durante el entrenamiento y se convierten en detectores de trazos, bordes y curvas. La segunda convolución los combina en patrones de más alto nivel. Esto es representation learning, el sello distintivo del deep learning.
- **A4.2** El cómputo (FLOPs por token o imagen), la memoria (pesos, activaciones, gradientes y estado del optimizador) y los requisitos de datos crecen en muchos órdenes de magnitud. Los modelos de miles de millones de parámetros necesitan memoria de GPU muy por encima de un solo dispositivo, entrenamiento multi-GPU o multinodo con interconexiones de alto ancho de banda, almacenamiento rápido para mantener alimentadas las GPU y stacks de inferencia optimizados. Por eso existe la infraestructura de AI de NVIDIA.
- **A4.3** El forward pass (`model(xb)` y la loss), el **backward pass** (`loss.backward()`, que calcula los gradientes) y la **actualización de pesos** (`opt.step()`). El backward pass y la actualización de pesos existen solo durante el entrenamiento. La inferencia ejecuta solo el forward pass.
- **A4.4** Sí a ambas. Pensá en tres círculos anidados: **AI ⊃ ML ⊃ DL**. Todo modelo de deep learning es un modelo de machine learning, y todo modelo de machine learning es una técnica de AI. Lo inverso no es cierto.

### Paso 5

- **A5.1** Los lanzamientos de kernels de CUDA son **asíncronos**: la llamada de Python retorna apenas el trabajo queda encolado. Sin `synchronize()` el timer mediría solo el tiempo de encolado, lo que reporta TFLOPS imposiblemente altos.
- **A5.2** Los **Tensor Cores** son unidades especializadas de multiply-accumulate de matrices que ejecutan precisión reducida y mixta (FP16, BF16, FP8, INT8) mucho más rápido que los CUDA cores FP32 de propósito general. El deep learning está dominado por matemática de matrices densas y tolera bien la precisión reducida. Un sistema basado en reglas hace comparaciones de strings y bifurcaciones, que no ganan nada con hardware de matrices.
- **A5.3** El deep learning alcanza su precisión ejecutando cantidades enormes de aritmética idéntica y paralela sobre grandes datasets, y las GPU hacen ese tipo de trabajo órdenes de magnitud más rápido y con más eficiencia que las CPU, mientras que la AI basada en reglas y la mayor parte del ML clásico nunca necesitaron cómputo a esa escala.

### Paso 6

- **A6.1** Desactiva autograd: no se registra ningún grafo de cómputo y no se guardan activaciones intermedias para un backward pass. También omite el seguimiento de contadores de versión. Sin activaciones ni gradientes almacenados, el uso de memoria y el overhead bajan en comparación con el entrenamiento.
- **A6.2** A un chatbot interactivo le importa sobre todo la **latencia**, es decir, el tiempo hasta el primer token y la latencia por token para cada usuario. Al scoring por lotes nocturno le importa sobre todo el **throughput**: ítems totales por segundo y costo por ítem. Las plataformas de inferencia ajustan el tamaño de batch, la precisión y la concurrencia para equilibrar ambos.
- **A6.3** TensorRT apunta al **deep learning**: redes neuronales entrenadas, normalmente importadas desde ONNX o mediante integraciones con frameworks. Aplica fusión de capas y tensores, calibración de precisión (FP16, INT8, FP8) y auto-tuning de kernels para la GPU de destino. El código basado en reglas no tiene un grafo de red que optimizar, y los modelos de ML clásico normalmente se sirven con otras herramientas.
- **A6.4** Tenés que **reconstruir los engines** para la nueva arquitectura de GPU y la nueva versión de TensorRT, y volver a validarlos. El CI/CD de inferencia debería tratar la construcción de engines como un artefacto por plataforma y no como un archivo portable.

### Paso 7

| # | Etiqueta | Justificación |
|---|---|---|
| a | Solo AI (basada en reglas) | Firmas escritas a mano; nada se aprende |
| b | ML, no DL | El random forest aprende de los datos; features elegidas por una persona; no es una red neuronal |
| c | DL | Los LLMs son redes neuronales transformer con miles de millones de parámetros |
| d | Solo AI | Búsqueda más una evaluación ajustada a mano; AI clásica simbólica o de búsqueda |
| e | DL | Los modelos de voz basados en transformers son redes neuronales profundas |
| f | ML, no DL | La regresión lineal se aprende de los datos, pero es un modelo shallow |
| g | DL | Detección de objetos basada en CNN |
| h | Caso límite; como mucho, solo AI | Una única regla fija; ver A7.4 |

- **A7.1** a, d y, discutiblemente, h.
- **A7.2** b, f.
- **A7.3** c, e, g. Todos usan **redes neuronales artificiales de múltiples capas** que aprenden representaciones jerárquicas directamente a partir de datos crudos (texto, audio o píxeles).
- **A7.4** A favor de "no es AI": un único umbral es un sistema de control sin razonamiento, representación del conocimiento, búsqueda ni aprendizaje. Llamarlo AI estira el término hasta vaciarlo de significado. A favor de "es AI": bajo la definición más amplia, cualquier agente de toma de decisiones automatizada califica. Para el examen, la postura segura es que es **como mucho AI basada en reglas**, y definitivamente **no es ML ni DL**.

### Paso 8

- **A8.1** ML clásico (Paso 3): normalmente **no**. Entrena en milisegundos en CPU, y una GPU quedaría ociosa desperdiciando un recurso escaso. Las bibliotecas aceleradas por GPU, como RAPIDS cuML, pueden ayudar con datasets tabulares muy grandes. Entrenamiento de la CNN: **sí**, una vez que crecen los datos y el tamaño del modelo, ya que una GPU acelera el forward y el backward pass. Inferencia de LLM en producción: **sí, prácticamente siempre**. Solo los pesos del modelo pueden necesitar de decenas a cientos de GB de memoria de GPU, y los objetivos de latencia requieren el throughput de GPU, a menudo repartido entre varias GPU.
- **A8.2** Los extended resources como `nvidia.com/gpu` deben especificarse en `limits`. Si se define `requests`, debe ser igual a `limits`, y por defecto las GPU no se pueden sobreasignar ni pedir de forma fraccionaria a través de este recurso; MIG o time-slicing son configuraciones aparte. Si ningún nodo tiene una GPU libre, el Pod queda en **`Pending`** con un evento `FailedScheduling` que informa `Insufficient nvidia.com/gpu`.
- **A8.3** El **NVIDIA Kubernetes device plugin** (`nvidia-device-plugin-daemonset`) registra `nvidia.com/gpu` en el kubelet. Las métricas de GPU para Prometheus vienen de **DCGM Exporter** (`nvidia-dcgm-exporter`).

</details>

---

## Referencias oficiales

- NVIDIA, *NCA-AIIO Exam Study Guide*: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, *AI Infrastructure and Operations Fundamentals*: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA, *AI Inference*: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA Technical Blog, *Tips on Scaling Storage for AI Training and Inferencing*: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- NVIDIA Blog, *What Are Large Language Models Used For?*: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA Technical Blog, *NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes*: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes