# Guided Exercises — Topic 1.8: Compare and Contrast GPU and CPU Architectures

**Certification:** NCA-AIIO · **Exam weight:** 4.75%

These exercises go from inspecting real hardware, to reasoning about peak compute and memory bandwidth, to measuring the trade-offs with a benchmark. They end with how a Kubernetes cluster schedules each kind of processor.

**Prerequisites**
- A Linux host with at least one NVIDIA data-center GPU and the NVIDIA driver installed.
- Python 3.10+ with PyTorch built for CUDA.
- Optional: `kubectl` access to a cluster running the NVIDIA GPU Operator.
- Without GPU access, you can still work through steps 1–4 and 7–9 using the sample outputs provided. They match an NVIDIA H100 SXM5 80GB on a dual-socket Intel Xeon Platinum 8480+ host.

**Official references**
- NVIDIA AI Infrastructure and Operations Fundamentals: https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
- NCA-AIIO exam study guide: https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
- NVIDIA AI Inference: https://developer.nvidia.com/topics/ai/ai-inference
- NVIDIA TensorRT: https://developer.nvidia.com/tensorrt
- GPU Operator overview: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
- Scaling storage for AI: https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
- LLM use cases: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
- CUDA C++ Programming Guide: https://docs.nvidia.com/cuda/cuda-c-programming-guide/
- CUDA C++ Best Practices Guide: https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/
- `nvidia-smi` documentation: https://docs.nvidia.com/deploy/nvidia-smi/index.html

---

## Exercise 1 — Inventory the CPU: few powerful cores built for latency

1. Print the CPU topology:

   ```bash
   lscpu
   ```

   Expected output (abridged):

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

2. Count physical cores, as opposed to hardware threads:

   ```bash
   lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l
   ```

   Expected output:

   ```
   112
   ```

3. Check the NUMA layout and how much memory is local to each socket:

   ```bash
   numactl --hardware
   ```

   Expected output (abridged):

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

**Questions**

- **Q1.1** The host shows 224 "CPUs" but only 112 physical cores. Where does the difference come from? Why does it matter when you size CPU threads for data-loading workers?
- **Q1.2** Each core has about 2 MiB of private L2, and each socket shares a large L3. What kind of workload is this cache hierarchy designed for?
- **Q1.3** What do the flags `avx512f` and `amx_bf16` tell you about the CPU's ability to run AI math? Why does a CPU with these flags still not replace a GPU for training?
- **Q1.4** The NUMA distance from node 0 to node 1 is 21, compared with 10 locally. Why should a GPU workload pin its CPU threads to the NUMA node closest to the GPU?

---

## Exercise 2 — Inventory the GPU: many simple cores built for throughput

1. List the GPUs and the driver version:

   ```bash
   nvidia-smi -L
   nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1
   ```

   Expected output:

   ```
   GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-3f1c2a7e-9b1d-4e0a-8c55-2d7b1e9f0a11)
   GPU 1: NVIDIA H100 80GB HBM3 (UUID: GPU-8a2e4c90-1f3b-47d2-b6a8-5e0c3d9f7b22)
   ...
   550.90.07
   ```

2. Query the architectural properties that matter for capacity planning:

   ```bash
   nvidia-smi --query-gpu=index,name,memory.total,clocks.max.sm,clocks.max.memory,power.limit,pcie.link.gen.max,pcie.link.width.max --format=csv
   ```

   Expected output:

   ```
   index, name, memory.total [MiB], clocks.max.sm [MHz], clocks.max.memory [MHz], power.limit [W], pcie.link.gen.max, pcie.link.width.max
   0, NVIDIA H100 80GB HBM3, 81559 MiB, 1980 MHz, 2619 MHz, 700.00 W, 5, 16
   ```

