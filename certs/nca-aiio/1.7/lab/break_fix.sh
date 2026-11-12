#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO · Topic 1.7 — Software components of the AI development & deployment
#                        life cycle
# Break & Fix lab: "Training shipped the model. Production never loaded it."
# =============================================================================
#
# WHAT THIS LAB IS ABOUT
# ----------------------
# An AI model passes through several software layers between a data scientist's
# notebook and a production endpoint:
#
#   Data prep        -> RAPIDS / DALI, data on fast shared storage
#   Training         -> PyTorch / TensorFlow / NeMo inside NGC containers
#   Export           -> framework-neutral artifact (ONNX) or TorchScript
#   Optimization     -> TensorRT builds a GPU-specific engine (model.plan)
#   Serving          -> Triton Inference Server (or NVIDIA NIM, which packages it)
#                       reading a MODEL REPOSITORY
#   Orchestration    -> Kubernetes + NVIDIA GPU Operator (driver, container
#                       toolkit, device plugin, DCGM exporter)
#   Monitoring       -> DCGM exporter + Triton metrics (:8002) -> Prometheus
#
# Most "the model doesn't work in prod" incidents happen at a HANDOFF between
# two of these layers. This lab breaks the most common one: the handoff from
# training/export to serving, through the Triton model repository contract.
#
# Triton loads a model only if the repository follows strict rules:
#   <repo>/<model-name>/config.pbtxt
#   <repo>/<model-name>/<numeric-version>/<default-file-for-the-backend>
#   e.g. onnxruntime_onnx -> model.onnx, tensorrt_plan -> model.plan
# and the config's name, platform/backend and I/O data types must agree with
# the directory and the artifact.
#
# HOW THE LAB WORKS
# -----------------
# No GPU, no Docker, no 15 GB Triton image, no root. Everything lives under
# $LAB_DIR (default: ~/aiio-lab-1.7). Model files are small text PLACEHOLDERS
# whose header describes the real artifact (format, I/O tensors). A bundled
# checker, bin/triton-repo-check, applies the same load-time rules Triton
# applies and prints a Triton-style model status table. Error messages are
# modeled on Triton's, not copied byte-for-byte.
#
# USAGE
#   ./lab-1.7.sh            # build the lab and break it (same as: break)
#   ./lab-1.7.sh check      # validate the model repository (your success test)
#   ./lab-1.7.sh reset      # wipe and re-break from scratch
#   ./lab-1.7.sh cleanup    # remove everything this lab created
#
# SOURCES
#   NCA-AIIO exam guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   AI Infrastructure & Operations Fundamentals:
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   TensorRT:            https://developer.nvidia.com/tensorrt
#   AI inference:        https://developer.nvidia.com/topics/ai/ai-inference
#   Storage for AI:      https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
#   LLM use cases:       https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
#   GPU Operator:        https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
#   Triton model repository / configuration (official docs):
#     https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/user_guide/model_repository.html
#     https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/user_guide/model_configuration.html
# =============================================================================

set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/aiio-lab-1.7}"
REPO="$LAB_DIR/model_repository"
ARTIFACTS="$LAB_DIR/artifacts/training-run-0042"
STATE="$LAB_DIR/.lab"
BIN="$LAB_DIR/bin"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bld=$'\e[1m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_ylw=""; c_bld=""; c_off=""; }

die()  { echo "${c_red}ERROR:${c_off} $*" >&2; exit 1; }
info() { echo "${c_bld}==>${c_off} $*"; }

guard_lab_dir() {
  case "$LAB_DIR" in
    ""|"/"|"$HOME"|"$HOME/"|"/root"|"/home"|"/tmp"|"/etc"|"/usr"|"/var")
      die "refusing to use LAB_DIR='$LAB_DIR' (too dangerous). Point LAB_DIR to a dedicated directory." ;;
  esac
}

require_tools() {
  local t
  for t in awk sed grep find sha256sum sort tail head basename; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
  done
}

