#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 1.5: Explain the key AI use cases and industries
# Break & Fix lab: "The AI Workload Placement Review Board"
#
# Run this ONLY on a disposable lab VM. The script does not need root and only
# writes inside a single lab directory (default: $HOME/aiio-lab-1.5).
#
# Scenario
# --------
# You are the platform engineer of a company that runs AI workloads for six
# internal business units, each in a different industry. Before a workload is
# promoted, a "placement review gate" (bin/placement-gate) checks that each
# use case is mapped to the workload profile its industry actually needs:
#
#   - workload type   : training | inference-batch | inference-realtime
#   - deployment      : datacenter | edge | public-cloud
#   - accelerator     : gpu | cpu
#   - optimizer       : none | tensorrt   (TensorRT / TensorRT-LLM for inference)
#   - latency budget  : end-to-end milliseconds the business can tolerate
#   - storage tier    : nvme-local | parallel-fs | object
#   - data class      : public | internal | pci | phi
#
# A junior engineer "simplified" the catalog by copy-pasting one generic
# profile everywhere. Several use cases are now mapped to a profile that
# cannot satisfy their industry's requirements, and the gate blocks the
# rollout of the whole platform.
#
# Usage
# -----
#   ./break_fix.sh            # build the lab and break it
#   ./break_fix.sh --verify   # run the placement gate (exit 0 = fixed)
#   ./break_fix.sh --reset    # remove the lab directory (also: --cleanup)
#
# Then:
#   ~/aiio-lab-1.5/bin/placement-gate            # see the symptom
#   ~/aiio-lab-1.5/bin/placement-gate --explain  # see each rule's rationale
#
# References (official sources):
#   - NVIDIA AI Infrastructure and Operations Fundamentals (NCA-AIIO course)
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   - NCA-AIIO exam study guide
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   - AI inference overview: https://developer.nvidia.com/topics/ai/ai-inference
#   - TensorRT: https://developer.nvidia.com/tensorrt
#   - Storage for AI training and inference:
#     https://developer.nvidia.com/blog/tips-on-scaling-storage-for-ai-training-and-inferencing/
#   - What are LLMs used for:
#     https://blogs.nvidia.com/blog/what-are-large-language-models-used-for/
#   - NVIDIA GPU Operator:
#     https://developer.nvidia.com/blog/nvidia-gpu-operator-simplifying-gpu-management-in-kubernetes
# =============================================================================

set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/aiio-lab-1.5}"
MARKER="$LAB_DIR/.aiio-lab-1.5"

say()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Safety checks
# ----------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  warn "You are running as root. This lab does not need root; continuing anyway."
fi

if command -v systemd-detect-virt >/dev/null 2>&1; then
  if [[ "$(systemd-detect-virt 2>/dev/null || true)" == "none" ]]; then
    warn "This does not look like a VM. The lab is harmless (it only writes to"
    warn "$LAB_DIR), but it is meant for a disposable lab machine."
  fi
fi

for bin in grep sed awk cut; do
  command -v "$bin" >/dev/null 2>&1 || die "Required tool '$bin' not found."
done

# ----------------------------------------------------------------------------
# --reset
# ----------------------------------------------------------------------------
if [[ "${1:-}" == "--verify" ]]; then
  [[ -x "$LAB_DIR/bin/placement-gate" ]] || die "Lab not set up: run $0 first."
  exec "$LAB_DIR/bin/placement-gate"
fi

if [[ "${1:-}" == "--reset" || "${1:-}" == "--cleanup" ]]; then
  if [[ -d "$LAB_DIR" && -f "$MARKER" ]]; then
    rm -rf -- "$LAB_DIR"
    say "Lab directory $LAB_DIR removed."
  elif [[ -d "$LAB_DIR" ]]; then
    die "$LAB_DIR exists but has no lab marker; refusing to delete it."
  else
    say "Nothing to reset."
  fi
  exit 0
fi

if [[ -d "$LAB_DIR" && ! -f "$MARKER" ]]; then
  die "$LAB_DIR already exists and was not created by this lab. Set LAB_DIR to another path."
fi

rm -rf -- "$LAB_DIR"
mkdir -p "$LAB_DIR"/{usecases,bin,docs}
touch "$MARKER"

