# Ejercicios guiados — Tema 1.8: Comparar y contrastar las arquitecturas de GPU y CPU

**Certificación:** NCA-AIIO · **Peso en el examen:** 4.75%

Estos ejercicios van desde inspeccionar hardware real, pasando por razonar sobre el cómputo pico y el ancho de banda de memoria, hasta medir las compensaciones con un benchmark. Terminan con cómo un clúster de Kubernetes planifica cada tipo de procesador.

**Requisitos previos**
- Un host Linux con al menos una GPU NVIDIA de data center y el driver de NVIDIA instalado.
- Python 3.10+ con PyTorch compilado para CUDA.
- Opcional: acceso con `kubectl` a un clúster que ejecute el NVIDIA GPU Operator.
- Sin acceso a GPU, igual podés resolver los pasos 1–4 y 7–9 usando las salidas de ejemplo provistas. Corresponden a una NVIDIA H100 SXM5 80GB en un host Intel Xeon Platinum 8480+ de doble socket.

**Referencias oficiales**
- NVIDIA AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- Guía de estudio del examen NCA-AIIO: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- Panorama del GPU Operator: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- Escalar el almacenamiento para IA: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- Casos de uso de LLM: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- CUDA C++ Programming Guide: https://docs.nvidia.com/cuda/cuda-c-programming-guide/
- CUDA C++ Best Practices Guide: https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/
- Documentación de `nvidia-smi`: https://docs.nvidia.com/deploy/nvidia-smi/index.html

---

## Ejercicio 1 — Inventariar la CPU: pocos núcleos potentes pensados para la latencia

1. Mostrá la topología de la CPU:

   ```bash
   lscpu
   ```

   Salida esperada (abreviada):

   ```
   Architecture:            x86_64
   CPU(s):                  224
   On-line CPU(s) list:     0-223
   Model name:              Intel(R) Xeon(R) Platinum 8480+
   Thread(s) per core:      2
   Core(s) per socket:      56
   Socket(s):               2
   CPU max MHz:             3800.0000
   CPU min MHz:             800.0000
   L1d cache:               5.3 MiB (112 instances)
   L1i cache:               3.5 MiB (112 instances)
   L2 cache:                224 MiB (112 instances)
   L3 cache:                210 MiB (2 instances)
   NUMA node(s):            2
   NUMA node0 CPU(s):       0-55,112-167
   NUMA node1 CPU(s):       56-111,168-223
   Flags:                   ... avx2 ... avx512f ... avx512_bf16 ... amx_bf16 amx_tile amx_int8 ...
   ```

2. Contá los núcleos físicos, a diferencia de los hilos de hardware:

   ```bash
   lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l
   ```

   Salida esperada:

   ```
   112
   ```

3. Revisá la disposición NUMA y cuánta memoria es local a cada socket:

   ```bash
   numactl --hardware
   ```

   Salida esperada (abreviada):

   ```
   available: 2 nodes (0-1)
   node 0 cpus: 0 1 2 ... 55 112 113 ... 167
   node 0 size: 1031612 MB
   node 1 cpus: 56 57 ... 111 168 ... 223
   node 1 size: 1032142 MB
   node distances:
   node   0   1
     0:  10  21
     1:  21  10
   ```

**Preguntas**

- **Q1.1** El host muestra 224 "CPUs" pero solo 112 núcleos físicos. ¿De dónde sale la diferencia? ¿Por qué importa al dimensionar los hilos de CPU para los workers de carga de datos?
- **Q1.2** Cada núcleo tiene unos 2 MiB de L2 privada, y cada socket comparte una L3 grande. ¿Para qué tipo de carga de trabajo está diseñada esta jerarquía de caché?
- **Q1.3** ¿Qué te dicen los flags `avx512f` y `amx_bf16` sobre la capacidad de la CPU para ejecutar matemática de IA? ¿Por qué una CPU con estos flags igual no reemplaza a una GPU para entrenamiento?
- **Q1.4** La distancia NUMA del nodo 0 al nodo 1 es 21, frente a 10 en local. ¿Por qué una carga de trabajo de GPU debería fijar sus hilos de CPU al nodo NUMA más cercano a la GPU?

---

## Ejercicio 2 — Inventariar la GPU: muchos núcleos simples pensados para el throughput