3. Get the Streaming Multiprocessor (SM) count and the compute capability from PyTorch:

   ```bash
   python3 -c "import torch; p=torch.cuda.get_device_properties(0); print(p.name, '| SMs:', p.multi_processor_count, '| CC:', f'{p.major}.{p.minor}', '| Mem GiB:', round(p.total_memory/2**30,1))"
   ```

   Expected output:

   ```
   NVIDIA H100 80GB HBM3 | SMs: 132 | CC: 9.0 | Mem GiB: 79.1
   ```

4. Fill in this comparison table using your outputs and the Hopper figures:

   | Property | CPU (1× Xeon 8480+) | GPU (1× H100 SXM5) |
   |---|---|---|
   | Independent "cores" | 56 cores (112 HW threads) | 132 SMs × 128 FP32 lanes = 16,896 CUDA cores |
   | Max clock | 3.8 GHz (turbo) | 1.98 GHz |
   | Threads resident at once | 112 | 132 SMs × 2,048 = 270,336 |
   | Specialized matrix units | AMX tiles per core | 528 fourth-gen Tensor Cores |
   | Main memory | DDR5, 8 channels, about 307 GB/s | HBM3, about 3.35 TB/s |
   | Memory capacity | Up to several TB per socket | 80 GB |
   | Last-level cache | 105 MB L3 | 50 MB L2 |
   | TDP | 350 W | Up to 700 W |

**Questions**

- **Q2.1** The GPU's clock is about half the CPU's turbo clock. How can the GPU still be more than an order of magnitude faster at matrix math?
- **Q2.2** The GPU can keep about 270,000 threads resident, while the CPU runs 112 hardware threads. What does the GPU do with all those resident threads when one of them waits on memory?
- **Q2.3** The CPU can address terabytes of memory, but the GPU has 80 GB. Name one consequence for LLM inference and one technique that works around it.
- **Q2.4** What is compute capability 9.0, and why would a container image built only for CC 8.0 be a problem on this GPU?

---

## Exercise 3 — Calculate theoretical peak compute

Peak FLOPS = (parallel execution units) × (FLOPs per unit per cycle) × (clock in Hz). One fused multiply-add (FMA) counts as 2 FLOPs.

1. **CPU FP32 peak**, for one Xeon 8480+ socket:
   - 56 cores, each with 2 AVX-512 FMA units.
   - One AVX-512 register holds 16 FP32 values.
   - FLOPs per cycle per core = 2 units × 16 lanes × 2 (FMA) = **64**.
   - The sustained all-core AVX-512 clock is about 2.0 GHz. It is lower than turbo because wide vector units reduce the frequency.

   ```bash
   python3 -c "print(f'CPU FP32 peak: {56*64*2.0e9/1e12:.2f} TFLOPS')"
   ```

   Expected output:

   ```
   CPU FP32 peak: 7.17 TFLOPS
   ```

2. **GPU FP32 peak**, using CUDA cores only (no Tensor Cores):

   ```bash
   python3 -c "print(f'GPU FP32 peak: {16896*2*1.98e9/1e12:.1f} TFLOPS')"
   ```

   Expected output:

   ```
   GPU FP32 peak: 66.9 TFLOPS
   ```

3. **GPU Tensor Core peak.** NVIDIA's published dense figure for H100 SXM5 is about 989 TFLOPS in FP16/BF16 and about 1,979 TFLOPS in FP8. Sparse figures are twice that. Compute the ratios:

   ```bash
   python3 -c "cpu=7.17; print(f'GPU FP32 / CPU FP32: {66.9/cpu:.1f}x'); print(f'GPU BF16 TC / CPU FP32: {989/cpu:.0f}x')"
   ```

   Expected output:

   ```
   GPU FP32 / CPU FP32: 9.3x
   GPU BF16 TC / CPU FP32: 138x
   ```

**Questions**

- **Q3.1** Why does the CPU calculation use 2.0 GHz instead of the 3.8 GHz turbo shown by `lscpu`?
- **Q3.2** About 93% of the GPU's peak advantage over the CPU (BF16 versus FP32) comes from Tensor Cores and lower precision, not from CUDA cores. Which software components make sure a model actually uses Tensor Cores?
- **Q3.3** A vendor slide shows "3,958 TFLOPS FP8" for an H100. Which two qualifiers must you check before you compare that number with a CPU figure?

---

## Exercise 4 — Memory bandwidth and the roofline model

A kernel's **arithmetic intensity** (AI) is the number of FLOPs it performs per byte it moves from main memory. The **ridge point** is peak FLOPS divided by peak bandwidth. A kernel whose AI falls below the ridge point is *memory-bound*. A kernel above it is *compute-bound*.

1. Calculate the ridge points:

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

   Expected output:

   ```
   CPU socket FP32      ridge =   23.4 FLOP/byte
   H100 FP32 (CUDA)     ridge =   20.0 FLOP/byte
   H100 BF16 (Tensor)   ridge =  295.2 FLOP/byte
   ```

2. Estimate the arithmetic intensity of two typical AI operations in BF16 (2 bytes per element):
   - **Large GEMM**, `C[N×N] = A[N×N] · B[N×N]` with N = 8192: FLOPs = 2N³, and bytes ≈ 3 × N² × 2.
   - **Element-wise activation**, such as GELU over 8192×8192 elements: about 8 FLOPs per element, and bytes = read + write = 2 × N² × 2.

   ```bash
   python3 - <<'EOF'
   N = 8192
   gemm_ai = (2*N**3) / (3*N*N*2)
   gelu_ai = (8*N*N) / (2*N*N*2)
   print(f"GEMM AI: {gemm_ai:.0f} FLOP/byte")
   print(f"GELU AI: {gelu_ai:.0f} FLOP/byte")
   EOF
   ```

   Expected output:

   ```
   GEMM AI: 2731 FLOP/byte
   GELU AI: 2 FLOP/byte
   ```

**Questions**

- **Q4.1** Classify the GEMM and the GELU on the H100 BF16 roofline. Which hardware resource limits each one?
- **Q4.2** During LLM *decode* (one new token per step at small batch sizes), the weight matrices are effectively multiplied by a vector, so arithmetic intensity is about 1–2 FLOP/byte. Which GPU specification predicts decode tokens/second better: TFLOPS or HBM bandwidth? Why does batching help?
- **Q4.3** Optimizers such as TensorRT apply *kernel fusion*, for example GEMM + bias + GELU in one kernel. Explain the benefit in roofline terms.
- **Q4.4** The FP32 ridge points of the CPU and the GPU are similar (about 20–23). Why is the GPU still much faster on a memory-bound FP32 kernel?

---

## Exercise 5 — Measure it: matrix multiply on CPU and GPU

1. Save the following script as `cpu_vs_gpu.py`:

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

2. Pin the process to the NUMA node closest to GPU 0. Exercise 6 shows how to find it; on the reference host it is node 0. Then run the script:

   ```bash
   numactl --cpunodebind=0 --membind=0 python3 cpu_vs_gpu.py
   ```

   Expected output. The numbers are illustrative and will vary with clocks, the BLAS library, and the PyTorch version:

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

   > Note: on Ampere and Hopper GPUs, PyTorch may run FP32 matmuls on Tensor Cores using TF32 if `torch.backends.cuda.matmul.allow_tf32 = True`. With that setting, the FP32 GPU row can exceed the 67 TFLOPS CUDA-core peak. Check the current default with `python3 -c "import torch; print(torch.backends.cuda.matmul.allow_tf32)"`.

3. Run the script again **without** `torch.cuda.synchronize()`. Replace `gpu_sync` with `cpu_sync` in the GPU `bench` calls and compare the 8192 GPU timings.

**Questions**

- **Q5.1** At N = 64, the GPU is barely faster than the CPU, or even slower. Name the two fixed costs that dominate small GPU operations.
- **Q5.2** Why does the GPU's achieved TFLOPS keep rising with N, while the CPU's flattens out early?
- **Q5.3** What happened to the timings in step 3, and why? What does this tell you about the CPU–GPU execution model?
- **Q5.4** BF16 on the GPU gave roughly 12× more throughput than FP32 at N = 8192, while on the CPU the gain was only about 2×. What explains the difference?
- **Q5.5** Which tier of the exam's AI workflow (data prep, training, inference) would still sensibly run *these small matmuls* on CPU? Give one example.

---

## Exercise 6 — The interconnect: the cost of moving data between CPU and GPU

1. Show the topology between GPUs, NICs, and CPU NUMA nodes:

   ```bash
   nvidia-smi topo -m
   ```

   Expected output (abridged, 8-GPU HGX H100):

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

2. Measure host-to-device bandwidth with pageable and pinned memory. Save the following script as `h2d.py`:

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

   Expected output (illustrative, PCIe Gen5 x16):

   ```
   pinned=False  H2D   22.4 GB/s
   pinned=True   H2D   53.7 GB/s
   device-to-device (HBM read+write)  2810.5 GB/s
   ```

3. Repeat step 2 with `--cpunodebind=1 --membind=1` and compare the pinned result.

**Questions**

- **Q6.1** HBM moves data about 50× faster than the PCIe link. What design rule follows for a training input pipeline?
- **Q6.2** Why is pinned (page-locked) memory faster for H2D copies than pageable memory?
- **Q6.3** What did step 3 (wrong NUMA node) show, and which column of `nvidia-smi topo -m` would have predicted it?
- **Q6.4** GPU0 and GPU1 talk over `NV18`. Give the approximate aggregate bandwidth of NVLink 4 on H100 and compare it with PCIe Gen5 x16.
- **Q6.5** NVIDIA Grace Hopper connects CPU and GPU with NVLink-C2C (about 900 GB/s) instead of PCIe. Which bottleneck from this exercise does that remove, and which workloads benefit most?

---

## Exercise 7 — Execution model: SIMT, warps, and branch divergence

Read the following CUDA kernel. You do not need to compile it.

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

1. Work out the launch geometry for `n = 1,000,000`:

   ```bash
   python3 -c "n=10**6; b=256; g=(n+b-1)//b; print('blocks:', g, '| threads:', g*b, '| warps:', g*b//32)"
   ```

   Expected output:

   ```
   blocks: 3907 | threads: 1000192 | warps: 31256
   ```

2. Compare the two processors' approach to the same `if/else`:
   - **CPU core:** out-of-order execution and a branch predictor guess the path. A wrong guess costs a pipeline flush of roughly 15–20 cycles. Each thread follows its own path independently.
   - **GPU SM:** 32 threads form a **warp** and share instruction issue (SIMT). If threads in one warp take different paths, the warp runs path A with some lanes masked off, then path B with the other lanes masked off.

**Questions**

- **Q7.1** How many SMs on the H100 would be busy with 3,907 blocks of 256 threads? How many blocks could each SM hold at once if threads are the only limit (2,048 per SM)?
- **Q7.2** If `x` contains random signs, what fraction of the arithmetic throughput is lost in the divergent branch, in the worst case? What if the data were sorted so that whole warps were all positive or all negative?
- **Q7.3** CPUs spend a large share of die area on branch prediction, out-of-order logic, and big caches. GPUs spend it on ALUs and register files (64K 32-bit registers per SM). Connect this design choice to the terms *latency-optimized* and *throughput-optimized*.
- **Q7.4** Name two AI-pipeline tasks that are branch-heavy and serial, so they belong on the CPU.

---

## Exercise 8 — How Kubernetes sees each processor

With the NVIDIA GPU Operator installed, the device plugin advertises GPUs as an extended resource. CPUs and memory are native resources.

1. Inspect a GPU node:

   ```bash
   kubectl describe node gpu-node-01 | sed -n '/Capacity:/,/Allocatable:/p'
   kubectl get node gpu-node-01 -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep nvidia.com/gpu
   ```

   Expected output (abridged):

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

