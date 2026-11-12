# Tema 1.8 — Comparar y contrastar las arquitecturas de GPU y CPU

**Certificación:** NVIDIA-Certified Associate: AI Infrastructure and Operations (NCA-AIIO)
**Peso en el examen:** 4.75%
**Dominio:** Essential AI Knowledge

---

## 1. Motivación: el problema arquitectónico en producción

Todo equipo de plataforma de IA se topa tarde o temprano con el mismo incidente. Un job de entrenamiento cae en un nodo con ocho GPUs, cada una de las cuales cuesta decenas de miles de dólares. `nvidia-smi` muestra una utilización de GPU que oscila entre 0% y 35%. Mientras tanto, `top` muestra 32 workers de DataLoader de Python saturando todos los núcleos de CPU. Las GPUs están hambrientas. La CPU, el componente al que nadie le asignó atención en el presupuesto, se convirtió en el cuello de botella de un clúster de varios millones de dólares.

También pasa lo contrario. Un equipo "ahorra plata" sirviendo un LLM de 7B parámetros en un servidor con CPU de 128 núcleos, y la latencia por token es diez veces peor que el SLO. El modelo nunca estuvo limitado por cómputo en la CPU. Estaba **limitado por el ancho de banda de memoria**, y DDR5 tiene una fracción del ancho de banda de HBM.

Ambas fallas vienen de no entender un hecho de diseño: **las CPUs y las GPUs están optimizadas para cosas opuestas.**

| Objetivo de diseño | CPU | GPU |
|---|---|---|
| Optimización principal | **Latencia** de un solo hilo | **Throughput** de muchos hilos |
| Estrategia para ocultar la latencia de memoria | Cachés grandes, prefetchers, ejecución fuera de orden, predicción de saltos | Multithreading masivo: cambiar a otro warp listo |
| En qué se gasta el presupuesto de transistores | Lógica de control y caché | Unidades aritméticas (ALUs, Tensor Cores) |
| Carga de trabajo ideal | Código con muchas ramas, serial, irregular, de SO/plano de control | Regular, paralelo en datos, denso en aritmética (matemática de matrices) |

NVIDIA presenta el data center de IA moderno como **tres procesadores trabajando juntos**: la **CPU** (control de propósito general y trabajo serial), la **GPU** (cómputo paralelo acelerado) y la **DPU** (BlueField, que descarga la infraestructura de red, almacenamiento y seguridad). Un operador de infraestructura de IA tiene que saber qué pilar se encarga de cada parte de la carga de trabajo, y cómo mantener alimentado al caro, la GPU.

---

## 2. Arquitectura de CPU: construida para la latencia

### 2.1 Mecánica interna

Un núcleo de CPU de servidor moderno, como Intel Xeon (Sapphire/Emerald/Granite Rapids), AMD EPYC (Genoa/Turin) o NVIDIA Grace (Arm Neoverse V2), es una máquina muy compleja cuyo trabajo es terminar **un único flujo de instrucciones lo más rápido posible**:

- **Pipeline fuera de orden (OoO) profundo y ancho.** El núcleo busca y decodifica varias instrucciones por ciclo, renombra registros y ejecuta las instrucciones apenas sus operandos están listos, no en el orden del programa. Un reorder buffer con cientos de entradas mantiene el estado especulativo.
- **Predicción de saltos.** Predictores sofisticados adivinan el resultado de las sentencias `if` y de los bucles para que el pipeline nunca se detenga. Una predicción errónea vacía el pipeline, lo que cuesta aproximadamente 15–20 ciclos.
- **Cachés grandes multinivel.** L1 por núcleo (~32–64 KB) y L2 (1–2 MB), más una L3/LLC compartida de decenas a cientos de MB. Las cachés existen para que la memoria *parezca* rápida para un hilo.
- **Unidades vectoriales SIMD.** AVX-512 / AMX en x86, SVE2 en Arm. Dan paralelismo de datos *dentro* de un núcleo, típicamente 16 lanes FP32 por instrucción. Intel AMX agrega pequeñas unidades de matrices en tiles, lo que ayuda a la inferencia en CPU pero sigue estando muy por debajo del throughput de los Tensor Cores de GPU.
- **SMT (Hyper-Threading).** 2 hilos de hardware por núcleo, así que hay poca capacidad de ocultar la latencia cambiando de hilo.
- **Subsistema de memoria.** DDR5 con 8–12 canales por socket. El ancho de banda agregado está en los cientos de GB/s por socket, con **gran capacidad** (TBs por nodo).
- **NUMA.** En servidores multisocket, cada socket es dueño de su memoria local y de sus lanes PCIe. Cruzar entre sockets (UPI / Infinity Fabric) agrega latencia y consume ancho de banda entre sockets.

### 2.2 Qué hace la CPU en una plataforma de IA

La CPU no es obsoleta en la infraestructura de IA. Es esencial para:

- Correr el SO, kubelet, el container runtime, los drivers y el CUDA runtime que **lanza kernels en la GPU**.
- **Ingesta y preprocesamiento de datos**: decodificación JPEG, tokenización, augmentation, shuffling, lectura desde almacenamiento. Esto salvo que se descargue a la GPU (NVIDIA DALI) o a una DPU.
- Orquestar el entrenamiento distribuido: el bucle de control en Python, el bootstrapping de NCCL, la serialización de checkpoints.
- Manejo de requests de inferencia: parseo HTTP/gRPC, lógica de batching, pre/post-procesamiento en Triton Inference Server.
- ML clásico y modelos chicos, donde domina el overhead de lanzamiento.

---

## 3. Arquitectura de GPU: construida para el throughput

### 3.1 El Streaming Multiprocessor (SM)

Una GPU NVIDIA es un arreglo de **Streaming Multiprocessors (SMs)**. Tomando como referencia la Hopper H100 SXM5 (según la documentación de arquitectura Hopper de NVIDIA):

