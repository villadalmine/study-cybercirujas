#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 1.2: Compare and contrast training and inference architecture
# requirements and considerations
# BREAK & FIX LAB: "The Inverted Cluster Architecture"
# =============================================================================
#
# ARCHITECTURAL MOTIVATION & PROBLEM STATEMENT
#   Deploying modern AI infrastructure requires navigating two diametrically
#   opposed computational and operational regimes:
#
#   1. DISTRIBUTED MODEL TRAINING (Scale-Out Throughput Fabric)
#      - Compute Profile: Compute-bound General Matrix Multiplications (GEMMs).
#        Massive state (weights, gradients, FP32 optimizer states, activations).
#      - Hardware: Bare-metal SXM form factors, all-to-all NVLink mesh
#        (900 GB/s on H100 to 1.8 TB/s on Blackwell). Never partitioned by MIG
#        because NCCL P2P is disabled across MIG instances.
#      - Interconnect: Dedicated multi-rail non-blocking InfiniBand (Quantum-2)
#        or lossless RoCEv2 (PFC+ECN) with GPUDirect RDMA (GDR). Strict 1:1
#        GPU-to-HCA ratio (8 HCAs per DGX node).
#      - Storage & Memory: High-bandwidth parallel file systems (Lustre/Weka/GPFS)
#        with GPUDirect Storage (GDS). Fast RAM-backed IPC (/dev/shm) to prevent
#        PyTorch DataLoader worker deadlock during dataset staging.
#      - Orchestration: Gang scheduling (Kueue, Volcano, Kubeflow PyTorchJob)
#        with all-or-nothing semantics. If 1 GPU fails, the entire gang halts
#        and resumes from the latest checkpoint. Rolling updates are forbidden.
#
#   2. REAL-TIME / STREAMING INFERENCE (Scale-Across Service Fabric)
#      - Compute Profile: Memory-bandwidth bound autoregressive token decode
#        (arithmetic intensity ~1 FLOP/byte reading weights + KV cache from HBM).
#      - Hardware: Density-optimized PCIe cards (L4, L40S, H100 NVL) or SXM
#        partitioned with Multi-Instance GPU (MIG) for strict hardware QoS
#        isolation, or Multi-Process Service (MPS) for kernel multiplexing.
#      - Interconnect: Standard North-South Datacenter Ethernet (25/100 GbE)
#        terminating on ingress load balancers. Inter-node RDMA is unneeded
#        for single-node models; PCIe Gen5 or point-to-point NVLink bridge is
#        sufficient for intra-node Tensor Parallelism (TP).
#      - Storage & Memory: Local high-speed NVMe for staging immutable model
#        weights. Dynamic KV cache memory pools managed via PagedAttention
#        (vLLM) or Triton Model Analyzer. Strict memory budgets to prevent OOM.
#      - Orchestration: Core Kubernetes Deployments/ReplicaSets autoscaled
#        via KEDA / Prometheus metrics (P99 latency, TTFT, request queue depth).
#        Mandatory HTTP/gRPC readiness probes (/v2/health/ready) to prevent
#        routing user requests before model weights are loaded into VRAM.
#
# THE SCENARIO
#   You have taken over an AI platform cluster node ('ai-infra-node-01').
#   Junior infrastructure engineers cross-wired the configuration profiles
#   between the Training Pipeline and the Inference Serving Gateway:
#
#   * FAULT 1 (Compute Partitioning Inversion):
#     The training workload was bound to a GPU with Multi-Instance GPU (MIG)
#     enabled, disabling NVLink P2P and causing NCCL ring initialization to fail.
#     Meanwhile, the multi-tenant inference service was deployed on a monolithic
#     GPU with MIG disabled, preventing sub-GPU slicing and stranding 85% of VRAM.
#
#   * FAULT 2 (Network Fabric & NCCL RDMA Mismatch):
#     The distributed training environment has NCCL_IB_DISABLE=1 and is bound
#     to the 1 GbE management socket (eth0), starving inter-node AllReduce and
#     triggering watchdog timeouts. Conversely, the single-GPU inference pod is
#     requesting dedicated InfiniBand HCAs (mlx5_0:1) that belong exclusively
#     to the rail-optimized training fabric.
#
#   * FAULT 3 (Memory Subsystem & KV-Cache Sizing Collapse):
#     The PyTorch distributed training manifest omits the /dev/shm memory mount,
#     causing DataLoader multiprocessing workers to die with SIGBUS errors.
#     Meanwhile, the inference engine configuration sets an unquantized FP32 KV
#     cache with max_model_len=65536 on a 40 GB slice, triggering instant OOM.
#
#   * FAULT 4 (Orchestration & Lifecycle Semantic Failure):
#     The training job was deployed as a standard Kubernetes Deployment with
#     RollingUpdate strategy (corrupting distributed rank synchronization),
#     while the inference service lacks readiness probes, exposing callers to
#     HTTP 503 errors during cold-start weight loading.
#
# OFFICIAL REFERENCES
#   - NVIDIA AI Enterprise / DGX SuperPOD Architecture Guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   - NVIDIA NCCL Architecture & Parameter Reference:
#     https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/
#   - NVIDIA Multi-Instance GPU (MIG) User Guide:
#     https://docs.nvidia.com/datacenter/tesla/mig-user-guide/
#   - Triton Inference Server Architecture & Health API:
#     https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/
#
# SAFETY & PORTABILITY
#   - Runs entirely in user space in a sandboxed directory (default: ~/nvlab_arch).
#   - Needs NO root privileges, NO real physical GPU, and NO specialized hardware.
#   - Simulated mocks implement real NVIDIA CLI behavior and exact error messages.
#
# USAGE
#   bash break_fix.sh           # build the broken lab (setup)
#   bash break_fix.sh check     # grade your architectural remediation
#   bash break_fix.sh reset     # cleanly remove the lab sandbox
# =============================================================================
set -euo pipefail

LAB="${NVLAB_ROOT:-$HOME/nvlab_arch}"
LAB="${LAB%/}"
MODE="${1:-setup}"
MARKER=".nvlab_arch_marker"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

