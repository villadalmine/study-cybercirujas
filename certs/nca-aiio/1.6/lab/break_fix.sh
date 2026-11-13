#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO | Topic 1.6 - Explain the purpose and use case of various NVIDIA solutions
# Lab type : BREAK & FIX (safe, offline, no GPU required, no root required)
# Target   : a DISPOSABLE lab VM. Everything lives under $LAB_DIR; nothing else
#            on the system is touched. No packages installed, no network used.
#
# Scenario:
#   You are the platform engineer of "Acme AI". A teammate prepared three
#   artifacts for a new image-classification inference service, and all three
#   are broken in ways that show they mixed up WHICH NVIDIA solution does WHAT:
#
#     1. A Triton Inference Server model repository  (serving layer)
#     2. A Kubernetes Pod manifest for a GPU node      (GPU Operator / device plugin / GFD)
#     3. A "solution intake map" that the architecture board uses to route
#        requirements to the right NVIDIA product      (the exam objective itself)
#
#   Your job: make `./this-script.sh check` report ALL GREEN.
#
# Usage:
#   ./break_fix.sh break    # create the broken lab
#   ./break_fix.sh check    # validate your fixes (run as often as you like)
#   ./break_fix.sh status   # show the scenario and what to achieve again
#   ./break_fix.sh reset    # delete the lab directory (only the lab)
#
# Override the location with: LAB_DIR=/tmp/mylab ./break_fix.sh break
#
# Official references:
#   - NVIDIA NCA-AIIO exam guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   - AI Infrastructure and Operations Fundamentals (NVIDIA Academy):
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   - TensorRT: https://developer.nvidia.com/tensorrt
#   - AI inference (Triton, TensorRT, NIM): https://developer.nvidia.com/topics/ai/ai-inference
#   - Storage for AI (GPUDirect Storage): https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
#   - LLM use cases: https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
#   - GPU Operator: https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
#   - Triton model repository layout:
#     https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/user_guide/model_repository.html
#   - Kubernetes GPU scheduling (extended resources, limits):
#     https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/
#
# NOTE: The "model.onnx" created here is a placeholder file, not a real network.
#       The checker validates layout and configuration exactly the way Triton and
#       the Kubernetes API server would reject them; messages tagged [simulated]
#       paraphrase the real component's behavior.
# =============================================================================

set -uo pipefail

LAB_DIR="${LAB_DIR:-$HOME/nca-aiio-lab-1.6}"
MARKER=".nca-aiio-lab-1.6"
REPO="$LAB_DIR/model_repository"
MODEL_DIR="$REPO/resnet50"
POD_FILE="$LAB_DIR/k8s/triton-gpu-pod.yaml"
MAP_FILE="$LAB_DIR/solution-map.conf"

if [[ -t 1 ]]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; BLD=""; RST=""
fi

