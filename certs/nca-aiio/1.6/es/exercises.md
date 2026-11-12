# Ejercicios guiados — Tema 1.6: Explicar el propósito y los casos de uso de las distintas soluciones de NVIDIA

> **Peso en el examen:** 4.75% · **Certificación:** NCA-AIIO (AI Infrastructure and Operations)
>
> Estos ejercicios recorren el stack de NVIDIA desde el silicio hacia arriba: hardware e interconexiones, software de sistema, orquestación de clústeres, la cadena de herramientas de inferencia (TensorRT → Triton → NIM) y los frameworks específicos de dominio. Los bloques prácticos te muestran qué *hace* realmente cada producto. Los bloques de escenarios entrenan el razonamiento de "¿qué solución encaja con este problema?" que evalúa el examen.

---

## Requisitos previos del lab

| Track | Qué necesitás | Ejercicios |
|---|---|---|
| **A: Un solo host con GPU** | Linux, GPU NVIDIA (Turing o más nueva; Ampere/Hopper para MIG), driver de NVIDIA, Docker, NVIDIA Container Toolkit | 1, 2, 3, 4, 5, 6 |
| **B: Kubernetes** | Clúster con al menos un nodo worker con GPU, `kubectl`, `helm` ≥ 3 | 7, 8, 9 |
| **C: Sin GPU** | Papel y un navegador | 1, 10 (más todas las preguntas) |