safe_lab_path() {
  [[ "$LAB" == /* ]] || die "NVLAB_ROOT must be an absolute path (got: $LAB)"
  case "$LAB" in
    ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/usr/local|/var|"$HOME")
      die "Refusing to operate on unsafe lab path: $LAB" ;;
  esac
}

case "$MODE" in
  setup|--setup) ;;
  check|--check)
    [[ -x "$LAB/bin/check-architecture" ]] || die "No lab found at $LAB (run: bash $0 setup)"
    exec "$LAB/bin/check-architecture" ;;
  reset|--reset)
    safe_lab_path
    [[ -f "$LAB/$MARKER" ]] || die "$LAB is not a valid nvlab directory; refusing to delete"
    rm -rf -- "$LAB"
    echo "Successfully removed lab sandbox at $LAB"
    exit 0 ;;
  *)
    echo "Usage: $0 [setup|check|reset]" >&2
    exit 2 ;;
esac

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
[[ ${EUID:-$(id -u)} -ne 0 ]] || die "Run this lab as a regular user, not as root."
safe_lab_path

if [[ -e "$LAB" ]]; then
  [[ -f "$LAB/$MARKER" ]] || die "$LAB exists and is not an nvlab directory; set NVLAB_ROOT to another path"
  rm -rf -- "$LAB"
fi

mkdir -p "$LAB/.nvlab" "$LAB/bin" "$LAB/etc/ai-platform" "$LAB/manifests" "$LAB/state"
echo "nvlab nca-aiio 1.2 created $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LAB/$MARKER"

# =============================================================================
# ENVIRONMENT SETUP & SIMULATED HARDWARE TOPOLOGY
# =============================================================================

# State files representing physical GPU hardware status
# GPU 0: SXM5 80GB (intended for Training)
# GPU 1: SXM5 80GB (intended for Inference / Multi-Tenant MIG)
cat > "$LAB/state/hardware.json" <<'EOF'
{
  "system": "NVIDIA DGX H100 / HGX H100",
  "gpus": [
    {
      "index": 0,
      "model": "NVIDIA H100 80GB HBM3",
      "form_factor": "SXM5",
      "nvlink_bandwidth": "900 GB/s",
      "mig_mode": "Enabled",
      "mig_instances": ["MIG-3g.40gb-0"],
      "intended_workload": "Distributed Pre-training"
    },
    {
      "index": 1,
      "model": "NVIDIA H100 80GB HBM3",
      "form_factor": "SXM5",
      "nvlink_bandwidth": "900 GB/s",
      "mig_mode": "Disabled",
      "mig_instances": [],
      "intended_workload": "Real-time Multi-tenant Inference"
    }
  ],
  "network": {
    "management": "eth0 (1 Gbps)",
    "fabric_interconnect": "mlx5_0:1 (InfiniBand NDR 400 Gbps, RoCEv2 capable)"
  }
}
EOF

# =============================================================================
# BROKEN CONFIGURATIONS (THE ARCHITECTURAL CROSS-WIRE)
# =============================================================================

# 1. Training Environment Configuration: Broken fabric & wrong network interfaces
cat > "$LAB/etc/ai-platform/training-cluster.env" <<'EOF'
# =============================================================================
# Production Distributed Training Environment Configuration (NCCL & PyTorch)
# =============================================================================
# Targeted Hardware: GPU 0
GPU_TARGET_INDEX=0

# BROKEN SETTINGS:
# The junior engineer disabled InfiniBand and routed NCCL over 1GbE management!
NCCL_IB_DISABLE=1
NCCL_NET_GDR_LEVEL=0
NCCL_SOCKET_IFNAME="eth0"
NCCL_DEBUG="INFO"
NCCL_DEBUG_SUBSYS="INIT,COLL,ENV"

# PyTorch Distributed Data Parallel (DDP) / Megatron settings
MASTER_ADDR="10.240.0.10"
MASTER_PORT=29500
WORLD_SIZE=2
NNODES=2
EOF

# 2. Inference Serving Environment: Requesting non-existent RDMA & invalid device
cat > "$LAB/etc/ai-platform/inference-serving.env" <<'EOF'
# =============================================================================
# Real-Time Inference Gateway Environment (Triton Inference Server / vLLM)
# =============================================================================
# Targeted Hardware: GPU 1
GPU_TARGET_INDEX=1

# BROKEN SETTINGS:
# Inference server misconfigured to bind to InfiniBand RDMA directly!
INFERENCE_FABRIC_MODE="infiniband_rdma"
INFERENCE_HCA_DEVICE="mlx5_0:1"
INFERENCE_INGRESS_PORT=8000
INFERENCE_GRPC_PORT=8001
INFERENCE_METRICS_PORT=8002

# Concurrency & Workload slicing
ENABLE_MIG=true
REQUIRED_MIG_PROFILE="3g.40gb"
EOF

# 3. Inference Engine Runtime Configuration (KV Cache & Memory Budget)
cat > "$LAB/etc/ai-platform/inference-engine.yaml" <<'EOF'
apiVersion: inference.nvidia.com/v1alpha1
kind: EngineConfig
metadata:
  name: llama-70b-streaming-service
spec:
  model: "meta-llama/Llama-2-70b-chat-hf"
  tensor_parallel_size: 1
  pipeline_parallel_size: 1
  # BROKEN SETTINGS:
  # The engineer requested 98% memory utilization with an unquantized FP32
  # KV cache and a 65,536 token context window on a 40 GB MIG partition!
  gpu_memory_utilization: 0.98
  max_model_len: 65536
  kv_cache_dtype: "fp32"
  max_num_seqs: 256
  block_size: 16
  enforce_eager: false
EOF

# 4. Kubernetes Manifest: Training Job (Broken Lifecycle & Missing /dev/shm)
cat > "$LAB/manifests/training-job.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pytorch-distributed-training-worker
  namespace: ai-workloads
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: pytorch-worker
  template:
    metadata:
      labels:
        app: pytorch-worker
    spec:
      restartPolicy: Always
      containers:
        - name: pytorch-trainer
          image: nvcr.io/nvidia/pytorch:24.04-py3
          command: ["torchrun", "train.py"]
          resources:
            limits:
              nvidia.com/gpu: "1"
              cpu: "16"
              memory: "64Gi"
            requests:
              nvidia.com/gpu: "1"
              cpu: "16"
              memory: "64Gi"
          # BROKEN SETTING:
          # Missing /dev/shm mount! PyTorch DataLoader workers will crash with SIGBUS.
EOF

# 5. Kubernetes Manifest: Inference Service (Missing Readiness Probe & Static)
cat > "$LAB/manifests/inference-service.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-inference-gateway
  namespace: ai-serving
spec:
  replicas: 1
  selector:
    matchLabels:
      app: triton-server
  template:
    metadata:
      labels:
        app: triton-server
    spec:
      containers:
        - name: triton-server
          image: nvcr.io/nvidia/tritonserver:24.04-pyt-python-py3
          command: ["tritonserver", "--model-repository=/models"]
          ports:
            - containerPort: 8000
              name: http
            - containerPort: 8001
              name: grpc
            - containerPort: 8002
              name: metrics
          resources:
            limits:
              nvidia.com/mig-3g.40gb: "1"
            requests:
              nvidia.com/mig-3g.40gb: "1"
          # BROKEN SETTING:
          # Missing readinessProbe! Requests will be routed before model weights
          # are loaded into VRAM, causing HTTP 503 errors and SLA breaches.
EOF

# =============================================================================
# SIMULATOR & DIAGNOSTIC CLI TOOLS
# =============================================================================

# Mock: nvidia-smi with MIG management simulation
cat > "$LAB/bin/nvidia-smi" <<'SMI'
#!/usr/bin/env bash
set -euo pipefail
LAB="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
STATE="$LAB/state/hardware.json"

get_mig_mode() {
  local idx="$1"
  python3 -c "import json; data=json.load(open('$STATE')); print(data['gpus'][$idx]['mig_mode'])" 2>/dev/null
}

set_mig_mode() {
  local idx="$1"
  local mode="$2"
  python3 -c "
import json
with open('$STATE', 'r') as f:
    d = json.load(f)
d['gpus'][$idx]['mig_mode'] = '$mode'
if '$mode' == 'Disabled':
    d['gpus'][$idx]['mig_instances'] = []
with open('$STATE', 'w') as f:
    json.dump(d, f, indent=2)
"
}

add_mig_instance() {
  local idx="$1"
  local profile="$2"
  python3 -c "
import json
with open('$STATE', 'r') as f:
    d = json.load(f)
if d['gpus'][$idx]['mig_mode'] != 'Enabled':
    print('Error: MIG mode is Disabled on GPU $idx')
    exit(1)
d['gpus'][$idx]['mig_instances'].append('MIG-$profile-' + str(len(d['gpus'][$idx]['mig_instances'])))
with open('$STATE', 'w') as f:
    json.dump(d, f, indent=2)
print('Successfully created GPU instance on GPU $idx with profile $profile')
"
}

# Handle command-line arguments
if [[ "$*" == *"-mig"* || "$*" == *"--multi-instance-gpu"* ]]; then
  # e.g., nvidia-smi -i 1 -mig 1 or nvidia-smi -i 0 -mig 0
  idx=0
  for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    if [[ "$arg" == "-i" ]]; then
      next_i=$((i+1))
      idx="${!next_i}"
    fi
    if [[ "$arg" == "-mig" || "$arg" == "--multi-instance-gpu" ]]; then
      next_i=$((i+1))
      val="${!next_i}"
      if [[ "$val" == "1" ]]; then
        set_mig_mode "$idx" "Enabled"
        echo "Enabled MIG mode for GPU 00000000:0$((idx+7)):00.0"
        exit 0
      elif [[ "$val" == "0" ]]; then
        set_mig_mode "$idx" "Disabled"
        echo "Disabled MIG mode for GPU 00000000:0$((idx+7)):00.0"
        exit 0
      fi
    fi
  done
fi

if [[ "$*" == *"mig -cgi"* || "$*" == *"-cgi"* ]]; then
  # Slicing creation: nvidia-smi mig -cgi 3g.40gb -i 1
  profile="3g.40gb"
  idx=1
  for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    if [[ "$arg" == "-i" ]]; then
      next_i=$((i+1))
      idx="${!next_i}"
    elif [[ "$arg" == "-cgi" ]]; then
      next_i=$((i+1))
      profile="${!next_i}"
    fi
  done
  add_mig_instance "$idx" "$profile"
  exit 0
fi

# Default query / status print
date
echo "+-----------------------------------------------------------------------------------------+"
echo "| NVIDIA-SMI 550.54.15              Driver Version: 550.54.15      CUDA Version: 12.4     |"
echo "|-----------------------------------------+------------------------+----------------------+"
echo "| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |"
echo "| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |"
echo "|                                         |                        |               MIG M. |"
echo "|=========================================+========================+======================|"

python3 -c "
import json
with open('$STATE') as f:
    data = json.load(f)
for g in data['gpus']:
    idx = g['index']
    name = g['model']
    mig = g['mig_mode']
    bus = f'00000000:0{idx+7}:00.0'
    print(f'|   {idx}  {name:<26} On  |   {bus} Off |                    0 |')
    print(f'| N/A   38C    P0             75W / 700W |       0MiB / 81920MiB |      0%      Default |')
    print(f'|                                         |                        |             {mig:<8} |')
    print('+-----------------------------------------+------------------------+----------------------+')
"

echo
echo "+-----------------------------------------------------------------------------------------+"
echo "| MIG devices:                                                                            |"
python3 -c "
import json
with open('$STATE') as f:
    data = json.load(f)
for g in data['gpus']:
    idx = g['index']
    mig = g['mig_mode']
    inst = g['mig_instances']
    if mig == 'Enabled':
        print(f'| GPU {idx}: Active MIG Profile instances: {inst}')
    else:
        print(f'| GPU {idx}: MIG Disabled (Full Bare-Metal SXM Monolithic Device)')
"
echo "+-----------------------------------------------------------------------------------------+"
SMI
chmod 0755 "$LAB/bin/nvidia-smi"

# Simulator tool: ai-infra-sim (validates architectures and runs synthetic workloads)
cat > "$LAB/bin/ai-infra-sim" <<'SIM'
#!/usr/bin/env bash
set -euo pipefail
LAB="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CMD="${1:-test-all}"

source_env() {
  # Load env configs
  source "$LAB/etc/ai-platform/training-cluster.env"
  source "$LAB/etc/ai-platform/inference-serving.env"
}

test_training() {
  echo "================================================================================"
  echo "[TEST 1] SIMULATING DISTRIBUTED TRAINING WORKLOAD (PyTorch DDP / Megatron-LM)"
  echo "================================================================================"
  source "$LAB/etc/ai-platform/training-cluster.env"
  
  # 1. Check GPU Compute Partitioning for Training
  local mig_gpu0
  mig_gpu0="$(python3 -c "import json; print(json.load(open('$LAB/state/hardware.json'))['gpus'][0]['mig_mode'])")"
  echo "[-] Inspecting GPU 0 Compute Architecture..."
  if [[ "$mig_gpu0" == "Enabled" ]]; then
    echo "    FATAL: GPU 0 has MIG mode Enabled!"
    echo "    NCCL WARN: Direct P2P via NVLink is disabled on MIG instances."
    echo "    NCCL WARN: Inter-GPU communication falls back to slow host memory staging."
    echo "    Distributed training throughput collapsed by 88%. Training aborted."
    return 1
  else
    echo "    [OK] GPU 0 is operating in bare-metal monolithic SXM mode with 900 GB/s NVLink mesh."
  fi

  # 2. Check Interconnect Fabric Configuration
  echo "[-] Inspecting Interconnect Fabric & NCCL Transport..."
  if [[ "${NCCL_IB_DISABLE:-0}" == "1" ]]; then
    echo "    FATAL: NCCL_IB_DISABLE=1 detected!"
    echo "    NCCL WARN: InfiniBand/RoCE verbs disabled. Falling back to Linux TCP sockets."
  fi

  if [[ "${NCCL_SOCKET_IFNAME:-}" == "eth0" ]]; then
    echo "    FATAL: NCCL_SOCKET_IFNAME is set to 'eth0' (1 Gbps management link)!"
    echo "    NCCL INFO: NET/Socket: Using interface eth0 (10.240.0.10) for inter-node communication"
    echo "    NCCL WARN: AllReduce ring latency: 85,200 us (Expected: < 4.2 us on 400G NDR InfiniBand)"
    echo "    NCCL WARN: Watchdog caught collective timeout after 600 seconds. Job stalled."
    return 1
  elif [[ "${NCCL_SOCKET_IFNAME:-}" =~ (mlx5|ib) && "${NCCL_IB_DISABLE:-0}" == "0" ]]; then
    echo "    [OK] NCCL is utilizing InfiniBand/RoCE multi-rail fabric (${NCCL_SOCKET_IFNAME}) with GPUDirect RDMA."
  else
    echo "    FATAL: Invalid NCCL transport configuration: NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME:-empty}, NCCL_IB_DISABLE=${NCCL_IB_DISABLE:-empty}"
    return 1
  fi

  # 3. Check DataLoader Shared Memory (/dev/shm)
  echo "[-] Inspecting Worker Shared Memory Subsystem (/dev/shm)..."
  if ! grep -q "medium: Memory" "$LAB/manifests/training-job.yaml" 2>/dev/null || ! grep -q "/dev/shm" "$LAB/manifests/training-job.yaml" 2>/dev/null; then
    echo "    FATAL: No RAM-backed /dev/shm volume mount found in $LAB/manifests/training-job.yaml!"
    echo "    RuntimeError: DataLoader worker (pid 14209) was killed by signal 7 (SIGBUS)."
    echo "    It is highly likely that your worker process ran out of shared memory (/dev/shm)."
    echo "    Training batch generation crashed."
    return 1
  else
    echo "    [OK] /dev/shm mounted as RAM-backed emptyDir. Inter-process DataLoader queues healthy."
  fi

  # 4. Check Gang Scheduling Semantics
  echo "[-] Inspecting Kubernetes Lifecycle & Scheduling Strategy..."
  if grep -q "type: RollingUpdate" "$LAB/manifests/training-job.yaml"; then
    echo "    FATAL: Training manifest is using 'RollingUpdate' strategy!"
    echo "    Architectural Violation: Distributed training requires atomic gang scheduling."
    echo "    Rolling restarts cause immediate rank desynchronization and NCCL connection drops."
    return 1
  elif ! grep -q -E "(queue-name|pod-group|kueue|volcano)" "$LAB/manifests/training-job.yaml"; then
    echo "    WARNING: Missing gang-scheduling annotation or queue reference (e.g., kueue.x-k8s.io/queue-name)."
    return 1
  else
    echo "    [OK] Training manifest adheres to batch gang execution semantics."
  fi

  echo ">>> [TRAINING WORKLOAD SIMULATION]: PASSED"
  return 0
}

test_inference() {
  echo "================================================================================"
  echo "[TEST 2] SIMULATING REAL-TIME INFERENCE GATEWAY (Triton / vLLM)"
  echo "================================================================================"
  source "$LAB/etc/ai-platform/inference-serving.env"

  # 1. Check GPU Partitioning & MIG Slices
  echo "[-] Inspecting GPU 1 Compute Partitioning (MIG)..."
  local mig_gpu1 inst_count
  mig_gpu1="$(python3 -c "import json; print(json.load(open('$LAB/state/hardware.json'))['gpus'][1]['mig_mode'])")"
  inst_count="$(python3 -c "import json; print(len(json.load(open('$LAB/state/hardware.json'))['gpus'][1]['mig_instances']))")"

  if [[ "$mig_gpu1" != "Enabled" || "$inst_count" -eq 0 ]]; then
    echo "    FATAL: GPU 1 has MIG mode Disabled or no active slices!"
    echo "    Platform Violation: Inference node requires hardware QoS slicing (MIG)."
    echo "    Running single-stream inference on an unpartitioned monolithic SXM GPU"
    echo "    strands 85% of GPU SMs and violates multi-tenant isolation guarantees."
    echo "    Pod status: Pending (0/1 nodes available: Insufficient nvidia.com/mig-3g.40gb)."
    return 1
  else
    echo "    [OK] GPU 1 has MIG Enabled with active hardware slices ($inst_count instances)."
  fi

  # 2. Check Ingress Fabric & Network Binding
  echo "[-] Inspecting Ingress Fabric & Network Mode..."
  if [[ "${INFERENCE_FABRIC_MODE:-}" == "infiniband_rdma" ]]; then
    echo "    FATAL: Inference gateway configured with INFERENCE_FABRIC_MODE='infiniband_rdma'!"
    echo "    Runtime Error: Failed to bind dedicated HCA '${INFERENCE_HCA_DEVICE:-}'."
    echo "    Architectural Violation: North-South inference serving traffic must terminate on"
    echo "    standard Ethernet ingress / API gateways (HTTP/gRPC/REST), not multi-rail backend fabrics."
    return 1
  else
    echo "    [OK] Inference gateway configured for standard low-overhead Ethernet ingress."
  fi

  # 3. Check KV Cache Allocation & Arithmetic Intensity Limits
  echo "[-] Inspecting KV-Cache Configuration & Memory Budget..."
  local mem_util max_len kv_dtype
  mem_util="$(python3 -c "import yaml; d=yaml.safe_load(open('$LAB/etc/ai-platform/inference-engine.yaml')); print(d['spec']['gpu_memory_utilization'])")"
  max_len="$(python3 -c "import yaml; d=yaml.safe_load(open('$LAB/etc/ai-platform/inference-engine.yaml')); print(d['spec']['max_model_len'])")"
  kv_dtype="$(python3 -c "import yaml; d=yaml.safe_load(open('$LAB/etc/ai-platform/inference-engine.yaml')); print(d['spec']['kv_cache_dtype'])")"

  if (( $(echo "$mem_util > 0.90" | bc -l) )) || [ "$max_len" -gt 16384 ] || [ "$kv_dtype" == "fp32" ]; then
    echo "    FATAL: Invalid Inference Memory Sizing in inference-engine.yaml!"
    echo "    Parameters: gpu_memory_utilization=$mem_util, max_model_len=$max_len, kv_cache_dtype=$kv_dtype"
    echo "    RuntimeError: CUDA out of memory during KV-cache pre-allocation!"
    echo "    KV cache requires 96.4 GiB VRAM at FP32 with 65k context; MIG slice capacity is only 40 GiB."
    echo "    Inference engines require bounded context (<= 8192 or 16384), quantized/FP16/FP8 KV cache,"
    echo "    and conservative utilization thresholds (<= 0.90) to prevent OOM panics during dynamic batching."
    return 1
  else
    echo "    [OK] KV cache memory profile properly bounded for high-throughput token generation."
  fi

  # 4. Check Kubernetes Readiness Probes
  echo "[-] Inspecting Kubernetes Service Lifecycle & Probes..."
  if ! grep -q "readinessProbe" "$LAB/manifests/inference-service.yaml"; then
    echo "    FATAL: inference-service.yaml lacks a 'readinessProbe'!"
    echo "    Architectural Violation: Model weight loading into VRAM takes 45-120 seconds."
    echo "    Without a readiness probe on '/v2/health/ready' (port 8000), Kubernetes routes"
    echo "    ingress API traffic immediately to uninitialized pods, causing continuous HTTP 503 errors."
    return 1
  else
    echo "    [OK] Readiness probe configured. Traffic will only be routed once weights are warm in VRAM."
  fi

  echo ">>> [INFERENCE WORKLOAD SIMULATION]: PASSED"
  return 0
}

case "$CMD" in
  test-training)  test_training ;;
  test-inference) test_inference ;;
  test-all)
    echo "RUNNING FULL AI CLUSTER ARCHITECTURE VALIDATION..."
    echo
    t_ok=0; i_ok=0
    test_training && t_ok=1 || true
    echo
    test_inference && i_ok=1 || true
    echo
    if [[ $t_ok -eq 1 && $i_ok -eq 1 ]]; then
      echo ">>> ALL ARCHITECTURAL CHECKS PASSED SUCCESSFULLY."
      exit 0
    else
      echo ">>> ARCHITECTURAL VIOLATIONS DETECTED. Review errors above."
      exit 1
    fi
    ;;
  *)
    echo "Usage: ai-infra-sim [test-training|test-inference|test-all]" >&2
    exit 2
    ;;
esac
SIM
chmod 0755 "$LAB/bin/ai-infra-sim"

# Grader script: check-architecture
cat > "$LAB/bin/check-architecture" <<'CHECK'
#!/usr/bin/env bash
set -uo pipefail
LAB="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

green() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
red()   { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; }

passed=0
failed=0

run_check() {
  local desc="$1"
  shift
  if "$@"; then
    green "$desc"
    passed=$((passed + 1))
  else
    red "$desc"
    failed=$((failed + 1))
  fi
}

echo "================================================================================"
echo "NCA-AIIO 1.2: Training vs. Inference Architecture Verification"
echo "================================================================================"

# Check 1: GPU 0 Partitioning (Training)
check_gpu0_mig() {
  local mode
  mode="$(python3 -c "import json; print(json.load(open('$LAB/state/hardware.json'))['gpus'][0]['mig_mode'])")"
  [[ "$mode" == "Disabled" ]]
}
run_check "Pillar 1A: GPU 0 has MIG Disabled (Bare-metal SXM NVLink access for Training)" check_gpu0_mig

# Check 2: GPU 1 Partitioning (Inference)
check_gpu1_mig() {
  local mode count
  mode="$(python3 -c "import json; print(json.load(open('$LAB/state/hardware.json'))['gpus'][1]['mig_mode'])")"
  count="$(python3 -c "import json; print(len(json.load(open('$LAB/state/hardware.json'))['gpus'][1]['mig_instances']))")"
  [[ "$mode" == "Enabled" && "$count" -ge 1 ]]
}
run_check "Pillar 1B: GPU 1 has MIG Enabled with active hardware slices (Inference QoS)" check_gpu1_mig

# Check 3: Training Network Fabric (InfiniBand/RoCE enabled with GPUDirect RDMA)
check_training_fabric() {
  source "$LAB/etc/ai-platform/training-cluster.env"
  [[ "${NCCL_IB_DISABLE:-1}" == "0" ]] && [[ "${NCCL_SOCKET_IFNAME:-}" =~ (mlx5|ib) ]]
}
run_check "Pillar 2A: Training cluster configured for Lossless RDMA fabric (NCCL_IB_DISABLE=0, InfiniBand/RoCE interface)" check_training_fabric

# Check 4: Inference Ingress Fabric (Standard Ethernet / TCP, not backend InfiniBand)
check_inference_fabric() {
  source "$LAB/etc/ai-platform/inference-serving.env"
  [[ "${INFERENCE_FABRIC_MODE:-}" =~ (tcp|ethernet|standard) ]]
}
run_check "Pillar 2B: Inference gateway configured for standard low-latency Ethernet API ingress" check_inference_fabric

# Check 5: Training Memory Subsystem (/dev/shm mounted)
check_training_shm() {
  grep -q "/dev/shm" "$LAB/manifests/training-job.yaml" && grep -q "medium: Memory" "$LAB/manifests/training-job.yaml"
}
run_check "Pillar 3A: Training manifest mounts RAM-backed /dev/shm to prevent DataLoader deadlocks" check_training_shm

# Check 6: Inference KV Cache Sizing (Bounded memory utilization and context)
check_inference_kv() {
  python3 -c "
import yaml, sys
d = yaml.safe_load(open('$LAB/etc/ai-platform/inference-engine.yaml'))['spec']
if float(d['gpu_memory_utilization']) > 0.90: sys.exit(1)
if int(d['max_model_len']) > 16384: sys.exit(1)
if str(d['kv_cache_dtype']).lower() not in ['fp8', 'fp16', 'auto']: sys.exit(1)
sys.exit(0)
"
}
run_check "Pillar 3B: Inference engine KV-cache configured within bounded memory budget (<=90% util, <=16k len, FP8/FP16)" check_inference_kv

# Check 7: Training Orchestration (Gang scheduling semantics)
check_training_gang() {
  ! grep -q "type: RollingUpdate" "$LAB/manifests/training-job.yaml" && \
  grep -q -E "(queue-name|pod-group|kueue|volcano)" "$LAB/manifests/training-job.yaml"
}
run_check "Pillar 4A: Training manifest uses atomic gang-scheduling semantics without rolling updates" check_training_gang

# Check 8: Inference Orchestration (Readiness probe on /v2/health/ready)
check_inference_probe() {
  grep -q "readinessProbe" "$LAB/manifests/inference-service.yaml" && \
  grep -q "/v2/health/ready" "$LAB/manifests/inference-service.yaml"
}
run_check "Pillar 4B: Inference manifest implements /v2/health/ready probe to prevent cold-start 503 errors" check_inference_probe

echo "================================================================================"
echo "Result: $passed passed, $failed failed"
echo

if [[ "$failed" -eq 0 ]]; then
  echo "CLUSTER ARCHITECTURAL CONTRACT RESTORED - Lab complete."
  exit 0
else
  echo "REMAINING ARCHITECTURAL VIOLATIONS DETECTED."
  echo "Run 'ai-infra-sim test-all' to inspect detailed runtime failures."
  exit 1
fi
CHECK
chmod 0755 "$LAB/bin/check-architecture"

# Create helper environment profile
cat > "$LAB/env.sh" <<EOF
# Source this file to enter the AI Infrastructure Platform environment
export NVLAB_ROOT="$LAB"
export PATH="\$NVLAB_ROOT/bin:\$PATH"
export PYTHONPATH="\$NVLAB_ROOT:\${PYTHONPATH:-}"

echo "================================================================================"
echo "  AI Platform Architecture Lab Environment Loaded"
echo "  Sandbox Root: \$NVLAB_ROOT"
echo "  Commands available:"
echo "    nvidia-smi            - Query/manage GPU hardware & MIG configurations"
echo "    ai-infra-sim test-all - Simulate distributed training & inference workloads"
echo "    check-architecture    - Grade your cluster remediation"
echo "================================================================================"
EOF

# =============================================================================
# PRINT LAB BRIEFING & INSTRUCTIONS
# =============================================================================

cat <<EOF
================================================================================
NCA-AIIO 1.2: Compare and Contrast Training and Inference Architecture
BREAK & FIX LAB INITIALIZED
================================================================================

SCENARIO BRIEFING:
  You have inherited 'ai-infra-node-01', a high-density NVIDIA HGX/DGX H100
  system intended to host both distributed pre-training jobs and high-concurrency
  real-time inference microservices.

  A recent deployment misconfigured the infrastructure contracts across both
  tiers. The distributed training pipeline is failing with severe NCCL watchdog
  timeouts and DataLoader bus errors, while the real-time inference service is
  stuck in 'Pending' with out-of-memory errors and routing failures.

SYMPTOMS CURRENTLY ACTIVE:
  1. Training Job:
     - NCCL ring initialization fails or stalls over Linux TCP sockets (eth0).
     - PyTorch DataLoader crashes with SIGBUS (shared memory exhaustion).
     - GPU 0 has MIG enabled, breaking direct peer-to-peer (P2P) NVLink.
     - K8s manifest specifies 'RollingUpdate', which breaks gang execution.
  2. Inference Gateway:
     - Triton/vLLM attempts to bind to backend InfiniBand RDMA interfaces.
     - GPU 1 is running in monolithic mode without MIG slices, stranding VRAM.
     - Memory configuration allocates an unquantized FP32 KV cache with 65k context,
       exhausting GPU memory during pre-allocation.
     - Ingress routes requests to cold pods because readiness probes are missing.

YOUR MISSION:
  1. Load the lab environment:
       source $LAB/env.sh
  2. Inspect the failure modes with the diagnostic simulator:
       ai-infra-sim test-all
  3. Reconfigure the 4 architectural pillars:
     - Compute Partitioning:
         Disable MIG on GPU 0:
           nvidia-smi -i 0 -mig 0
         Enable MIG on GPU 1 and instantiate a 3g.40gb slice:
           nvidia-smi -i 1 -mig 1
           nvidia-smi -i 1 -cgi 3g.40gb
     - Interconnect Fabric:
         In '$LAB/etc/ai-platform/training-cluster.env', enable InfiniBand RDMA
         (NCCL_IB_DISABLE=0, bind NCCL_SOCKET_IFNAME to 'mlx5_0:1' or 'ib0').
         In '$LAB/etc/ai-platform/inference-serving.env', switch fabric mode
         to standard Ethernet/TCP ('tcp').
     - Memory Subsystems:
         In '$LAB/manifests/training-job.yaml', mount RAM-backed '/dev/shm'
         (emptyDir with medium: Memory).
         In '$LAB/etc/ai-platform/inference-engine.yaml', set realistic inference
         limits (gpu_memory_utilization <= 0.90, max_model_len <= 8192 or 16384,
         kv_cache_dtype to 'fp8' or 'fp16').
     - Orchestration & Lifecycle:
         In '$LAB/manifests/training-job.yaml', remove 'RollingUpdate' and add
         gang scheduling metadata (e.g. kueue.x-k8s.io/queue-name: training-queue).
         In '$LAB/manifests/inference-service.yaml', add a readinessProbe on
         path '/v2/health/ready' on port 8000.
  4. Validate your fix:
       check-architecture
     (or: bash break_fix.sh check)

A step-by-step commented solution is included at the end of this script file.
================================================================================
EOF

exit 0

# =============================================================================
# STEP-BY-STEP SOLUTION (COMMENTED OUT FOR REFERENCE)
# =============================================================================
#
# -----------------------------------------------------------------------------
# STEP 0: INITIAL ENVIRONMENT & PROBLEM VERIFICATION
# -----------------------------------------------------------------------------
# First, enter the sandbox environment and run the full simulator test:
#
#   source ~/nvlab_arch/env.sh
#   ai-infra-sim test-all
#
# You will see both workloads fail with explicit architectural violations:
# - Training fails due to:
#     * GPU 0 has MIG mode Enabled (NCCL P2P disabled)
#     * NCCL_IB_DISABLE=1 and NCCL_SOCKET_IFNAME="eth0" (1 Gbps socket)
#     * Missing RAM-backed /dev/shm (DataLoader SIGBUS error)
#     * RollingUpdate strategy on a distributed training job
# - Inference fails due to:
#     * GPU 1 has MIG mode Disabled (no QoS hardware slices)
#     * INFERENCE_FABRIC_MODE="infiniband_rdma" (invalid ingress transport)
#     * Out of memory during KV-cache pre-allocation (FP32 KV cache, 65k context)
#     * Missing readinessProbe on /v2/health/ready
#
# -----------------------------------------------------------------------------
# STEP 1: FIX COMPUTE PARTITIONING & TOPOLOGY (PILLAR 1)
# -----------------------------------------------------------------------------
# Architectural Reason:
# Distributed training requires monolithic, bare-metal access to the full GPU
# and high-speed NVLink mesh (900 GB/s on H100). When MIG is enabled, the GPU's
# cross-bar and NVLink P2P engine are partitioned and disabled between slices.
# Real-time multi-tenant inference, however, requires deterministic QoS isolation
# (dedicated compute engines, memory controllers, and DMA channels) to prevent
# head-of-line blocking between concurrent API consumers.
#
# Commands:
#   # 1. Disable MIG on GPU 0 (restore full SXM NVLink access for training):
#   nvidia-smi -i 0 -mig 0
#
#   # 2. Enable MIG on GPU 1 and instantiate a 3g.40gb slice (for inference):
#   nvidia-smi -i 1 -mig 1
#   nvidia-smi -i 1 -cgi 3g.40gb
#
#   # Verify with nvidia-smi:
#   nvidia-smi
#
# -----------------------------------------------------------------------------
# STEP 2: FIX INTERCONNECT & COMMUNICATION FABRIC (PILLAR 2)
# -----------------------------------------------------------------------------
# Architectural Reason:
# Distributed training is compute-bound during GEMM and communication-bound
# during gradient AllReduce. Running NCCL over standard 1 GbE management sockets
# (eth0) introduces milliseconds of latency, completely collapsing MFU (Model
# Flops Utilization). Training requires lossless InfiniBand/RoCE with GPUDirect
# RDMA.
# Inference serving terminates standard North-South user requests from API
# gateways (Envoy, Cilium, Ingress-NGINX) using standard HTTP/REST or gRPC
# over datacenter Ethernet. It should never bind to raw InfiniBand backend HCAs.
#
# Commands:
#   # 1. Fix training-cluster.env:
#   sed -i 's/NCCL_IB_DISABLE=1/NCCL_IB_DISABLE=0/' $NVLAB_ROOT/etc/ai-platform/training-cluster.env
#   sed -i 's/NCCL_NET_GDR_LEVEL=0/NCCL_NET_GDR_LEVEL=5/' $NVLAB_ROOT/etc/ai-platform/training-cluster.env
#   sed -i 's/NCCL_SOCKET_IFNAME="eth0"/NCCL_SOCKET_IFNAME="mlx5_0:1"/' $NVLAB_ROOT/etc/ai-platform/training-cluster.env
#
#   # 2. Fix inference-serving.env:
#   sed -i 's/INFERENCE_FABRIC_MODE="infiniband_rdma"/INFERENCE_FABRIC_MODE="tcp"/' $NVLAB_ROOT/etc/ai-platform/inference-serving.env
#
# -----------------------------------------------------------------------------
# STEP 3: FIX MEMORY SUBSYSTEMS & WORKLOAD PROFILES (PILLAR 3)
# -----------------------------------------------------------------------------
# Architectural Reason:
# Training: PyTorch DataLoader workers use Python multiprocessing and exchange
# batches via POSIX shared memory (/dev/shm). Standard containers default to a
# tiny 64 MB shm partition, which quickly exhausts and causes SIGBUS kernel
# kills. Mounting a RAM-backed emptyDir is mandatory in Kubernetes.
# Inference: Autoregressive decoding is strictly memory-bandwidth bound. For each
# generated token, weights and the Key-Value (KV) cache are read from HBM.
# Sizing the KV cache with 65k context and FP32 precision requires ~96 GB of
# VRAM, immediately exceeding the 40 GB capacity of a 3g.40gb slice. Tuning
# max_model_len to 8192 or 16384, setting KV cache to FP8 or FP16, and lowering
# utilization to <= 0.90 ensures predictable, low-latency token generation.
#
# Commands:
#   # 1. Mount /dev/shm in manifests/training-job.yaml:
#   # Replace the spec with a valid volume and volumeMount:
#   cat > $NVLAB_ROOT/manifests/training-job.yaml << 'EOF'
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: pytorch-distributed-training-worker
#   namespace: ai-workloads
#   labels:
#     kueue.x-k8s.io/queue-name: training-queue
# spec:
#   replicas: 2
#   selector:
#     matchLabels:
#       app: pytorch-worker
#   template:
#     metadata:
#       labels:
#         app: pytorch-worker
#         kueue.x-k8s.io/queue-name: training-queue
#     spec:
#       restartPolicy: Always
#       containers:
#         - name: pytorch-trainer
#           image: nvcr.io/nvidia/pytorch:24.04-py3
#           command: ["torchrun", "train.py"]
#           resources:
#             limits:
#               nvidia.com/gpu: "1"
#               cpu: "16"
#               memory: "64Gi"
#             requests:
#               nvidia.com/gpu: "1"
#               cpu: "16"
#               memory: "64Gi"
#           volumeMounts:
#             - mountPath: /dev/shm
#               name: dshm
#       volumes:
#         - name: dshm
#           emptyDir:
#             medium: Memory
#             sizeLimit: 16Gi
# EOF
#
#   # 2. Adjust KV-cache parameters in etc/ai-platform/inference-engine.yaml:
#   cat > $NVLAB_ROOT/etc/ai-platform/inference-engine.yaml << 'EOF'
# apiVersion: inference.nvidia.com/v1alpha1
# kind: EngineConfig
# metadata:
#   name: llama-70b-streaming-service
# spec:
#   model: "meta-llama/Llama-2-70b-chat-hf"
#   tensor_parallel_size: 1
#   pipeline_parallel_size: 1
#   gpu_memory_utilization: 0.85
#   max_model_len: 8192
#   kv_cache_dtype: "fp8"
#   max_num_seqs: 64
#   block_size: 16
#   enforce_eager: false
# EOF
#
# -----------------------------------------------------------------------------
# STEP 4: FIX ORCHESTRATION & LIFECYCLE SEMANTICS (PILLAR 4)
# -----------------------------------------------------------------------------
# Architectural Reason:
# Training jobs cannot tolerate partial rolling updates. If pod 0 restarts,
# pod 1 hangs in an unrecoverable NCCL collective timeout. Distributed training
# requires gang-scheduling (all-or-nothing allocation via Kueue or Volcano).
# Inference services, conversely, are stateless request/response engines that
# scale horizontally with HPA or KEDA. However, LLM weight loading takes tens
# of seconds. Without a readiness probe on /v2/health/ready, Kubernetes endpoints
# immediately send traffic to uninitialized pods, throwing HTTP 503 errors.
#
# Commands:
#   # Add readinessProbe to manifests/inference-service.yaml:
#   cat > $NVLAB_ROOT/manifests/inference-service.yaml << 'EOF'
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   name: triton-inference-gateway
#   namespace: ai-serving
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       app: triton-server
#   template:
#     metadata:
#       labels:
#         app: triton-server
#     spec:
#       containers:
#         - name: triton-server
#           image: nvcr.io/nvidia/tritonserver:24.04-pyt-python-py3
#           command: ["tritonserver", "--model-repository=/models"]
#           ports:
#             - containerPort: 8000
#               name: http
#             - containerPort: 8001
#               name: grpc
#             - containerPort: 8002
#               name: metrics
#           readinessProbe:
#             httpGet:
#               path: /v2/health/ready
#               port: 8000
#             initialDelaySeconds: 15
#             periodSeconds: 5
#           resources:
#             limits:
#               nvidia.com/mig-3g.40gb: "1"
#             requests:
#               nvidia.com/mig-3g.40gb: "1"
# EOF
#
# -----------------------------------------------------------------------------
# STEP 5: VERIFY REMEDIATION
# -----------------------------------------------------------------------------
# Run the simulation and the grading suite:
#
#   ai-infra-sim test-all
#   check-architecture
#
# Expected output:
#   Result: 8 passed, 0 failed
#   CLUSTER ARCHITECTURAL CONTRACT RESTORED - Lab complete.
#
# -----------------------------------------------------------------------------
# EXAM TAKEAWAYS (NCA-AIIO TOPIC 1.2)
# -----------------------------------------------------------------------------
# 1. Compute Partitioning:
#    - Training requires monolithic SXM GPUs with uninterrupted NVLink mesh.
#      MIG disables NVLink P2P and should NEVER be used for distributed training.
#    - Inference maximizes throughput and cost-efficiency via MIG hardware slices
#      (or MPS for shared memory/compute kernel multiplexing).
# 2. Network Topology:
#    - Training requires rail-optimized non-blocking InfiniBand (Quantum-2) or
#      lossless RoCEv2 with GPUDirect RDMA. A 1:1 GPU-to-HCA ratio is standard.
#    - Inference serves North-South API traffic over standard Datacenter Ethernet.
# 3. Memory & I/O Profiles:
#    - Training is compute-bound during forward/backward GEMM, requiring large
#      RAM-backed /dev/shm for PyTorch DataLoader multiprocessing.
#    - Inference decode is memory-bandwidth bound (~1 FLOP/byte). The KV cache
#      must be carefully sized and quantized (FP8/FP16) to avoid VRAM OOM panics.
# 4. Orchestration & Resilience:
#    - Training jobs use batch gang scheduling (Kueue, Volcano, PyTorchJob).
#      Any single node failure terminates the gang to reload from a checkpoint.
#    - Inference services use standard Deployments with KEDA/HPA autoscaling
#      and mandatory /v2/health/ready probes.
# =============================================================================