# ----------------------------------------------------------------------------
# Industry requirements reference (what the student should reason from)
# ----------------------------------------------------------------------------
cat > "$LAB_DIR/docs/industry-requirements.txt" <<'EOF'
AI USE CASES BY INDUSTRY - PLACEMENT REQUIREMENTS (internal policy)
===================================================================

Financial services - real-time fraud detection
  * Every card authorization is scored inline, before approval.
  * The scoring path has a tight end-to-end budget (<= 50 ms).
  * Runs as real-time inference on GPUs in the bank's datacenter,
    with the model optimized for inference (TensorRT).

Healthcare - medical imaging (radiology triage)
  * Images contain PHI. Hospital policy: PHI never leaves the
    hospital's own infrastructure -> on-prem datacenter or edge only,
    never shared public cloud.
  * Real-time inference on GPU next to the PACS system.

Automotive - autonomous vehicle perception
  * Camera/lidar perception must run inside the vehicle (edge):
    no network round-trip is acceptable for safety-critical decisions.
  * Latency budget <= 30 ms per frame, GPU accelerated, TensorRT-optimized.

Retail / telecom - LLM customer-support assistant
  * Generative AI chatbot (LLM + retrieval). Interactive users expect
    fast token generation -> real-time GPU inference, served with an
    inference-optimized runtime (TensorRT-LLM).
  * CPU-only serving of a multi-billion-parameter LLM cannot meet the
    interactive latency budget.

Life sciences - drug discovery model training
  * Trains protein/molecule models on a ~120 TB dataset across many
    GPU nodes. The dataset is far larger than node-local NVMe
    (30 TB per node), so all nodes must read it from a shared
    high-throughput parallel filesystem.

Manufacturing - predictive maintenance
  * Sensor/vision inference at the factory edge, GPU accelerated,
    latency budget 100 ms.
EOF

# ----------------------------------------------------------------------------
# The placement gate (the "monitoring" the student will look at)
# ----------------------------------------------------------------------------
cat > "$LAB_DIR/bin/placement-gate" <<'EOF'
#!/usr/bin/env bash
# Placement review gate: validates each use case against its industry profile.
set -uo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UC_DIR="$LAB_DIR/usecases"
EXPLAIN=0
[[ "${1:-}" == "--explain" ]] && EXPLAIN=1

FAILS=0
PASSES=0

get() {
  # get <file> <key> -> value without inline comments or trailing spaces
  grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | tail -n1 \
    | cut -d= -f2- | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

check() {
  # check <usecase> <description> <condition-result 0/1> <rationale>
  local uc="$1" desc="$2" ok="$3" why="$4"
  if [[ "$ok" -eq 0 ]]; then
    printf '  [PASS] %-24s %s\n' "$uc" "$desc"
    PASSES=$((PASSES + 1))
  else
    printf '  [FAIL] %-24s %s\n' "$uc" "$desc"
    FAILS=$((FAILS + 1))
  fi
  [[ "$EXPLAIN" -eq 1 ]] && printf '         why: %s\n' "$why"
  return 0
}

eq()  { [[ "$1" == "$2" ]] && echo 0 || echo 1; }
ne()  { [[ "$1" != "$2" ]] && echo 0 || echo 1; }
le()  { is_int "$1" && [[ "$1" -le "$2" ]] && echo 0 || echo 1; }

echo "== AI workload placement gate =="
echo

shopt -s nullglob
files=("$UC_DIR"/*.conf)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "No use case definitions found in $UC_DIR"
  exit 2
fi

for f in "${files[@]}"; do
  uc="$(get "$f" use_case)"
  wl="$(get "$f" workload)"
  dep="$(get "$f" deployment)"
  acc="$(get "$f" accelerator)"
  opt="$(get "$f" optimizer)"
  lat="$(get "$f" latency_budget_ms)"
  sto="$(get "$f" storage)"
  dc="$(get "$f" data_class)"
  ds="$(get "$f" dataset_tb)"
  nl="$(get "$f" node_local_tb)"

  case "$uc" in
    fraud-detection)
      check "$uc" "workload is real-time inference" "$(eq "$wl" inference-realtime)" \
        "Fraud scoring happens inline in the authorization path, not in a nightly batch."
      check "$uc" "latency budget <= 50 ms" "$(le "$lat" 50)" \
        "The card network times out the authorization if scoring is slow."
      check "$uc" "GPU accelerated" "$(eq "$acc" gpu)" \
        "High-throughput, low-latency scoring of large models needs GPUs."
      check "$uc" "inference optimized with TensorRT" "$(eq "$opt" tensorrt)" \
        "TensorRT optimizes trained models for low-latency, high-throughput inference."
      ;;
    medical-imaging)
      check "$uc" "PHI stays off shared public cloud" \
        "$( [[ "$dc" == phi && "$dep" == public-cloud ]] && echo 1 || echo 0 )" \
        "Hospital policy: PHI never leaves hospital infrastructure (datacenter or edge only)."
      check "$uc" "data class declared as phi" "$(eq "$dc" phi)" \
        "Medical images contain protected health information; declassifying it is not a fix."
      check "$uc" "GPU accelerated" "$(eq "$acc" gpu)" \
        "Imaging models (CNNs/transformers on large images) need GPU inference."
      ;;
    av-perception)
      check "$uc" "deployed at the edge (in-vehicle)" "$(eq "$dep" edge)" \
        "Safety-critical perception cannot depend on a network round-trip to a datacenter."
      check "$uc" "latency budget <= 30 ms" "$(le "$lat" 30)" \
        "Each camera/lidar frame must be processed before the next one arrives."
      check "$uc" "GPU accelerated" "$(eq "$acc" gpu)" \
        "Multi-sensor perception requires an embedded GPU platform."
      check "$uc" "inference optimized with TensorRT" "$(eq "$opt" tensorrt)" \
        "Embedded edge GPUs need optimized engines to meet the frame budget."
      ;;
    llm-support)
      check "$uc" "workload is real-time inference" "$(eq "$wl" inference-realtime)" \
        "A chatbot is interactive: users wait for every generated token."
      check "$uc" "GPU accelerated" "$(eq "$acc" gpu)" \
        "Generating tokens from a multi-billion-parameter LLM on CPU misses the interactive budget."
      check "$uc" "served with TensorRT(-LLM)" "$(eq "$opt" tensorrt)" \
        "TensorRT-LLM accelerates LLM inference on NVIDIA GPUs."
      ;;
    drug-discovery)
      check "$uc" "workload is training" "$(eq "$wl" training)" \
        "This use case trains new models; it does not serve requests."
      check "$uc" "GPU accelerated" "$(eq "$acc" gpu)" \
        "Distributed training of large models runs on multi-GPU nodes."
      if is_int "$ds" && is_int "$nl" && [[ "$ds" -gt "$nl" ]]; then
        check "$uc" "dataset > node-local NVMe -> parallel-fs" "$(eq "$sto" parallel-fs)" \
          "A 120 TB dataset does not fit on 30 TB node-local NVMe; all nodes need a shared high-throughput filesystem."
      else
        check "$uc" "dataset size declared correctly" 1 \
          "dataset_tb and node_local_tb must be integers describing the real sizes (120 and 30)."
      fi
      ;;
    predictive-maintenance)
      check "$uc" "deployed at the edge (factory)" "$(eq "$dep" edge)" \
        "Sensor data is processed where it is produced, on the factory floor."
      check "$uc" "latency budget <= 100 ms" "$(le "$lat" 100)" \
        "Faults must be flagged before the line produces defective parts."
      ;;
    *)
      echo "  [WARN] unknown use case '$uc' in $(basename "$f")"
      ;;
  esac
done

echo
echo "Result: $PASSES passed, $FAILS failed"
if [[ "$FAILS" -gt 0 ]]; then
  echo "GATE: BLOCKED - platform rollout halted until every use case matches its industry profile."
  exit 1
fi
echo "GATE: OPEN - all use cases are placed correctly. Rollout approved."
exit 0
EOF
chmod +x "$LAB_DIR/bin/placement-gate"

# ----------------------------------------------------------------------------
# Use case catalog - the BROKEN state (generic profile pasted everywhere)
# ----------------------------------------------------------------------------
cat > "$LAB_DIR/usecases/10-fraud-detection.conf" <<'EOF'
use_case=fraud-detection
industry=financial-services
workload=inference-batch       # training | inference-batch | inference-realtime
deployment=datacenter          # datacenter | edge | public-cloud
accelerator=gpu                # gpu | cpu
optimizer=none                 # none | tensorrt
latency_budget_ms=5000
storage=nvme-local             # nvme-local | parallel-fs | object
data_class=pci                 # public | internal | pci | phi
EOF

cat > "$LAB_DIR/usecases/20-medical-imaging.conf" <<'EOF'
use_case=medical-imaging
industry=healthcare
workload=inference-realtime
deployment=public-cloud
accelerator=gpu
optimizer=tensorrt
latency_budget_ms=500
storage=object
data_class=phi
EOF

cat > "$LAB_DIR/usecases/30-av-perception.conf" <<'EOF'
use_case=av-perception
industry=automotive
workload=inference-realtime
deployment=datacenter
accelerator=gpu
optimizer=tensorrt
latency_budget_ms=250
storage=nvme-local
data_class=internal
EOF

cat > "$LAB_DIR/usecases/40-llm-support.conf" <<'EOF'
use_case=llm-support
industry=retail-telecom
workload=inference-realtime
deployment=datacenter
accelerator=cpu
optimizer=none
latency_budget_ms=2000
storage=nvme-local
data_class=internal
EOF

cat > "$LAB_DIR/usecases/50-drug-discovery.conf" <<'EOF'
use_case=drug-discovery
industry=life-sciences
workload=training
deployment=datacenter
accelerator=gpu
optimizer=none
latency_budget_ms=0
storage=nvme-local
dataset_tb=120
node_local_tb=30
data_class=internal
EOF

cat > "$LAB_DIR/usecases/60-predictive-maintenance.conf" <<'EOF'
use_case=predictive-maintenance
industry=manufacturing
workload=inference-realtime
deployment=edge
accelerator=gpu
optimizer=tensorrt
latency_budget_ms=100
storage=nvme-local
data_class=internal
EOF

# Pristine copy so the student can start over without rerunning the script
mkdir -p "$LAB_DIR/.broken-snapshot"
cp "$LAB_DIR"/usecases/*.conf "$LAB_DIR/.broken-snapshot/"

# ----------------------------------------------------------------------------
# Briefing
# ----------------------------------------------------------------------------
cat <<EOF

============================================================================
 LAB READY - Topic 1.5: AI use cases and industries
============================================================================

 Lab directory : $LAB_DIR
 Catalog       : $LAB_DIR/usecases/*.conf
 Requirements  : $LAB_DIR/docs/industry-requirements.txt
 Gate          : $LAB_DIR/bin/placement-gate [--explain]

 SYMPTOM
 -------
 The platform rollout is halted. Running the gate prints several [FAIL]
 lines, finishes with "GATE: BLOCKED" and exits with code 1. Six business
 units in six industries are affected; not all of them are broken.

 YOUR GOAL
 ---------
 1. Run the gate and identify which use cases are misplaced.
 2. For each failure, explain in one sentence WHY that industry's use case
    needs a different profile (real-time vs batch, edge vs datacenter,
    data residency, GPU vs CPU, TensorRT, storage tier).
 3. Edit ONLY the .conf files so that the gate prints "GATE: OPEN" and
    exits 0. Do not edit bin/placement-gate, and do not "fix" a rule by
    misdeclaring the data (for example, relabelling PHI as public).
 4. Leave predictive-maintenance untouched if it is already correct.

 Restart from the broken state at any time:
   cp $LAB_DIR/.broken-snapshot/*.conf $LAB_DIR/usecases/

 Remove the lab:
   $0 --reset
============================================================================

EOF

"$LAB_DIR/bin/placement-gate" || true

# =============================================================================
# SOLUTION (step by step) - read only after attempting the lab
# =============================================================================
#
# Step 0 - Observe the symptom
#   ~/aiio-lab-1.5/bin/placement-gate ; echo "exit=$?"
#   Expected (abridged):
#     [FAIL] fraud-detection          workload is real-time inference
#     [FAIL] fraud-detection          latency budget <= 50 ms
#     [PASS] fraud-detection          GPU accelerated
#     [FAIL] fraud-detection          inference optimized with TensorRT
#     [FAIL] medical-imaging          PHI stays off shared public cloud
#     ...
#     [FAIL] av-perception            deployed at the edge (in-vehicle)
#     [FAIL] av-perception            latency budget <= 30 ms
#     ...
#     [FAIL] llm-support              GPU accelerated
#     [FAIL] llm-support              served with TensorRT(-LLM)
#     ...
#     [FAIL] drug-discovery           dataset > node-local NVMe -> parallel-fs
#     [PASS] predictive-maintenance   deployed at the edge (factory)
#     [PASS] predictive-maintenance   latency budget <= 100 ms
#     Result: 13 passed, 10 failed
#     GATE: BLOCKED - platform rollout halted ...
#     exit=1
#
#   Use --explain to read the rationale behind each rule.
#
#   cd ~/aiio-lab-1.5/usecases
#
# Step 1 - Financial services: fraud detection is REAL-TIME inference.
#   Scoring sits inline in the card authorization path, so it cannot be a
#   batch job, and it must answer within the authorization budget. TensorRT
#   optimizes the trained model for low-latency inference on the GPU.
#     sed -i -E 's/^workload=[^ ]+/workload=inference-realtime/' 10-fraud-detection.conf
#     sed -i -E 's/^optimizer=[^ ]+/optimizer=tensorrt/'          10-fraud-detection.conf
#     sed -i -E 's/^latency_budget_ms=.*/latency_budget_ms=50/'    10-fraud-detection.conf
#
# Step 2 - Healthcare: medical imaging handles PHI.
#   Data residency, not compute, is the constraint: move the workload to the
#   hospital's own datacenter (or edge). Do NOT change data_class - the gate
#   explicitly fails if PHI is relabelled.
#     sed -i -E 's/^deployment=.*/deployment=datacenter/' 20-medical-imaging.conf
#
# Step 3 - Automotive: AV perception runs IN the vehicle (edge AI).
#   A datacenter round-trip adds network latency and a connectivity
#   dependency to a safety-critical loop. Move it to the edge and set a
#   per-frame budget.
#     sed -i -E 's/^deployment=.*/deployment=edge/'             30-av-perception.conf
#     sed -i -E 's/^latency_budget_ms=.*/latency_budget_ms=30/' 30-av-perception.conf
#
# Step 4 - Retail/telecom: the LLM assistant is interactive generative AI.
#   Serving a multi-billion-parameter LLM on CPU cannot deliver interactive
#   token rates. Use GPUs and an inference-optimized runtime (TensorRT-LLM).
#   In Kubernetes, the NVIDIA GPU Operator is what makes those GPUs
#   schedulable (driver, container toolkit, device plugin).
#     sed -i -E 's/^accelerator=.*/accelerator=gpu/'    40-llm-support.conf
#     sed -i -E 's/^optimizer=[^ ]+/optimizer=tensorrt/' 40-llm-support.conf
#
# Step 5 - Life sciences: drug discovery is a TRAINING workload with a
#   120 TB dataset and 30 TB node-local NVMe. The data does not fit locally
#   and every node must read the same data at high throughput, so it needs a
#   shared parallel filesystem (local NVMe remains useful as a cache).
#     sed -i -E 's/^storage=.*/storage=parallel-fs/' 50-drug-discovery.conf
#
# Step 6 - Manufacturing: predictive maintenance was already correct
#   (edge, GPU, 100 ms). It was a distractor; leave it as is.
#
# Step 7 - Verify
#   ~/aiio-lab-1.5/bin/placement-gate ; echo "exit=$?"
#   Expected:
#     Result: 23 passed, 0 failed
#     GATE: OPEN - all use cases are placed correctly. Rollout approved.
#     exit=0
#
# Takeaways for the exam
#   - The same model family maps to very different infrastructure depending
#     on the industry: latency (fraud, AV), data residency (healthcare),
#     location of the data source (AV, manufacturing -> edge), and data
#     scale (life sciences -> parallel storage for training).
#   - Training is throughput- and storage-bound; inference is latency- and
#     cost-per-request-bound, which is why TensorRT/TensorRT-LLM exist.
#   - Generative AI / LLM use cases (customer support, code assistants,
#     search, summarization) are interactive GPU inference workloads.
# =============================================================================