1. Listá las GPUs y la versión del driver:

   ```bash
   nvidia-smi -L
   nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1
   ```

   Salida esperada:

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1c2a7e-9b1d-4e0a-8c55-2d7b1e9f0a11)
   GPU 1: NVIDIA H100 80GB HBM3 (UUID: GPU-8a2e4c90-1f3b-47d2-b6a8-5e0c3d9f7b22)
   ...
   550.90.07
   ```

2. Consultá las propiedades de arquitectura que importan para la planificación de capacidad:

   ```bash
   nvidia-smi --query-gpu=index,name,memory.total,clocks.max.sm,clocks.max.memory,power.limit,pcie.link.gen.max,pcie.link.width.max --format=csv
   ```

   Salida esperada:

   ```
   index, name, memory.total [MiB], clocks.max.sm [MHz], clocks.max.memory [MHz], power.limit [W], pcie.link.gen.max, pcie.link.width.max
   0, NVIDIA H100 80GB HBM3, 81559 MiB, 1980 MHz, 2619 MHz, 700.00 W, 5, 16
   ```

3. Obtené la cantidad de Streaming Multiprocessors (SM) y la compute capability desde PyTorch:

   ```bash
   python3 -c "import torch; p=torch.cuda.get_device_properties(0); print(p.name, '| SMs:', p.multi_processor_count, '| CC:', f'{p.major}.{p.minor}', '| Mem GiB:', round(p.total_memory/2**30,1))"
   ```

   Salida esperada:

   ```
   NVIDIA H100 80GB HBM3 | SMs: 132 | CC: 9.0 | Mem GiB: 79.1
   ```

4. Completá esta tabla comparativa usando tus salidas y las cifras de Hopper:

   | Propiedad | CPU (1× Xeon 8480+) | GPU (1× H100 SXM5) |
   |---|---|---|
   | "Núcleos" independientes | 56 núcleos (112 hilos de HW) | 132 SMs × 128 carriles FP32 = 16,896 CUDA cores |
   | Clock máximo | 3.8 GHz (turbo) | 1.98 GHz |
   | Hilos residentes a la vez | 112 | 132 SMs × 2,048 = 270,336 |
   | Unidades matriciales especializadas | Tiles AMX por núcleo | 528 Tensor Cores de cuarta generación |
   | Memoria principal | DDR5, 8 canales, unos 307 GB/s | HBM3, unos 3.35 TB/s |
   | Capacidad de memoria | Hasta varios TB por socket | 80 GB |
   | Caché de último nivel | 105 MB L3 | 50 MB L2 |
   | TDP | 350 W | Hasta 700 W |

**Preguntas**

- **Q2.1** El clock de la GPU es aproximadamente la mitad del clock turbo de la CPU. ¿Cómo puede la GPU ser igualmente más de un orden de magnitud más rápida en matemática matricial?
- **Q2.2** La GPU puede mantener unos 270,000 hilos residentes, mientras que la CPU ejecuta 112 hilos de hardware. ¿Qué hace la GPU con todos esos hilos residentes cuando uno de ellos espera a la memoria?
- **Q2.3** La CPU puede direccionar terabytes de memoria, pero la GPU tiene 80 GB. Nombrá una consecuencia para la inferencia de LLM y una técnica que la sortea.
- **Q2.4** ¿Qué es la compute capability 9.0, y por qué sería un problema en esta GPU una imagen de contenedor compilada solo para CC 8.0?

---

## Ejercicio 3 — Calcular el cómputo pico teórico

FLOPS pico = (unidades de ejecución en paralelo) × (FLOPs por unidad por ciclo) × (clock en Hz). Una fused multiply-add (FMA) cuenta como 2 FLOPs.

1. **Pico FP32 de la CPU**, para un socket Xeon 8480+:
   - 56 núcleos, cada uno con 2 unidades FMA AVX-512.
   - Un registro AVX-512 contiene 16 valores FP32.
   - FLOPs por ciclo por núcleo = 2 unidades × 16 carriles × 2 (FMA) = **64**.
   - El clock AVX-512 sostenido con todos los núcleos es de unos 2.0 GHz. Es menor que el turbo porque las unidades vectoriales anchas reducen la frecuencia.

   ```bash
   python3 -c "print(f'CPU FP32 peak: {56*64*2.0e9/1e12:.2f} TFLOPS')"
   ```

   Salida esperada:

   ```
   CPU FP32 peak: 7.17 TFLOPS
   ```

2. **Pico FP32 de la GPU**, usando solo CUDA cores (sin Tensor Cores):

   ```bash
   python3 -c "print(f'GPU FP32 peak: {16896*2*1.98e9/1e12:.1f} TFLOPS')"
   ```

   Salida esperada:

   ```
   GPU FP32 peak: 66.9 TFLOPS
   ```

3. **Pico de Tensor Cores de la GPU.** La cifra densa publicada por NVIDIA para la H100 SXM5 es de unos 989 TFLOPS en FP16/BF16 y unos 1,979 TFLOPS en FP8. Las cifras con sparsity son el doble. Calculá las proporciones:

   ```bash
   python3 -c "cpu=7.17; print(f'GPU FP32 / CPU FP32: {66.9/cpu:.1f}x'); print(f'GPU BF16 TC / CPU FP32: {989/cpu:.0f}x')"
   ```

   Salida esperada:

   ```
   GPU FP32 / CPU FP32: 9.3x
   GPU BF16 TC / CPU FP32: 138x
   ```

**Preguntas**

- **Q3.1** ¿Por qué el cálculo de la CPU usa 2.0 GHz en lugar de los 3.8 GHz de turbo que muestra `lscpu`?
- **Q3.2** Alrededor del 93% de la ventaja pico de la GPU sobre la CPU (BF16 frente a FP32) viene de los Tensor Cores y de la menor precisión, no de los CUDA cores. ¿Qué componentes de software aseguran que un modelo realmente use los Tensor Cores?
- **Q3.3** Una diapositiva de un fabricante muestra "3,958 TFLOPS FP8" para una H100. ¿Qué dos calificadores tenés que verificar antes de comparar ese número con una cifra de CPU?

---

## Ejercicio 4 — Ancho de banda de memoria y el modelo roofline

La **intensidad aritmética** (AI) de un kernel es la cantidad de FLOPs que realiza por cada byte que mueve desde la memoria principal. El **ridge point** es el pico de FLOPS dividido por el pico de ancho de banda. Un kernel cuya AI cae por debajo del ridge point está *limitado por memoria* (memory-bound). Un kernel por encima está *limitado por cómputo* (compute-bound).

1. Calculá los ridge points:

   ```bash
   python3 - <<'EOF'
   systems = {
       "CPU socket FP32":    (7.17e12, 307e9),
       "H100 FP32 (CUDA)":   (66.9e12, 3.35e12),
       "H100 BF16 (Tensor)": (989e12, 3.35e12),
   }
   for name, (flops, bw) in systems.items():
       print(f"{name:20s} ridge = {flops/bw:6.1f} FLOP/byte")
   EOF
   ```

   Salida esperada:

   ```
   CPU socket FP32      ridge =   23.4 FLOP/byte
   H100 FP32 (CUDA)     ridge =   20.0 FLOP/byte
   H100 BF16 (Tensor)   ridge =  295.2 FLOP/byte
   ```

2. Estimá la intensidad aritmética de dos operaciones típicas de IA en BF16 (2 bytes por elemento):
   - **GEMM grande**, `C[N×N] = A[N×N] · B[N×N]` con N = 8192: FLOPs = 2N³, y bytes ≈ 3 × N² × 2.
   - **Activación elemento a elemento**, como GELU sobre 8192×8192 elementos: unos 8 FLOPs por elemento, y bytes = lectura + escritura = 2 × N² × 2.

   ```bash
   python3 - <<'EOF'
   N = 8192
   gemm_ai = (2*N**3) / (3*N*N*2)
   gelu_ai = (8*N*N) / (2*N*N*2)
   print(f"GEMM AI: {gemm_ai:.0f} FLOP/byte")
   print(f"GELU AI: {gelu_ai:.0f} FLOP/byte")
   EOF
   ```

   Salida esperada:

   ```
   GEMM AI: 2731 FLOP/byte
   GELU AI: 2 FLOP/byte
   ```

**Preguntas**

- **Q4.1** Clasificá la GEMM y la GELU en el roofline BF16 de la H100. ¿Qué recurso de hardware limita a cada una?
- **Q4.2** Durante el *decode* de un LLM (un token nuevo por paso con tamaños de batch chicos), las matrices de pesos se multiplican en la práctica por un vector, así que la intensidad aritmética es de alrededor de 1–2 FLOP/byte. ¿Qué especificación de la GPU predice mejor los tokens/segundo del decode: los TFLOPS o el ancho de banda de HBM? ¿Por qué ayuda el batching?
- **Q4.3** Optimizadores como TensorRT aplican *kernel fusion*, por ejemplo GEMM + bias + GELU en un solo kernel. Explicá el beneficio en términos de roofline.
- **Q4.4** Los ridge points FP32 de la CPU y de la GPU son similares (alrededor de 20–23). ¿Por qué la GPU sigue siendo mucho más rápida en un kernel FP32 limitado por memoria?

---

## Ejercicio 5 — Medirlo: multiplicación de matrices en CPU y GPU

1. Guardá el siguiente script como `cpu_vs_gpu.py`:

   ```python
   import time
   import torch

   def bench(fn, sync, warmup=3, iters=10):
       for _ in range(warmup):
           fn()
       sync()
       t0 = time.perf_counter()
       for _ in range(iters):
           fn()
       sync()
       return (time.perf_counter() - t0) / iters

   def cpu_sync():
       pass

   def gpu_sync():
       torch.cuda.synchronize()

   torch.set_num_threads(torch.get_num_threads())
   print(f"CPU threads used by PyTorch: {torch.get_num_threads()}")
   print(f"{'N':>6} {'dtype':>9} {'device':>6} {'ms/iter':>10} {'TFLOPS':>8}")

   for n in (64, 1024, 4096, 8192):
       flops = 2 * n**3
       for dtype in (torch.float32, torch.bfloat16):
           a_cpu = torch.randn(n, n, dtype=dtype)
           b_cpu = torch.randn(n, n, dtype=dtype)
           if n <= 4096:
               t = bench(lambda: a_cpu @ b_cpu, cpu_sync, iters=3)
               print(f"{n:>6} {str(dtype)[6:]:>9} {'cpu':>6} {t*1e3:>10.3f} {flops/t/1e12:>8.2f}")
           a_gpu = a_cpu.cuda()
           b_gpu = b_cpu.cuda()
           t = bench(lambda: a_gpu @ b_gpu, gpu_sync)
           print(f"{n:>6} {str(dtype)[6:]:>9} {'gpu':>6} {t*1e3:>10.3f} {flops/t/1e12:>8.2f}")
   ```

2. Fijá el proceso al nodo NUMA más cercano a la GPU 0. El Ejercicio 6 muestra cómo encontrarlo; en el host de referencia es el nodo 0. Después ejecutá el script:

   ```bash
   numactl --cpunodebind=0 --membind=0 python3 cpu_vs_gpu.py
   ```

   Salida esperada. Los números son ilustrativos y van a variar según los clocks, la biblioteca BLAS y la versión de PyTorch:

   ```
   CPU threads used by PyTorch: 56
        N     dtype device    ms/iter   TFLOPS
       64   float32    cpu      0.021     0.02
       64   float32    gpu      0.012     0.04
       64  bfloat16    cpu      0.035     0.01
       64  bfloat16    gpu      0.011     0.05
     1024   float32    cpu      0.640     3.36
     1024   float32    gpu      0.041    52.40
     1024  bfloat16    cpu      0.390     5.51
     1024  bfloat16    gpu      0.009   238.60
     4096   float32    cpu     34.100     4.03
     4096   float32    gpu      2.250    61.10
     4096  bfloat16    cpu     14.800     9.29
     4096  bfloat16    gpu      0.190   723.40
     8192   float32    gpu     18.300    60.10
     8192  bfloat16    gpu      1.420   774.30
   ```

   > Nota: en GPUs Ampere y Hopper, PyTorch puede ejecutar los matmuls FP32 en Tensor Cores usando TF32 si `torch.backends.cuda.matmul.allow_tf32 = True`. Con esa configuración, la fila FP32 de la GPU puede superar el pico de 67 TFLOPS de los CUDA cores. Verificá el valor por defecto actual con `python3 -c "import torch; print(torch.backends.cuda.matmul.allow_tf32)"`.

3. Ejecutá el script de nuevo **sin** `torch.cuda.synchronize()`. Reemplazá `gpu_sync` por `cpu_sync` en las llamadas a `bench` de la GPU y compará los tiempos de la GPU con 8192.

**Preguntas**

- **Q5.1** Con N = 64, la GPU es apenas más rápida que la CPU, o incluso más lenta. Nombrá los dos costos fijos que dominan las operaciones chicas en GPU.
- **Q5.2** ¿Por qué los TFLOPS alcanzados por la GPU siguen subiendo con N, mientras que los de la CPU se aplanan temprano?
- **Q5.3** ¿Qué pasó con los tiempos en el paso 3, y por qué? ¿Qué te dice esto sobre el modelo de ejecución CPU–GPU?
- **Q5.4** BF16 en la GPU dio aproximadamente 12× más throughput que FP32 con N = 8192, mientras que en la CPU la ganancia fue de solo unas 2×. ¿Qué explica la diferencia?
- **Q5.5** ¿Qué etapa del flujo de trabajo de IA del examen (preparación de datos, entrenamiento, inferencia) seguiría ejecutando razonablemente *estos matmuls chicos* en CPU? Dá un ejemplo.

---

## Ejercicio 6 — La interconexión: el costo de mover datos entre CPU y GPU

1. Mostrá la topología entre GPUs, NICs y nodos NUMA de la CPU:

   ```bash
   nvidia-smi topo -m
   ```

   Salida esperada (abreviada, HGX H100 de 8 GPUs):

   ```
           GPU0  GPU1  GPU2  ...  GPU7  NIC0  CPU Affinity  NUMA Affinity
   GPU0     X    NV18  NV18  ...  NV18  PIX   0-55,112-167  0
   GPU1    NV18   X    NV18  ...  NV18  NODE  0-55,112-167  0
   ...
   GPU4    NV18  NV18  NV18  ...  NV18  SYS   56-111,168-223 1
   ...
   Legend:
     X    = Self
     SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
     NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
     PIX  = Connection traversing at most a single PCIe bridge
     NV#  = Connection traversing a bonded set of # NVLinks
   ```

2. Medí el ancho de banda host-to-device con memoria paginable y con memoria pinned. Guardá el siguiente script como `h2d.py`:

   ```python
   import time
   import torch

   size_bytes = 1 << 30  # 1 GiB
   n = size_bytes // 4
   dev = torch.empty(n, dtype=torch.float32, device="cuda")

   for pinned in (False, True):
       host = torch.empty(n, dtype=torch.float32, pin_memory=pinned)
       host.fill_(1.0)
       for _ in range(2):
           dev.copy_(host, non_blocking=pinned)
       torch.cuda.synchronize()
       t0 = time.perf_counter()
       iters = 10
       for _ in range(iters):
           dev.copy_(host, non_blocking=pinned)
       torch.cuda.synchronize()
       dt = (time.perf_counter() - t0) / iters
       print(f"pinned={pinned!s:5}  H2D {size_bytes/dt/1e9:6.1f} GB/s")

   d2d = torch.empty_like(dev)
   torch.cuda.synchronize()
   t0 = time.perf_counter()
   for _ in range(10):
       d2d.copy_(dev)
   torch.cuda.synchronize()
   dt = (time.perf_counter() - t0) / 10
   print(f"device-to-device (HBM read+write) {2*size_bytes/dt/1e9:7.1f} GB/s")
   ```

   ```bash
   numactl --cpunodebind=0 --membind=0 python3 h2d.py
   ```

   Salida esperada (ilustrativa, PCIe Gen5 x16):

   ```
   pinned=False  H2D   22.4 GB/s
   pinned=True   H2D   53.7 GB/s
   device-to-device (HBM read+write)  2810.5 GB/s
   ```

3. Repetí el paso 2 con `--cpunodebind=1 --membind=1` y compará el resultado pinned.

**Preguntas**

- **Q6.1** HBM mueve datos unas 50× más rápido que el enlace PCIe. ¿Qué regla de diseño se desprende para un pipeline de entrada de entrenamiento?
- **Q6.2** ¿Por qué la memoria pinned (page-locked) es más rápida para copias H2D que la memoria paginable?
- **Q6.3** ¿Qué mostró el paso 3 (nodo NUMA equivocado), y qué columna de `nvidia-smi topo -m` lo habría predicho?
- **Q6.4** GPU0 y GPU1 se comunican por `NV18`. Dá el ancho de banda agregado aproximado de NVLink 4 en la H100 y comparalo con PCIe Gen5 x16.
- **Q6.5** NVIDIA Grace Hopper conecta CPU y GPU con NVLink-C2C (unos 900 GB/s) en lugar de PCIe. ¿Qué cuello de botella de este ejercicio elimina eso, y qué cargas de trabajo se benefician más?

---

## Ejercicio 7 — Modelo de ejecución: SIMT, warps y divergencia de ramas

Leé el siguiente kernel CUDA. No hace falta que lo compiles.

```cuda
__global__ void scale_or_clip(float *x, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        if (x[i] > 0.0f) {
            x[i] = x[i] * 2.0f;      // path A
        } else {
            x[i] = fmaxf(x[i], -1.0f); // path B
        }
    }
}
// launched as: scale_or_clip<<<(n + 255) / 256, 256>>>(d_x, n);
```

1. Calculá la geometría de lanzamiento para `n = 1,000,000`:

   ```bash
   python3 -c "n=10**6; b=256; g=(n+b-1)//b; print('blocks:', g, '| threads:', g*b, '| warps:', g*b//32)"
   ```

   Salida esperada:

   ```
   blocks: 3907 | threads: 1000192 | warps: 31256
   ```

2. Compará el enfoque de los dos procesadores frente al mismo `if/else`:
   - **Núcleo de CPU:** la ejecución fuera de orden y un predictor de saltos adivinan el camino. Un error de predicción cuesta un vaciado del pipeline de aproximadamente 15–20 ciclos. Cada hilo sigue su propio camino de forma independiente.
   - **SM de GPU:** 32 hilos forman un **warp** y comparten la emisión de instrucciones (SIMT). Si los hilos de un warp toman caminos distintos, el warp ejecuta el camino A con algunos carriles enmascarados, y después el camino B con los otros carriles enmascarados.

**Preguntas**

- **Q7.1** ¿Cuántos SMs de la H100 estarían ocupados con 3,907 bloques de 256 hilos? ¿Cuántos bloques podría alojar cada SM a la vez si los hilos fueran el único límite (2,048 por SM)?
- **Q7.2** Si `x` contiene signos aleatorios, ¿qué fracción del throughput aritmético se pierde en la rama divergente, en el peor caso? ¿Y si los datos estuvieran ordenados de modo que warps enteros fueran todos positivos o todos negativos?
- **Q7.3** Las CPUs dedican una gran parte del área del die a la predicción de saltos, la lógica fuera de orden y cachés grandes. Las GPUs la dedican a ALUs y bancos de registros (64K registros de 32 bits por SM). Relacioná esta decisión de diseño con los términos *optimizado para latencia* y *optimizado para throughput*.
- **Q7.4** Nombrá dos tareas del pipeline de IA que tengan muchas ramas y sean seriales, de modo que corresponden a la CPU.

---

## Ejercicio 8 — Cómo ve Kubernetes a cada procesador

Con el NVIDIA GPU Operator instalado, el device plugin anuncia las GPUs como un recurso extendido. La CPU y la memoria son recursos nativos.

1. Inspeccioná un nodo con GPU:

   ```bash
   kubectl describe node gpu-node-01 | sed -n '/Capacity:/,/Allocatable:/p'
   kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep nvidia.com/gpu
   ```

   Salida esperada (abreviada):

   ```
   Capacity:
     cpu:                224
     ephemeral-storage:  1872766232Ki
     hugepages-1Gi:      0
     hugepages-2Mi:      0
     memory:             2113536000Ki
     nvidia.com/gpu:     8
     pods:               110
   Allocatable:
   "nvidia.com/gpu.count":"8"
   "nvidia.com/gpu.memory":"81559"
   "nvidia.com/gpu.product":"NVIDIA-H100-80GB-HBM3"
   ```

2. Desplegá un Pod que use recursos de CPU y de GPU:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: arch-compare
     labels:
       app: arch-compare
   spec:
     restartPolicy: Never
     nodeSelector:
       nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
     containers:
       - name: cuda
         image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
         command: ["bash", "-c"]
         args:
           - "nproc && nvidia-smi --query-gpu=name,memory.total --format=csv"
         resources:
           requests:
             cpu: "16"
             memory: 64Gi
             nvidia.com/gpu: 1
           limits:
             cpu: "16"
             memory: 64Gi
             nvidia.com/gpu: 1
   ```

   ```bash
   kubectl apply -f arch-compare.yaml
   kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/arch-compare --timeout=120s
   kubectl logs arch-compare
   ```

   Salida esperada:

   ```
   pod/arch-compare created
   pod/arch-compare condition met
   16
   name, memory.total [MiB]
   NVIDIA H100 80GB HBM3, 81559 MiB
   ```