| Componente | H100 SXM5 (aprox.) |
|---|---|
| SMs | 132 |
| CUDA cores FP32 por SM | 128 → 16,896 en total |
| Tensor Cores | 4 por SM (4ª gen) → 528 en total |
| Register file por SM | 256 KB |
| L1 / shared memory por SM | 256 KB (división configurable) |
| Caché L2 | 50 MB |
| Máximo de hilos residentes por SM | 2,048 (64 warps) |
| Memoria | 80 GB HBM3, ~3.35 TB/s |
| NVLink (4ª gen) | 900 GB/s bidireccional por GPU |
| TDP | hasta 700 W |

Compará el register file: **256 KB por SM** contra unos pocos KB de registros arquitectónicos por núcleo de CPU. La GPU mantiene residente en el chip el estado de miles de hilos a la vez. Esa es la clave de su estrategia para ocultar la latencia.

### 3.2 SIMT, warps y ocultamiento de latencia

- Los hilos se agrupan en **warps de 32 hilos** que ejecutan la misma instrucción sobre datos distintos. NVIDIA llama a esto **SIMT** (Single Instruction, Multiple Threads).
- Los hilos se organizan como **grid → thread blocks → warps → threads**. Un block se planifica en un SM y comparte la shared memory de ese SM.
- Cuando un warp emite una carga a HBM (cientos de ciclos de latencia), el **warp scheduler simplemente cambia a otro warp listo** en un solo ciclo. La GPU no intenta hacer que la memoria sea rápida. Mantiene tanto trabajo en vuelo que la latencia deja de importar. Esto se llama **occupancy**.
- **Penalidad por divergencia.** Si los hilos de un warp toman ramas distintas, los caminos se serializan. El código con muchas ramas desperdicia lanes de GPU, mientras que la CPU lo maneja con predicción de saltos.

### 3.3 Tensor Cores y precisión reducida

Los CUDA cores realizan operaciones FMA escalares. Los **Tensor Cores** realizan una multiplicación-acumulación de matrices pequeña completa (`D = A×B + C`) por instrucción. El deep learning está dominado por GEMMs (General Matrix Multiplies) y convoluciones, así que los Tensor Cores entregan la mayor parte del throughput de IA.

Cada generación agrega formatos de menor precisión. Menor precisión da más operaciones por ciclo y por byte movido:

| Formato | Introducido en Tensor Cores | Uso típico |
|---|---|---|
| FP64 | Ampere (A100) | Simulación HPC |
| TF32 | Ampere | Entrenamiento tipo FP32 sin cambios de código |
| FP16 / BF16 | Volta / Ampere | Entrenamiento de precisión mixta, inferencia |
| INT8 | Turing | Inferencia cuantizada |
| FP8 (E4M3/E5M2) | Hopper (Transformer Engine) | Entrenamiento e inferencia de LLMs |
| FP4 / FP6 | Blackwell (Transformer Engine de 2ª gen) | Inferencia de LLMs de baja precisión |

El **Transformer Engine** (Hopper en adelante) elige dinámicamente precisión FP8 o de 16 bits por capa para preservar la exactitud. **TensorRT** / **TensorRT-LLM** compilan modelos en engines optimizados que explotan estas precisiones, fusionan kernels y maximizan la utilización de los Tensor Cores para inferencia.

### 3.4 High-Bandwidth Memory (HBM)

HBM apila dies de DRAM verticalmente junto al die de la GPU sobre un interposer de silicio, lo que da un bus muy ancho:

| Memoria | Ancho de banda típico por dispositivo/socket | Capacidad por dispositivo/socket |
|---|---|---|
| DDR5 (socket de CPU de servidor, 8–12 canales) | ~300–600 GB/s | 512 GB – varios TB |
| LPDDR5X (CPU Grace) | hasta ~500 GB/s | hasta 480 GB |
| HBM3 (H100 SXM) | ~3.35 TB/s | 80 GB |
| HBM3e (H200) | ~4.8 TB/s | 141 GB |
| HBM3e (B200) | ~8 TB/s | 192 GB |

**Trade-off:** HBM da aproximadamente 10× el ancho de banda, pero mucha menos capacidad por dispositivo y un costo por GB mucho más alto. Por eso los modelos grandes necesitan múltiples GPUs (paralelismo tensor/pipeline), y por eso se usa la memoria de la CPU para offload (estados del optimizer, desborde del KV-cache).

### 3.5 Interconexiones: scale-up vs. scale-out

| Enlace | Ancho de banda (aprox.) | Rol |
|---|---|---|
| PCIe Gen5 x16 | ~64 GB/s por dirección | CPU↔GPU, GPU↔NIC (camino del host) |
| NVLink 4 (Hopper) | 900 GB/s por GPU | GPU↔GPU dentro de un nodo / dominio NVLink |
| NVLink 5 (Blackwell) | 1.8 TB/s por GPU | GPU↔GPU, dominio NVL72 a escala de rack |
| NVLink-C2C (Grace Hopper / Grace Blackwell) | 900 GB/s | CPU↔GPU coherente |
| InfiniBand NDR / Spectrum-X Ethernet | 400 Gb/s por puerto | Nodo↔nodo (scale-out), GPUDirect RDMA |

**NVSwitch** arma un fabric NVLink all-to-all no bloqueante, de modo que cada GPU de un nodo HGX/DGX habla con todas las demás a velocidad NVLink completa. **GPUDirect RDMA** permite que una NIC lea y escriba la memoria de la GPU directamente, salteando la memoria de la CPU. **GPUDirect Storage** hace lo mismo para el tráfico de NVMe y almacenamiento. Ambos sacan a la CPU del camino de datos. Esta es una forma concreta en que la arquitectura compensa que la CPU sea el pilar más lento.

---

## 4. Comparación cara a cara

### 4.1 Trade-offs arquitectónicos