ok()   { printf '  %s[PASS]%s %s\n' "$GRN" "$RST" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
hint() { printf '         %shint:%s %s\n' "$YLW" "$RST" "$*"; }
sim()  { printf '         %s[simulated]%s %s\n' "$BLU" "$RST" "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$BLD" "$*" "$RST"; }

die() { printf '%sERROR:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

safety_checks() {
  [[ "${BASH_VERSINFO[0]}" -ge 4 ]] || die "bash >= 4 required (associative arrays)."
  case "$LAB_DIR" in
    ""|"/"|"$HOME"|"$HOME/"|"/root"|"/home"|"/tmp"|"/var"|"/etc"|"/usr")
      die "Refusing to use LAB_DIR='$LAB_DIR'. Point it to a dedicated directory." ;;
  esac
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  safety_checks
  if [[ -e "$LAB_DIR" && ! -f "$LAB_DIR/$MARKER" ]]; then
    die "$LAB_DIR exists and is not a lab directory created by this script. Choose another LAB_DIR."
  fi
  rm -rf -- "$LAB_DIR"
  mkdir -p "$MODEL_DIR" "$LAB_DIR/k8s"
  touch "$LAB_DIR/$MARKER"

  # --- Fault 1: Triton model repository -------------------------------------
  #  a) model file at the model root instead of a numeric version directory
  #  b) config "name" does not match the directory name
  #  c) platform says TensorRT engine, but the artifact is an ONNX file
  printf 'PLACEHOLDER-ONNX-GRAPH resnet50 opset17 (lab file, not a real model)\n' \
    > "$MODEL_DIR/model.onnx"

  cat > "$MODEL_DIR/config.pbtxt" <<'EOF'
name: "resnet-50"
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
    name: "probabilities"
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
dynamic_batching {
  max_queue_delay_microseconds: 100
}
EOF

  # --- Fault 2: Kubernetes Pod for a GPU node ---------------------------------
  #  a) nodeSelector value is a YAML boolean (labels must be strings)
  #  b) wrong extended-resource name (the device plugin advertises nvidia.com/gpu)
  cat > "$POD_FILE" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: triton-resnet50
  namespace: inference
  labels:
    app: triton-resnet50
spec:
  restartPolicy: Always
  nodeSelector:
    nvidia.com/gpu.present: true
  containers:
    - name: triton
      image: nvcr.io/nvidia/tritonserver:24.08-py3
      args:
        - tritonserver
        - --model-repository=/models
      ports:
        - name: http
          containerPort: 8000
        - name: grpc
          containerPort: 8001
        - name: metrics
          containerPort: 8002
      resources:
        limits:
          nvidia/gpu: 1
      volumeMounts:
        - name: models
          mountPath: /models
  volumes:
    - name: models
      persistentVolumeClaim:
        claimName: triton-model-repo
EOF

  # --- Fault 3: solution intake map -------------------------------------------
  cat > "$MAP_FILE" <<'EOF'
# Acme AI - architecture board intake map
# Format: <requirement_key> = <NVIDIA solution that addresses it>
# Some entries are correct, some were swapped by mistake.

# Install/upgrade GPU driver, container toolkit, device plugin, GFD, DCGM exporter on K8s nodes
k8s_gpu_stack_lifecycle = TensorRT

# Per-GPU health, temperature, ECC, XID errors and utilization metrics for Prometheus
gpu_health_telemetry = NeMo

# Compile a trained network into an optimized engine (layer fusion, FP16/INT8, kernel autotuning)
model_compile_optimize = GPU Operator

# Serve many models from many frameworks (ONNX, PyTorch, TensorRT) with dynamic batching over HTTP/gRPC
inference_serving = Triton Inference Server

# Optimized inference engine for large language models (in-flight batching, paged KV cache)
llm_inference_engine = TensorRT-LLM

# Pre-packaged, optimized model containers with a standard API, deployable anywhere in minutes
packaged_model_microservice = NIM

# Build, customize (fine-tune, PEFT), and guardrail LLMs and generative AI models
llm_customization = DCGM

# DMA path between NVMe/NFS storage and GPU memory, bypassing the CPU bounce buffer
storage_to_gpu_io = RAPIDS

# GPU-accelerated dataframes and ETL with a pandas-like API
gpu_dataframe_etl = GPUDirect Storage

# Split one A100/H100 into hardware-isolated GPU instances for multiple tenants
gpu_partitioning = MIG

# Licensed, supported software suite (frameworks, NIM, Triton, operators) for production
enterprise_support_suite = NVIDIA AI Enterprise
EOF

  printf '%sLab created in %s%s\n' "$GRN" "$LAB_DIR" "$RST"
  do_status
}

# -----------------------------------------------------------------------------
# STATUS / SCENARIO
# -----------------------------------------------------------------------------
do_status() {
  cat <<EOF

${BLD}SCENARIO${RST}
  Files to fix:
    $MODEL_DIR/
    $POD_FILE
    $MAP_FILE

${BLD}SYMPTOMS YOU WOULD SEE ON A REAL PLATFORM${RST}
  1) Triton Inference Server starts but the model never becomes READY:
       - the server polls the repository and finds no numeric version directory
         under resnet50/, so there is no version to load;
       - the config "name" disagrees with the directory name;
       - the config asks the TensorRT backend to load a .plan engine, but the
         artifact delivered is ONNX. curl localhost:8000/v2/models/resnet50/ready
         would not return HTTP 200.

  2) kubectl apply -f k8s/triton-gpu-pod.yaml is rejected by the API server:
       Pod in version "v1" cannot be handled as a Pod: json: cannot unmarshal
       bool into Go struct field PodSpec.spec.nodeSelector of type string
     After fixing that, the Pod stays Pending forever with an event similar to:
       0/3 nodes are available: 3 Insufficient nvidia/gpu.
     because the NVIDIA device plugin (deployed by the GPU Operator) advertises
     a different extended resource name.

  3) The architecture board is routing requests to the wrong teams: telemetry
     tickets go to the LLM team, storage tickets go to the data-science team...

