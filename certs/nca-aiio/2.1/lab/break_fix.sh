#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO · Topic 2.1 — Identify hardware requirements for specific AI
#                        training task use cases
# BREAK & FIX LAB: "The bill of materials that cannot train"
#
# WHAT THIS SCRIPT DOES
#   - Builds a self-contained, SIMULATED sizing environment under
#     /opt/aiio-lab-2.1 and one symlink: /usr/local/bin/aiio-sizing-check
#   - "Breaks" a cluster bill of materials (BOM), cluster.conf, the same way
#     real AI-infra teams get it wrong when they size hardware for a large
#     training job.
#
# WHAT THIS SCRIPT DOES NOT DO
#   - It needs no GPU. It does not touch drivers, kernel modules, network
#     configuration, packages or running services. Every "hardware" fact is
#     a catalog file, and every "measurement" is computed from that catalog.
#   - Run it on a disposable lab VM anyway, as every break & fix lab should be.
#
# USAGE
#   sudo ./aiio-2.1-break-fix.sh break       # build the lab and break it (default)
#   sudo ./aiio-2.1-break-fix.sh check       # run the validator
#   sudo ./aiio-2.1-break-fix.sh hint [1-3]  # progressive hints
#   sudo ./aiio-2.1-break-fix.sh reset       # restore the broken cluster.conf
#   sudo ./aiio-2.1-break-fix.sh cleanup     # remove everything this lab created
#
#   Non-interactive: AIIO_LAB_YES=1 sudo -E ./aiio-2.1-break-fix.sh break
#
# REFERENCES (official)
#   NVIDIA DGX H100 User Guide, component descriptions:
#     https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   NVIDIA DGX SuperPOD Reference Architecture (DGX B200):
#     https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#   NVLink and NVSwitch:
#     https://www.nvidia.com/en-us/data-center/nvlink/
#   Accelerating IO in the Modern Data Center: Network IO:
#     https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
#   Offloading and Isolating Data Center Workloads with BlueField DPU:
#     https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
#   NVIDIA AI Infrastructure and Operations Fundamentals (course):
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   NCA-AIIO exam study guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
# =============================================================================
set -euo pipefail

readonly LAB_DIR="/opt/aiio-lab-2.1"
readonly LINK="/usr/local/bin/aiio-sizing-check"
readonly MARKER="$LAB_DIR/.state/OWNED_BY_AIIO_LAB_2_1"
readonly SELF="$(basename "$0")"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bld=$'\e[1m'; c_rst=$'\e[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_ylw=""; c_bld=""; c_rst=""; }

die()  { printf '%sERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_ylw" "$c_rst" "$*"; }

usage() {
  sed -n '/^# USAGE/,/^# REFERENCES/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
# Preflight and safety guards
# -----------------------------------------------------------------------------
require_root() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo) on a disposable lab VM."
}

need_tools() {
  local t
  for t in awk sed sha256sum ln install basename readlink; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
  done
}

guard_paths() {
  if [[ -e "$LAB_DIR" && ! -f "$MARKER" ]]; then
    die "$LAB_DIR exists but was not created by this lab; refusing to touch it."
  fi
  if [[ -e "$LINK" || -L "$LINK" ]]; then
    if [[ ! -L "$LINK" || "$(readlink "$LINK")" != "$LAB_DIR/bin/aiio-sizing-check" ]]; then
      die "$LINK exists and does not belong to this lab; refusing to overwrite it."
    fi
  fi
}

confirm() {
  [[ "${AIIO_LAB_YES:-}" == "1" ]] && return 0
  echo "This lab creates $LAB_DIR and the symlink $LINK."
  echo "Nothing else on the system is modified (no drivers, network or services)."
  local ans=""
  read -r -p "Is this a disposable lab VM? [y/N] " ans || true
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted by user."
}