| Dimensión | CPU | GPU | Consecuencia operativa |
|---|---|---|---|
| Cantidad de núcleos | Decenas a ~200 núcleos complejos | Miles de lanes simples + cientos de Tensor Cores | La GPU gana solo si el trabajo se puede dividir en miles de piezas independientes |
| Rendimiento por hilo | Muy alto (boost de 4+ GHz, OoO) | Bajo (~1.5–2 GHz, en orden por warp) | El código serial en una GPU es más lento que en una CPU |
| Lógica de control | Porción dominante del área del die | Mínima | Las GPUs son malas para código con muchas ramas o irregular |
| Ocultamiento de latencia | Cachés + especulación | Paralelismo a nivel de hilo (cambio de warp) | Las GPUs necesitan batch sizes grandes para ser eficientes |
| Ancho de banda de memoria | Cientos de GB/s | Varios TB/s | Las cargas de IA limitadas por memoria (decode de LLM) escalan con HBM |
| Capacidad de memoria | TBs | 80–192 GB por GPU | Los modelos grandes se fragmentan entre GPUs |
| Soporte de precisión | FP64/FP32 fuerte; BF16/INT8 vía AMX/VNNI | De FP64 hasta FP4 con Tensor Cores | La cuantización multiplica el throughput de la GPU |
| Modelo de programación | Hilos estándar, cualquier lenguaje | Kernels CUDA, librerías (cuBLAS, cuDNN, NCCL, TensorRT) | Las GPUs dependen del stack de software y de la matriz de versiones driver/CUDA |
| Potencia por dispositivo | ~250–500 W por socket | 300–1,000+ W por GPU | La densidad de potencia por rack y la refrigeración líquida se vuelven restricciones de diseño |
| Perf/Watt en matemática de IA | Bajo | Muy alto | Los clústeres de GPU cuestan más de entrada pero menos por corrida de entrenamiento |
| Virtualización/compartición | Madura (cgroups, VMs) | MIG, time-slicing, MPS, vGPU | Compartir GPUs requiere configuración explícita |

### 4.2 CPU vs. GPU vs. DPU

| | CPU | GPU | DPU (BlueField) |
|---|---|---|---|
| Propósito | Cómputo de propósito general, plano de control | Cómputo paralelo acelerado | Offload de infraestructura del data center |
| Rol en IA | Orquestación, preprocesamiento, lógica de serving | Entrenamiento, matemática de inferencia | Red (RDMA, OVS), almacenamiento (NVMe-oF), seguridad (aislamiento, cripto) |
| Libera a | — | La CPU de la matemática | La CPU de las tareas de infraestructura |

### 4.3 Guía de ubicación de cargas de trabajo

| Carga de trabajo | Mejor opción | Por qué |
|---|---|---|
| Entrenar un transformer | GPU (multinodo, NVLink + InfiniBand) | GEMMs densas en aritmética, comunicación colectiva |
| Inferencia de LLM, fase de decode | GPU con alto ancho de banda HBM | Limitada por memoria: cada token lee todos los pesos |
| Inferencia de LLM, fase de prefill | Tensor Cores de GPU | GEMMs limitadas por cómputo sobre todo el prompt |
| Tokenización, parseo de JSON, ruteo de requests | CPU | Serial, con muchas ramas, intensiva en strings |
| Decode/augment de imágenes a alto throughput | CPU, o GPU vía DALI | CPU por defecto; descargar a GPU cuando la CPU es el límite |
| Gradient-boosted trees, datos tabulares chicos | CPU (o GPU vía RAPIDS cuML/XGBoost a gran escala) | Los datos chicos no amortizan el overhead de la GPU |
| ETL sobre terabytes de datos tabulares | GPU vía RAPIDS / Spark RAPIDS | Las operaciones columnares se paralelizan bien |
| Plano de control de Kubernetes, bases de datos | CPU | No hay matemática paralela en datos |

---

## 5. Razonamiento cuantitativo: limitado por cómputo vs. limitado por memoria

El **modelo roofline** decide qué propiedad de la arquitectura importa. **Intensidad aritmética** = FLOPs realizados / bytes movidos desde memoria.

```
ridge point = peak FLOP/s / memory bandwidth (B/s)

H100 SXM, dense BF16 Tensor Core:  ~989 TFLOP/s / 3.35 TB/s  ≈ 295 FLOP/byte
```

- Intensidad aritmética **por debajo** del ridge point → **limitado por memoria**. El rendimiento escala con el ancho de banda.
- Intensidad aritmética **por encima** del ridge point → **limitado por cómputo**. El rendimiento escala con los FLOPs.

**Ejemplo resuelto: decode de LLM con batch size 1.** Un modelo de 7B parámetros en BF16 ocupa ~14 GB. Generar un token lee esencialmente cada peso una vez, a ~2 FLOPs por parámetro, lo que da ~1 FLOP/byte. Eso está profundamente limitado por memoria.

```
Upper bound tokens/s ≈ memory bandwidth / model bytes

H100 (3.35 TB/s):       3,350 GB/s / 14 GB ≈ 239 tokens/s
CPU socket (~300 GB/s):   300 GB/s / 14 GB ≈  21 tokens/s
```

La diferencia de un orden de magnitud viene del **ancho de banda de memoria, no de la cantidad de núcleos**. Hacer batching de muchos requests sube la intensidad aritmética, porque los pesos se leen una vez por batch. Por eso los servidores de inferencia (Triton, TensorRT-LLM, NIM) usan in-flight/continuous batching para acercarse al régimen limitado por cómputo.

**La Ley de Amdahl se aplica a todo el pipeline.** Si el 10% de cada paso de entrenamiento es trabajo serial de CPU (carga de datos, overhead de Python), el speedup máximo con GPUs infinitamente rápidas es 10×. Acelerar solo la parte de GPU termina chocando contra la pared de la CPU. Ese es exactamente el incidente descripto en la Sección 1.

---

## 6. Arquitecturas híbridas: cerrando la brecha CPU–GPU

- **Topología PCIe discreta (x86 clásico + GPU).** La CPU y la GPU tienen memorias separadas. Los datos se copian por PCIe (~64 GB/s por dirección en Gen5), que es mucho más lento que HBM. La memoria del host pinned (page-locked) y las copias asíncronas (`cudaMemcpyAsync`, CUDA streams) superponen transferencia y cómputo.
- **Sistemas HGX/DGX.** 8 GPUs en una baseboard NVSwitch, CPUs x86 duales y una relación 1:1 de GPU a NIC para GPUDirect RDMA. La afinidad CPU-GPU sigue la topología PCIe: las GPUs 0–3 cuelgan del socket 0 y las GPUs 4–7 del socket 1.
- **Grace Hopper (GH200) / Grace Blackwell (GB200).** Una CPU Arm NVIDIA Grace (72 núcleos Neoverse V2, LPDDR5X) conectada a la GPU por **NVLink-C2C a 900 GB/s**, con memoria unificada coherente en caché. La GPU puede acceder a la memoria de la CPU a aproximadamente 7× el ancho de banda de PCIe Gen5. Esto convierte a la gran memoria de la CPU en una extensión práctica para KV caches, embeddings y modelos grandes. El GB200 NVL72 une 36 CPUs Grace y 72 GPUs Blackwell en un único dominio NVLink.