2. Deploy a pod that uses both CPU and GPU resources:

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

   Expected output:

   ```
   pod/arch-compare created
   pod/arch-compare condition met
   16
   name, memory.total [MiB]
   NVIDIA H100 80GB HBM3, 81559 MiB
   ```

3. Now try to request half a GPU by changing both `nvidia.com/gpu` values to `500m` and applying again.

   Expected output:

   ```
   The Pod "arch-compare" is invalid:
   * spec.containers[0].resources.requests[nvidia.com/gpu]: Invalid value: "500m": must be an integer
   ```

**Questions**

- **Q8.1** CPU can be requested as `250m`, but `nvidia.com/gpu` must be an integer. Why? Which two GPU Operator features let several pods share one physical GPU, and how do they differ in isolation?
- **Q8.2** Why must a GPU extended resource have `requests` equal to `limits`, or appear only in `limits`?
- **Q8.3** The pod requested 16 CPUs alongside 1 GPU. Why does a GPU training pod need a substantial CPU request? What happens to GPU utilization if the CPU request is too small?
- **Q8.4** Which GPU Operator components had to be running for `nvidia.com/gpu: 8` to appear on the node?

---

## Exercise 9 — Architecture decision scenarios

For each workload, choose **CPU**, **GPU**, or **both, with a named split**, and justify the choice in one sentence using the concepts from Exercises 3–7.

| # | Workload |
|---|---|
| a | Pre-training a 70B-parameter LLM on 2T tokens |
| b | Tokenizing and shuffling a 5 TB text corpus before training |
| c | Serving a fraud-detection gradient-boosted tree model at 200 requests/s with a strict 2 ms p99 |
| d | Serving a 13B LLM chatbot to 5,000 concurrent users |
| e | Running the Kubernetes control plane, Prometheus, and the data-loader processes on a DGX node |
| f | Real-time video analytics: decoding 64 camera streams, then object detection |
| g | A nightly ETL job with many joins and group-bys over 2 TB of Parquet |

**Questions**

- **Q9.1** For (d), which inference optimization stack from NVIDIA would you name, and which roofline limit does it attack?
- **Q9.2** For (g), the default answer is CPU, but there is a GPU-accelerated option. Name it and state the condition under which it wins.

---

## Answers

<details>
<summary>Exercise 1 — CPU inventory</summary>

- **Q1.1** Hyper-Threading (SMT) exposes 2 hardware threads per physical core. The threads share the core's execution units and caches, so 224 logical CPUs do not mean 224× throughput. For data loaders, size the worker count on physical cores and leave headroom for the training process's own threads. Oversubscription causes context switches that starve the GPU of input.
- **Q1.2** Latency-sensitive, irregular, branchy code with good temporal locality: OS kernels, databases, control logic, request handling. The large caches hide DRAM latency for a few threads instead of using thousands of threads to hide it.
- **Q1.3** AVX-512 provides 512-bit SIMD (16 FP32 lanes). AMX adds tile-based matrix units for BF16/INT8. The CPU can therefore run small-model inference and some fine-tuning reasonably well. However, its peak (Exercise 3) and its memory bandwidth (about 307 GB/s compared with 3.35 TB/s) remain one to two orders of magnitude below an H100, which dominates training time and cost.
- **Q1.4** Each GPU hangs off a PCIe root complex attached to one socket. Threads and buffers on the remote node force H2D traffic across the inter-socket link (UPI). That adds latency and reduces bandwidth, as Exercise 6 Q6.3 shows. Use the `CPU Affinity` / `NUMA Affinity` columns of `nvidia-smi topo -m`.
</details>

<details>
<summary>Exercise 2 — GPU inventory</summary>

- **Q2.1** Massive parallelism: 16,896 FP32 lanes, compared with 56 cores × 16 AVX-512 lanes × 2 units, which is about 1,792 lanes. Tensor Cores add dense matrix-multiply-accumulate units that do far more work per cycle. Throughput = parallelism × clock, and the GPU wins on parallelism by a much larger factor than it loses on clock.
- **Q2.2** It switches warps. Each SM's warp schedulers pick, every cycle, a warp whose operands are ready. Because registers for all resident warps stay on-chip, switching costs nothing. Memory latency (hundreds of cycles) is hidden by keeping other warps busy. This is *latency hiding through occupancy*, as opposed to the CPU's *latency avoidance through caches*.
- **Q2.3** Consequence: a large model's weights plus the KV cache may not fit in one GPU. A 70B model in FP16 needs about 140 GB for weights alone. Workarounds include tensor/pipeline parallelism across GPUs over NVLink, quantization (FP8/INT8/INT4 with TensorRT), and KV-cache paging/offload. Grace Hopper can also extend into CPU LPDDR5X over NVLink-C2C.
- **Q2.4** Compute capability identifies the SM architecture's feature set and instruction set: 9.0 = Hopper, 8.0 = A100 Ampere. A binary compiled only to CC 8.0 SASS without PTX cannot run natively on CC 9.0 and fails with "no kernel image is available". It also cannot use Hopper features such as FP8 Tensor Cores and the Transformer Engine. Use NGC images built for the target architectures, or include PTX for JIT compilation.
</details>

<details>
<summary>Exercise 3 — Peak compute</summary>

- **Q3.1** Heavy AVX-512 use draws more power, so the CPU lowers its all-core frequency (license-based frequency reduction). The 3.8 GHz turbo applies to few active cores on light instructions. An honest peak uses the sustained all-core vector clock.
- **Q3.2** Tensor Cores are used when the framework calls libraries such as cuBLAS/cuDNN with supported precisions (TF32, BF16, FP16, FP8, INT8) and suitable shapes. In practice that means mixed-precision training (`torch.autocast` / AMP), the Transformer Engine for FP8 on Hopper, and TensorRT / TensorRT-LLM for inference, which picks Tensor Core kernels and lower precisions.
- **Q3.3** (1) **Precision**: FP8 compared with the CPU's FP32 is not like for like. (2) **Sparsity**: NVIDIA's headline numbers often assume 2:4 structured sparsity, which doubles the dense figure. The dense FP8 number is about 1,979 TFLOPS. Also check form factor (SXM versus PCIe) and boost-clock assumptions.
</details>

<details>
<summary>Exercise 4 — Roofline</summary>

- **Q4.1** GEMM (2,731 FLOP/byte) is above the 295 ridge, so it is **compute-bound** and limited by Tensor Core throughput. GELU (2 FLOP/byte) is far below the ridge, so it is **memory-bound** and limited by HBM bandwidth.
- **Q4.2** HBM bandwidth. Each decode step streams all weights from HBM to do roughly one FMA per weight, so tokens/s ≈ bandwidth ÷ bytes of weights (plus KV cache). Batching reuses each weight load across many sequences and multiplies arithmetic intensity by the batch size. That moves the workload toward the compute-bound region and raises throughput, at some cost in per-request latency.
- **Q4.3** Without fusion, the GEMM writes its output to HBM, then the bias kernel reads and writes it, then GELU reads and writes it again. Fusion keeps the intermediate in registers or shared memory, removing those round trips. Fewer bytes for the same FLOPs means higher arithmetic intensity and fewer kernel launches.
- **Q4.4** The ridge point is a ratio. A memory-bound kernel's speed equals its bandwidth, and the GPU has about 11× more of it (3.35 TB/s compared with 307 GB/s per socket). Both processors sit on the bandwidth slope of their roofline, but the GPU's slope is much higher.
</details>

<details>
<summary>Exercise 5 — Benchmark</summary>