3. Ahora intentá pedir media GPU cambiando ambos valores de `nvidia.com/gpu` a `500m` y aplicando de nuevo.

   Salida esperada:

   ```
   The Pod "arch-compare" is invalid:
   * spec.containers[0].resources.requests[nvidia.com/gpu]: Invalid value: "500m": must be an integer
   ```

**Preguntas**

- **Q8.1** La CPU se puede pedir como `250m`, pero `nvidia.com/gpu` tiene que ser un entero. ¿Por qué? ¿Qué dos funcionalidades del GPU Operator permiten que varios Pods compartan una GPU física, y en qué se diferencian en cuanto a aislamiento?
- **Q8.2** ¿Por qué un recurso extendido de GPU tiene que tener `requests` igual a `limits`, o aparecer solo en `limits`?
- **Q8.3** El Pod pidió 16 CPUs junto con 1 GPU. ¿Por qué un Pod de entrenamiento con GPU necesita un request de CPU considerable? ¿Qué le pasa a la utilización de la GPU si el request de CPU es demasiado chico?
- **Q8.4** ¿Qué componentes del GPU Operator tenían que estar corriendo para que `nvidia.com/gpu: 8` apareciera en el nodo?

---

## Ejercicio 9 — Escenarios de decisión de arquitectura

Para cada carga de trabajo, elegí **CPU**, **GPU** o **ambas, con un reparto explícito**, y justificá la elección en una oración usando los conceptos de los Ejercicios 3–7.