---

## 7. Kubernetes: exponer correctamente ambas arquitecturas

En Kubernetes, las CPUs son un recurso nativo: las manejan los cgroups, los requests y limits de `cpu`, y el CPU Manager. Las GPUs son un **extended resource** (`nvidia.com/gpu`) anunciado por el **NVIDIA device plugin**. El **NVIDIA GPU Operator** automatiza todo el stack de software de GPU como componentes de Kubernetes: driver, NVIDIA Container Toolkit, device plugin, GPU Feature Discovery (GFD), DCGM exporter, MIG manager y validator.

### 7.1 Instalar el GPU Operator

```
$ helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
"nvidia" has been added to your repositories
...Successfully got an update from the "nvidia" chart repository

$ helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace --wait
NAME: gpu-operator
NAMESPACE: gpu-operator
STATUS: deployed
REVISION: 1

$ kubectl get pods -n gpu-operator
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-7xk2p                                   1/1     Running     0          4m
gpu-operator-6d8b4c9f7-q9lwz                                  1/1     Running     0          5m
gpu-operator-node-feature-discovery-gc-5b7f9c8d6-hv2mn        1/1     Running     0          5m
gpu-operator-node-feature-discovery-master-7c9d8f5b4-x2kfp    1/1     Running     0          5m
gpu-operator-node-feature-discovery-worker-j8m4t              1/1     Running     0          5m
nvidia-container-toolkit-daemonset-4mzrw                      1/1     Running     0          4m
nvidia-cuda-validator-p7v2c                                   0/1     Completed   0          2m
nvidia-dcgm-exporter-vt9qk                                    1/1     Running     0          4m
nvidia-device-plugin-daemonset-lw7sx                          1/1     Running     0          4m
nvidia-driver-daemonset-8rn5d                                 1/1     Running     0          5m
nvidia-operator-validator-kq4jd                               1/1     Running     0          4m
```

Verificá cómo el nodo ahora anuncia **ambas** arquitecturas:

```
$ kubectl describe node gpu-node-01 | sed -n '/Capacity:/,/Allocatable:/p'
Capacity:
  cpu:                224
  ephemeral-storage:  1843069856Ki
  hugepages-1Gi:      0
  hugepages-2Mi:      0
  memory:             2113362764Ki
  nvidia.com/gpu:     8
  pods:               110
Allocatable:

$ kubectl get node gpu-node-01 -o json | jq '.metadata.labels | with_entries(select(.key | startswith("nvidia.com/gpu")))'
{
  "nvidia.com/gpu.compute.major": "9",
  "nvidia.com/gpu.compute.minor": "0",
  "nvidia.com/gpu.count": "8",
  "nvidia.com/gpu.family": "hopper",
  "nvidia.com/gpu.machine": "DGXH100",
  "nvidia.com/gpu.memory": "81559",
  "nvidia.com/gpu.present": "true",
  "nvidia.com/gpu.product": "NVIDIA-H100-80GB-HBM3",
  "nvidia.com/gpu.replicas": "1"
}
```

### 7.2 Kubelet: alineación de CPU y GPU consciente de NUMA

Por defecto, un pod que pide 1 GPU y 16 CPUs puede recibir una GPU en el socket 1 y CPUs en el socket 0. Entonces cada copia host-a-dispositivo cruza el enlace entre sockets. El **Topology Manager** alinea los hints del CPU Manager, del Memory Manager y del device plugin al mismo nodo NUMA.

`/var/lib/kubelet/config.yaml` (campos relevantes, completo y válido):

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  full-pcpus-only: "true"
cpuManagerReconcilePeriod: 10s
memoryManagerPolicy: Static
topologyManagerPolicy: best-effort
topologyManagerScope: pod
reservedSystemCPUs: "0,1,112,113"
kubeReserved:
  memory: 1Gi
systemReserved:
  memory: 1Gi
evictionHard:
  memory.available: 100Mi
reservedMemory:
  - numaNode: 0
    limits:
      memory: 2148Mi