Necesitás una **NGC API key** (https://ngc.nvidia.com → *Setup* → *Generate API Key*) para los Ejercicios 3–6.

**Regla de alineación de versiones.** Los contenedores de NGC publicados en el mismo mes (`YY.MM`) comparten las mismas versiones de CUDA, cuDNN y TensorRT. Los engines de TensorRT **no son portables** entre versiones de TensorRT ni entre arquitecturas de GPU, así que todos los contenedores de este lab deben usar el **mismo tag de release**:

```bash
# Pick the latest monthly release listed at https://catalog.ngc.nvidia.com/orgs/nvidia/containers/tritonserver
export RELEASE=24.12
export NGC_API_KEY=<your-key>
```

---

## Ejercicio 1: Ubicar el stack de NVIDIA en sus capas (papel)

### Pasos

1. Dibujá cinco capas horizontales en papel, de abajo hacia arriba:
   1. **Hardware e interconexión**
   2. **Software de sistema y librerías**
   3. **Gestión de infraestructura y orquestación**
   4. **Plataformas de desarrollo y despliegue de IA**
   5. **Frameworks de aplicación específicos de dominio**

2. Ubicá cada uno de los siguientes productos en **exactamente una** capa:

   `DGX H100/B200` · `HGX` · `Grace Hopper Superchip` · `BlueField-3 DPU` · `ConnectX-7` · `Quantum InfiniBand` · `Spectrum-X Ethernet` · `NVLink / NVSwitch` · `CUDA` · `cuDNN` · `NCCL` · `DCGM` · `GPUDirect Storage (Magnum IO)` · `DOCA` · `GPU Operator` · `Network Operator` · `Base Command Manager` · `Run:ai` · `Fleet Command` · `NGC` · `NVIDIA AI Enterprise` · `TensorRT` · `TensorRT-LLM` · `Triton Inference Server` · `NIM` · `NeMo` · `RAPIDS` · `TAO Toolkit` · `Riva` · `DeepStream / Metropolis` · `Morpheus` · `Clara` · `Merlin` · `Omniverse`

3. Dibujá una flecha desde **NVIDIA AI Enterprise** hacia cada producto que licencia y soporta. Dibujá otra desde **NGC** hacia cada producto que podés descargar desde ahí como contenedor, Helm chart o modelo.

### Preguntas

- **Q1.1** ¿Por qué DOCA está en una capa distinta de BlueField, si DOCA no sirve de nada sin un BlueField?
- **Q1.2** Tanto NGC como NVIDIA AI Enterprise "te dan software de NVIDIA". ¿Cuál es la diferencia operativa entre ellos?
- **Q1.3** TensorRT, Triton y NIM tienen que ver con inferencia. Escribí una oración para cada uno que explique el trabajo *distinto* que hace.
- **Q1.4** ¿Qué dos productos de la lista existen principalmente para que **Kubernetes** trate a las GPUs y a las NICs de alta velocidad como recursos de primera clase?

---

## Ejercicio 2: Mirar el hardware a través del driver (Track A)

### Pasos

1. Identificá las GPUs, el driver y la versión máxima de CUDA soportada:

   ```bash
   nvidia-smi
   ```

   Salida esperada (abreviada, los valores varían):

   ```
   +-----------------------------------------------------------------------------------------+
   | NVIDIA-SMI 560.35.03              Driver Version: 560.35.03      CUDA Version: 12.6     |
   |-----------------------------------------+------------------------+----------------------+
   | GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
   |   0  NVIDIA H100 80GB HBM3          On  |   00000000:18:00.0 Off |                    0 |
   ...
   ```

2. Inspeccioná la topología de interconexión entre GPUs y NICs:

   ```bash
   nvidia-smi topo -m
   ```

   Salida ilustrativa en un nodo HGX/DGX de 8 GPUs (truncada):

   ```
           GPU0    GPU1    GPU2    GPU3    NIC0    CPU Affinity    NUMA Affinity
   GPU0     X      NV18    NV18    NV18    PXB     0-55            0
   GPU1    NV18     X      NV18    NV18    PXB     0-55            0
   GPU2    NV18    NV18     X      NV18    SYS     0-55            0
   ...
   Legend:
     NV#  = Connection traversing a bonded set of # NVLinks
     PIX  = Connection traversing at most a single PCIe bridge
     PXB  = Connection traversing multiple PCIe bridges
     SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
   ```

3. Si tus GPUs tienen NVLink, revisá el estado y la velocidad de los enlaces:

   ```bash
   nvidia-smi nvlink -s
   ```

4. (Opcional, solo si el paquete de GPUDirect Storage está instalado) Verificá si la plataforma soporta GDS:

   ```bash
   /usr/local/cuda/gds/tools/gdscheck -p
   ```

   Buscá líneas como `NVMe : Supported` y `GDS release version`.

### Preguntas

- **Q2.1** El encabezado muestra `CUDA Version: 12.6`. ¿Significa que CUDA 12.6 está instalado en el host? ¿Qué te dice realmente?
- **Q2.2** En la matriz de topología, GPU0↔GPU1 es `NV18` y GPU2↔NIC0 es `SYS`. ¿Qué par va a lograr mayor ancho de banda de all-reduce, y por qué le importa a NCCL?
- **Q2.3** En un DGX H100, el tráfico GPU a GPU *dentro* de un nodo va por NVLink/NVSwitch. ¿Qué transporta el tráfico GPU a GPU *entre* nodos en un DGX SuperPOD, y qué familias de productos de NVIDIA lo componen?
- **Q2.4** ¿Qué problema resuelve GPUDirect Storage, y qué parte del camino de datos clásico elimina?

---

## Ejercicio 3: Consumir el stack desde NGC (Track A)

### Pasos

1. Iniciá sesión en el registry de NGC. El nombre de usuario es literalmente `$oauthtoken`:

   ```bash
   echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
   ```

   Esperado: `Login Succeeded`

2. Iniciá el contenedor PyTorch de NGC e imprimí las versiones de las librerías CUDA-X que incluye:

   ```bash
   docker run --rm --gpus all nvcr.io/nvidia/pytorch:${RELEASE}-py3 \
     python -c "import torch; print('torch', torch.__version__); print('cuda', torch.version.cuda); print('cudnn', torch.backends.cudnn.version()); print('nccl', torch.cuda.nccl.version()); print('gpu', torch.cuda.get_device_name(0))"
   ```

   Salida ilustrativa:

   ```
   torch 2.6.0a0+df5bbc09d1.nv24.12
   cuda 12.6
   cudnn 90501
   nccl (2, 23, 4)
   gpu NVIDIA H100 80GB HBM3
   ```

3. Compará el resultado con las release notes del mismo tag en la NGC Frameworks Support Matrix (https://docs.nvidia.com/deeplearning/frameworks/support-matrix/).

### Preguntas

- **Q3.1** El driver del host reportó CUDA 12.6 en el Ejercicio 2. El contenedor podría traer un CUDA toolkit distinto. ¿Qué componente dentro del contenedor habla con el driver del host, y quién inyecta las librerías del driver en el contenedor?
- **Q3.2** Dá tres razones por las que un equipo empresarial estandarizaría en contenedores de NGC en lugar de `pip install torch` sobre bare metal.
- **Q3.3** ¿Para qué se usa NCCL, y en qué topología de entrenamiento se vuelve crítico?

---

## Ejercicio 4: Optimizar un modelo con TensorRT (Track A)

### Pasos

1. Creá un directorio de trabajo y exportá un ResNet-50 a ONNX con una **dimensión de batch dinámica**. Los pesos aleatorios alcanzan, porque estás midiendo rendimiento, no precisión:

   ```bash
   mkdir -p ~/nvlab && cd ~/nvlab
   cat > export.py <<'EOF'
   import torch, torchvision
   model = torchvision.models.resnet50(weights=None).eval().cuda()
   dummy = torch.randn(1, 3, 224, 224, device="cuda")
   torch.onnx.export(
       model, dummy, "resnet50.onnx",
       input_names=["input"], output_names=["output"],
       dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
       opset_version=17,
   )
   print("exported resnet50.onnx")
   EOF
   docker run --rm --gpus all -v "$PWD":/work -w /work \
     nvcr.io/nvidia/pytorch:${RELEASE}-py3 python export.py
   ```

2. Construí un engine **FP32** y hacele benchmark con `trtexec`. Si `trtexec` no está en el `PATH`, usá `/usr/src/tensorrt/bin/trtexec`:

   ```bash
   docker run --rm --gpus all -v "$PWD":/work -w /work \
     nvcr.io/nvidia/tensorrt:${RELEASE}-py3 \
     trtexec --onnx=resnet50.onnx \
       --minShapes=input:1x3x224x224 --optShapes=input:8x3x224x224 --maxShapes=input:8x3x224x224 \
       --shapes=input:8x3x224x224 \
       --saveEngine=resnet50_fp32.plan
   ```

3. Construí un engine **FP16** con las mismas shapes:

   ```bash
   docker run --rm --gpus all -v "$PWD":/work -w /work \
     nvcr.io/nvidia/tensorrt:${RELEASE}-py3 \
     trtexec --onnx=resnet50.onnx \
       --minShapes=input:1x3x224x224 --optShapes=input:8x3x224x224 --maxShapes=input:8x3x224x224 \
       --shapes=input:8x3x224x224 \
       --fp16 --saveEngine=resnet50_fp16.plan
   ```

4. Anotá las líneas de resumen de cada corrida. Salida ilustrativa:

   ```
   [I] === Performance summary ===
   [I] Throughput: 1843.27 qps
   [I] Latency: min = 0.52 ms, max = 0.71 ms, mean = 0.54 ms, median = 0.54 ms, percentile(90%) = 0.55 ms, percentile(95%) = 0.56 ms, percentile(99%) = 0.60 ms
   ...
   &&&& PASSED TensorRT.trtexec [TensorRT v100700]
   ```

   Completá esta tabla. Acá el valor `qps` cuenta *batches* por segundo, así que multiplicalo por 8 para obtener imágenes/s.

   | Precisión | Throughput (qps) | Imágenes/s | Latencia mediana (ms) | Tamaño del engine (`ls -lh`) |
   |---|---|---|---|---|
   | FP32 | | | | |
   | FP16 | | | | |

### Preguntas

- **Q4.1** Enumerá al menos cuatro optimizaciones que TensorRT realiza mientras construye el engine.
- **Q4.2** ¿Por qué FP16 aceleró tanto las cosas en una GPU Volta o más nueva? ¿Qué unidad de hardware aprovecha?
- **Q4.3** Construís `resnet50_fp16.plan` en una H100 y lo copiás a un servidor con L4. ¿Qué pasa, y cuál es la práctica correcta?
- **Q4.4** INT8 o FP8 serían todavía más rápidos. ¿Qué paso extra necesita normalmente INT8 que FP16 no?
- **Q4.5** Para un large language model, ¿usarías TensorRT a secas o TensorRT-LLM? Nombrá dos funcionalidades específicas de LLM que justifiquen la diferencia.

---

## Ejercicio 5: Servir el engine con Triton Inference Server (Track A)

### Pasos

1. Armá un model repository. Triton exige la estructura `<repo>/<model>/<version>/<file>`, y un engine de TensorRT tiene que llamarse `model.plan`:

   ```bash
   mkdir -p model_repository/resnet50/1
   cp resnet50_fp16.plan model_repository/resnet50/1/model.plan
   ```

2. Escribí la configuración del modelo. Este archivo está en formato de texto protobuf, no YAML:

   ```bash
   cat > model_repository/resnet50/config.pbtxt <<'EOF'
   name: "resnet50"
   platform: "tensorrt_plan"
   max_batch_size: 8
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
       count: 1
       kind: KIND_GPU
     }
   ]
   EOF
   ```

3. Iniciá Triton. El puerto 8000 sirve HTTP/REST, el 8001 sirve gRPC y el 8002 sirve métricas de Prometheus:

   ```bash
   docker run -d --name triton --gpus all \
     -p 8000:8000 -p 8001:8001 -p 8002:8002 \
     -v "$PWD/model_repository":/models \
     nvcr.io/nvidia/tritonserver:${RELEASE}-py3 \
     tritonserver --model-repository=/models
   docker logs -f triton   # wait for: Started HTTPService at 0.0.0.0:8000
   ```

   En los logs, buscá la tabla de modelos:

   ```
   +----------+---------+--------+
   | Model    | Version | Status |
   +----------+---------+--------+
   | resnet50 | 1       | READY  |
   +----------+---------+--------+
   ```

4. Verificá la readiness y la metadata del modelo (protocolo KServe v2):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' localhost:8000/v2/health/ready
   curl -s localhost:8000/v2/models/resnet50
   ```

   Esperado: `200`, y después:

   ```json
   {"name":"resnet50","versions":["1"],"platform":"tensorrt_plan","inputs":[{"name":"input","datatype":"FP32","shape":[-1,3,224,224]}],"outputs":[{"name":"output","datatype":"FP32","shape":[-1,1000]}]}
   ```

5. Hacé una prueba de carga **sin** dynamic batching. Cada cliente envía batch size 1:

   ```bash
   docker run --rm --net=host nvcr.io/nvidia/tritonserver:${RELEASE}-py3-sdk \
     perf_analyzer -m resnet50 -b 1 --concurrency-range 1:16:4
   ```

   Salida ilustrativa:

   ```
   Concurrency: 1, throughput: 610.2 infer/sec, latency 1630 usec
   Concurrency: 5, throughput: 1190.4 infer/sec, latency 4190 usec
   Concurrency: 9, throughput: 1215.8 infer/sec, latency 7390 usec
   Concurrency: 13, throughput: 1221.0 infer/sec, latency 10640 usec
   ```

6. Habilitá dynamic batching. Agregá esto al final de `config.pbtxt`, después reiniciá Triton y repetí el paso 5:

   ```bash
   cat >> model_repository/resnet50/config.pbtxt <<'EOF'
   dynamic_batching {
     preferred_batch_size: [ 4, 8 ]
     max_queue_delay_microseconds: 100
   }
   EOF
   docker restart triton
   ```

7. Mirá las métricas del lado del servidor:

   ```bash
   curl -s localhost:8002/metrics | grep -E '^nv_inference_(request_success|exec_count|count)'
   ```

   Compará `nv_inference_count` (inferencias) con `nv_inference_exec_count` (ejecuciones en batch).

### Preguntas

- **Q5.1** En el paso 6, ¿cómo cambió el throughput con concurrencia ≥ 5, y cuánto costó en latencia? Explicá el mecanismo.
- **Q5.2** Después del paso 6, `nv_inference_count` es mucho mayor que `nv_inference_exec_count`. ¿Qué representa el cociente?
- **Q5.3** Acá Triton sirvió un engine de TensorRT. Nombrá otros cuatro backends que soporta, y explicá por qué importa un servidor multi-framework en una empresa.
- **Q5.4** ¿Por qué el lab insistió en que el contenedor de TensorRT y el de Triton usen el mismo `${RELEASE}`?
- **Q5.5** ¿Cómo usarías `instance_group` para subir la utilización de una GPU que queda en 40% bajo carga?
- **Q5.6** ¿Qué funcionalidad de Triton usarías para encadenar *preprocesamiento → modelo → postprocesamiento* en el servidor, sin idas y vueltas al cliente?

---

## Ejercicio 6: Desplegar un LLM en minutos con NVIDIA NIM (Track A, ≥ 24 GB de memoria de GPU)

### Pasos

1. Listá los perfiles optimizados que el NIM trae para **tu** GPU:

   ```bash
   docker run --rm --gpus all -e NGC_API_KEY \
     nvcr.io/nim/meta/llama-3.1-8b-instruct:latest list-model-profiles
   ```

   Salida ilustrativa (abreviada):

   ```
   SYSTEM INFO
   - Free GPUs:
     -  [2330:10de] (0) NVIDIA H100 80GB HBM3 (H100 80GB) [current utilization: 0%]
   MODEL PROFILES
   - Compatible with system and runnable:
     - 3bb4e8fe... (tensorrt_llm-h100-fp8-tp1-throughput)
     - 8835c31... (tensorrt_llm-h100-bf16-tp1-latency)
     - 193649a... (vllm-bf16-tp1)
   ```

2. Ejecutá el NIM con una caché de modelos persistente:

   ```bash
   export LOCAL_NIM_CACHE=~/.cache/nim
   mkdir -p "$LOCAL_NIM_CACHE"
   docker run -d --name nim-llm --gpus all --shm-size=16GB \
     -e NGC_API_KEY \
     -v "$LOCAL_NIM_CACHE:/opt/nim/.cache" \
     -u "$(id -u)" \
     -p 8000:8000 \
     nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
   docker logs -f nim-llm   # wait for: Uvicorn running on http://0.0.0.0:8000
   ```

   > Si Triton del Ejercicio 5 sigue corriendo, detenelo primero (`docker rm -f triton`), porque ambos usan el puerto 8000.

3. Consultalo con la API **compatible con OpenAI**:

   ```bash
   curl -s localhost:8000/v1/models
   curl -s localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model": "meta/llama-3.1-8b-instruct", "messages": [{"role": "user", "content": "In one sentence, what does NVLink do?"}], "max_tokens": 64}'
   ```

   Respuesta ilustrativa (truncada):

   ```
   {"id":"chat-1f2e...","object":"chat.completion","model":"meta/llama-3.1-8b-instruct","choices":[{"index":0,"message":{"role":"assistant","content":"NVLink is a high-bandwidth, low-latency interconnect that lets GPUs exchange data directly..."},"finish_reason":"stop"}],"usage":{"prompt_tokens":21,"completion_tokens":38,"total_tokens":59}}
   ```

4. Detené el contenedor y volvé a iniciarlo. Medí cuánto tarda en llegar a "ready" con la caché caliente:

   ```bash
   docker rm -f nim-llm
   time (docker run -d --name nim-llm --gpus all --shm-size=16GB -e NGC_API_KEY \
     -v "$LOCAL_NIM_CACHE:/opt/nim/.cache" -u "$(id -u)" -p 8000:8000 \
     nvcr.io/nim/meta/llama-3.1-8b-instruct:latest >/dev/null; \
     until curl -sf localhost:8000/v1/health/ready >/dev/null; do sleep 2; done)
   ```

### Preguntas

- **Q6.1** El NIM eligió un perfil `tensorrt_llm-h100-fp8-tp1-throughput` sin que vos construyeras nada. Relacioná esto con lo que hiciste a mano en los Ejercicios 4 y 5.
- **Q6.2** ¿Por qué le importa una API compatible con OpenAI al equipo de aplicaciones que la adopta?
- **Q6.3** ¿Qué significa `tp1` en el nombre del perfil, y qué necesitaría `tp2` del hardware?
- **Q6.4** ¿Bajo qué producto ofrece NVIDIA soporte de producción para NIM?
- **Q6.5** El blog sobre LLMs de las fuentes enumera casos de uso como generación de contenido, resumen, chatbots, generación de código y traducción. Un equipo quiere un chatbot fundamentado en sus documentos internos. ¿Qué framework de NVIDIA usarían para *personalizar* o *proteger* el modelo, y qué patrón evita reentrenar por completo?

---

## Ejercicio 7: Hacer que Kubernetes reconozca GPUs con el GPU Operator (Track B)

### Pasos

1. Instalá el GPU Operator desde el repositorio Helm de NGC:

   ```bash
   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
   helm install --wait --generate-name \
     -n gpu-operator --create-namespace \
     nvidia/gpu-operator
   ```

   > Si los nodos ya tienen un driver de NVIDIA instalado (por ejemplo, una imagen de nodo de una nube administrada), agregá `--set driver.enabled=false`.

2. Mirá cómo levantan los componentes:

   ```bash
   kubectl get pods -n gpu-operator
   ```

   Salida ilustrativa:

   ```
   NAME                                                READY   STATUS      RESTARTS   AGE
   gpu-feature-discovery-x7k2p                         1/1     Running     0          4m
   gpu-operator-6d8f9c7b5-jq2lm                        1/1     Running     0          5m
   gpu-operator-node-feature-discovery-master-...      1/1     Running     0          5m
   gpu-operator-node-feature-discovery-worker-...      1/1     Running     0          5m
   nvidia-container-toolkit-daemonset-4wq8n            1/1     Running     0          4m
   nvidia-cuda-validator-hn6tz                         0/1     Completed   0          3m
   nvidia-dcgm-exporter-t9r4c                          1/1     Running     0          4m
   nvidia-device-plugin-daemonset-k5vbd                1/1     Running     0          4m
   nvidia-driver-daemonset-zp8f2                       1/1     Running     0          5m
   nvidia-operator-validator-ld7xs                     1/1     Running     0          4m
   ```

3. Revisá lo que el nodo anuncia ahora:

   ```bash
   NODE=<your-gpu-node>
   kubectl get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   kubectl get node "$NODE" --show-labels | tr ',' '\n' | grep -E 'nvidia.com/(gpu.product|gpu.memory|cuda.driver.major|gpu.count)'
   ```

   Salida ilustrativa:

   ```
   1
   nvidia.com/cuda.driver.major=560
   nvidia.com/gpu.count=1
   nvidia.com/gpu.memory=81559
   nvidia.com/gpu.product=NVIDIA-H100-80GB-HBM3
   ```

4. Ejecutá una carga de trabajo con GPU. Guardá esto como `cuda-vectoradd.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: cuda-vectoradd
   spec:
     restartPolicy: OnFailure
     containers:
       - name: cuda-vectoradd
         image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04
         resources:
           limits:
             nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f cuda-vectoradd.yaml
   kubectl logs pod/cuda-vectoradd
   ```

   Esperado:

   ```
   [Vector addition of 50000 elements]
   Copy input data from the host memory to the CUDA device
   CUDA kernel launch with 196 blocks of 256 threads
   Copy output data from the CUDA device to the host memory
   Test PASSED
   Done
   ```

### Preguntas

- **Q7.1** Para cada uno de estos DaemonSets, indicá en una línea qué hace: driver, container-toolkit, device-plugin, gpu-feature-discovery, dcgm-exporter, operator-validator.
- **Q7.2** Sin el GPU Operator, ¿qué tendría que hacer manualmente un equipo de operaciones en cada nodo con GPU, y por qué eso no escala a 200 nodos?
- **Q7.3** ¿Cómo usarías la etiqueta `nvidia.com/gpu.product` en un Deployment, y por qué podrías necesitarla?
- **Q7.4** El GPU Operator se encarga de las GPUs. ¿Qué operator hermano se encarga de las NICs ConnectX, RDMA y SR-IOV para entrenamiento multinodo en Kubernetes?
- **Q7.5** El device plugin anuncia GPUs completas como un recurso entero. ¿Qué pasaría si pidieras `nvidia.com/gpu: 0.5`?

---

## Ejercicio 8: Observar GPUs con DCGM (Track B, Track A opcional)

### Pasos

1. Leé las métricas crudas de DCGM Exporter:

   ```bash
   kubectl -n gpu-operator port-forward svc/nvidia-dcgm-exporter 9400:9400 &
   curl -s localhost:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_UTIL|FB_USED|FB_FREE|GPU_TEMP|POWER_USAGE|XID_ERRORS)'
   ```

   Salida ilustrativa:

   ```
   DCGM_FI_DEV_GPU_TEMP{gpu="0",UUID="GPU-5a1c...",device="nvidia0",modelName="NVIDIA H100 80GB HBM3",Hostname="gpu-node-1"} 34
   DCGM_FI_DEV_POWER_USAGE{gpu="0",...} 71.2
   DCGM_FI_DEV_GPU_UTIL{gpu="0",...} 0
   DCGM_FI_DEV_FB_FREE{gpu="0",...} 81004
   DCGM_FI_DEV_FB_USED{gpu="0",...} 555
   DCGM_FI_DEV_XID_ERRORS{gpu="0",...} 0
   ```

2. Si usás el Prometheus Operator, creá reglas de alerta. Guardá esto como `gpu-alerts.yaml`:

   ```yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: gpu-alerts
     namespace: gpu-operator
   spec:
     groups:
       - name: gpu.rules
         rules:
           - alert: GPUHighTemperature
             expr: DCGM_FI_DEV_GPU_TEMP > 85
             for: 5m
             labels:
               severity: warning
             annotations:
               summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} is above 85C"
           - alert: GPUFramebufferNearlyFull
             expr: |
               DCGM_FI_DEV_FB_USED
               / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.95
             for: 10m
             labels:
               severity: warning
             annotations:
               summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} framebuffer above 95%"
           - alert: GPUXidError
             expr: DCGM_FI_DEV_XID_ERRORS > 0
             for: 0m
             labels:
               severity: critical
             annotations:
               summary: "XID error {{ $value }} on GPU {{ $labels.gpu }} ({{ $labels.Hostname }})"
   ```

   ```bash
   kubectl apply -f gpu-alerts.yaml
   ```

3. (Track A, con el paquete DCGM en el host) Ejecutá un diagnóstico de salud rápido:

   ```bash
   dcgmi discovery -l
   dcgmi diag -r 1
   ```

   Salida ilustrativa (abreviada):

   ```
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
   ...
   ```

### Preguntas

- **Q8.1** `DCGM_FI_DEV_GPU_UTIL` marca 100% pero el entrenamiento sigue lento. ¿Por qué la "utilización" puede engañar, y qué campos de profiling de DCGM dan una imagen más fiel?
- **Q8.2** ¿Qué es un error XID, y cuál es una primera respuesta operativa razonable ante un `DCGM_FI_DEV_XID_ERRORS` distinto de cero?
- **Q8.3** ¿Cuál es la diferencia entre `dcgmi diag -r 1` y `-r 3`, y cuándo correrías el más largo?
- **Q8.4** Tanto `nvidia-smi` como DCGM reportan el estado de la GPU. ¿Por qué un data center usa DCGM en lugar de hacer scraping de `nvidia-smi`?

---

## Ejercicio 9: Compartir GPUs con MIG y time-slicing (Track B; MIG necesita A100/A30/H100/H200/B200)

### Pasos

1. **Time-slicing.** Guardá esto como `time-slicing.yaml`:

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

   ```bash
   kubectl apply -f time-slicing.yaml
   kubectl patch clusterpolicies.nvidia.com/cluster-policy --type merge \
     -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config", "default": "any"}}}}'
   sleep 60
   kubectl get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```

   Esperado: el allocatable pasa de `1` a `4` por GPU física, y aparece la etiqueta `nvidia.com/gpu.replicas=4`.

2. Revertí el time-slicing antes de probar MIG:

   ```bash
   kubectl patch clusterpolicies.nvidia.com/cluster-policy --type json \
     -p '[{"op": "remove", "path": "/spec/devicePlugin/config"}]'
   ```

3. **MIG** (solo GPUs con soporte MIG). Listá los perfiles desde el host:

   ```bash
   nvidia-smi mig -lgip
   ```

   Salida ilustrativa para una H100 80GB (abreviada):

   ```
   | GPU instance profiles:                                                      |
   | GPU   Name             ID    Instances   Memory     P2P    SM    DEC   ENC  |
   |                              Free/Total   GiB              CE    JPEG  OFA  |
   |   0  MIG 1g.10gb       19     7/7        9.75       No     16     1     0   |
   |   0  MIG 2g.20gb       14     3/3        19.62      No     32     2     0   |
   |   0  MIG 3g.40gb        9     2/2        39.50      No     60     3     0   |
   |   0  MIG 7g.80gb        0     1/1        79.25      No     132    7     0   |
   ```

4. Dejá que el MIG Manager del GPU Operator reconfigure el nodo. Usá la estrategia `single` y `all-1g.10gb` en H100 80GB (usá `all-1g.5gb` en A100 40GB):

   ```bash
   helm upgrade $(helm list -n gpu-operator -q) nvidia/gpu-operator -n gpu-operator \
     --reuse-values --set mig.strategy=single
   kubectl label node "$NODE" nvidia.com/mig.config=all-1g.10gb --overwrite
   kubectl get node "$NODE" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}{"\n"}'
   kubectl get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
   ```

   Esperado: `success`, y después `7`.

5. Revertí:

   ```bash
   kubectl label node "$NODE" nvidia.com/mig.config=all-disabled --overwrite
   ```

### Preguntas

- **Q9.1** Ambos métodos convirtieron una GPU en varias unidades planificables. Comparalos en aislamiento de memoria, aislamiento de fallas y QoS.
- **Q9.2** ¿Qué enfoque elegirías para (a) un clúster de desarrollo donde los data scientists corren notebooks que pasan la mayor parte del tiempo ociosos, y (b) una plataforma de inferencia multi-tenant con SLAs de latencia?
- **Q9.3** ¿Qué agrega NVIDIA vGPU que ni MIG ni time-slicing proveen por sí solos?
- **Q9.4** Con `mig.strategy=mixed`, ¿qué nombres de recurso pediría un Pod en lugar de `nvidia.com/gpu`?
- **Q9.5** ¿Qué producto de NVIDIA agrega cuotas por equipo, scheduling fair-share y asignación fraccional de GPU *por encima de* Kubernetes para muchos equipos que comparten un clúster?

---

## Ejercicio 10: Asociar la solución con el escenario (estilo examen, papel)

### Pasos

1. Para cada escenario, escribí la solución **principal** de NVIDIA y una justificación de una línea. Puede intervenir más de un producto, pero nombrá el que *resuelve el problema planteado*.

| # | Escenario |
|---|---|
| S1 | El pipeline de ETL de un retailer en pandas/Spark tarda 6 horas en preparar features antes de cada corrida de entrenamiento. |
| S2 | Un banco quiere preentrenar y luego hacer fine-tuning de un LLM de dominio, agregarle guardrails y evaluarlo. |
| S3 | Un call center necesita ASR y TTS en tiempo real en varios idiomas, desplegados on premises. |
| S4 | Una ciudad quiere analizar 2.000 streams de cámaras para detectar incidentes de tránsito en el edge. |
| S5 | Una telco necesita detectar comportamiento anómalo de red y credenciales filtradas en tiempo real sobre petabytes de logs. |
| S6 | Una empresa de e-commerce quiere entrenamiento y serving de recomendadores acelerados por GPU con tablas de embeddings grandes. |
| S7 | El equipo de imágenes de un hospital necesita workflows de IA para imágenes médicas y modelos preentrenados. |
| S8 | Un fabricante quiere un digital twin físicamente preciso de una fábrica para simular robots. |
| S9 | Un equipo chico sin experiencia profunda en ML quiere hacer fine-tuning de un modelo de visión preentrenado para detección de defectos con poco código. |
| S10 | 500 tiendas minoristas tienen cada una un servidor chico con GPU; IT tiene que desplegar y actualizar apps de IA de forma remota y segura. |
| S11 | Un clúster nuevo de 32 nodos con GPU tiene que aprovisionarse (imágenes de OS, drivers, Slurm o Kubernetes, monitoreo) desde bare metal. |
| S12 | Los jobs de entrenamiento en 64 GPUs pasan el 30% de cada step esperando leer datos del share NFS; las CPUs están al tope copiando buffers. |
| S13 | Un proveedor cloud quiere descargar el procesamiento de red, almacenamiento y seguridad de las CPUs del host y aislar tenants a nivel de infraestructura. |
| S14 | Una empresa construye un fabric de IA basado en Ethernet y quiere un rendimiento similar al de InfiniBand para nubes de IA multi-tenant. |
| S15 | El preentrenamiento multinodo de un LLM requiere la latencia más baja, con reducciones in-network entre nodos. |
| S16 | Una empresa necesita un stack de software de IA soportado, con parches de seguridad y certificado, con SLA para producción. |
| S17 | Los desarrolladores quieren desplegar un modelo Llama con un endpoint compatible con OpenAI en minutos, optimizado para la GPU que tengan. |
| S18 | Varios equipos comparten un clúster de GPUs y se quejan de que algunos acaparan GPUs mientras otros hacen cola; la dirección quiere cuotas y fair share. |

2. Para S12, usá el blog sobre escalado de almacenamiento de las fuentes para escribir **tres** mitigaciones adicionales que no sean GPUDirect.

### Preguntas

- **Q10.1** ¿Cuáles de los 18 escenarios resolverías además con **NVIDIA AI Enterprise** como vehículo de licenciamiento/soporte, y por qué AI Enterprise rara vez es la respuesta *directa* a un escenario técnico?
- **Q10.2** S14 y S15 tratan sobre el fabric de red. Indicá el factor decisivo entre Spectrum-X y Quantum InfiniBand.
- **Q10.3** Para S2, ¿qué productos de inferencia usaría el banco una vez entrenado el modelo, y en qué orden los viste en este lab?

---

## Respuestas

<details>
<summary><strong>Ejercicio 1</strong></summary>

**Mapa de capas (referencia):**

| Capa | Productos |
|---|---|
| Hardware e interconexión | DGX H100/B200, HGX, Grace Hopper, BlueField-3 DPU, ConnectX-7, Quantum InfiniBand, Spectrum-X Ethernet, NVLink/NVSwitch |
| Software de sistema y librerías | CUDA, cuDNN, NCCL, DCGM, GPUDirect Storage (Magnum IO), DOCA |
| Gestión de infraestructura y orquestación | GPU Operator, Network Operator, Base Command Manager, Run:ai, Fleet Command |
| Plataformas de desarrollo y despliegue de IA | NGC, NVIDIA AI Enterprise, TensorRT, TensorRT-LLM, Triton, NIM, NeMo, RAPIDS, TAO |
| Frameworks de dominio | Riva, DeepStream/Metropolis, Morpheus, Clara, Merlin, Omniverse |

**Q1.1** BlueField es el hardware: una DPU con núcleos Arm, una NIC ConnectX y aceleradores. DOCA es el **SDK/runtime** que se usa para programar y ejecutar servicios sobre ella, del mismo modo que CUDA es la capa de software de la GPU. Están en capas distintas porque uno es silicio y el otro es el software que lo expone.

**Q1.2** **NGC** es el catálogo/registry (contenedores, modelos, Helm charts, SDKs). Gran parte se puede descargar gratis. **NVIDIA AI Enterprise** es la **suscripción comercial**. Agrega soporte empresarial, un stack de software validado/certificado, parches de seguridad (remediación de CVEs), ramas de soporte de largo plazo y estabilidad de API, y habilita el uso en producción de productos como NIM. Muchos componentes de AI Enterprise se *entregan a través de* NGC.

**Q1.3**
- **TensorRT** es el *compilador/optimizador y runtime* que convierte un modelo entrenado en un engine optimizado y específico para una GPU.
- **Triton** es el *servidor de inferencia* que aloja modelos de muchos frameworks detrás de HTTP/gRPC, con batching, concurrencia, ensembles y métricas.
- **NIM** es un *microservicio preempaquetado* que reúne un modelo específico, sus engines optimizados (TensorRT-LLM/vLLM/Triton) y una API estándar de la industria en un solo contenedor que podés poner a correr en minutos.

**Q1.4** **GPU Operator** (GPUs) y **Network Operator** (NICs ConnectX/BlueField, RDMA, SR-IOV, GPUDirect RDMA).
</details>

<details>
<summary><strong>Ejercicio 2</strong></summary>

**Q2.1** No. Es la **versión de CUDA más alta que soporta el driver instalado**. El CUDA toolkit/runtime puede no estar en el host y normalmente viene dentro del contenedor. El driver es retrocompatible con runtimes de CUDA más viejos, y existen paquetes de compatibilidad hacia adelante para algunas GPUs de data center.

**Q2.2** GPU0↔GPU1 sobre `NV18`, que son 18 enlaces NVLink agrupados que dan cientos de GB/s. `SYS` atraviesa PCIe *y* la interconexión entre sockets de CPU, que es mucho más lenta y agrega latencia. NCCL lee esta topología para armar anillos/árboles para las operaciones colectivas (all-reduce, all-gather). Los caminos malos se vuelven el cuello de botella de cada sincronización de gradientes.

**Q2.3** El **fabric de cómputo** de NICs ConnectX (una por GPU en DGX H100) conectadas mediante switches **NVIDIA Quantum InfiniBand** (o **Spectrum-X Ethernet** en diseños Ethernet). Usa **GPUDirect RDMA** para que las transferencias entre la NIC y la memoria de la GPU eviten la CPU. En los sistemas GB200 NVL72, NVLink Switch además extiende NVLink a lo largo de un rack.

**Q2.4** GDS crea un **camino DMA directo entre el almacenamiento (NVMe local o NVMe-oF/FS paralelo remoto) y la memoria de la GPU**. Elimina el **bounce buffer en la memoria de sistema de la CPU** y las copias de CPU asociadas. El resultado es mayor ancho de banda, menor latencia y menor carga de CPU. GDS es parte de la familia **Magnum IO**.
</details>

<details>
<summary><strong>Ejercicio 3</strong></summary>

**Q3.1** El runtime de CUDA/las librerías de modo usuario del contenedor llaman a `libcuda.so`, el componente de modo usuario del driver, que habla con el driver del kernel. El **NVIDIA Container Toolkit** (`nvidia-container-runtime` / CDI) monta las librerías del driver del host y los nodos de dispositivo dentro del contenedor al iniciarlo, disparado por `--gpus all`.

**Q3.2** Tres cualesquiera de las siguientes:
- Los contenedores de NGC están **probados y ajustados** en conjunto (framework + CUDA + cuDNN + NCCL + TensorRT).
- Se **actualizan mensualmente**, con release notes y una matriz de soporte publicadas.
- Dan **reproducibilidad** entre laptop, clúster y nube.
- Incluyen optimizaciones de rendimiento de NVIDIA que no siempre están upstream.
- Se escanean por seguridad, y algunos están cubiertos por el soporte de AI Enterprise.
- Evitan el "infierno de dependencias" de drivers/librerías en bare metal.

**Q3.3** NCCL (NVIDIA Collective Communications Library) implementa operaciones colectivas multi-GPU/multinodo conscientes de la topología (all-reduce, broadcast, all-gather, reduce-scatter) sobre NVLink, PCIe, InfiniBand y RoCE. Es crítica en el **entrenamiento distribuido con paralelismo de datos y de modelo** (DDP, FSDP, Megatron), donde los gradientes o shards se tienen que sincronizar en cada step.
</details>

<details>
<summary><strong>Ejercicio 4</strong></summary>

**Q4.1** Cuatro cualesquiera de las siguientes:
- **Fusión** de capas y tensores (por ejemplo conv+bias+ReLU).
- **Calibración/reducción de precisión** (FP16, BF16, INT8, FP8).
- **Auto-tuning de kernels**, que selecciona los kernels más rápidos para la GPU de destino.
- **Optimización/reutilización** dinámica de memoria de tensores.
- Eliminación de capas muertas.
- Ejecución **multi-stream**.
- Perfiles de optimización para shapes dinámicas.

**Q4.2** FP16 reduce a la mitad el tráfico de memoria y permite que la matemática matricial corra en **Tensor Cores**, que entregan muchas veces los FLOPS de los CUDA cores en FP32. Las redes convolucionales como ResNet están dominadas por operaciones GEMM/conv, así que el throughput típicamente sube 2× o más.

**Q4.3** Falla al deserializar, o es rechazado, porque los engines están atados a la **arquitectura/compute capability de la GPU y a la versión de TensorRT** (H100 es Hopper SM90 y L4 es Ada SM89). La práctica correcta es conservar el artefacto portable (ONNX) y **construir el engine en, o para, la GPU de destino**, idealmente como parte del pipeline de despliegue. Existen opciones de build con compatibilidad de hardware, pero sacrifican algo de rendimiento.

**Q4.4** **Calibración** con un dataset representativo para calcular los rangos de activación (cuantización post-entrenamiento), o entrenamiento con cuantización (quantization-aware training). Un ONNX explícitamente cuantizado con nodos Q/DQ es otro camino.

**Q4.5** **TensorRT-LLM.** Agrega funcionalidades específicas de LLM como:
- In-flight (continuous) batching
- Paged KV-cache
- Kernels de atención optimizados
- Paralelismo tensorial y de pipeline entre GPUs
- Cuantización de pesos FP8/INT4
- Speculative decoding

TensorRT a secas no maneja eficientemente los patrones de generación autorregresiva.
</details>

<details>
<summary><strong>Ejercicio 5</strong></summary>

**Q5.1** El throughput sube significativamente, a menudo cerca de 1.5–3× para este modelo, mientras que la latencia con la misma concurrencia sube apenas, aproximadamente hasta `max_queue_delay_microseconds` más la ejecución del batch más grande. El scheduler de Triton **retiene las solicitudes individuales en una cola corta y las fusiona en un batch más grande**. Los batches más grandes aprovechan el paralelismo de la GPU mucho mejor que muchas ejecuciones con batch 1.

**Q5.2** El **tamaño de batch promedio realmente ejecutado**, es decir, inferencias por ejecución en la GPU. Un cociente cercano a 1 significa que no está ocurriendo batching. Un cociente cercano a `max_batch_size` significa que es muy efectivo.

**Q5.3** Cuatro cualesquiera de los siguientes:
- PyTorch (LibTorch/TorchScript)
- ONNX Runtime
- TensorFlow
- OpenVINO
- Python backend
- vLLM
- TensorRT-LLM
- FIL (modelos de árboles: XGBoost/LightGBM)
- DALI

Un único servidor le da a la empresa **una sola superficie operativa**: las mismas APIs, métricas, escalado y proceso de despliegue, sin importar qué framework eligió cada equipo de data science.

**Q5.4** Triton carga el `.plan` con su **runtime de TensorRT incluido**. Un engine serializado con otra versión de TensorRT no se carga. Usar los mismos tags `YY.MM` de NGC garantiza que las versiones coincidan.

**Q5.5** Aumentá `instance_group { count: 2 (or more) kind: KIND_GPU }` para que varias copias del modelo se ejecuten **concurrentemente** en la misma GPU. Esto superpone ejecución y transferencia de datos y llena los SMs ociosos. Volvé a medir con `perf_analyzer`, porque más instancias también usan más memoria de GPU.

**Q5.6** **Ensemble models**, un DAG definido en `config.pbtxt`, o **Business Logic Scripting** en el Python backend para lógica condicional o bucles.
</details>

<details>
<summary><strong>Ejercicio 6</strong></summary>

**Q6.1** A mano exportaste a ONNX, construiste un engine de TensorRT para tu GPU y precisión específicas, escribiste una config de Triton y ajustaste el batching. Un NIM **trae engines precompilados y preajustados** para muchas combinaciones de GPU/precisión/paralelismo. Al iniciar detecta el hardware, elige el mejor perfil compatible y lo sirve a través de un runtime optimizado. Eso condensa esos días de trabajo en un solo `docker run`.

**Q6.2** Las aplicaciones escritas contra la API de OpenAI (SDKs, LangChain, LlamaIndex y otras) pueden pasarse a un NIM autoalojado cambiando solo la **base URL y el nombre del modelo**. Esto evita el lock-in y los cambios de código, y mantiene los datos on premises.

**Q6.3** **Paralelismo tensorial de grado 1**: el modelo corre en una sola GPU. `tp2` reparte los pesos de cada capa entre **2 GPUs**, lo que requiere suficientes GPUs en el nodo e idealmente **NVLink** entre ellas, porque el paralelismo tensorial intercambia activaciones en cada capa.

**Q6.4** **NVIDIA AI Enterprise.** El uso en producción de NIM está cubierto por una licencia de AI Enterprise. El acceso para desarrollo está disponible a través del NVIDIA Developer Program.

**Q6.5** **NeMo** (el framework NeMo para personalización/fine-tuning, como LoRA/PEFT; NeMo Guardrails para rails de seguridad y temáticos; NeMo Retriever para microservicios de embeddings y reranking). El patrón es **RAG (retrieval-augmented generation)**, que recupera fragmentos relevantes de documentos en el momento de la consulta y los agrega al prompt, así que no hace falta reentrenar.
</details>

<details>
<summary><strong>Ejercicio 7</strong></summary>

**Q7.1**
- **driver**: instala/compila el driver de kernel de NVIDIA en un contenedor en cada nodo.
- **container-toolkit**: configura containerd/CRI-O para que los contenedores puedan acceder a las GPUs.
- **device-plugin**: anuncia `nvidia.com/gpu` al kubelet y asigna dispositivos a los Pods.
- **gpu-feature-discovery**: etiqueta los nodos con modelo de GPU, memoria, cantidad, MIG y capacidades de CUDA.
- **dcgm-exporter**: expone telemetría de GPU en formato Prometheus.
- **operator-validator**: ejecuta cargas de validación (incluido el CUDA validator) para confirmar que el stack funciona antes de que se planifiquen cargas de trabajo.

**Q7.2** El equipo tendría que instalar y alinear versiones del driver, el container toolkit, la configuración del runtime, el device plugin, los agentes de monitoreo y la configuración de MIG en cada nodo, y rehacer todo en cada actualización de kernel o de OS. Con 200 nodos esto genera **configuration drift**, actualizaciones lentas y propensas a errores, y diferencias entre nodos. El Operator hace que todo el stack sea declarativo (una ClusterPolicy) y gestiona el ciclo de vida y las actualizaciones automáticamente.

**Q7.3** Usala en `nodeSelector` o `nodeAffinity`, por ejemplo `nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3`. Razones típicas: fijar una carga de trabajo al tipo de GPU para el que se construyó su engine de TensorRT, asegurar suficiente memoria para un modelo grande, o mandar jobs baratos a GPUs más viejas.

**Q7.4** El **NVIDIA Network Operator**.

**Q7.5** La solicitud es rechazada. Los extended resources tienen que ser enteros, así que las solicitudes fraccionarias son inválidas. Compartir requiere time-slicing, MIG, vGPU o una capa de scheduling como Run:ai.
</details>

<details>
<summary><strong>Ejercicio 8</strong></summary>

**Q8.1** `GPU_UTIL` es el porcentaje de tiempo en que **al menos un kernel** estaba corriendo. Un solo kernel chico lo mantiene en 100% mientras la mayoría de los SMs y Tensor Cores están ociosos. Mejores señales son los campos de profiling de DCGM: `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_SM_OCCUPANCY`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_PROF_DRAM_ACTIVE`, y `DCGM_FI_PROF_PCIE_RX/TX_BYTES` / `DCGM_FI_PROF_NVLINK_RX/TX_BYTES`, que ayudan a encontrar cuellos de botella de I/O y de comunicación.