${BLD}WHAT YOU MUST ACHIEVE${RST}
  - Triton repo follows <repo>/<model>/config.pbtxt + <repo>/<model>/<version>/<file>,
    config name == directory name, and the backend matches the artifact you have.
    (You only have ONNX and no GPU here: think about why you cannot just rename it.)
  - The Pod is accepted by the API server and requests the GPU resource that the
    device plugin actually advertises, on nodes labeled by GPU Feature Discovery.
  - Every entry in solution-map.conf names the NVIDIA solution whose PURPOSE matches.

  Then run: $0 check
EOF
}

# -----------------------------------------------------------------------------
# CHECKS
# -----------------------------------------------------------------------------
FAILS=0
fail() { bad "$1"; shift; for h in "$@"; do hint "$h"; done; FAILS=$((FAILS + 1)); }

check_triton() {
  hdr "1. Triton model repository ($REPO)"
  local cfg="$MODEL_DIR/config.pbtxt"

  if [[ ! -f "$cfg" ]]; then
    fail "config.pbtxt missing in $MODEL_DIR" \
         "Triton expects <repo>/<model_name>/config.pbtxt"
    return
  fi

  # Version directory
  local versions
  versions=$(find "$MODEL_DIR" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' | wc -l)
  if [[ "$versions" -ge 1 ]]; then
    ok "numeric version directory present"
  else
    fail "no numeric version directory under resnet50/" \
         "Model files live in <model>/<version>/, e.g. resnet50/1/"
    sim "Triton: no version subdirectory found for 'resnet50', model unavailable"
  fi

  if [[ -f "$MODEL_DIR/1/model.onnx" ]]; then
    ok "resnet50/1/model.onnx found"
  else
    fail "resnet50/1/model.onnx not found" \
         "Default filename for the ONNX Runtime backend is model.onnx inside the version dir"
  fi

  if [[ -f "$MODEL_DIR/model.onnx" ]]; then
    fail "stray model.onnx at the model root" \
         "Triton ignores files next to config.pbtxt; move it, do not copy it"
  fi

  # Top-level name (first 'name:' line is the model name; inputs/outputs come later)
  local mname
  mname=$(awk -F'"' '/^[[:space:]]*name:/ {print $2; exit}' "$cfg")
  if [[ "$mname" == "resnet50" ]]; then
    ok "config name matches directory name (resnet50)"
  else
    fail "config name is '${mname:-<empty>}' but the directory is 'resnet50'" \
         "If 'name' is set, it must equal the model directory name"
    sim "Triton: model name in config does not match directory, model not loaded"
  fi

  # Backend vs artifact
  if grep -Eq '^[[:space:]]*platform:[[:space:]]*"tensorrt_plan"' "$cfg"; then
    fail "platform is tensorrt_plan but the artifact is ONNX" \
         "tensorrt_plan expects a serialized TensorRT engine (model.plan) built by trtexec on the target GPU" \
         "With an ONNX file, use the ONNX Runtime backend (or build an engine later, on the GPU node)"
    sim "Triton: unable to deserialize TensorRT engine from model file"
  elif grep -Eq '^[[:space:]]*platform:[[:space:]]*"onnxruntime_onnx"' "$cfg" \
    || grep -Eq '^[[:space:]]*backend:[[:space:]]*"onnxruntime"' "$cfg"; then
    ok "backend matches the ONNX artifact (onnxruntime)"
  else
    fail "no valid platform/backend for an ONNX model" \
         "Accepted: platform: \"onnxruntime_onnx\"  or  backend: \"onnxruntime\""
  fi
}

check_pod() {
  hdr "2. Kubernetes GPU Pod ($POD_FILE)"
  if [[ ! -f "$POD_FILE" ]]; then
    fail "Pod manifest missing" "Run '$0 reset' and '$0 break' to recreate it"
    return
  fi

  if grep -Eq '^[[:space:]]+nvidia\.com/gpu\.present:[[:space:]]*("true"|'"'"'true'"'"')[[:space:]]*$' "$POD_FILE"; then
    ok "nodeSelector value is a string"
  else
    fail "nodeSelector 'nvidia.com/gpu.present' is not the string \"true\"" \
         "Label values are strings; an unquoted true is a YAML boolean" \
         "This label is applied by GPU Feature Discovery (deployed by the GPU Operator)"
    sim "API server: cannot unmarshal bool into Go struct field PodSpec.spec.nodeSelector of type string"
  fi

  if grep -Eq '(^|[[:space:]])nvidia/gpu[[:space:]]*:' "$POD_FILE"; then
    fail "resource 'nvidia/gpu' is not advertised by any device plugin" \
         "Check: kubectl get node <gpu-node> -o jsonpath='{.status.allocatable}'"
    sim "Scheduler: 0/3 nodes are available: 3 Insufficient nvidia/gpu."
  fi

  if awk '
      /^[[:space:]]*limits:[[:space:]]*$/ {inl=1; next}
      inl && /^[[:space:]]*nvidia\.com\/gpu:[[:space:]]*"?1"?[[:space:]]*$/ {found=1}
      inl && /^[[:space:]]*[a-zA-Z]+:[[:space:]]*$/ && !/limits:/ {inl=0}
      END {exit found ? 0 : 1}' "$POD_FILE"; then
    ok "resources.limits requests nvidia.com/gpu: 1"
  else
    fail "resources.limits does not contain 'nvidia.com/gpu: 1'" \
         "GPUs are extended resources: set them under limits (requests, if set, must equal limits)"
  fi
}

norm() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/nvidia//g; s/[^a-z0-9]//g'; }

check_map() {
  hdr "3. Solution intake map ($MAP_FILE)"
  if [[ ! -f "$MAP_FILE" ]]; then
    fail "solution-map.conf missing" "Run '$0 reset' and '$0 break' to recreate it"
    return
  fi

  declare -A expect=(
    [k8s_gpu_stack_lifecycle]="gpuoperator"
    [gpu_health_telemetry]="dcgm dcgmexporter datacentergpumanager"
    [model_compile_optimize]="tensorrt"
    [inference_serving]="triton tritoninferenceserver tritonserver"
    [llm_inference_engine]="tensorrtllm trtllm"
    [packaged_model_microservice]="nim nims nimmicroservice nimmicroservices"
    [llm_customization]="nemo nemoframework nemocustomizer"
    [storage_to_gpu_io]="gpudirectstorage gds magnumiogds"
    [gpu_dataframe_etl]="rapids rapidscudf cudf"
    [gpu_partitioning]="mig multiinstancegpu"
    [enterprise_support_suite]="aienterprise nvaie"
  )
  declare -A why=(
    [k8s_gpu_stack_lifecycle]="Which operator automates driver, toolkit, device plugin and GFD on every GPU node?"
    [gpu_health_telemetry]="Which tool collects GPU health/telemetry and exposes it to Prometheus via an exporter?"
    [model_compile_optimize]="Which SDK turns a trained model into an optimized inference engine?"
    [inference_serving]="Which open-source server serves models from multiple frameworks?"
    [llm_inference_engine]="Which library specializes TensorRT for LLM inference?"
    [packaged_model_microservice]="Which offering ships optimized models as ready-to-run microservices?"
    [llm_customization]="Which framework builds and customizes generative AI / LLM models?"
    [storage_to_gpu_io]="Which Magnum IO technology moves data between storage and GPU memory directly?"
    [gpu_dataframe_etl]="Which suite of libraries accelerates data science / dataframes on GPUs?"
    [gpu_partitioning]="Which feature partitions one GPU into isolated instances?"
    [enterprise_support_suite]="Which suite is the supported, licensed enterprise AI software platform?"
  )

  declare -A got=()
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *"="* ]] || continue
    key=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"${line%%=*}")
    val=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"${line#*=}")
    got[$key]="$val"
  done < "$MAP_FILE"

  local k n a matched
  for k in "${!expect[@]}"; do
    if [[ -z "${got[$k]:-}" ]]; then
      fail "$k: entry missing" "${why[$k]}"
      continue
    fi
    n=$(norm "${got[$k]}")
    matched=0
    for a in ${expect[$k]}; do [[ "$n" == "$a" ]] && matched=1 && break; done
    if [[ "$matched" -eq 1 ]]; then
      ok "$k = ${got[$k]}"
    else
      fail "$k = ${got[$k]}  (wrong solution for this purpose)" "${why[$k]}"
    fi
  done
}