# -----------------------------------------------------------------------------
# The checker: emulates Triton's model-repository load validation
# -----------------------------------------------------------------------------
write_checker() {
  mkdir -p "$BIN"
  cat > "$BIN/triton-repo-check" <<'CHECKER'
#!/usr/bin/env bash
# triton-repo-check — lab emulation of the load-time validation that
# Triton Inference Server performs on each model in a model repository.
# Usage: triton-repo-check <model_repository> [lab_state_dir]
set -uo pipefail

REPO="${1:?usage: triton-repo-check <model_repository> [lab_state_dir]}"
STATE="${2:-}"
REQUIRED_MODELS="fraud-detector fraud-detector-trt"

row() { printf '| %-20s | %-7s | %s\n' "$1" "$2" "$3"; }

# Top-level (non-indented) string field from config.pbtxt
top_field() { sed -n -E "s/^$1:[[:space:]]*\"([^\"]*)\".*/\1/p" "$2" | head -n1; }

# data_type declared in config.pbtxt for a given input/output tensor name
cfg_io_type() {
  awk -v want="$1" '
    /^[[:space:]]+name:/      { n=$0; sub(/^[^"]*"/,"",n); sub(/".*$/,"",n); next }
    /^[[:space:]]+data_type:/ { t=$0; sub(/^.*data_type:[[:space:]]*/,"",t); sub(/[[:space:]].*$/,"",t)
                                if (n==want) { print t; exit } }
  ' "$2"
}

check_model() {
  local dir="$1" model cfg name platform backend file dmf expect_fmt ver path fmt
  local io_tag io_name io_type cfg_type want have
  model="$(basename "$dir")"
  cfg="$dir/config.pbtxt"

  if [[ ! -f "$cfg" ]]; then
    row "$model" "-" "UNAVAILABLE: Invalid argument: unable to find 'config.pbtxt' for model '$model'"
    return 1
  fi

  name="$(top_field name "$cfg")"
  if [[ -n "$name" && "$name" != "$model" ]]; then
    row "$model" "-" "UNAVAILABLE: Invalid argument: unexpected name '$name' in config.pbtxt; the model name must match its directory name '$model'"
    return 1
  fi

  platform="$(top_field platform "$cfg")"
  backend="$(top_field backend "$cfg")"
  case "${platform}/${backend}" in
    onnxruntime_onnx/|onnxruntime_onnx/onnxruntime|/onnxruntime)
      backend=onnxruntime; file=model.onnx; expect_fmt=onnx ;;
    tensorrt_plan/|tensorrt_plan/tensorrt|/tensorrt)
      backend=tensorrt;    file=model.plan; expect_fmt=tensorrt_plan ;;
    pytorch_libtorch/|pytorch_libtorch/pytorch|/pytorch)
      backend=pytorch;     file=model.pt;   expect_fmt=torchscript ;;
    /python)
      backend=python;      file=model.py;   expect_fmt=python ;;
    /)
      row "$model" "-" "UNAVAILABLE: Invalid argument: must specify 'platform' or 'backend' for '$model'"
      return 1 ;;
    *)
      row "$model" "-" "UNAVAILABLE: Invalid argument: unknown or inconsistent platform '$platform' / backend '$backend' for '$model'"
      return 1 ;;
  esac

  dmf="$(top_field default_model_filename "$cfg")"
  [[ -n "$dmf" ]] && file="$dmf"

  # Default version policy is latest{num_versions: 1}. Version directories must
  # be numeric; names that are non-numeric or start with 0 are ignored.
  ver="$(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
          | grep -E '^[1-9][0-9]*$' | sort -n | tail -n1)"
  if [[ -z "$ver" ]]; then
    local seen
    seen="$(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
    row "$model" "-" "UNAVAILABLE: Internal: at least one version must be available under the version policy of model '$model' (ignored non-numeric version dirs: ${seen:-none})"
    return 1
  fi

  path="$dir/$ver/$file"
  if [[ ! -f "$path" ]]; then
    have="$(ls -A "$dir/$ver" 2>/dev/null | tr '\n' ' ')"
    row "$model" "$ver" "UNAVAILABLE: Internal: unable to find '$path' ($backend backend expects '$file'; version dir contains: ${have:-nothing})"
    return 1
  fi

  fmt="$(sed -n -E 's/^#LABMODEL format=([^ ]+).*/\1/p' "$path" | head -n1)"
  if [[ "$fmt" != "$expect_fmt" ]]; then
    row "$model" "$ver" "UNAVAILABLE: Internal: $backend backend failed to load '$path': artifact format is '${fmt:-unknown}', expected '$expect_fmt' (renaming a file does not convert a model)"
    return 1
  fi

  if [[ -n "$STATE" && -f "$STATE/$fmt.sha256" ]]; then
    want="$(cat "$STATE/$fmt.sha256")"
    have="$(sha256sum "$path" | awk '{print $1}')"
    if [[ "$want" != "$have" ]]; then
      row "$model" "$ver" "UNAVAILABLE: lab integrity: '$path' differs from the artifact produced upstream; restore it, serving must not alter what training/optimization produced"
      return 1
    fi
  fi

  while read -r io_tag io_name io_type; do
    [[ "$io_tag" == "#io" ]] || continue
    cfg_type="$(cfg_io_type "$io_name" "$cfg")"
    if [[ -z "$cfg_type" ]]; then
      row "$model" "$ver" "UNAVAILABLE: Invalid argument: model expects tensor '$io_name' but it is not declared in config.pbtxt"
      return 1
    fi
    if [[ "$cfg_type" != "$io_type" ]]; then
      row "$model" "$ver" "UNAVAILABLE: Invalid argument: unexpected datatype $cfg_type for tensor '$io_name' of model '$model', model expects $io_type"
      return 1
    fi
  done < <(grep -E '^#io ' "$path")

  row "$model" "$ver" "READY"
  return 0
}