```

Notas:
- El CPU Manager `static` da **núcleos exclusivos** solo a pods con QoS Guaranteed y requests de CPU enteros.
- `full-pcpus-only` asigna núcleos físicos completos (ambos hermanos SMT). Esto evita efectos de vecino ruidoso en los hilos de carga de datos.
- Con `memoryManagerPolicy: Static`, la suma de `reservedMemory` tiene que ser igual a la memoria de `kubeReserved` + `systemReserved` + `evictionHard` (1024 + 1024 + 100 = 2148 Mi).
- Trade-off de `topologyManagerPolicy`: `single-numa-node` da la alineación más estricta pero **rechaza los pods que no entran en un único nodo NUMA**. En un DGX H100, las GPUs 0–3 están en NUMA 0 y las GPUs 4–7 en NUMA 1. Con `single-numa-node`, un pod de 8 GPUs falla la admisión con `TopologyAffinityError`. Usá `best-effort` o `restricted` en los nodos que corren jobs de entrenamiento de nodo completo. Reservá `single-numa-node` para nodos dedicados a pods de inferencia de ≤4 GPUs.

Cambiar `cpuManagerPolicy` requiere drenar el nodo, borrar `/var/lib/kubelet/cpu_manager_state` y reiniciar kubelet. Hacé lo mismo con `memory_manager_state` cuando cambies la política del memory manager.

### 7.3 Un Job de benchmark CPU vs. GPU

Este Job corre la misma GEMM en la CPU y en la GPU. Hace que la diferencia de throughput sea medible en tu propio hardware.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: arch-lab
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gemm-bench
  namespace: arch-lab
data:
  bench.py: |
    import os
    import time
    import torch

    def bench(device, n, dtype, iters):
        a = torch.randn(n, n, device=device, dtype=dtype)
        b = torch.randn(n, n, device=device, dtype=dtype)
        torch.matmul(a, b)
        if device == "cuda":
            torch.cuda.synchronize()
        t0 = time.perf_counter()
        for _ in range(iters):
            torch.matmul(a, b)
        if device == "cuda":
            torch.cuda.synchronize()
        dt = (time.perf_counter() - t0) / iters
        tflops = 2 * n ** 3 / dt / 1e12
        print(f"{device:5s} {str(dtype):15s} n={n} {dt * 1000:9.2f} ms/iter {tflops:9.2f} TFLOP/s", flush=True)

    torch.set_num_threads(int(os.environ.get("CPU_THREADS", "16")))
    print(f"torch {torch.__version__}, CPU threads: {torch.get_num_threads()}", flush=True)
    print(f"GPU: {torch.cuda.get_device_name(0)}", flush=True)

    bench("cpu", 8192, torch.float32, 3)
    bench("cpu", 8192, torch.bfloat16, 3)

    torch.backends.cuda.matmul.allow_tf32 = False
    bench("cuda", 8192, torch.float32, 50)
    torch.backends.cuda.matmul.allow_tf32 = True
    bench("cuda", 8192, torch.float32, 50)
    bench("cuda", 8192, torch.bfloat16, 50)
    bench("cuda", 8192, torch.float16, 50)
---
apiVersion: batch/v1
kind: Job
metadata:
  name: gemm-cpu-vs-gpu
  namespace: arch-lab
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: gemm-bench
    spec:
      restartPolicy: Never
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: nvidia.com/gpu.family
                    operator: In
                    values:
                      - hopper
                      - blackwell
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      containers:
        - name: bench
          image: nvcr.io/nvidia/pytorch:24.08-py3
          command:
            - python
            - /bench/bench.py
          env:
            - name: CPU_THREADS
              value: "16"
            - name: OMP_NUM_THREADS
              value: "16"
          resources:
            requests:
              cpu: "16"
              memory: 64Gi
              nvidia.com/gpu: 1
            limits:
              cpu: "16"
              memory: 64Gi
              nvidia.com/gpu: 1
          volumeMounts:
            - name: bench
              mountPath: /bench
              readOnly: true
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: bench
          configMap:
            name: gemm-bench
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 8Gi
```

Puntos clave de diseño:
- `requests == limits` con CPU entera → **QoS Guaranteed** → núcleos exclusivos y alineados a NUMA bajo el CPU Manager static.
- `nvidia.com/gpu` está definido en `limits`. Los extended resources no se pueden sobrecomprometer, y un request, si se especifica, tiene que ser igual al limit.
- `/dev/shm` como `emptyDir` respaldado en memoria. Los workers del DataLoader de PyTorch intercambian tensores a través de memoria compartida, y el default de 64 MB del contenedor provoca caídas con `Bus error`.

```
$ kubectl apply -f gemm-bench.yaml
namespace/arch-lab created
configmap/gemm-bench created
job.batch/gemm-cpu-vs-gpu created

$ kubectl -n arch-lab wait --for=condition=complete job/gemm-cpu-vs-gpu --timeout=15m
job.batch/gemm-cpu-vs-gpu condition met

$ kubectl -n arch-lab logs job/gemm-cpu-vs-gpu
torch 2.5.0a0+872d972e41.nv24.08, CPU threads: 16
GPU: NVIDIA H100 80GB HBM3
cpu   torch.float32   n=8192    812.44 ms/iter      1.35 TFLOP/s
cpu   torch.bfloat16  n=8192    402.17 ms/iter      2.73 TFLOP/s
cuda  torch.float32   n=8192     22.91 ms/iter     48.00 TFLOP/s
cuda  torch.float32   n=8192      3.12 ms/iter    352.40 TFLOP/s
cuda  torch.bfloat16  n=8192      1.64 ms/iter    670.42 TFLOP/s
cuda  torch.float16   n=8192      1.61 ms/iter    682.91 TFLOP/s
```

Los números son ilustrativos. Tu hardware, tus clocks y tus versiones de librerías van a diferir. Las **proporciones** son la lección:
- FP32 en CUDA cores es ~35× la CPU de 16 núcleos.
- Habilitar TF32 rutea el mismo código FP32 a los Tensor Cores por otro ~7×.
- Los Tensor Cores en BF16 llegan a ~500× la línea base de CPU en FP32.
- La mayor parte de la ventaja de la GPU en matemática de IA viene de los **Tensor Cores más la precisión reducida**, no solo de "más núcleos".

### 7.4 Compartir GPUs: un concepto sin equivalente en CPU

Las CPUs se comparten con granularidad fina mediante el scheduler del kernel y los cgroups. Las GPUs necesitan mecanismos explícitos:

| Mecanismo | Aislamiento | Granularidad | Caso de uso |
|---|---|---|---|
| GPU completa | Total | 1 GPU | Entrenamiento, inferencia grande |
| MIG (A100/H100/H200/B200) | Hardware: SMs dedicados, slices de L2, partición de HBM | Hasta 7 instancias | Inferencia multi-tenant con garantías de QoS |
| Time-slicing | Ninguno (memoria compartida, cambio de contexto) | N réplicas | Dev/test, cargas en ráfagas o de baja utilización |
| MPS | Parcial (kernels concurrentes, aislamiento de fallas limitado) | Porcentaje de SMs | Muchos procesos de inferencia chicos y cooperativos |
| vGPU | A nivel de hipervisor | Perfiles | Virtualización basada en VMs |

Configuración de time-slicing para el device plugin del GPU Operator:

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

```
$ kubectl apply -f time-slicing-config.yaml
configmap/time-slicing-config created

$ kubectl patch clusterpolicies.nvidia.com/cluster-policy -n gpu-operator --type merge \
    -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'
clusterpolicy.nvidia.com/cluster-policy patched

$ kubectl get node gpu-node-01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}{.metadata.labels.nvidia\.com/gpu\.replicas}{"\n"}'
32
4
```

MIG con la estrategia single, usando el label del MIG manager:

```
$ kubectl label node gpu-node-01 nvidia.com/mig.config=all-1g.10gb --overwrite
node/gpu-node-01 labeled

$ kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}{"\n"}'
success
```

---

## 8. CLI a nivel de host: leer la arquitectura

### 8.1 Lado CPU

```
$ lscpu | grep -E 'Model name|Socket|Core\(s\)|Thread|NUMA|L3|Flags' | cut -c1-120
Model name:                      Intel(R) Xeon(R) Platinum 8480C
Thread(s) per core:              2
Core(s) per socket:              56
Socket(s):                       2
L3 cache:                        210 MiB (2 instances)
NUMA node(s):                    2
NUMA node0 CPU(s):               0-55,112-167
NUMA node1 CPU(s):               56-111,168-223
Flags:                           fpu vme de pse ... avx512f avx512_bf16 amx_bf16 amx_tile amx_int8 ...

$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 ... 55 112 113 ... 167
node 0 size: 1031629 MB
node 0 free: 987412 MB
node 1 cpus: 56 57 ... 111 168 ... 223
node 1 size: 1032142 MB
node 1 free: 990236 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10
```

Una distancia de 21 vs. 10 significa que el acceso a memoria remota cuesta alrededor de 2.1× el local. Esa penalidad es la razón por la que importa la alineación NUMA.

### 8.2 Lado GPU

```
$ nvidia-smi --query-gpu=index,name,memory.total,clocks.max.sm,power.limit,pcie.link.gen.max,pcie.link.width.max --format=csv
index, name, memory.total [MiB], clocks.max.sm [MHz], power.limit [W], pcie.link.gen.max, pcie.link.width.max
0, NVIDIA H100 80GB HBM3, 81559 MiB, 1980 MHz, 700.00 W, 5, 16
1, NVIDIA H100 80GB HBM3, 81559 MiB, 1980 MHz, 700.00 W, 5, 16
...
7, NVIDIA H100 80GB HBM3, 81559 MiB, 1980 MHz, 700.00 W, 5, 16
```

`deviceQuery` de los CUDA samples muestra la estructura de SM/warp:

```
$ ./deviceQuery | grep -E 'Device 0|Multiprocessors|Warp size|threads per multiprocessor|threads per block|Memory Bus|L2 Cache'
Device 0: "NVIDIA H100 80GB HBM3"
  (132) Multiprocessors, (128) CUDA Cores/MP:    16896 CUDA Cores
  Memory Bus Width:                              5120-bit
  L2 Cache Size:                                 52428800 bytes
  Maximum number of threads per multiprocessor:  2048
  Maximum number of threads per block:           1024
  Warp size:                                     32
```

Compará el bus HBM de **5120 bits** con un canal DDR5 de 64 bits. El ancho del bus es de donde sale el ancho de banda.

### 8.3 Topología: el mapa CPU–GPU–NIC

```
$ nvidia-smi topo -m
        GPU0  GPU1  GPU2  GPU3  GPU4  GPU5  GPU6  GPU7  NIC0  NIC1  CPU Affinity     NUMA Affinity  GPU NUMA ID
GPU0     X    NV18  NV18  NV18  NV18  NV18  NV18  NV18  PIX   SYS   0-55,112-167     0              N/A
GPU1    NV18   X    NV18  NV18  NV18  NV18  NV18  NV18  SYS   SYS   0-55,112-167     0              N/A
GPU2    NV18  NV18   X    NV18  NV18  NV18  NV18  NV18  SYS   SYS   0-55,112-167     0              N/A
GPU3    NV18  NV18  NV18   X    NV18  NV18  NV18  NV18  SYS   SYS   0-55,112-167     0              N/A
GPU4    NV18  NV18  NV18  NV18   X    NV18  NV18  NV18  SYS   PIX   56-111,168-223   1              N/A
GPU5    NV18  NV18  NV18  NV18  NV18   X    NV18  NV18  SYS   SYS   56-111,168-223   1              N/A
GPU6    NV18  NV18  NV18  NV18  NV18  NV18   X    NV18  SYS   SYS   56-111,168-223   1              N/A
GPU7    NV18  NV18  NV18  NV18  NV18  NV18  NV18   X    SYS   SYS   56-111,168-223   1              N/A
NIC0    PIX   SYS   SYS   SYS   SYS   SYS   SYS   SYS    X    SYS
NIC1    SYS   SYS   SYS   SYS   PIX   SYS   SYS   SYS   SYS    X

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes (e.g., QPI/UPI)
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
```

Cómo leerlo:
- `NV18`: 18 enlaces NVLink 4 agrupados entre cada par de GPUs (vía NVSwitch), así que el tráfico GPU↔GPU nunca toca la CPU.
- `PIX` entre GPU y NIC: comparten un switch PCIe, que es el camino ideal para GPUDirect RDMA.
- `SYS`: el tráfico cruza los sockets de CPU, el camino más lento. NCCL lo evita cuando puede.
- `CPU Affinity` te dice a qué núcleos fijar el proceso que alimenta a una GPU.

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Síntoma: baja utilización de GPU, CPU alta (pipeline de entrada limitado por CPU)

```
$ nvidia-smi dmon -s u -c 5
# gpu    sm   mem   enc   dec   jpg   ofa
# Idx     %     %     %     %     %     %
    0    31    12     0     0     0     0
    0     0     0     0     0     0     0
    0    28    10     0     0     0     0
    0     0     0     0     0     0     0
    0    35    13     0     0     0     0

$ top -b -n1 -o %CPU | head -12
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
 418223 trainer   20   0   38.1g   9.2g   1.1g R  99.7   0.4  12:03.11 pt_data_worker
 418224 trainer   20   0   38.1g   9.1g   1.1g R  99.7   0.4  12:02.87 pt_data_worker
 ...
```

El patrón de diente de sierra (ocupada, ociosa, ocupada) significa que la GPU termina cada batch y después espera a la CPU.

**Soluciones, en orden de esfuerzo:**
1. Aumentá `num_workers`, y habilitá `pin_memory=True` y `prefetch_factor` en el DataLoader. Dale al pod suficientes CPUs Guaranteed y un `/dev/shm` grande.
2. Mové el decode/augmentation a la GPU (NVIDIA DALI, nvJPEG). Mové el ETL a la GPU (RAPIDS).
3. Preprocesá offline a formatos eficientes (WebDataset, TFRecord, Parquet) para que el bucle de entrenamiento solo lea.
4. Verificá el throughput del almacenamiento. Si la CPU está en `iowait`, el cuello de botella es la capa de almacenamiento, no la CPU. GPUDirect Storage elimina el bounce buffer de la CPU.

Regla práctica: planificá **varios núcleos de CPU por GPU** para entrenamiento de visión. Los sistemas de referencia de NVIDIA vienen con aproximadamente 14 núcleos físicos por GPU (112 núcleos / 8 GPUs en DGX H100).

### 9.2 Síntoma: transferencias host↔dispositivo lentas (PCIe degradado o desajuste NUMA)

```
$ nvidia-smi -q -i 3 -d PCI | grep -A3 -E 'Link Width|PCIe Generation'
        PCIe Generation
            Max                       : 5
            Current                   : 3
            Device Current            : 3
        Link Width
            Max                       : 16x
            Current                   : 8x
```

Un enlace Gen3 x8 bajo carga entrega alrededor de un cuarto del ancho de banda de Gen5 x16. Las GPUs ociosas bajan legítimamente a una generación PCIe menor para ahorrar energía, así que **verificalo bajo carga**. Una degradación persistente bajo carga apunta a un problema de reasiento, riser o firmware. Corroborá con `lspci -vv -s <bus_id> | grep LnkSta`, y escalalo como un problema de hardware.

Para problemas de NUMA, compará en qué CPUs corre realmente el proceso con la `CPU Affinity` de la GPU según `nvidia-smi topo -m`:

```
$ taskset -cp $(pgrep -f train.py | head -1)
pid 418201's current affinity list: 56-71
```

Si el proceso usa GPU0 (NUMA 0, CPUs 0–55), está en el socket equivocado. En Kubernetes, verificá que el CPU Manager y el Topology Manager estén activos:

```
$ sudo cat /var/lib/kubelet/cpu_manager_state | jq .
{
  "policyName": "static",
  "defaultCpuSet": "2-55,57-111,114-167,169-223",
  "entries": {
    "7f3c1e2a-...": {
      "bench": "0,1,56,112,113,168"
    }
  },
  "checksum": 1834201147
}
```

### 9.3 Síntoma: Pod rechazado con `TopologyAffinityError`

```
$ kubectl -n arch-lab get pods
NAME                    READY   STATUS                   RESTARTS   AGE
train-8gpu-6m2xk        0/1     TopologyAffinityError    0          8s

$ kubectl -n arch-lab describe pod train-8gpu-6m2xk | tail -3
  Warning  TopologyAffinityError  8s    kubelet  Resources cannot be allocated with Topology locality
```

La causa es `topologyManagerPolicy: single-numa-node` con un request que abarca ambos sockets: 8 GPUs, o más CPUs de las que tiene un nodo NUMA. O reducís el request, o planificás el pod en nodos que usen `best-effort`/`restricted`.

### 9.4 Síntoma: el throughput de la GPU cae con el tiempo (throttling térmico/de potencia)

```
$ nvidia-smi -q -i 0 -d PERFORMANCE
==============NVSMI LOG==============
Attached GPUs                             : 8
GPU 00000000:1B:00.0
    Performance State                     : P0
    Clocks Event Reasons
        Idle                              : Not Active
        Applications Clocks Setting       : Not Active
        SW Power Cap                      : Active
        HW Slowdown                       : Not Active
            HW Thermal Slowdown           : Not Active
            HW Power Brake Slowdown       : Not Active
        Sync Boost                        : Not Active
        SW Thermal Slowdown               : Not Active
        Display Clock Setting             : Not Active

$ nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory,power.draw,clocks.sm --format=csv
index, temperature.gpu, temperature.memory, power.draw [W], clocks.sm [MHz]
0, 71, 82, 699.14 W, 1650 MHz
```

`SW Power Cap: Active` a ~700 W es **normal** bajo una carga GEMM pesada: la GPU está usando todo su presupuesto de potencia. `HW Thermal Slowdown` o `HW Power Brake Slowdown` **no** es normal. Apunta a problemas de refrigeración, flujo de aire o PSU/potencia del rack. Los racks de GPU a menudo superan los 40 kW y con frecuencia requieren refrigeración líquida, lo cual es una diferencia a nivel de instalaciones respecto de los racks solo con CPU.

### 9.5 Síntoma: errores de GPU y dispositivos que desaparecen (eventos XID)

```
$ sudo dmesg -T | grep -i xid
[Wed Nov 12 09:41:07 2026] NVRM: Xid (PCI:0000:9a:00): 79, pid=418223, GPU has fallen off the bus.
```

| XID | Significado | Acción típica |
|---|---|---|
| 13 / 31 / 43 | Falla de aplicación (acceso ilegal, falla de MMU, kernel detenido) | Normalmente un bug de software: revisá el job |
| 48 | Error ECC de doble bit | Drená el nodo, reseteá la GPU, RMA si se repite |
| 63 / 64 | Evento / falla de row-remapping | Revisá `nvidia-smi -q -d ROW_REMAPPER`; reseteá para aplicar |
| 74 | Error de NVLink | Revisá `nvidia-smi nvlink -s`, reasentá, fabric manager |
| 79 | La GPU se cayó del bus | Hardware/PCIe/potencia: drená e investigá |
| 94 / 95 | Error ECC contenido / no contenido | 94: reiniciá la app afectada; 95: reseteá la GPU |

Corré diagnósticos activos con DCGM:

```
$ dcgmi diag -r 2
Successfully ran diagnostic for group.
+---------------------------+------------------------------------------------+
| Diagnostic                | Result                                         |
+===========================+================================================+
|-----  Metadata  ----------+------------------------------------------------|
| DCGM Version              | 3.3.7                                          |
| Driver Version Detected   | 550.90.07                                      |
| GPU Device IDs Detected   | 2330,2330,2330,2330,2330,2330,2330,2330        |
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

En Kubernetes, el **DCGM exporter** del GPU Operator publica estas señales como métricas de Prometheus, por ejemplo `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_DEV_XID_ERRORS` y `DCGM_FI_PROF_PCIE_RX_BYTES`. Una alerta que combina un `DCGM_FI_PROF_SM_ACTIVE` bajo con un uso alto de CPU del nodo detecta automáticamente el pipeline limitado por CPU de la Sección 9.1:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-starvation
  namespace: gpu-operator
spec:
  groups:
    - name: gpu-cpu-balance
      rules:
        - alert: GPUStarvedByCPU
          expr: |
            avg by (Hostname) (DCGM_FI_PROF_SM_ACTIVE) < 0.4
            and on (Hostname)
            label_replace(
              1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])),
              "Hostname", "$1", "instance", "([^:]+).*"
            ) > 0.9
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "GPUs on {{ $labels.Hostname }} are idle while CPUs are saturated"
            description: "SM activity below 40% with CPU above 90% for 15m. Likely a CPU-bound input pipeline: review DataLoader workers, consider DALI or GPU preprocessing."
```

El `label_replace` une el label `Hostname` de DCGM con el label `instance` de node-exporter. Adaptá la regex si tus valores de `instance` son FQDNs o IPs en lugar de nombres de nodo.

### 9.6 Checklist rápido de triage

| Verificación | Comando | Saludable |
|---|---|---|
| Driver y GPUs visibles | `nvidia-smi -L` | Todas las GPUs esperadas listadas |
| Kubernetes ve las GPUs | `kubectl get node -o jsonpath='{..allocatable.nvidia\.com/gpu}'` | Coincide con la cantidad física (o × réplicas) |
| Operator saludable | `kubectl get pods -n gpu-operator` | Todos Running/Completed |
| Topología | `nvidia-smi topo -m` | NV# entre GPUs, PIX/PXB hacia las NICs |
| PCIe bajo carga | `nvidia-smi -q -d PCI` | Gen5 x16 (o el máximo de la plataforma) |
| Clocks/throttling | `nvidia-smi -q -d PERFORMANCE` | Sin HW slowdown |
| Salud | `dcgmi diag -r 2` | Todo Pass |
| Pinning de CPU | `cat /var/lib/kubelet/cpu_manager_state` | `static`, entradas de pods presentes |
| Balance de alimentación | `nvidia-smi dmon -s u` + `top` | SM% alto y estable, CPU no saturada |

---

## 10. Resumen orientado al examen

- **CPU = optimizada para latencia**: pocos núcleos potentes, ejecución OoO, predicción de saltos, cachés grandes, memoria DDR de alta capacidad. Corre trabajo serial, con muchas ramas, de plano de control, de SO y de preprocesamiento.
- **GPU = optimizada para throughput**: miles de núcleos simples organizados en SMs, warps de 32 hilos (SIMT), latencia oculta mediante multithreading masivo, Tensor Cores para matemática de matrices, HBM para un ancho de banda muy alto. Corre entrenamiento e inferencia de IA paralelos y densos en aritmética.
- **Son complementarias**, no competidoras. La CPU orquesta y alimenta, y la GPU calcula. La **DPU** es el tercer pilar y descarga red, almacenamiento y seguridad.
- **Tensor Cores + precisión reducida** (TF32, BF16, FP8, FP4) dan la mayor parte del speedup de IA de la GPU. TensorRT y el Transformer Engine los explotan.
- **El decode de inferencia de LLM está limitado por el ancho de banda de memoria**, así que el ancho de banda HBM predice los tokens/s mejor que los FLOPS.
- **Las interconexiones importan**: PCIe para host↔dispositivo, NVLink/NVSwitch para GPU↔GPU, NVLink-C2C para CPU↔GPU coherente (Grace Hopper), InfiniBand/Ethernet con GPUDirect RDMA entre nodos.
- **En Kubernetes**, las CPUs son recursos nativos y las GPUs son extended resources (`nvidia.com/gpu`) gestionados por el GPU Operator. La alineación necesita CPU Manager + Topology Manager. Compartir necesita MIG, time-slicing o MPS.
- La **falla clásica de producción** es la GPU hambrienta por un pipeline de CPU/datos subdimensionado (Ley de Amdahl).

### Preguntas de práctica

1. *¿Por qué una GPU tolera mejor que una CPU una latencia de memoria alta?*
   Mantiene muchos warps residentes y cambia a un warp listo en un ciclo (paralelismo a nivel de hilo). Una CPU depende de cachés y especulación para un único hilo.
2. *Un clúster de serving de LLM muestra alta latencia por token con batch size 1, pero baja utilización de SM. ¿Qué propiedad de hardware lo limita?*
   El ancho de banda de memoria (HBM). El decode está limitado por memoria. El batching sube la intensidad aritmética.
3. *¿Qué carga de trabajo debería quedarse en la CPU: parseo de requests JSON, GEMM en FP8 o all-reduce de gradientes?*
   El parseo de requests JSON.
4. *¿Qué funcionalidad permite que una NIC escriba directamente en la memoria de la GPU, salteando la memoria del host?*
   GPUDirect RDMA.
5. *¿Qué mecanismo de compartición de GPU provee aislamiento por hardware de SMs y memoria?*
   MIG.

---

## Referencias

- NVIDIA AI Infrastructure and Operations (NCA-AIIO) exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- NVIDIA Hopper Architecture In-Depth: https://developer.nvidia.com/blog/nvidia-hopper-architecture-in-depth/
- CUDA C++ Programming Guide (hardware implementation, SIMT): https://docs.nvidia.com/cuda/cuda-c-programming-guide/
- NVIDIA GPU Operator documentation (time-slicing, MIG): https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/
- NVIDIA DCGM documentation: https://docs.nvidia.com/datacenter/dcgm/latest/
- NVIDIA XID errors reference: https://docs.nvidia.com/deploy/xid-errors/
- Kubernetes Topology Manager: https://kubernetes.io/docs/tasks/administer-cluster/topology-manager/
- Kubernetes CPU Management Policies: https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/
- Kubernetes Device Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/