do_check() {
  safety_checks
  [[ -f "$LAB_DIR/$MARKER" ]] || die "No lab found in $LAB_DIR. Run: $0 break"
  FAILS=0
  check_triton
  check_pod
  check_map
  echo
  if [[ "$FAILS" -eq 0 ]]; then
    printf '%s%sALL GREEN: Triton would load resnet50, the Pod would schedule on a GPU node,\nand every requirement is routed to the right NVIDIA solution.%s\n' "$GRN" "$BLD" "$RST"
    return 0
  else
    printf '%s%s%d problem(s) remaining.%s Fix them and run: %s check\n' "$RED" "$BLD" "$FAILS" "$RST" "$0"
    return 1
  fi
}

do_reset() {
  safety_checks
  if [[ -f "$LAB_DIR/$MARKER" ]]; then
    rm -rf -- "$LAB_DIR"
    printf '%sLab removed: %s%s\n' "$GRN" "$LAB_DIR" "$RST"
  else
    printf 'Nothing to remove (no lab marker in %s).\n' "$LAB_DIR"
  fi
}

case "${1:-help}" in
  break)  do_break ;;
  check)  do_check ;;
  status) do_status ;;
  reset)  do_reset ;;
  *)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
esac

# =============================================================================
# SOLUTION (read only after trying!)
# =============================================================================
# L=${LAB_DIR:-$HOME/nca-aiio-lab-1.6}
#
# --- Fault 1: Triton model repository ---------------------------------------
# Triton requires <repo>/<model>/<version>/<file>. Files next to config.pbtxt
# are not a loadable version.
#   mkdir -p "$L/model_repository/resnet50/1"
#   mv "$L/model_repository/resnet50/model.onnx" "$L/model_repository/resnet50/1/model.onnx"
#
# The config name must equal the directory name:
#   sed -i 's/^name: "resnet-50"/name: "resnet50"/' "$L/model_repository/resnet50/config.pbtxt"
#
# The artifact is ONNX, so use the ONNX Runtime backend:
#   sed -i 's/^platform: "tensorrt_plan"/platform: "onnxruntime_onnx"/' "$L/model_repository/resnet50/config.pbtxt"
#
# Why not just rename model.onnx to model.plan? A TensorRT engine is a
# serialized, GPU-architecture- and TensorRT-version-specific artifact produced
# by the TensorRT builder (e.g. `trtexec --onnx=model.onnx --saveEngine=model.plan
# --fp16` run ON the target GPU type). Renaming an ONNX file does not make it an
# engine. Production path: serve ONNX first with Triton's ONNX Runtime backend
# (optionally with its TensorRT execution provider), then build a real .plan on
# the GPU node and switch platform to tensorrt_plan for lower latency.
#
# --- Fault 2: Kubernetes GPU Pod --------------------------------------------
# Label values are strings; quote the boolean:
#   sed -i 's#nvidia.com/gpu.present: true#nvidia.com/gpu.present: "true"#' "$L/k8s/triton-gpu-pod.yaml"
#
# The NVIDIA device plugin (installed and managed by the GPU Operator)
# advertises the extended resource nvidia.com/gpu:
#   sed -i 's#nvidia/gpu: 1#nvidia.com/gpu: 1#' "$L/k8s/triton-gpu-pod.yaml"
#
# On a real cluster you would verify with:
#   kubectl get nodes -L nvidia.com/gpu.present
#   kubectl get node <gpu-node> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
#   kubectl get pods -n gpu-operator      # driver, toolkit, device-plugin, gfd, dcgm-exporter
#   kubectl describe pod triton-resnet50 -n inference | sed -n '/Events/,$p'
#
# --- Fault 3: solution intake map -------------------------------------------
#   sed -i 's/^k8s_gpu_stack_lifecycle = .*/k8s_gpu_stack_lifecycle = GPU Operator/'  "$L/solution-map.conf"
#   sed -i 's/^gpu_health_telemetry = .*/gpu_health_telemetry = DCGM/'                "$L/solution-map.conf"
#   sed -i 's/^model_compile_optimize = .*/model_compile_optimize = TensorRT/'        "$L/solution-map.conf"
#   sed -i 's/^llm_customization = .*/llm_customization = NeMo/'                      "$L/solution-map.conf"
#   sed -i 's/^storage_to_gpu_io = .*/storage_to_gpu_io = GPUDirect Storage/'         "$L/solution-map.conf"
#   sed -i 's/^gpu_dataframe_etl = .*/gpu_dataframe_etl = RAPIDS/'                    "$L/solution-map.conf"
#
# Rationale (the exam objective):
#   GPU Operator         -> lifecycle of the GPU software stack on Kubernetes nodes
#                           (driver, container toolkit, device plugin, GFD, DCGM exporter, MIG manager)
#   DCGM / DCGM Exporter -> GPU health, diagnostics and telemetry (Prometheus metrics)
#   TensorRT             -> inference optimizer/runtime: fusion, precision calibration (FP16/INT8/FP8),
#                           kernel auto-tuning -> serialized engine
#   TensorRT-LLM         -> TensorRT specialized for LLMs (in-flight batching, paged KV cache)
#   Triton               -> multi-framework inference server, dynamic batching, HTTP/gRPC, metrics
#   NIM                  -> prebuilt, optimized inference microservices with standard APIs
#   NeMo                 -> build/customize/guardrail generative AI and LLMs
#   GPUDirect Storage    -> direct DMA path storage <-> GPU memory (Magnum IO), no CPU bounce buffer
#   RAPIDS               -> GPU-accelerated data science (cuDF, cuML) for ETL/feature engineering
#   MIG                  -> hardware partitioning of one GPU into isolated instances
#   NVIDIA AI Enterprise -> supported, licensed software suite bundling the above for production
#
# --- Verify ------------------------------------------------------------------
#   ./break_fix.sh check     # expect: ALL GREEN
#   ./break_fix.sh reset     # clean up the disposable lab
# =============================================================================