| # | Carga de trabajo |
|---|---|
| a | Preentrenar un LLM de 70B parámetros con 2T tokens |
| b | Tokenizar y mezclar un corpus de texto de 5 TB antes del entrenamiento |
| c | Servir un modelo de detección de fraude basado en árboles con gradient boosting a 200 requests/s con un p99 estricto de 2 ms |
| d | Servir un chatbot LLM de 13B a 5,000 usuarios concurrentes |
| e | Ejecutar el control plane de Kubernetes, Prometheus y los procesos de carga de datos en un nodo DGX |
| f | Analítica de video en tiempo real: decodificar 64 streams de cámaras y luego detectar objetos |
| g | Un job ETL nocturno con muchos joins y group-bys sobre 2 TB de Parquet |

**Preguntas**

- **Q9.1** Para (d), ¿qué stack de optimización de inferencia de NVIDIA nombrarías, y qué límite del roofline ataca?
- **Q9.2** Para (g), la respuesta por defecto es CPU, pero existe una opción acelerada por GPU. Nombrala e indicá la condición bajo la cual gana.

---

## Respuestas

<details>
<summary>Ejercicio 1 — Inventario de la CPU</summary>

- **Q1.1** Hyper-Threading (SMT) expone 2 hilos de hardware por núcleo físico. Los hilos comparten las unidades de ejecución y las cachés del núcleo, así que 224 CPUs lógicas no significan 224× de throughput. Para los data loaders, dimensioná la cantidad de workers según los núcleos físicos y dejá margen para los hilos propios del proceso de entrenamiento. La sobresuscripción provoca cambios de contexto que dejan a la GPU sin datos de entrada.
- **Q1.2** Código sensible a la latencia, irregular, con muchas ramas y buena localidad temporal: kernels de sistemas operativos, bases de datos, lógica de control, manejo de requests. Las cachés grandes ocultan la latencia de la DRAM para pocos hilos, en lugar de usar miles de hilos para ocultarla.
- **Q1.3** AVX-512 provee SIMD de 512 bits (16 carriles FP32). AMX agrega unidades matriciales basadas en tiles para BF16/INT8. Por lo tanto, la CPU puede ejecutar razonablemente bien inferencia de modelos chicos y algo de fine-tuning. Sin embargo, su pico (Ejercicio 3) y su ancho de banda de memoria (unos 307 GB/s frente a 3.35 TB/s) siguen estando uno o dos órdenes de magnitud por debajo de una H100, lo que domina el tiempo y el costo de entrenamiento.
- **Q1.4** Cada GPU cuelga de un root complex PCIe conectado a un socket. Los hilos y buffers en el nodo remoto obligan al tráfico H2D a cruzar el enlace entre sockets (UPI). Eso agrega latencia y reduce el ancho de banda, como muestra la Q6.3 del Ejercicio 6. Usá las columnas `CPU Affinity` / `NUMA Affinity` de `nvidia-smi topo -m`.
</details>

<details>
<summary>Ejercicio 2 — Inventario de la GPU</summary>

- **Q2.1** Paralelismo masivo: 16,896 carriles FP32, frente a 56 núcleos × 16 carriles AVX-512 × 2 unidades, que da unos 1,792 carriles. Los Tensor Cores agregan unidades densas de multiplicación-acumulación de matrices que hacen muchísimo más trabajo por ciclo. Throughput = paralelismo × clock, y la GPU gana en paralelismo por un factor mucho mayor del que pierde en clock.
- **Q2.2** Cambia de warp. Los warp schedulers de cada SM eligen, en cada ciclo, un warp cuyos operandos estén listos. Como los registros de todos los warps residentes permanecen en el chip, cambiar no cuesta nada. La latencia de memoria (cientos de ciclos) se oculta manteniendo ocupados a otros warps. Esto es *ocultar la latencia mediante ocupación*, a diferencia de la estrategia de la CPU de *evitar la latencia mediante cachés*.
- **Q2.3** Consecuencia: los pesos de un modelo grande más la KV cache pueden no entrar en una sola GPU. Un modelo de 70B en FP16 necesita unos 140 GB solo para los pesos. Las alternativas incluyen paralelismo de tensor/pipeline entre GPUs sobre NVLink, cuantización (FP8/INT8/INT4 con TensorRT) y paginación/offload de la KV cache. Grace Hopper también puede extenderse a la LPDDR5X de la CPU a través de NVLink-C2C.
- **Q2.4** La compute capability identifica el conjunto de funcionalidades y el conjunto de instrucciones de la arquitectura del SM: 9.0 = Hopper, 8.0 = A100 Ampere. Un binario compilado solo a SASS de CC 8.0 sin PTX no puede ejecutarse de forma nativa en CC 9.0 y falla con "no kernel image is available". Tampoco puede usar funcionalidades de Hopper como los Tensor Cores FP8 y el Transformer Engine. Usá imágenes de NGC compiladas para las arquitecturas de destino, o incluí PTX para compilación JIT.
</details>