# -----------------------------------------------------------------------------
# Lab content: catalog, job spec, validator
# -----------------------------------------------------------------------------
write_catalog() {
  install -d -m 0755 "$LAB_DIR/catalog" "$LAB_DIR/job" "$LAB_DIR/bin"
  install -d -m 0700 "$LAB_DIR/.state"

  cat > "$LAB_DIR/catalog/dgx-h100.conf" <<'EOF'
# NVIDIA DGX H100 — source: DGX H100 User Guide, component descriptions
name=NVIDIA DGX H100 (8x H100 SXM5)
gpu_model=H100 SXM5
gpus_per_node=8
gpu_mem_gb=80
gpu_form_factor=SXM5
# 4th-gen NVLink, 18 links per GPU, all-to-all through NVSwitch
nvlink_gen=4
nvlink_gbs_per_gpu=900
nvswitch=yes
topo_gpu_gpu=NV18
# Compute (east-west) fabric: 4x OSFP cages serving 8x single-port ConnectX-7
compute_nic_model=ConnectX-7
max_compute_nics=8
compute_nic_gbps=400
# Storage / in-band (north-south): 2x dual-port QSFP112 ConnectX-7
storage_ports=4
EOF

  cat > "$LAB_DIR/catalog/dgx-b200.conf" <<'EOF'
# NVIDIA DGX B200 — source: DGX SuperPOD reference architecture (B200)
name=NVIDIA DGX B200 (8x B200)
gpu_model=B200
gpus_per_node=8
gpu_mem_gb=180
gpu_form_factor=SXM
# 5th-gen NVLink, 18 links per GPU, all-to-all through NVSwitch
nvlink_gen=5
nvlink_gbs_per_gpu=1800
nvswitch=yes
topo_gpu_gpu=NV18
# Compute fabric: 4x OSFP cages serving 8x single-port ConnectX-7
compute_nic_model=ConnectX-7
max_compute_nics=8
compute_nic_gbps=400
# Storage / in-band: 2x dual-port QSFP112 BlueField-3 DPU
storage_ports=4
EOF

  cat > "$LAB_DIR/catalog/pcie-l40s-8gpu.conf" <<'EOF'
# Generic 2-socket PCIe server with 8x L40S (no NVLink on L40S)
name=Generic 2U PCIe server (8x L40S 48GB)
gpu_model=L40S
gpus_per_node=8
gpu_mem_gb=48
gpu_form_factor=PCIe
nvlink_gen=0
nvlink_gbs_per_gpu=0
nvswitch=no
topo_gpu_gpu=PCIe
compute_nic_model=ConnectX-7
max_compute_nics=2
compute_nic_gbps=200
storage_ports=2
EOF

  cat > "$LAB_DIR/catalog/pcie-l4-8gpu.conf" <<'EOF'
# Generic 2-socket PCIe server with 8x L4 (inference / video / edge class)
name=Generic 2U PCIe server (8x L4 24GB)
gpu_model=L4
gpus_per_node=8
gpu_mem_gb=24
gpu_form_factor=PCIe
nvlink_gen=0
nvlink_gbs_per_gpu=0
nvswitch=no
topo_gpu_gpu=PCIe
compute_nic_model=ConnectX-6 Dx
max_compute_nics=2
compute_nic_gbps=100
storage_ports=2
EOF

  cat > "$LAB_DIR/catalog/fabrics.conf" <<'EOF'
# id           | role       | gbps_per_port | rdma | description
eth-25g-mgmt   | management | 25            | no   | 25GbE in-band management network
eth-100g-tcp   | storage    | 100           | no   | 100GbE TCP/IP front-end, north-south and NFS
roce-200       | compute    | 200           | yes  | 200Gb/s Ethernet with RoCEv2
ib-ndr-400     | compute    | 400           | yes  | NVIDIA Quantum-2 InfiniBand NDR 400Gb/s
spcx-400       | compute    | 400           | yes  | NVIDIA Spectrum-X Ethernet 400Gb/s with RoCEv2
EOF

  cat > "$LAB_DIR/job/llm-70b-pretrain.conf" <<'EOF'
# Training job requirements, handed over by the ML team
job=llm-70b-pretrain
model=dense decoder-only transformer
params_billion=70
precision=bf16-mixed
optimizer=adamw
# Persistent training state per parameter, mixed precision + Adam:
#   2 B bf16 weights + 2 B bf16 grads + 4 B fp32 master + 4 B Adam m + 4 B Adam v
bytes_per_param_state=16
# Activations, NCCL buffers, fragmentation
activation_overhead_pct=25
# Tensor parallelism: every transformer layer all-reduces inside the TP group,
# forward and backward
tensor_parallel=8
# Time-to-train was budgeted for 4 nodes x 8 GPUs (data parallel across nodes)
nodes_min=4
min_intranode_gbs_per_gpu=400
min_internode_gbps_per_gpu=400
require_rdma=yes
EOF
}