**Q8.2** Un XID es un evento de error reportado por el driver de NVIDIA, como una falla de GPU, un problema de memoria/ECC, la GPU que se cae del bus o una falla provocada por la aplicación. Primera respuesta:
1. Identificar el código XID en el log del driver/kernel (`dmesg`) y buscarlo en el catálogo de XID de NVIDIA.
2. Hacer **cordon/drain** del nodo si el código indica un problema de hardware.
3. Ejecutar `dcgmi diag`.
4. Resetear la GPU o reiniciar.
5. Abrir un RMA si el error se repite.

**Q8.3** `-r 1` es un chequeo rápido de despliegue/software (segundos). `-r 2` agrega pruebas cortas de hardware. `-r 3` (y `-r 4`) ejecutan **pruebas de estrés más largas** de PCIe, memoria, SM y de potencia/estrés dirigidas, que duran minutos o más. Corré los niveles más largos en la aceptación del nodo (burn-in), después de reparaciones de hardware, o cuando sospechás de una GPU inestable. No los corras mientras haya jobs de producción en el nodo.

**Q8.4** DCGM está pensado para operar flotas. Ofrece recolección continua de bajo overhead, **métricas de profiling** que `nvidia-smi` no expone, watches y políticas de salud, diagnósticos activos, estadísticas por job, gestión de grupos e integración nativa con Prometheus (dcgm-exporter), Kubernetes y gestores de clústeres.
</details>