<details>
<summary>Ejercicio 3 — Cómputo pico</summary>

- **Q3.1** El uso intensivo de AVX-512 consume más energía, así que la CPU baja su frecuencia con todos los núcleos activos (reducción de frecuencia basada en licencias). El turbo de 3.8 GHz aplica con pocos núcleos activos y con instrucciones livianas. Un pico honesto usa el clock vectorial sostenido con todos los núcleos.
- **Q3.2** Los Tensor Cores se usan cuando el framework llama a bibliotecas como cuBLAS/cuDNN con precisiones soportadas (TF32, BF16, FP16, FP8, INT8) y formas adecuadas. En la práctica eso significa entrenamiento con precisión mixta (`torch.autocast` / AMP), el Transformer Engine para FP8 en Hopper, y TensorRT / TensorRT-LLM para inferencia, que elige kernels de Tensor Cores y precisiones más bajas.
- **Q3.3** (1) **Precisión**: FP8 frente al FP32 de la CPU no es una comparación equivalente. (2) **Sparsity**: los números destacados de NVIDIA suelen asumir sparsity estructurada 2:4, que duplica la cifra densa. El número denso en FP8 es de unos 1,979 TFLOPS. También revisá el form factor (SXM frente a PCIe) y los supuestos de boost clock.
</details>

<details>
<summary>Ejercicio 4 — Roofline</summary>