[[ -d "$REPO" ]] || { echo "model repository not found: $REPO" >&2; exit 2; }

rc=0
echo "+----------------------+---------+--------------------------------------"
printf '| %-20s | %-7s | %s\n' "Model" "Version" "Status"
echo "+----------------------+---------+--------------------------------------"
for d in "$REPO"/*/; do
  [[ -d "$d" ]] || continue
  check_model "${d%/}" || rc=1
done
for m in $REQUIRED_MODELS; do
  if [[ ! -d "$REPO/$m" ]]; then
    row "$m" "-" "UNAVAILABLE: model directory '$REPO/$m' is missing"
    rc=1
  fi
done
echo "+----------------------+---------+--------------------------------------"
exit "$rc"
CHECKER
  chmod +x "$BIN/triton-repo-check"
}

# -----------------------------------------------------------------------------
# Build the lab environment, then break it
# -----------------------------------------------------------------------------
write_artifacts() {
  mkdir -p "$ARTIFACTS"

  # What the training team handed off: an ONNX export of a PyTorch model.
  cat > "$ARTIFACTS/model.onnx" <<'ONNX'
#LABMODEL format=onnx opset=17 producer=pytorch-2.4 exporter=torch.onnx.export
#io INPUT__0 TYPE_FP32 30
#io OUTPUT__0 TYPE_FP32 2
# (lab placeholder: a real ONNX file is a protobuf graph, not text)
ONNX

  cat > "$ARTIFACTS/export_manifest.yaml" <<'MANIFEST'
run_id: training-run-0042
model: fraud-detector
training_container: "nvcr.io/nvidia/pytorch:24.08-py3"
export_format: onnx
onnx_opset: 17
precision: fp32
inputs:
  - name: INPUT__0
    data_type: TYPE_FP32
    dims: [30]
outputs:
  - name: OUTPUT__0
    data_type: TYPE_FP32
    dims: [2]
notes: "FP32 export. Not yet optimized with TensorRT; serve with the ONNX Runtime backend."
MANIFEST
}

write_healthy_trt_model() {
  local d="$REPO/fraud-detector-trt"
  mkdir -p "$d/1"

  # Previous model generation: already optimized with TensorRT (FP16 engine).
  cat > "$d/1/model.plan" <<'PLAN'
#LABMODEL format=tensorrt_plan precision=fp16 tensorrt=10.3 built_for=sm_90
#io INPUT__0 TYPE_FP16 30
#io OUTPUT__0 TYPE_FP16 2
# (lab placeholder: a real plan is a serialized TensorRT engine tied to GPU arch + TRT version)
PLAN

  cat > "$d/config.pbtxt" <<'CFG'
name: "fraud-detector-trt"
platform: "tensorrt_plan"
max_batch_size: 32
input [
  {
    name: "INPUT__0"
    data_type: TYPE_FP16
    dims: [ 30 ]
  }
]
output [
  {
    name: "OUTPUT__0"
    data_type: TYPE_FP16
    dims: [ 2 ]
  }
]
instance_group [
  {
    count: 1
    kind: KIND_GPU
  }
]
dynamic_batching { }
CFG
}

write_broken_onnx_model() {
  local d="$REPO/fraud-detector"
  # FAULT 3: version directory is not numeric ("v1"), Triton ignores it.
  mkdir -p "$d/v1"
  cp "$ARTIFACTS/model.onnx" "$d/v1/model.onnx"

  # The on-call engineer copied the TensorRT model's config and "adapted" it.
  # FAULT 1: name uses an underscore, directory uses a dash.
  # FAULT 2: platform still says tensorrt_plan for an ONNX artifact.
  # FAULT 4: data types still FP16, the ONNX export is FP32.
  cat > "$d/config.pbtxt" <<'CFG'
name: "fraud_detector"
platform: "tensorrt_plan"
max_batch_size: 32
input [
  {
    name: "INPUT__0"
    data_type: TYPE_FP16
    dims: [ 30 ]
  }
]
output [
  {
    name: "OUTPUT__0"
    data_type: TYPE_FP16
    dims: [ 2 ]
  }
]
instance_group [
  {
    count: 1
    kind: KIND_GPU
  }
]
dynamic_batching { }
CFG
}

write_ticket() {
  cat > "$LAB_DIR/TICKET.txt" <<'TICKET'
INC-7731  Severity: 2  Component: inference-platform

The ML team finished training run 'training-run-0042' (new fraud-detector,
exported to ONNX, FP32). It was dropped into the Triton model repository next
to the existing TensorRT model 'fraud-detector-trt'.

After the rollout, clients calling
  POST /v2/models/fraud-detector/infer
get HTTP 400 "Request for unknown model: 'fraud-detector' is not found".
Readiness for that model never turns green. The old TensorRT model keeps
serving fine.

The on-call engineer "created the config by copying the TRT one" before going
off shift.

Handoff artifacts: artifacts/training-run-0042/
TICKET
}

record_state() {
  mkdir -p "$STATE"
  echo "aiio-lab-1.7" > "$STATE/marker"
  sha256sum "$ARTIFACTS/model.onnx" | awk '{print $1}' > "$STATE/onnx.sha256"
  sha256sum "$REPO/fraud-detector-trt/1/model.plan" | awk '{print $1}' > "$STATE/tensorrt_plan.sha256"
}

briefing() {
  cat <<EOF

${c_bld}================ NCA-AIIO 1.7 · BREAK & FIX ================${c_off}
Lab directory : $LAB_DIR
Ticket        : $LAB_DIR/TICKET.txt
Handoff       : $ARTIFACTS/
Repository    : $REPO/

${c_ylw}SYMPTOM${c_off}
  Triton would refuse to load 'fraud-detector'. Clients get
  "unknown model" / readiness stays false. 'fraud-detector-trt' is READY.
  Run the checker and read the status table:

      $0 check

  The checker reports ONE error per model at a time, in the order Triton
  validates (config -> name -> backend -> version -> file -> tensors), so
  expect to iterate.

${c_ylw}YOUR GOAL${c_off}
  * '$0 check' shows BOTH models READY and exits 0.
  * Serve the artifact the training team produced, as it is
    (ONNX, FP32). Do not edit or "convert" the model file.
  * Do not touch 'fraud-detector-trt': it is in production.

${c_ylw}QUESTIONS TO ANSWER WHILE YOU FIX IT${c_off}
  1. Which lifecycle stage produced each artifact (ONNX vs plan)?
  2. Why can't you just rename model.onnx to model.plan?
  3. What would you run on a GPU node to turn this ONNX into a TensorRT
     engine, and why is that engine not portable across GPU architectures?

A full commented solution is at the bottom of this script.
EOF
}

do_break() {
  guard_lab_dir
  require_tools
  if [[ -e "$LAB_DIR" ]]; then
    if [[ -f "$STATE/marker" ]]; then
      die "lab already exists at $LAB_DIR. Use '$0 reset' to start over or '$0 check' to validate."
    fi
    [[ -z "$(ls -A "$LAB_DIR" 2>/dev/null)" ]] || die "$LAB_DIR exists and is not a lab directory; refusing to touch it."
  fi
  info "Building lab in $LAB_DIR"
  mkdir -p "$LAB_DIR" "$REPO"
  write_checker
  write_artifacts
  write_healthy_trt_model
  write_broken_onnx_model
  write_ticket
  record_state
  info "Injecting faults into the model repository... done."
  echo
  "$BIN/triton-repo-check" "$REPO" "$STATE" || true
  briefing
}

do_check() {
  guard_lab_dir
  [[ -f "$STATE/marker" ]] || die "no lab found at $LAB_DIR. Run '$0' first."
  info "Validating $REPO (Triton-style load check)"
  if "$BIN/triton-repo-check" "$REPO" "$STATE"; then
    echo
    echo "${c_grn}${c_bld}PASS${c_off}: all models READY. On a real server you would now confirm with:"
    echo "  curl -s -o /dev/null -w '%{http_code}\\n' localhost:8000/v2/models/fraud-detector/ready   # expect 200"
    return 0
  else
    echo
    echo "${c_red}${c_bld}FAIL${c_off}: at least one model is UNAVAILABLE. Fix the reported error and re-run '$0 check'."
    return 1
  fi
}

do_cleanup() {
  guard_lab_dir
  if [[ ! -e "$LAB_DIR" ]]; then
    info "Nothing to clean: $LAB_DIR does not exist."
    return 0
  fi
  [[ -f "$STATE/marker" ]] || die "$LAB_DIR has no lab marker; refusing to delete it."
  rm -rf -- "$LAB_DIR"
  info "Removed $LAB_DIR"
}

case "${1:-break}" in
  break)   do_break ;;
  check)   do_check ;;
  reset)   do_cleanup; do_break ;;
  cleanup) do_cleanup ;;
  -h|--help|help) sed -n '2,60p' "$0" ;;
  *) die "unknown command '$1' (use: break | check | reset | cleanup)" ;;
esac

exit 0

# =============================================================================
# SOLUTION (step by step) — try on your own first
# =============================================================================
#
# cd ~/aiio-lab-1.7
#
# --- Step 0: read the handoff, not the copied config --------------------------
# cat artifacts/training-run-0042/export_manifest.yaml
#   -> export_format: onnx, precision: fp32, INPUT__0 / OUTPUT__0 TYPE_FP32
# head -3 model_repository/fraud-detector/v1/model.onnx
#   #LABMODEL format=onnx opset=17 producer=pytorch-2.4 ...
#   #io INPUT__0 TYPE_FP32 30
#   #io OUTPUT__0 TYPE_FP32 2
# The source of truth for the serving config is the ARTIFACT, not the config of
# a different model that happens to share a use case.
#
# --- Step 1: model name must match the directory ------------------------------
# ./lab-1.7.sh check
#   | fraud-detector | -  | UNAVAILABLE: Invalid argument: unexpected name 'fraud_detector' ...
# sed -i 's/^name: "fraud_detector"/name: "fraud-detector"/' model_repository/fraud-detector/config.pbtxt
# (Triton identifies a model by its directory name; 'name' in config.pbtxt is
#  optional, but if present it must match. Clients call /v2/models/<dir-name>.)
#
# --- Step 2: platform must match the artifact format --------------------------
#   | fraud-detector | -  | ... (next error depends on the order you fix things)
# sed -i 's/^platform: "tensorrt_plan"/platform: "onnxruntime_onnx"/' model_repository/fraud-detector/config.pbtxt
# Equivalent modern form:  backend: "onnxruntime"
# The platform/backend decides which backend shared library loads the model and
# which default file name it looks for:
#   onnxruntime_onnx -> model.onnx     tensorrt_plan    -> model.plan
#   pytorch_libtorch -> model.pt       python backend   -> model.py
#
# --- Step 3: version directories must be numeric ------------------------------
#   | fraud-detector | -  | UNAVAILABLE: Internal: at least one version must be available ...
#                          (ignored non-numeric version dirs: v1)
# mv model_repository/fraud-detector/v1 model_repository/fraud-detector/1
# The default version policy is latest { num_versions: 1 }: Triton serves the
# highest numeric version. Rolling out a new model generation = adding
# directory "2" next to "1" (and rollback = removing it), which is how the
# serving layer participates in the model life cycle.
#
# --- Step 4: tensor data types must match the model ---------------------------
#   | fraud-detector | 1  | UNAVAILABLE: Invalid argument: unexpected datatype TYPE_FP16
#                           for tensor 'INPUT__0' ... model expects TYPE_FP32
# sed -i 's/TYPE_FP16/TYPE_FP32/g' model_repository/fraud-detector/config.pbtxt
# FP16 came from the TensorRT engine of the OLD model, which was built with
# reduced precision. The new ONNX export is FP32 until someone optimizes it.
#
# --- Step 5: verify -----------------------------------------------------------
# ./lab-1.7.sh check
#   | fraud-detector       | 1       | READY
#   | fraud-detector-trt   | 1       | READY
#   PASS: all models READY.
#
# Final model_repository/fraud-detector/config.pbtxt:
#   name: "fraud-detector"
#   platform: "onnxruntime_onnx"
#   max_batch_size: 32
#   input [
#     {
#       name: "INPUT__0"
#       data_type: TYPE_FP32
#       dims: [ 30 ]
#     }
#   ]
#   output [
#     {
#       name: "OUTPUT__0"
#       data_type: TYPE_FP32
#       dims: [ 2 ]
#     }
#   ]
#   instance_group [
#     {
#       count: 1
#       kind: KIND_GPU
#     }
#   ]
#   dynamic_batching { }
#
# --- The WRONG fix (and why the checker rejects it) ---------------------------
# mv 1/model.onnx 1/model.plan  + keep platform tensorrt_plan
#   -> "artifact format is 'onnx', expected 'tensorrt_plan' (renaming a file
#       does not convert a model)"
# A TensorRT plan is a serialized engine: kernels already selected and tuned
# for one GPU architecture and one TensorRT version. It is PRODUCED by the
# optimization stage, never by renaming.
#
# --- Answers to the questions -------------------------------------------------
# 1. model.onnx: training/export stage (PyTorch in an NGC container,
#    torch.onnx.export). model.plan: optimization stage (TensorRT).
#    Triton is the serving stage; Kubernetes + GPU Operator are the platform
#    that runs it; DCGM exporter + Triton metrics on :8002 close the loop
#    with monitoring.
# 2. Different formats, different backends. ONNX is a portable graph run by
#    ONNX Runtime (optionally with its TensorRT execution provider). A .plan is
#    a hardware-specific compiled engine run by the TensorRT backend.
# 3. On a GPU node, inside the matching NGC TensorRT/Triton container:
#      trtexec --onnx=model.onnx --saveEngine=model.plan --fp16
#    Expected tail of the output:
#      &&&& PASSED TensorRT.trtexec [TensorRT v10xxx] # trtexec --onnx=model.onnx ...
#    Then place it as fraud-detector/2/model.plan with platform "tensorrt_plan"
#    (and FP16 I/O if you build with FP16 I/O formats). Build the engine with
#    the SAME TensorRT version Triton uses and on the SAME GPU architecture
#    that will serve it; an engine built for sm_90 (H100) will not deserialize
#    on sm_80 (A100). That's why many teams ship ONNX and build engines per
#    node pool in CI, or let NIM pick a prebuilt optimized profile per GPU.
#
# --- Doing the same check against a real Triton (GPU host) --------------------
# docker run --rm --gpus all -p8000:8000 -p8001:8001 -p8002:8002 \
#   -v "$PWD/model_repository:/models" \
#   nvcr.io/nvidia/tritonserver:<yy.mm>-py3 \
#   tritonserver --model-repository=/models
# Startup prints the same kind of table:
#   +--------------------+---------+--------+
#   | Model              | Version | Status |
#   +--------------------+---------+--------+
#   | fraud-detector     | 1       | READY  |
#   | fraud-detector-trt | 1       | READY  |
#   +--------------------+---------+--------+
# curl -s -o /dev/null -w '%{http_code}\n' localhost:8000/v2/health/ready         # 200
# curl -s -o /dev/null -w '%{http_code}\n' localhost:8000/v2/models/fraud-detector/ready  # 200
# curl -s -X POST localhost:8000/v2/repository/index                              # JSON list with state per model
# curl -s localhost:8002/metrics | grep nv_inference_request_success              # per-model counters
#
# On Kubernetes the repository usually lives on shared storage (PVC / object
# store) mounted by the Triton pods; the GPU Operator provides the driver,
# NVIDIA Container Toolkit and device plugin so the pod can request
# nvidia.com/gpu. Same contract, same failure modes.
#
# Cleanup when done:
#   ./lab-1.7.sh cleanup
# =============================================================================