<details>
<summary><strong>Ejercicio 9</strong></summary>

**Q9.1**

| | Time-slicing | MIG |
|---|---|---|
| Aislamiento de memoria | **Ninguno**: todas las réplicas comparten el framebuffer completo, así que un Pod puede agotarlo | Memoria y caché **particionadas por hardware** por instancia |
| Aislamiento de fallas | Una falla puede afectar a todos los que comparten | Los errores quedan contenidos en la instancia |
| QoS / rendimiento | Impredecible; cambio de contexto entre procesos | **SMs y ancho de banda de memoria dedicados**, latencia predecible |
| Hardware | Cualquier GPU soportada | A100, A30, H100, H200, B200 y posteriores |
| Flexibilidad | Cualquier cantidad de réplicas | Formas de perfil fijas (hasta 7 instancias) |

**Q9.2** (a) **Time-slicing**: sobresuscripción barata para cargas de trabajo confiables, en ráfagas y mayormente ociosas. (b) **MIG**: los recursos garantizados y el aislamiento entre tenants protegen los SLAs de latencia.

**Q9.3** **Virtualización**: GPUs compartidas por o asignadas a **máquinas virtuales** bajo un hipervisor (VMware, KVM, OpenShift Virtualization), con live migration en las plataformas soportadas y licenciamiento y gestión por VM. vGPU se puede combinar con MIG (vGPU respaldado por MIG) para tener aislamiento por hardware dentro de las VMs.