- **Q4.1** La GEMM (2,731 FLOP/byte) está por encima del ridge de 295, así que está **limitada por cómputo** y la limita el throughput de los Tensor Cores. La GELU (2 FLOP/byte) está muy por debajo del ridge, así que está **limitada por memoria** y la limita el ancho de banda de HBM.
- **Q4.2** El ancho de banda de HBM. Cada paso de decode lee todos los pesos desde HBM para hacer aproximadamente una FMA por peso, así que tokens/s ≈ ancho de banda ÷ bytes de pesos (más la KV cache). El batching reutiliza cada carga de pesos entre muchas secuencias y multiplica la intensidad aritmética por el tamaño del batch. Eso desplaza la carga de trabajo hacia la región limitada por cómputo y sube el throughput, a cierto costo de latencia por request.
- **Q4.3** Sin fusión, la GEMM escribe su salida en HBM, después el kernel de bias la lee y la escribe, y después GELU la lee y la escribe de nuevo. La fusión mantiene el resultado intermedio en registros o en memoria compartida, eliminando esos viajes de ida y vuelta. Menos bytes para los mismos FLOPs significa mayor intensidad aritmética y menos lanzamientos de kernels.
- **Q4.4** El ridge point es un cociente. La velocidad de un kernel limitado por memoria es igual a su ancho de banda, y la GPU tiene unas 11× más (3.35 TB/s frente a 307 GB/s por socket). Ambos procesadores están sobre la pendiente de ancho de banda de su roofline, pero la pendiente de la GPU es mucho más alta.
</details>

<details>
<summary>Ejercicio 5 — Benchmark</summary>

- **Q5.1** (1) **Overhead de lanzamiento de kernels**: unos pocos microsegundos por lanzamiento a través del driver y el runtime. (2) **Subutilización**: un matmul de 64×64 produce muy pocos thread blocks para llenar 132 SMs. Si hay que copiar datos desde el host, la transferencia por PCIe agrega un tercer costo que puede dominar.
- **Q5.2** Un N más grande da más tiles independientes, así que todos los SMs se llenan y muchos warps por SM ocultan la latencia. La intensidad aritmética también crece linealmente con N, lo que empuja al kernel más allá del ridge point. La CPU satura sus 56 núcleos y sus unidades vectoriales con un N modesto y no tiene más paralelismo para aprovechar.
- **Q5.3** Los tiempos de la GPU se desploman a microsegundos. Los lanzamientos de kernels CUDA son **asíncronos**: la CPU encola el trabajo en un stream y retorna de inmediato. Sin sincronización solo medís el tiempo de encolado. La CPU actúa como el *host* que orquesta al *device* GPU; necesitás `synchronize`, eventos o una copia bloqueante para observar la finalización.
- **Q5.4** En la GPU, BF16 mueve el matmul de los CUDA cores (FP32, unos 67 TFLOPS) a los Tensor Cores (unos 989 TFLOPS densos) y reduce a la mitad los bytes movidos. En la CPU, las ganancias de BF16 dependen de los caminos AMX/AVX-512-BF16 en oneDNN. Las unidades matriciales de la CPU son mucho más chicas en relación con el resto del núcleo.
- **Q5.5** Preparación de datos y pre/post-procesamiento. Por ejemplo: feature engineering por muestra, lookups de embeddings chicos en el camino de request de un recomendador, o un clasificador diminuto dentro de un pipeline de serving, donde el viaje de ida y vuelta por PCIe y el costo de lanzamiento superan al cómputo.
</details>

<details>
<summary>Ejercicio 6 — Interconexión</summary>

- **Q6.1** Mové los datos a la GPU una vez y mantenelos ahí. Solapá las transferencias con el cómputo (prefetch, `non_blocking=True`, múltiples CUDA streams). Hacé la decodificación y el aumento de datos lo más arriba posible en el pipeline, o en la GPU con DALI. Asegurate de que el almacenamiento y la red puedan sostener la tasa agregada que consumen las GPUs, como se describe en la guía de NVIDIA sobre escalado de almacenamiento.
- **Q6.2** Los motores DMA solo pueden transferir desde memoria física que el sistema operativo no puede paginar a disco. Con memoria paginable, el driver primero copia a un buffer de staging pinned interno, lo que agrega un memcpy extra y serializa la transferencia. La memoria pinned permite DMA directo y asíncrono cerca de la velocidad de línea de PCIe (unos 64 GB/s teóricos por dirección para Gen5 x16).
- **Q6.3** El ancho de banda baja y la latencia sube (la magnitud exacta depende de la plataforma), porque la copia cruza el enlace entre sockets. Las columnas `CPU Affinity` / `NUMA Affinity`, y la marca `SYS` para caminos remotos, muestran qué nodo es local a cada GPU.
- **Q6.4** NVLink 4 en la H100 ofrece 18 enlaces que suman unos 900 GB/s bidireccionales por GPU. PCIe Gen5 x16 ofrece unos 128 GB/s bidireccionales, así que NVLink tiene unas 7× más de ancho de banda. A través de NVSwitch, las 8 GPUs de un HGX se comunican con todo el ancho de banda de NVLink, lo que es crítico para el all-reduce en entrenamiento data-parallel y para el paralelismo de tensor.
- **Q6.5** Elimina el cuello de botella host-to-device de PCIe. Con un espacio de memoria coherente entre CPU y GPU, la GPU también puede acceder a la memoria de la CPU con alto ancho de banda. Los más beneficiados son las cargas de trabajo cuyo working set excede la HBM: inferencia de modelos grandes con pesos o KV cache descargados, sistemas de recomendación con tablas de embeddings enormes, analítica de grafos y algunas aplicaciones de HPC.
</details>

<details>
<summary>Ejercicio 7 — SIMT y divergencia</summary>

- **Q7.1** 3,907 bloques es muchísimo más que 132, así que los 132 SMs están ocupados y el trabajo se ejecuta en varias *olas*. Con 256 hilos por bloque, cada SM puede alojar 2,048 ÷ 256 = **8 bloques**, que son 64 warps, si los registros y la memoria compartida lo permiten.
- **Q7.2** En el peor caso, alrededor del **50%**. Un warp con signos mezclados ejecuta ambos caminos en serie con la mitad de los carriles enmascarados cada vez. Estrictamente, el costo es la suma de las longitudes de ambos caminos, frente a uno solo. Si warps enteros comparten el signo, cada warp toma un único camino y la divergencia desaparece. Por eso la disposición y el ordenamiento de los datos importan en las GPUs.
- **Q7.3** La CPU invierte transistores en hacer que *un hilo termine lo más rápido posible* (optimizada para latencia): predicción, especulación, cachés profundas. La GPU los invierte en *terminar la mayor cantidad de trabajo total por segundo* (optimizada para throughput): muchos carriles simples, un banco de registros enorme para mantener miles de hilos residentes, y planificación de warps por hardware para ocultar la latencia en lugar de evitarla.
- **Q7.4** Ejemplos: tokenización y normalización de texto, parseo de requests JSON/protobuf, la lógica de control de beam search o sampling y la planificación de requests en un sistema de serving, operaciones de sistema de archivos y metadatos en el data loader, y orquestación (Kubernetes, Slurm).
</details>

<details>
<summary>Ejercicio 8 — Kubernetes</summary>

- **Q8.1** Los recursos extendidos registrados por un device plugin son contadores enteros opacos; Kubernetes no tiene noción de time-slicing ni de particionarlos. La CPU, en cambio, la aplica el scheduler CFS de Linux en cuotas fraccionarias. Existen dos mecanismos para compartir. **MIG** (Multi-Instance GPU, A100/H100) particiona la GPU por hardware en hasta 7 instancias, cada una con SMs, porciones de L2 y HBM dedicados, lo que da un aislamiento fuerte y QoS predecible. Aparecen como recursos del tipo `nvidia.com/mig-1g.10gb`. El **time-slicing**, configurado a través del device plugin, anuncia una GPU como N réplicas que la comparten mediante cambio de contexto, sin aislamiento de memoria ni de fallas.
- **Q8.2** Los recursos extendidos no se pueden sobrecomprometer. El kubelet asigna dispositivos enteros a un contenedor, así que requests y limits tienen que coincidir. Si definís solo `limits`, Kubernetes copia el límite en el request.
- **Q8.3** La CPU alimenta a la GPU: carga de datos, decodificación, aumento de datos, tokenización, lanzamiento de kernels e hilos proxy de NCCL. Con muy pocas CPUs, el pipeline de entrada no da abasto. La utilización de la GPU (`GPU-Util` de `nvidia-smi`, o `DCGM_FI_PROF_SM_ACTIVE` de DCGM) cae en forma de diente de sierra mientras el acelerador caro espera a la CPU barata.
- **Q8.4** El driver de NVIDIA (en contenedor o preinstalado), el NVIDIA Container Toolkit y el **device plugin** que registra `nvidia.com/gpu`. **GPU Feature Discovery** (con NFD) crea las etiquetas `nvidia.com/gpu.product`, `.memory` y `.count`. El operador también despliega DCGM Exporter para métricas, el MIG Manager cuando se usa MIG, y el validador que verifica el stack.
</details>

<details>
<summary>Ejercicio 9 — Decisiones</summary>

| # | Elección | Justificación |
|---|---|---|
| a | **GPU**, multinodo con NVLink/NVSwitch más InfiniBand | Las GEMMs densas están limitadas por cómputo y necesitan el throughput de los Tensor Cores, mientras que el all-reduce entre GPUs necesita una interconexión de alto ancho de banda. |
| b | **CPU**, con almacenamiento paralelo grande | La tokenización tiene muchas ramas, mucho manejo de strings y está limitada por I/O, así que se adapta mal a SIMT y gana poco con los Tensor Cores. |
| c | **CPU** normalmente; GPU solo con tamaños de batch grandes | Recorrer árboles genera divergencia de ramas, y con batches chicos por request el overhead de PCIe y de lanzamiento se comería el presupuesto de 2 ms. |
| d | **GPU** para el modelo, con CPUs para tokenización, planificación y la API | El decode está limitado por el ancho de banda de memoria y necesita HBM más gran capacidad para la KV cache, mientras que el continuous batching sube la intensidad aritmética. |
| e | **CPU** | Los procesos del control plane y de monitoreo son código de propósito general, serial y sensible a la latencia. Reservá CPU para ellos así no dejan sin recursos a los jobs de GPU. |
| f | **Ambas**: NVDEC de la GPU para decodificar e inferencia en GPU; CPU para orquestación e I/O | Mantener los frames decodificados en la memoria de la GPU evita viajes de ida y vuelta por PCIe, y las CNNs de detección son matemática densa y paralela. |
| g | **CPU** por defecto, o GPU vía RAPIDS | Los joins y group-bys están limitados por memoria y tienen muchas ramas, así que la CPU es la opción segura por defecto, salvo que se cumplan las condiciones de aceleración por GPU que se indican abajo. |

- **Q9.1** **TensorRT-LLM**, normalmente servido con Triton Inference Server o NIM. Usa batching en vuelo (continuo), KV cache paginada, cuantización FP8/INT4 y kernels de attention fusionados. La cuantización y la fusión reducen los bytes movidos por token, lo que ataca el **límite de ancho de banda de memoria**. El batching sube la intensidad aritmética hacia el ridge de cómputo.
- **Q9.2** **RAPIDS** (cuDF, o el RAPIDS Accelerator for Apache Spark). Gana cuando los datos son grandes y columnares, las operaciones son mayormente vectorizables (scans, hash joins, agregaciones sobre tipos de ancho fijo) y los datos pueden quedarse en la GPU a lo largo de varias etapas. En ese caso el ancho de banda de HBM le gana a la DRAM y los costos de transferencia por PCIe se amortizan. Pierde con datasets chicos, lógica pesada de strings o UDFs, y pipelines que devuelven los datos a la CPU entre pasos.
</details>