write_validator() {
  cat > "$LAB_DIR/bin/aiio-sizing-check" <<'VALIDATOR'
#!/usr/bin/env bash
# aiio-sizing-check: simulated hardware-fit validator for NCA-AIIO lab 2.1.
# Do not edit this file: the lab verifies its checksum. Edit cluster.conf only.
set -uo pipefail
LAB=/opt/aiio-lab-2.1
CAT="$LAB/catalog"
JOB="$LAB/job/llm-70b-pretrain.conf"
CLUSTER="$LAB/cluster.conf"
FAIL=0
JOBNAME="job"

kv() {
  sed -e 's/#.*$//' "$1" 2>/dev/null | awk -v k="$2" '
    { i = index($0, "="); if (!i) next
      key = substr($0, 1, i - 1); val = substr($0, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (key == k) v = val }
    END { print v }'
}

fabric_field() {
  sed -e 's/#.*$//' "$CAT/fabrics.conf" | awk -F'|' -v id="$1" -v f="$2" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $1) }
    $1 == id { v = $f; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }'
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
ok()   { printf '  [PASS] %s\n' "$*"; }
ko()   { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
note() { printf '         %s\n' "$*"; }

result() {
  echo
  if (( FAIL )); then
    echo "RESULT: NOT FIT. This BOM cannot run $JOBNAME as specified."
    exit 1
  fi
  echo "RESULT: FIT. The BOM meets every hardware requirement of $JOBNAME."
  exit 0
}

profile_file() {
  local p="$1"
  [[ -n "$p" && "$p" != "fabrics" && "$p" =~ ^[a-z0-9-]+$ && -f "$CAT/$p.conf" ]] || return 1
  printf '%s' "$CAT/$p.conf"
}

show_topo() {
  local prof="$1" f n link i j cell
  f=$(profile_file "$prof") || { echo "unknown profile '$prof' (see: aiio-sizing-check inventory)" >&2; exit 2; }
  n=$(kv "$f" gpus_per_node); link=$(kv "$f" topo_gpu_gpu)
  echo "SIMULATED 'nvidia-smi topo -m' for profile $prof: $(kv "$f" name)"
  echo
  printf '%-8s' ""
  for ((j = 0; j < n; j++)); do printf '%-6s' "GPU$j"; done
  printf '%s\n' "CPU Affinity"
  for ((i = 0; i < n; i++)); do
    printf '%-8s' "GPU$i"
    for ((j = 0; j < n; j++)); do
      if (( i == j )); then cell=X
      elif [[ "$link" == NV* ]]; then cell="$link"
      elif (( i / 2 == j / 2 )); then cell=PIX
      elif (( i / (n / 2) == j / (n / 2) )); then cell=NODE
      else cell=SYS
      fi
      printf '%-6s' "$cell"
    done
    if (( i < n / 2 )); then echo "0-55"; else echo "56-111"; fi
  done
  cat <<'LEGEND'

Legend:
  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks
LEGEND
}

inventory() {
  local f p
  echo "Node profiles ($CAT):"
  printf '  %-16s %-5s %-7s %-7s %-9s %-11s %-13s %s\n' \
    PROFILE GPUS MEM_GB FORM NVSWITCH NVLINK_GBs COMPUTE_NICS NIC_GBPS
  for f in "$CAT"/*.conf; do
    p=$(basename "$f" .conf)
    [[ "$p" == fabrics ]] && continue
    printf '  %-16s %-5s %-7s %-7s %-9s %-11s %-13s %s\n' "$p" \
      "$(kv "$f" gpus_per_node)" "$(kv "$f" gpu_mem_gb)" "$(kv "$f" gpu_form_factor)" \
      "$(kv "$f" nvswitch)" "$(kv "$f" nvlink_gbs_per_gpu)" \
      "$(kv "$f" max_compute_nics)" "$(kv "$f" compute_nic_gbps)"
  done
  echo
  echo "Fabrics ($CAT/fabrics.conf):"
  sed -e '/^[[:space:]]*$/d' -e 's/^/  /' "$CAT/fabrics.conf"
}

do_check() {
  [[ -r "$JOB" && -r "$CLUSTER" ]] || { echo "lab files missing; run the lab script with 'break' or 'reset'" >&2; exit 2; }
  local prof nodes fab nics pf
  local gpus mem nvsw nvbw maxnics nicg form model
  local params bpp ovh tp nmin min_intra min_inter rdma_req
  local need have pergpu total role fg rd effg per_gpu_net

  JOBNAME=$(kv "$JOB" job)
  prof=$(kv "$CLUSTER" node_profile)
  nodes=$(kv "$CLUSTER" nodes)
  fab=$(kv "$CLUSTER" compute_fabric)
  nics=$(kv "$CLUSTER" compute_nics_per_node)

  echo "aiio-sizing-check :: job=$JOBNAME  bom=$CLUSTER"
  echo "  node_profile=$prof  nodes=$nodes  compute_fabric=$fab  compute_nics_per_node=$nics"

  echo
  echo "[1/5] Lab integrity"
  if (cd "$LAB" && sha256sum --quiet -c .state/SHA256SUMS) >/dev/null 2>&1; then
    ok "validator, catalog and job spec are untouched"
  else
    ko "validator, catalog or job spec were modified; only cluster.conf may be edited"
    note "restore with: sudo <lab script> reset"
  fi

  if ! pf=$(profile_file "$prof"); then
    ko "node_profile '$prof' is not in the catalog (see: aiio-sizing-check inventory)"
    result
  fi
  is_int "$nodes" && (( nodes > 0 )) || { ko "nodes must be a positive integer (got '$nodes')"; result; }
  is_int "$nics" || { ko "compute_nics_per_node must be an integer (got '$nics')"; result; }

  gpus=$(kv "$pf" gpus_per_node); mem=$(kv "$pf" gpu_mem_gb)
  nvsw=$(kv "$pf" nvswitch); nvbw=$(kv "$pf" nvlink_gbs_per_gpu)
  maxnics=$(kv "$pf" max_compute_nics); nicg=$(kv "$pf" compute_nic_gbps)
  form=$(kv "$pf" gpu_form_factor); model=$(kv "$pf" gpu_model)

  params=$(kv "$JOB" params_billion); bpp=$(kv "$JOB" bytes_per_param_state)
  ovh=$(kv "$JOB" activation_overhead_pct); tp=$(kv "$JOB" tensor_parallel)
  nmin=$(kv "$JOB" nodes_min); min_intra=$(kv "$JOB" min_intranode_gbs_per_gpu)
  min_inter=$(kv "$JOB" min_internode_gbps_per_gpu); rdma_req=$(kv "$JOB" require_rdma)

  echo
  echo "[2/5] Scale (time-to-train budget)"
  total=$(( nodes * gpus ))
  if (( nodes >= nmin )); then
    ok "$nodes nodes x $gpus GPUs = $total GPUs (job budget: >= $nmin nodes)"
  else
    ko "$nodes nodes is below the $nmin nodes the training schedule was budgeted for"
  fi

  echo
  echo "[3/5] Aggregate GPU memory (FSDP / ZeRO-3 sharded training state)"
  need=$(awk -v p="$params" -v b="$bpp" -v o="$ovh" 'BEGIN { printf "%d", p * b * (1 + o / 100) + 0.5 }')
  have=$(( total * mem ))
  pergpu=$(awk -v n="$need" -v t="$total" 'BEGIN { printf "%.1f", n / t }')
  note "state: ${params}B params x ${bpp} B = $(( params * bpp )) GB; +${ovh}% activations/buffers = ${need} GB"
  note "available: $total x ${mem} GB ($model) = ${have} GB; sharded need per GPU = ${pergpu} GB"
  if (( have >= need )); then
    ok "aggregate HBM/GDDR covers the sharded training state"
  else
    ko "aggregate GPU memory (${have} GB) < required (${need} GB): the job OOMs at step 0"
  fi

  echo
  echo "[4/5] Intra-node GPU interconnect (tensor parallel = $tp)"
  if (( tp > gpus )); then
    ko "TP=$tp exceeds $gpus GPUs per node: the TP group would cross the network every layer"
  elif [[ "$nvsw" != "yes" ]]; then
    ko "no NVLink/NVSwitch: the $form GPU-to-GPU path is PCIe (topo shows PIX/NODE/SYS)"
    note "TP all-reduce/all-gather runs in EVERY layer, forward and backward;"
    note "over PCIe and the inter-socket link, GPUs stall waiting on communication."
    note "inspect: aiio-sizing-check topo $prof"
  elif (( nvbw < min_intra )); then
    ko "NVLink bandwidth ${nvbw} GB/s per GPU < required ${min_intra} GB/s"
  else
    ok "NVSwitch all-to-all domain, ${nvbw} GB/s per GPU >= ${min_intra} GB/s"
  fi

  echo
  echo "[5/5] Inter-node compute fabric (east-west, gradient all-reduce)"
  role=$(fabric_field "$fab" 2); fg=$(fabric_field "$fab" 3); rd=$(fabric_field "$fab" 4)
  if [[ -z "$role" ]]; then
    ko "compute_fabric '$fab' is not in the catalog (see: aiio-sizing-check inventory)"
    result
  fi
  note "fabric '$fab': role=$role, ${fg} Gb/s per port, rdma=$rd"
  if [[ "$role" != "compute" ]]; then
    ko "'$fab' is a $role network, not a compute fabric: GPU traffic must stay off it"
  fi
  if [[ "$rdma_req" == "yes" && "$rd" != "yes" ]]; then
    ko "no RDMA: NCCL falls back to TCP sockets, with no GPUDirect RDMA path from NIC to HBM"
  fi
  if (( nics > maxnics )); then
    ko "$nics compute NICs requested, but profile '$prof' exposes only $maxnics compute ports"
    nics=$maxnics
  fi
  effg=$(( fg < nicg ? fg : nicg ))
  per_gpu_net=$(awk -v n="$nics" -v g="$effg" -v t="$gpus" 'BEGIN { printf "%.1f", n * g / t }')
  note "per-GPU east-west bandwidth: $nics NICs x ${effg} Gb/s / $gpus GPUs = ${per_gpu_net} Gb/s"
  if awk -v a="$per_gpu_net" -v b="$min_inter" 'BEGIN { exit !(a >= b) }'; then
    if [[ "$role" == "compute" && ( "$rdma_req" != "yes" || "$rd" == "yes" ) ]]; then
      ok "${per_gpu_net} Gb/s per GPU >= ${min_inter} Gb/s (rail-optimized: one NIC per GPU)"
    fi
  else
    ko "${per_gpu_net} Gb/s per GPU < ${min_inter} Gb/s required per GPU"
  fi

  result
}

case "${1:-check}" in
  check)     do_check ;;
  topo)      show_topo "${2:-$(kv "$CLUSTER" node_profile)}" ;;
  inventory) inventory ;;
  -h|--help) echo "usage: aiio-sizing-check [check|topo [profile]|inventory]" ;;
  *)         echo "usage: aiio-sizing-check [check|topo [profile]|inventory]" >&2; exit 2 ;;
esac
VALIDATOR
  chmod 0755 "$LAB_DIR/bin/aiio-sizing-check"
}

write_broken_bom() {
  cat > "$LAB_DIR/cluster.conf" <<'EOF'
# Bill of materials for the llm-70b-pretrain cluster.
# Approved by procurement because "48 GB x 32 GPUs is more memory than we need".
# Edit THIS file only, then re-run: aiio-sizing-check
node_profile=pcie-l40s-8gpu
nodes=4
compute_fabric=eth-25g-mgmt
compute_nics_per_node=2
EOF
  chmod 0644 "$LAB_DIR/cluster.conf"
}

seal() {
  ( cd "$LAB_DIR" && sha256sum bin/aiio-sizing-check catalog/*.conf job/*.conf > .state/SHA256SUMS )
  chmod 0600 "$LAB_DIR/.state/SHA256SUMS"
  : > "$MARKER"
}

# -----------------------------------------------------------------------------
# Student-facing text
# -----------------------------------------------------------------------------
briefing() {
  cat <<EOF

${c_bld}SCENARIO${c_rst}
  The ML team will pretrain a 70B-parameter dense LLM (bf16 mixed precision,
  AdamW, tensor parallel = 8, data parallel across nodes). Procurement already
  filled in the bill of materials in:

      $LAB_DIR/cluster.conf

  The platform team runs a sizing gate before any purchase order goes out:

      aiio-sizing-check              # full fit check (exit 0 = FIT)
      aiio-sizing-check inventory    # catalog of node profiles and fabrics
      aiio-sizing-check topo [prof]  # simulated 'nvidia-smi topo -m'

${c_bld}SYMPTOM YOU WILL SEE${c_rst}
  The gate reports "RESULT: NOT FIT" and exits 1. Look closely at WHICH checks
  pass: the BOM looks fine on the metric procurement used, and it still cannot
  train this model.

${c_bld}YOUR GOAL${c_rst}
  1. Make 'aiio-sizing-check' exit 0, editing ONLY $LAB_DIR/cluster.conf.
     (The validator, catalog and job spec are checksummed.)
  2. Be able to justify every value you chose:
     - why aggregate memory alone does not make a node fit for training,
     - what tensor parallelism demands from the intra-node interconnect,
     - what the east-west fabric must provide per GPU, and why the
       management network is not an option.

  Hints:   sudo $SELF hint 1   (then 2, then 3)
  Restart: sudo $SELF reset

Current gate output:
EOF
}

hint() {
  case "${1:-1}" in
    1) cat <<'EOF'
HINT 1. Run: aiio-sizing-check topo
  With TP=8, the 8 GPUs of a node exchange activations in every transformer
  layer, in both forward and backward passes. Which links connect those GPUs in
  the current profile? Compare against: aiio-sizing-check topo dgx-h100
EOF
      ;;
    2) cat <<'EOF'
HINT 2. Look at the 'role' and 'rdma' columns in: aiio-sizing-check inventory
  Gradient all-reduce across nodes runs on a dedicated compute (east-west)
  fabric with RDMA, separate from storage, in-band management and OOB networks.
  Reference architectures are "rail-optimized": one compute NIC per GPU.
EOF
      ;;
    3) cat <<'EOF'
HINT 3. Three keys must change together: node_profile, compute_fabric and
  compute_nics_per_node. Pick a profile with nvswitch=yes and 8 compute ports,
  a 'compute' fabric with rdma=yes at 400 Gb/s per port, and give every GPU its
  own NIC. Leave nodes at 4.
EOF
      ;;
    *) die "hint level must be 1, 2 or 3" ;;
  esac
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
do_break() {
  require_root; need_tools; guard_paths; confirm
  info "building simulated sizing lab in $LAB_DIR"
  write_catalog
  write_validator
  write_broken_bom
  seal
  ln -sfn "$LAB_DIR/bin/aiio-sizing-check" "$LINK"
  info "lab ready; the BOM is broken"
  briefing
  "$LINK" check || true
}

do_check() {
  [[ -x "$LINK" ]] || die "lab not built; run: sudo $SELF break"
  "$LINK" check
}

do_reset() {
  require_root
  [[ -f "$MARKER" ]] || die "lab not built; run: sudo $SELF break"
  write_catalog
  write_validator
  write_broken_bom
  seal
  ln -sfn "$LAB_DIR/bin/aiio-sizing-check" "$LINK"
  info "lab restored to its broken state"
  "$LINK" check || true
}

do_cleanup() {
  require_root
  if [[ -L "$LINK" && "$(readlink "$LINK")" == "$LAB_DIR/bin/aiio-sizing-check" ]]; then
    rm -f -- "$LINK"
    info "removed $LINK"
  fi
  if [[ -f "$MARKER" ]]; then
    rm -rf -- "$LAB_DIR"
    info "removed $LAB_DIR"
  elif [[ -e "$LAB_DIR" ]]; then
    warn "$LAB_DIR exists without the lab marker; left untouched"
  fi
}

case "${1:-break}" in
  break)          do_break ;;
  check)          do_check ;;
  hint)           hint "${2:-1}" ;;
  reset)          do_reset ;;
  cleanup)        do_cleanup ;;
  -h|--help|help) usage ;;
  *)              usage; exit 2 ;;
esac

# =============================================================================
# SOLUTION (step by step). Try the lab before reading this.
# =============================================================================
#
# STEP 0. Read the symptom carefully
#   $ aiio-sizing-check
#   [1/5] Lab integrity                 [PASS]
#   [2/5] Scale                         [PASS] 4 x 8 = 32 GPUs
#   [3/5] Aggregate GPU memory          [PASS] 32 x 48 GB = 1536 GB >= 1400 GB
#   [4/5] Intra-node interconnect       [FAIL] no NVLink/NVSwitch ...
#   [5/5] Inter-node compute fabric     [FAIL] management network, no RDMA,
#                                              6.2 Gb/s per GPU < 400
#   RESULT: NOT FIT
#
#   The trap: procurement sized on memory alone, and memory PASSES. Training
#   hardware is sized on three axes: memory capacity, intra-node bandwidth
#   (for tensor/model parallelism) and inter-node bandwidth (for data-parallel
#   gradient all-reduce), plus storage and management networks.
#
# STEP 1. Verify the memory math yourself
#   Mixed-precision Adam keeps ~16 bytes of persistent state per parameter:
#     2 (bf16 weights) + 2 (bf16 grads) + 4 (fp32 master) + 4 (m) + 4 (v)
#   70e9 params x 16 B = 1120 GB; +25% for activations/buffers ~= 1400 GB.
#   That does not fit in a single 8x80 GB node (640 GB), so the state is sharded
#   (FSDP / ZeRO-3) across nodes. That sharding is itself communication heavy,
#   which is why the fabric matters as much as the memory.
#
# STEP 2. Diagnose the intra-node problem
#   $ aiio-sizing-check topo
#   GPU0 to GPU1 = PIX, GPU0 to GPU3 = NODE, GPU0 to GPU4 = SYS
#   Every TP all-reduce crosses PCIe switches and the CPU socket interconnect.
#   L40S has no NVLink. A PCIe Gen5 x16 link is ~64 GB/s per direction, while an
#   H100 SXM5 has 900 GB/s of NVLink 4 bandwidth (18 links) into NVSwitch, so
#   any GPU talks to any other at full rate:
#   $ aiio-sizing-check topo dgx-h100       -> every pair shows NV18
#   Fix: node_profile=dgx-h100 (or dgx-b200: 180 GB HBM3e per GPU, NVLink 5 at
#   1.8 TB/s per GPU).
#   Why not pcie-l4-8gpu: L4 is an inference/video/edge part: 32 x 24 GB =
#   768 GB < 1400 GB, and it has no NVLink either.
#
# STEP 3. Diagnose the inter-node problem
#   eth-25g-mgmt is the in-band management network: wrong role, no RDMA, and
#   2 x 25 Gb/s shared by 8 GPUs = 6.25 Gb/s per GPU. NCCL would fall back to
#   TCP sockets with no GPUDirect RDMA (the NIC cannot DMA straight into GPU
#   memory), and gradient all-reduce dominates step time.
#   The DGX SuperPOD reference architecture uses a dedicated, rail-optimized
#   compute fabric: each DGX node has 8 single-port ConnectX-7 adapters
#   (4 OSFP cages) at 400 Gb/s, one per GPU, with GPU N of every node on rail N.
#   Storage and in-band traffic go through separate ports: dual-port
#   ConnectX-7 on DGX H100, BlueField-3 DPUs on DGX B200, which can also
#   offload and isolate storage, networking and security work from the host
#   CPU. OOB/BMC management is a separate network again.
#   Fix: compute_fabric=ib-ndr-400 (InfiniBand NDR) or spcx-400 (Spectrum-X
#   Ethernet with RoCE), and compute_nics_per_node=8.
#
# STEP 4. Apply the fix (edit only cluster.conf)
#   sudo sed -i \
#     -e 's/^node_profile=.*/node_profile=dgx-h100/' \
#     -e 's/^compute_fabric=.*/compute_fabric=ib-ndr-400/' \
#     -e 's/^compute_nics_per_node=.*/compute_nics_per_node=8/' \
#     /opt/aiio-lab-2.1/cluster.conf
#
#   Resulting file:
#     node_profile=dgx-h100
#     nodes=4
#     compute_fabric=ib-ndr-400
#     compute_nics_per_node=8
#
# STEP 5. Verify
#   $ aiio-sizing-check; echo "exit=$?"
#   [1/5] Lab integrity      [PASS] validator, catalog and job spec are untouched
#   [2/5] Scale              [PASS] 4 nodes x 8 GPUs = 32 GPUs (job budget: >= 4 nodes)
#   [3/5] Aggregate memory   [PASS] 32 x 80 GB = 2560 GB >= 1400 GB (43.8 GB/GPU sharded)
#   [4/5] Intra-node         [PASS] NVSwitch all-to-all domain, 900 GB/s per GPU >= 400 GB/s
#   [5/5] Inter-node fabric  [PASS] 8 x 400 / 8 = 400.0 Gb/s per GPU >= 400 Gb/s
#   RESULT: FIT. The BOM meets every hardware requirement of llm-70b-pretrain.
#   exit=0
#
#   Equally valid: node_profile=dgx-b200 and/or compute_fabric=spcx-400.
#   Still wrong: roce-200 (8 x 200 / 8 = 200 Gb/s per GPU), or keeping the L40S
#   profile (only 2 compute ports and no NVLink, whatever fabric you choose).
#
# STEP 6. Takeaways for the exam
#   - Training at scale: SXM GPUs with NVLink/NVSwitch for model and tensor
#     parallelism, plus large HBM capacity for weights, gradients, optimizer
#     state and activations.
#   - PCIe GPUs such as L40S or L4 are a good fit for inference, fine-tuning
#     small models, graphics and video. They are not a fit for TP-heavy LLM
#     pretraining.
#   - East-west compute fabric: RDMA (InfiniBand or RoCE/Spectrum-X), 400 Gb/s
#     per GPU, rail-optimized, with GPUDirect RDMA.
#   - Keep compute, storage, in-band and OOB networks separate; BlueField DPUs
#     offload and isolate infrastructure work from the host.
#   - Size memory first, then check that the interconnect can feed the
#     parallelism strategy the job actually uses.
#
# STEP 7. Clean up
#   sudo ./aiio-2.1-break-fix.sh cleanup
# =============================================================================