**Q9.4** Recursos específicos por perfil como `nvidia.com/mig-1g.10gb`, `nvidia.com/mig-3g.40gb`, etc.

**Q9.5** **NVIDIA Run:ai.**
</details>

<details>
<summary><strong>Ejercicio 10</strong></summary>

**Paso 1:**

| # | Solución | Por qué |
|---|---|---|
| S1 | **RAPIDS** (cuDF, cuML; RAPIDS Accelerator for Apache Spark) | Dataframes/ETL acelerados por GPU con APIs compatibles con pandas y Spark |
| S2 | **NeMo** | Framework de punta a punta para construir, personalizar, evaluar y ponerle guardrails a modelos de IA generativa |
| S3 | **Riva** | Microservicios de speech AI acelerados por GPU (ASR, TTS, NMT) |
| S4 | **Metropolis / DeepStream** | Framework de vision AI y SDK de analítica de streaming para video multi-stream en el edge |
| S5 | **Morpheus** | Framework de IA para ciberseguridad acelerado por GPU (detección de anomalías, detección de información sensible) |
| S6 | **Merlin** | Framework para sistemas de recomendación (NVTabular, HugeCTR, manejo de embeddings) |
| S7 | **Clara** (Clara/MONAI para imágenes) | Plataforma de IA para salud y ciencias de la vida |
| S8 | **Omniverse** (con Isaac Sim para robótica) | Plataforma basada en OpenUSD para simulación físicamente basada y digital twins |
| S9 | **TAO Toolkit** | Transfer learning low-code sobre modelos preentrenados |
| S10 | **Fleet Command** | Despliegue y ciclo de vida seguros, administrados desde la nube, de apps de IA en sitios edge distribuidos |
| S11 | **Base Command Manager** | Aprovisionamiento y gestión de clústeres (imágenes, workload managers, monitoreo) |
| S12 | **GPUDirect Storage (Magnum IO)**, con un filesystem paralelo | El DMA directo almacenamiento→GPU elimina los bounce buffers de CPU |
| S13 | **BlueField DPU + DOCA** | Descargar, acelerar y aislar red, almacenamiento y seguridad en la DPU |
| S14 | **Spectrum-X** | Plataforma Ethernet (switches Spectrum-4 + SuperNICs BlueField-3) optimizada para IA, con adaptive routing y control de congestión |
| S15 | **Quantum InfiniBand** (con cómputo in-network SHARP) | Latencia más baja; SHARP descarga las reducciones colectivas en los switches |
| S16 | **NVIDIA AI Enterprise** | Suite de software de producción soportada, segura y certificada |
| S17 | **NIM** | Microservicio de inferencia optimizado y precompilado con una API compatible con OpenAI |
| S18 | **Run:ai** | Orquestación de GPUs con cuotas, fair-share y GPUs fraccionales |