- **Q5.1** (1) **Kernel launch overhead**: a few microseconds per launch through the driver and runtime. (2) **Underutilization**: a 64×64 matmul produces too few thread blocks to fill 132 SMs. If data has to be copied from the host, the PCIe transfer adds a third cost that can dominate.
- **Q5.2** Larger N gives more independent tiles, so all SMs fill and many warps per SM hide latency. Arithmetic intensity also grows linearly with N, which pushes the kernel past the ridge point. The CPU saturates its 56 cores and its vector units at modest N and has no further parallelism to unlock.
- **Q5.3** The GPU times collapse to microseconds. CUDA kernel launches are **asynchronous**: the CPU enqueues work on a stream and returns immediately. Without synchronization you measure only the enqueue time. The CPU acts as the *host* that orchestrates the GPU *device*; you need `synchronize`, events, or a blocking copy to observe completion.
- **Q5.4** On the GPU, BF16 moves the matmul from CUDA cores (FP32, about 67 TFLOPS) to Tensor Cores (about 989 TFLOPS dense) and halves the bytes moved. On the CPU, BF16 gains depend on the AMX/AVX-512-BF16 paths in oneDNN. The CPU's matrix units are much smaller relative to the rest of the core.
- **Q5.5** Data preparation and pre/post-processing. For example: per-sample feature engineering, small embedding lookups in a recommender's request path, or a tiny classifier inside a serving pipeline, where the PCIe round trip and launch cost exceed the compute.
</details>

<details>
<summary>Exercise 6 — Interconnect</summary>

- **Q6.1** Move data to the GPU once and keep it there. Overlap transfers with compute (prefetch, `non_blocking=True`, multiple CUDA streams). Do the decoding and augmentation as far upstream as possible, or on the GPU with DALI. Make sure storage and network can feed the aggregate rate the GPUs consume, as described in NVIDIA's storage-scaling guidance.
- **Q6.2** DMA engines can only transfer from physical memory that the OS cannot page out. With pageable memory the driver first copies into an internal pinned staging buffer, which adds an extra memcpy and serializes the transfer. Pinned memory allows direct, asynchronous DMA at close to PCIe line rate (about 64 GB/s theoretical per direction for Gen5 x16).
- **Q6.3** Bandwidth drops and latency rises (the exact amount depends on the platform), because the copy crosses the inter-socket link. The `CPU Affinity` / `NUMA Affinity` columns, and the `SYS` marking for remote paths, show which node is local to each GPU.
- **Q6.4** NVLink 4 on H100 offers 18 links totalling about 900 GB/s bidirectional per GPU. PCIe Gen5 x16 offers about 128 GB/s bidirectional, so NVLink has about 7× the bandwidth. Through NVSwitch, all 8 GPUs in an HGX communicate at full NVLink bandwidth, which is critical for all-reduce in data-parallel training and for tensor parallelism.
- **Q6.5** It removes the PCIe host-to-device bottleneck. With a coherent CPU–GPU memory space, the GPU can also access CPU memory at high bandwidth. The biggest winners are workloads whose working set exceeds HBM: large-model inference with offloaded weights or KV cache, recommender systems with huge embedding tables, graph analytics, and some HPC applications.
</details>

<details>
<summary>Exercise 7 — SIMT and divergence</summary>

- **Q7.1** 3,907 blocks is far more than 132, so all 132 SMs are busy, and the work runs in several *waves*. With 256 threads per block, each SM can hold 2,048 ÷ 256 = **8 blocks**, which is 64 warps, if registers and shared memory allow it.
- **Q7.2** Worst case, about **50%**. A warp with mixed signs runs both paths serially with half the lanes masked each time. Strictly, the cost is the sum of both path lengths, compared with only one. If whole warps share a sign, every warp takes a single path and divergence disappears. This is why data layout and sorting matter on GPUs.
- **Q7.3** The CPU invests transistors to make *one thread finish as fast as possible* (latency-optimized): prediction, speculation, deep caches. The GPU invests them in *finishing the most total work per second* (throughput-optimized): many simple lanes, a huge register file to keep thousands of threads resident, and hardware warp scheduling to hide latency instead of avoiding it.
- **Q7.4** Examples: tokenization and text normalization, JSON/protobuf parsing of requests, beam-search or sampling control logic and request scheduling in a serving system, file system and metadata operations in the data loader, and orchestration (Kubernetes, Slurm).
</details>

<details>
<summary>Exercise 8 — Kubernetes</summary>

- **Q8.1** Extended resources registered by a device plugin are opaque integer counters; Kubernetes has no notion of time-slicing or partitioning them. CPU, by contrast, is enforced by the Linux CFS scheduler in fractional quotas. Two sharing mechanisms exist. **MIG** (Multi-Instance GPU, A100/H100) partitions the GPU in hardware into up to 7 instances, each with dedicated SMs, L2 slices, and HBM, giving strong isolation and predictable QoS. They appear as resources like `nvidia.com/mig-1g.10gb`. **Time-slicing**, configured through the device plugin, advertises one GPU as N replicas that share it by context switching, with no memory or fault isolation.
- **Q8.2** Extended resources cannot be overcommitted. The kubelet allocates whole devices to a container, so requests and limits must match. If you set only `limits`, Kubernetes copies the limit into the request.
- **Q8.3** The CPU feeds the GPU: data loading, decoding, augmentation, tokenization, launching kernels, and NCCL proxy threads. With too few CPUs, the input pipeline cannot keep up. GPU utilization (`nvidia-smi` `GPU-Util`, or DCGM `DCGM_FI_PROF_SM_ACTIVE`) drops into a sawtooth while the expensive accelerator waits on the cheap CPU.
- **Q8.4** The NVIDIA driver (containerized or pre-installed), the NVIDIA Container Toolkit, and the **device plugin** that registers `nvidia.com/gpu`. **GPU Feature Discovery** (with NFD) creates the `nvidia.com/gpu.product`, `.memory`, and `.count` labels. The operator also deploys DCGM Exporter for metrics, the MIG Manager when MIG is used, and the validator that checks the stack.
</details>

<details>
<summary>Exercise 9 — Decisions</summary>

| # | Choice | Justification |
|---|---|---|
| a | **GPU**, multi-node with NVLink/NVSwitch plus InfiniBand | Dense GEMMs are compute-bound and need Tensor Core throughput, while all-reduce across GPUs needs high-bandwidth interconnect. |
| b | **CPU**, with large parallel storage | Tokenization is branchy, string-heavy, and I/O-bound, so it maps poorly to SIMT and gains little from Tensor Cores. |
| c | **CPU** usually; GPU only at large batch sizes | Tree traversal is branch-divergent, and with small per-request batches the PCIe and launch overhead would eat the 2 ms budget. |
| d | **GPU** for the model, with CPUs for tokenization, scheduling, and the API | Decode is memory-bandwidth-bound and needs HBM plus large KV-cache capacity, while continuous batching raises arithmetic intensity. |
| e | **CPU** | Control-plane and monitoring processes are latency-sensitive, serial, general-purpose code. Reserve CPU for them so they do not starve the GPU jobs. |
| f | **Both**: GPU NVDEC for decode and GPU inference; CPU for orchestration and I/O | Keeping decoded frames in GPU memory avoids PCIe round trips, and detection CNNs are dense parallel math. |
| g | **CPU** by default, or GPU via RAPIDS | Joins and group-bys are memory-bound and branchy, so CPU is the safe default unless the GPU-accelerated conditions below hold. |

- **Q9.1** **TensorRT-LLM**, typically served with Triton Inference Server or NIM. It uses in-flight (continuous) batching, paged KV cache, FP8/INT4 quantization, and fused attention kernels. Quantization and fusion reduce the bytes moved per token, which attacks the **memory-bandwidth limit**. Batching raises arithmetic intensity toward the compute ridge.
- **Q9.2** **RAPIDS** (cuDF, or the RAPIDS Accelerator for Apache Spark). It wins when the data is large and columnar, the operations are mostly vectorizable (scans, hash joins, aggregations on fixed-width types), and the data can stay on the GPU across several stages. In that case HBM bandwidth beats DRAM and PCIe transfer costs are amortized. It loses on small datasets, heavy string or UDF logic, and pipelines that bounce data back to the CPU between steps.
</details>