**Paso 2: mitigaciones de almacenamiento** (de la guía de NVIDIA sobre escalado de almacenamiento):
- Usar **NVMe local como caché** del dataset, o una capa de caché, para que las épocas repetidas no golpeen el almacenamiento compartido.
- Pasar a un **filesystem paralelo/scale-out** diseñado para muchos lectores concurrentes en lugar de un único head NFS.
- Darle forma al I/O: **archivos más grandes/formatos shardeados** (menos archivos chiquitos), más workers del data loader, prefetching y lecturas asíncronas.
- Dimensionar la red de almacenamiento según la cantidad de GPUs (suficiente ancho de banda por nodo), y escalonar los checkpoints de forma asíncrona para que las escrituras no frenen el entrenamiento.

**Q10.1** Prácticamente cualquier escenario que corra software de NVIDIA en producción: S2–S7, S9, S12 y S17, entre otros, y por supuesto S16. AI Enterprise es el **envoltorio comercial** (soporte, seguridad, certificación y habilitación). No cumple una función técnica por sí mismo, así que cuando un escenario nombra un problema técnico, la respuesta es el componente que lo resuelve.

**Q10.2** El factor decisivo es el **requisito operativo/de ecosistema**:
- **Spectrum-X** le conviene a organizaciones que estandarizan en **Ethernet** (nubes de IA multi-tenant, operaciones y herramientas Ethernet existentes) y quieren ganar rendimiento optimizado para IA.
- **Quantum InfiniBand** le conviene a quienes necesitan la **latencia más baja posible y cómputo in-network (SHARP)** para los jobs de entrenamiento más grandes y fuertemente acoplados.

**Q10.3** Optimizar con **TensorRT-LLM**, servir a través de **Triton** (que tiene un backend de TensorRT-LLM) o, más simple, empaquetar y desplegar como un **NIM**, con soporte de producción a través de **NVIDIA AI Enterprise**. En este lab los viste en el orden TensorRT (Ejercicio 4) → Triton (Ejercicio 5) → NIM (Ejercicio 6), cada uno agregando una capa de empaquetado sobre el anterior.
</details>

---

## Fuentes oficiales

- NVIDIA NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA Academy, AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- NVIDIA AI Inference (Triton, NIM, TensorRT-LLM): https://developer.nvidia.com/topics/ai/ai-inference
- Tips on Scaling Storage for AI Training and Inferencing: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- What Are Large Language Models Used For?: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- NVIDIA GPU Operator: Simplifying GPU Management in Kubernetes: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes