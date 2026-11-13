#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO · Topic 2.3 · Power and cooling requirements in an AI data center
# BREAK & FIX LAB: "Rack R07 is one PDU failure away from going dark"
# =============================================================================
#
# WHAT THIS SCRIPT DOES
#   It builds a self-contained simulation of one AI rack: two DGX H100 nodes,
#   two redundant 3-phase PDU feeds (A/B, 2N), a CRAH cooling unit, and the
#   rack's blanking panels. It then breaks that rack in the same ways real
#   racks get broken:
#     1. A driver upgrade reset the GPU power caps to the 700 W default
#        (caps set with nvidia-smi -pl are NOT persistent). The rack now draws
#        more than ONE feed can carry, so the 2N redundancy is fake: losing
#        feed B would trip feed A.
#     2. A "PUE improvement" change ticket raised the CRAH supply setpoint
#        to 29 C.
#     3. Blanking panels were never reinstalled after racking the DGXs, so
#        hot exhaust recirculates into the cold side.
#     Result: rack inlet above the ASHRAE recommended envelope, GPUs in HW
#     Thermal Slowdown, and a training job running 38% slower.
#
# SAFETY
#   * Pure simulation. No real GPU, BMC, PDU, sysfs, or cpufreq is touched.
#   * It installs a MOCK `nvidia-smi`. It REFUSES to run if a real nvidia-smi
#     is present, so it can never shadow a real driver tool.
#   * Everything lives in /opt/aiio-lab, /var/lib/aiio-lab and four symlinks
#     in /usr/local/bin.  Undo with:  sudo ./this-script.sh --cleanup
#   * Intended for a disposable lab VM (any modern Linux with bash + awk).
#
# USAGE
#   sudo ./break_fix.sh            # install + break
#   lab-check                                            # verify your fix
#   sudo ./break_fix.sh --verify                         # the same check, as a script mode
#   sudo ./break_fix.sh --cleanup  # remove everything
#
# OFFICIAL REFERENCES
#   DGX H100 component descriptions and system power (~10.2 kW max):
#     https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   DGX SuperPOD B200 reference architecture (rack power/cooling density):
#     https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#   NVIDIA AI Infrastructure and Operations Fundamentals:
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   NCA-AIIO exam study guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   NVLink / NVSwitch (part of the non-GPU node power budget):
#     https://www.nvidia.com/en-us/data-center/nvlink/
#   BlueField DPU offload (infrastructure work moved off host CPUs):
#     https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
#   Network IO in the modern data center:
#     https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
# =============================================================================

set -euo pipefail

LAB_ROOT=/opt/aiio-lab
STATE_DIR=/var/lib/aiio-lab
BIN_DIR=/usr/local/bin
TOOLS=(dcim aiio-node lab-check nvidia-smi)

msg()  { printf '\033[1;36m[aiio-lab]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[aiio-lab] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo); the lab installs tools under $LAB_ROOT and $BIN_DIR"
command -v awk >/dev/null 2>&1 || die "awk is required"

# ----------------------------------------------------------------------------- cleanup
if [[ ${1:-} == "--cleanup" ]]; then
  for t in "${TOOLS[@]}"; do
    if [[ -L $BIN_DIR/$t && $(readlink "$BIN_DIR/$t") == "$LAB_ROOT"/* ]]; then
      rm -f "$BIN_DIR/$t"
      msg "removed symlink $BIN_DIR/$t"
    fi
  done
  [[ -d /opt/aiio-lab ]] && rm -rf /opt/aiio-lab && msg "removed /opt/aiio-lab"
  [[ -d /var/lib/aiio-lab ]] && rm -rf /var/lib/aiio-lab && msg "removed /var/lib/aiio-lab"
  msg "cleanup complete"
  exit 0
fi
# ----------------------------------------------------------------------------- verify
# The same grader as `lab-check`, reachable as a script mode so the study-lab runner can call it.
if [[ ${1:-} == "--verify" ]]; then
  [[ -x $LAB_ROOT/bin/lab-check ]] || die "lab not installed; run this script without arguments first"
  exec "$LAB_ROOT/bin/lab-check"
fi
[[ $# -eq 0 ]] || die "unknown argument '$1' (only --verify and --cleanup are supported)"

# ----------------------------------------------------------------------------- pre-flight
if [[ -e $BIN_DIR/nvidia-smi && ! -L $BIN_DIR/nvidia-smi ]]; then
  die "$BIN_DIR/nvidia-smi is a real file; this lab must run on a disposable VM without NVIDIA drivers"
fi
if real_smi=$(PATH=${PATH//$BIN_DIR/} command -v nvidia-smi 2>/dev/null); then
  die "a real nvidia-smi exists at $real_smi; this lab ships a mock and refuses to shadow a real driver tool"
fi
for t in "${TOOLS[@]}"; do
  if [[ -e $BIN_DIR/$t || -L $BIN_DIR/$t ]]; then
    if [[ ! -L $BIN_DIR/$t || $(readlink "$BIN_DIR/$t") != "$LAB_ROOT"/* ]]; then
      die "$BIN_DIR/$t already exists and does not belong to this lab; not overwriting it"
    fi
  fi
done

install -d -m 0755 "$LAB_ROOT/bin" "$LAB_ROOT/lib" "$STATE_DIR"

# ----------------------------------------------------------------------------- shared model
cat > "$LAB_ROOT/lib/common.sh" <<'__COMMON__'
# shellcheck shell=bash
# Shared physical model for the AIIO power & cooling lab. Pure simulation.
STATE_FILE=/var/lib/aiio-lab/state
EVENTS_FILE=/var/lib/aiio-lab/events.log

NODE_BASE_W=4600      # non-GPU share of a ~10.2 kW DGX H100: CPUs, NVSwitch, NICs/DPUs, NVMe, fans
GPUS_PER_NODE=8
GPU_MAX_PL_W=700      # H100 SXM5 default/max board power
GPU_MIN_PL_W=200
DRAW_FACTOR=0.95      # a saturated training job draws ~95% of the enforced cap
SLA_MIN_PL_W=500      # below this cap the training job misses its step-time SLA
FEED_VOLTS=415        # 3-phase, line-to-line
FEED_AMPS=32
FEED_DERATE=0.80      # continuous-load rule: plan for 80% of breaker rating
RECIRC_MISSING_C=6    # inlet rise from hot-air recirculation without blanking panels
RECIRC_INSTALLED_C=1
ASHRAE_MIN_C=18       # ASHRAE TC 9.9 recommended inlet envelope
ASHRAE_MAX_C=27
THERMAL_SLOWDOWN_C=85 # lab model threshold for HW Thermal Slowdown
SHUTDOWN_C=92
CRAH_MIN_C=14
CRAH_MAX_C=30
GPU_NAME="NVIDIA H100 80GB HBM3"
GPU_BUS_IDS=(00000000:18:00.0 00000000:2A:00.0 00000000:3A:00.0 00000000:5D:00.0
             00000000:9A:00.0 00000000:AB:00.0 00000000:BA:00.0 00000000:DB:00.0)

die()          { echo "ERROR: $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "this operation changes lab state; run it with sudo"; }
st_get()       { grep -E "^$1=" "$STATE_FILE" | tail -n1 | cut -d= -f2-; }
st_set()       { grep -qE "^$1=" "$STATE_FILE" || die "unknown state key $1"; sed -i "s|^$1=.*|$1=$2|" "$STATE_FILE"; }
log_event()    { printf '%s  %-8s %-11s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" "$3" >> "$EVENTS_FILE"; }
nodes()        { st_get NODES | tr ',' ' '; }
is_node()      { local n; for n in $(nodes); do [[ $n == "$1" ]] && return 0; done; return 1; }
node_key()     { local n=${1^^}; printf 'PL_%s' "${n//-/}"; }
node_pl()      { st_get "$(node_key "$1")"; }
kw()           { awk -v w="$1" 'BEGIN{printf "%.2f", w/1000}'; }
btu()          { awk -v w="$1" 'BEGIN{printf "%.0f", w*3.412}'; }

node_draw_w() {
  awk -v b="$NODE_BASE_W" -v g="$GPUS_PER_NODE" -v pl="$(node_pl "$1")" -v f="$DRAW_FACTOR" \
      'BEGIN{printf "%.0f", b + g*pl*f}'
}
rack_total_w() {
  local t=0 n
  for n in $(nodes); do t=$(( t + $(node_draw_w "$n") )); done
  echo "$t"
}
feed_nameplate_w() { awk -v v="$FEED_VOLTS" -v a="$FEED_AMPS" 'BEGIN{printf "%.0f", sqrt(3)*v*a}'; }
feed_capacity_w()  { awk -v v="$FEED_VOLTS" -v a="$FEED_AMPS" -v d="$FEED_DERATE" 'BEGIN{printf "%.0f", sqrt(3)*v*a*d}'; }
worst_case_feed_w() {
  local t; t=$(rack_total_w)
  if [[ $(st_get REDUNDANCY) == "2N" ]]; then echo "$t"; else echo $(( t / 2 )); fi
}
inlet_c() {
  local c; c=$(st_get CRAH_SUPPLY_C)
  if [[ $(st_get BLANKING) == "installed" ]]; then echo $(( c + RECIRC_INSTALLED_C ))
  else echo $(( c + RECIRC_MISSING_C )); fi
}
gpu_temp_c() { awk -v t="$(inlet_c)" -v pl="$1" -v i="$2" 'BEGIN{printf "%.0f", t + 0.075*pl + 0.5*i}'; }
gpu_draw_w() { awk -v pl="$1" -v f="$DRAW_FACTOR" 'BEGIN{printf "%.2f", pl*f}'; }
max_gpu_temp_c() {
  local pl m=0 i t; pl=$(node_pl "$1")
  for (( i=0; i<GPUS_PER_NODE; i++ )); do
    t=$(gpu_temp_c "$pl" "$i")
    if (( t > m )); then m=$t; fi
  done
  echo "$m"
}
__COMMON__

# ----------------------------------------------------------------------------- mock nvidia-smi
cat > "$LAB_ROOT/bin/nvidia-smi" <<'__NVSMI__'
#!/usr/bin/env bash
# AIIO LAB MOCK of nvidia-smi. Models a DGX H100 node (8x H100 SXM5).
# Target another node with:  aiio-node dgx-02 nvidia-smi ...
set -uo pipefail
source /opt/aiio-lab/lib/common.sh

NODE=${AIIO_NODE:-dgx-01}
is_node "$NODE" || die "unknown node '$NODE' (known: $(nodes))"
PL=$(node_pl "$NODE")

usage() {
  cat <<'U'
nvidia-smi (AIIO LAB MOCK). Supported subset:
  nvidia-smi                                   summary table
  nvidia-smi -L                                list GPUs
  nvidia-smi -q [-d POWER|TEMPERATURE|PERFORMANCE] [-i N]
  nvidia-smi --query-gpu=FIELDS --format=csv[,noheader][,nounits] [-i N]
      fields: index,name,pci.bus_id,power.draw,power.limit,temperature.gpu,clocks.sm,
              clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.sw_power_cap
  sudo nvidia-smi -pl WATTS                    set power limit on all 8 GPUs of this node
U
}

gpu_fields() {
  local i=$1
  G_TEMP=$(gpu_temp_c "$PL" "$i")
  G_DRAW=$(gpu_draw_w "$PL")
  if (( G_TEMP >= THERMAL_SLOWDOWN_C )); then
    G_THERM="Active"; G_SM=1155
  else
    G_THERM="Not Active"
    G_SM=$(awk -v pl="$PL" -v m="$GPU_MAX_PL_W" 'BEGIN{printf "%.0f", 1980*sqrt(pl/m)}')
  fi
  if (( PL < GPU_MAX_PL_W )); then G_SWCAP="Active"; else G_SWCAP="Not Active"; fi
}

IDX=""; PL_REQ=""; QUERY=0; DISP=""; QFIELDS=""; FMT=""; LIST=0
while (( $# )); do
  case $1 in
    -i|--id)            IDX=${2:-}; shift 2 || shift ;;
    --id=*)             IDX=${1#*=}; shift ;;
    -pl|--power-limit)  PL_REQ=${2:-}; [[ -n $PL_REQ ]] || die "-pl needs a value in watts"; shift 2 ;;
    --power-limit=*)    PL_REQ=${1#*=}; shift ;;
    -q|--query)         QUERY=1; shift ;;
    -d|--display)       DISP=${2:-}; shift 2 || shift ;;
    --display=*)        DISP=${1#*=}; shift ;;
    --query-gpu=*)      QFIELDS=${1#*=}; shift ;;
    --format=*)         FMT=${1#*=}; shift ;;
    -L|--list-gpus)     LIST=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) die "lab mock: option '$1' is not modeled (see nvidia-smi --help)" ;;
  esac
done

if [[ -n $IDX ]]; then
  [[ $IDX =~ ^[0-7]$ ]] || die "lab mock: -i accepts a single index 0-7"
  INDICES=("$IDX")
else
  INDICES=(0 1 2 3 4 5 6 7)
fi

# --- set power limit
if [[ -n $PL_REQ ]]; then
  require_root
  [[ -z $IDX ]] || die "lab mock: per-GPU caps are not modeled; omit -i to cap all 8 GPUs of $NODE"
  [[ $PL_REQ =~ ^[0-9]+(\.0+)?$ ]] || die "Invalid power limit '$PL_REQ'"
  PL_REQ=${PL_REQ%%.*}
  if (( PL_REQ < GPU_MIN_PL_W || PL_REQ > GPU_MAX_PL_W )); then
    echo "Provided power limit ${PL_REQ}.00 W is not a valid power limit which should be between ${GPU_MIN_PL_W}.00 W and ${GPU_MAX_PL_W}.00 W for GPU ${GPU_BUS_IDS[0]}"
    exit 1
  fi
  for bus in "${GPU_BUS_IDS[@]}"; do
    printf 'Power limit for GPU %s was set to %d.00 W from %d.00 W.\n' "$bus" "$PL_REQ" "$PL"
  done
  echo "All done."
  st_set "$(node_key "$NODE")" "$PL_REQ"
  log_event INFO "$NODE" "GPU power limit changed ${PL} W -> ${PL_REQ} W on 8/8 GPUs (runtime, not persistent)"
  exit 0
fi

# --- list
if (( LIST )); then
  for i in "${INDICES[@]}"; do
    printf 'GPU %d: %s (UUID: GPU-a110de00-0000-4000-8000-%s00000000%d)\n' "$i" "$GPU_NAME" "${NODE//-/}" "$i"
  done
  exit 0
fi

# --- csv query
if [[ -n $QFIELDS ]]; then
  [[ $FMT == csv* ]] || die "lab mock: --query-gpu requires --format=csv[,noheader][,nounits]"
  NOHEADER=0; NOUNITS=0
  [[ $FMT == *noheader* ]] && NOHEADER=1
  [[ $FMT == *nounits* ]] && NOUNITS=1
  IFS=',' read -r -a F <<< "$QFIELDS"
  if (( ! NOHEADER )); then
    hdr=()
    for f in "${F[@]}"; do
      case $f in
        power.draw|power.limit) hdr+=("$f [W]") ;;
        clocks.sm)              hdr+=("$f [MHz]") ;;
        *)                      hdr+=("$f") ;;
      esac
    done
    (IFS=','; echo "${hdr[*]}" | sed 's/,/, /g')
  fi
  for i in "${INDICES[@]}"; do
    gpu_fields "$i"; row=()
    for f in "${F[@]}"; do
      case $f in
        index)       row+=("$i") ;;
        name)        row+=("$GPU_NAME") ;;
        pci.bus_id)  row+=("${GPU_BUS_IDS[$i]}") ;;
        power.draw)  if (( NOUNITS )); then row+=("$G_DRAW"); else row+=("$G_DRAW W"); fi ;;
        power.limit) if (( NOUNITS )); then row+=("$PL.00"); else row+=("$PL.00 W"); fi ;;
        temperature.gpu) row+=("$G_TEMP") ;;
        clocks.sm)   if (( NOUNITS )); then row+=("$G_SM"); else row+=("$G_SM MHz"); fi ;;
        clocks_event_reasons.hw_thermal_slowdown|clocks_throttle_reasons.hw_thermal_slowdown) row+=("$G_THERM") ;;
        clocks_event_reasons.sw_power_cap|clocks_throttle_reasons.sw_power_cap)               row+=("$G_SWCAP") ;;
        *) die "lab mock: field '$f' is not modeled" ;;
      esac
    done
    (IFS=','; echo "${row[*]}" | sed 's/,/, /g')
  done
  exit 0
fi

# --- -q
if (( QUERY )); then
  echo "==============NVSMI LOG=============="
  echo
  printf '%-42s: %s\n' "Timestamp" "$(date)"
  printf '%-42s: %s\n' "Driver Version" "550.54.15 (AIIO LAB MOCK, node $NODE)"
  printf '%-42s: %s\n' "Attached GPUs" "8"
  for i in "${INDICES[@]}"; do
    gpu_fields "$i"
    echo
    echo "GPU ${GPU_BUS_IDS[$i]}"
    printf '    %-38s: %s\n' "Product Name" "$GPU_NAME"
    if [[ -z $DISP || ${DISP^^} == *PERFORMANCE* ]]; then
      printf '    %-38s: %s\n' "Performance State" "P0"
      echo   "    Clocks Event Reasons"
      printf '        %-34s: %s\n' "Idle" "Not Active"
      printf '        %-34s: %s\n' "Applications Clocks Setting" "Not Active"
      printf '        %-34s: %s\n' "SW Power Cap" "$G_SWCAP"
      printf '        %-34s: %s\n' "HW Slowdown" "$G_THERM"
      printf '            %-30s: %s\n' "HW Thermal Slowdown" "$G_THERM"
      printf '            %-30s: %s\n' "HW Power Brake Slowdown" "Not Active"
      printf '        %-34s: %s\n' "Sync Boost" "Not Active"
      printf '        %-34s: %s\n' "SW Thermal Slowdown" "Not Active"
      echo   "    Clocks"
      printf '        %-34s: %s MHz\n' "SM" "$G_SM"
    fi
    if [[ -z $DISP || ${DISP^^} == *TEMPERATURE* ]]; then
      echo   "    Temperature"
      printf '        %-34s: %s C\n' "GPU Current Temp" "$G_TEMP"
      printf '        %-34s: %s C\n' "GPU Shutdown Temp" "$SHUTDOWN_C"
      printf '        %-34s: %s C\n' "GPU Slowdown Temp" "$THERMAL_SLOWDOWN_C"
    fi
    if [[ -z $DISP || ${DISP^^} == *POWER* ]]; then
      echo   "    GPU Power Readings"
      printf '        %-34s: %s W\n' "Power Draw" "$G_DRAW"
      printf '        %-34s: %s.00 W\n' "Current Power Limit" "$PL"
      printf '        %-34s: %s.00 W\n' "Requested Power Limit" "$PL"
      printf '        %-34s: %s.00 W\n' "Default Power Limit" "$GPU_MAX_PL_W"
      printf '        %-34s: %s.00 W\n' "Min Power Limit" "$GPU_MIN_PL_W"
      printf '        %-34s: %s.00 W\n' "Max Power Limit" "$GPU_MAX_PL_W"
    fi
  done
  exit 0
fi

# --- default summary
echo "+------------------------------------------------------------------------------+"
printf '| NVIDIA-SMI 550.54.15 (AIIO LAB MOCK)              node: %-22s|\n' "$NODE"
echo "+-----+------------------------+------+------------------+---------+------------+"
echo "| GPU | Name                   | Temp | Pwr:Usage/Cap    | SM MHz  | HW Thermal |"
echo "+-----+------------------------+------+------------------+---------+------------+"
for i in "${INDICES[@]}"; do
  gpu_fields "$i"
  printf '| %3d | %-22s | %3sC | %6.0fW / %4sW  | %7s | %-10s |\n' \
    "$i" "H100 80GB HBM3" "$G_TEMP" "$G_DRAW" "$PL" "$G_SM" "$G_THERM"
done
echo "+-----+------------------------+------+------------------+---------+------------+"
__NVSMI__

# ----------------------------------------------------------------------------- aiio-node
cat > "$LAB_ROOT/bin/aiio-node" <<'__NODE__'
#!/usr/bin/env bash
# Run a command "on" another simulated node:  aiio-node dgx-02 nvidia-smi -q -d POWER
set -uo pipefail
source /opt/aiio-lab/lib/common.sh
[[ $# -ge 2 ]] || die "usage: aiio-node <node> <command> [args...]   (nodes: $(nodes))"
is_node "$1" || die "unknown node '$1' (nodes: $(nodes))"
export AIIO_NODE=$1
shift
exec "$@"
__NODE__

# ----------------------------------------------------------------------------- dcim
cat > "$LAB_ROOT/bin/dcim" <<'__DCIM__'
#!/usr/bin/env bash
# Simulated DCIM (Data Center Infrastructure Management) console for rack R07.
set -uo pipefail
source /opt/aiio-lab/lib/common.sh

usage() {
  cat <<'U'
dcim - simulated DCIM console (row C, rack R07)

  dcim rack show                         IT load, redundancy, airflow, inlet temp
  dcim pdu show                          feed A/B ratings and load (normal and failover)
  dcim crah show                         cooling unit serving row C
  dcim events                            alarm and change log
  sudo dcim crah set-supply <C>          CRAH supply-air setpoint (14-30 C)
  sudo dcim rack set-blanking installed|missing
  sudo dcim rack set-redundancy 2N|N     (2N = each feed must carry 100% of the rack)
U
}

status_tag() { if [[ $1 == ok ]]; then printf '\033[1;32m[OK]\033[0m'; else printf '\033[1;31m[%s]\033[0m' "$2"; fi; }

rack_show() {
  local total worst cap inlet n
  total=$(rack_total_w); worst=$(worst_case_feed_w); cap=$(feed_capacity_w); inlet=$(inlet_c)
  echo "RACK R07  (row C, hot/cold aisle, no containment)"
  printf '  %-8s %-10s %12s %10s %12s\n' NODE MODEL "GPU_CAP(W)" "DRAW(kW)" "MAX_GPU(C)"
  for n in $(nodes); do
    printf '  %-8s %-10s %12s %10s %12s\n' "$n" "DGX H100" "$(node_pl "$n")" "$(kw "$(node_draw_w "$n")")" "$(max_gpu_temp_c "$n")"
  done
  echo
  printf '  %-28s: %s kW  (heat to remove: %s BTU/hr)\n' "Rack IT load" "$(kw "$total")" "$(btu "$total")"
  printf '  %-28s: %s\n' "Power redundancy" "$(st_get REDUNDANCY)"
  printf '  %-28s: %s kW of %s kW per feed  ' "Worst-case single-feed load" "$(kw "$worst")" "$(kw "$cap")"
  if (( worst <= cap )); then status_tag ok; else status_tag bad "OVER BUDGET"; fi; echo
  printf '  %-28s: %s\n' "Blanking panels" "$(st_get BLANKING)"
  printf '  %-28s: %s C  (ASHRAE recommended %s-%s C)  ' "Rack inlet temperature" "$inlet" "$ASHRAE_MIN_C" "$ASHRAE_MAX_C"
  if (( inlet >= ASHRAE_MIN_C && inlet <= ASHRAE_MAX_C )); then status_tag ok; else status_tag bad "OUT OF ENVELOPE"; fi; echo
}

pdu_show() {
  local total name cap red
  total=$(rack_total_w); name=$(feed_nameplate_w); cap=$(feed_capacity_w); red=$(st_get REDUNDANCY)
  echo "PDU feeds for rack R07  (3-phase ${FEED_VOLTS} V L-L, ${FEED_AMPS} A breaker, PF ~1.0)"
  printf '  %-34s: %s kW  (sqrt(3) x %s V x %s A)\n' "Nameplate per feed" "$(kw "$name")" "$FEED_VOLTS" "$FEED_AMPS"
  printf '  %-34s: %s kW  (%s%% continuous-load derating)\n' "Usable continuous per feed" "$(kw "$cap")" "$(awk -v d="$FEED_DERATE" 'BEGIN{print d*100}')"
  printf '  %-34s: %s kW on A, %s kW on B\n' "Normal operation (shared)" "$(kw $(( total / 2 )))" "$(kw $(( total / 2 )))"
  if [[ $red == "2N" ]]; then
    printf '  %-34s: %s kW on the surviving feed  ' "Failover (one feed lost)" "$(kw "$total")"
    if (( total <= cap )); then status_tag ok; else status_tag bad "BREAKER TRIP"; fi; echo
  else
    printf '  %-34s: NOT GUARANTEED (redundancy set to N; losing a feed drops the rack)\n' "Failover (one feed lost)"
  fi
}

crah_show() {
  echo "CRAH-C2 (serves row C)"
  printf '  %-30s: %s C\n' "Supply air setpoint" "$(st_get CRAH_SUPPLY_C)"
  printf '  %-30s: %s C\n' "Measured inlet at R07 (top U)" "$(inlet_c)"
  if [[ $(st_get BLANKING) == "installed" ]]; then
    printf '  %-30s: +%s C (normal mixing)\n' "Recirculation penalty" "$RECIRC_INSTALLED_C"
  else
    printf '  %-30s: +%s C (hot exhaust leaking through open U slots)\n' "Recirculation penalty" "$RECIRC_MISSING_C"
  fi
}

case "${1:-} ${2:-}" in
  "rack show") rack_show ;;
  "pdu show")  pdu_show ;;
  "crah show") crah_show ;;
  "events ")   cat "$EVENTS_FILE" ;;
  "crah set-supply")
    require_root; v=${3:-}
    [[ $v =~ ^[0-9]+$ ]] || die "setpoint must be an integer in C"
    (( v >= CRAH_MIN_C && v <= CRAH_MAX_C )) || die "setpoint must be between $CRAH_MIN_C and $CRAH_MAX_C C"
    old=$(st_get CRAH_SUPPLY_C); st_set CRAH_SUPPLY_C "$v"
    log_event CHANGE CRAH-C2 "supply setpoint ${old} C -> ${v} C"
    echo "CRAH-C2 supply setpoint: ${old} C -> ${v} C (rack R07 inlet now $(inlet_c) C)" ;;
  "rack set-blanking")
    require_root; v=${3:-}
    [[ $v == installed || $v == missing ]] || die "use: installed | missing"
    st_set BLANKING "$v"; log_event CHANGE R07 "blanking panels: $v"
    echo "R07 blanking panels: $v (rack inlet now $(inlet_c) C)" ;;
  "rack set-redundancy")
    require_root; v=${3:-}
    [[ $v == 2N || $v == N ]] || die "use: 2N | N"
    st_set REDUNDANCY "$v"; log_event CHANGE R07 "power redundancy policy: $v"
    echo "R07 power redundancy policy: $v" ;;
  *) usage; [[ -z ${1:-} || ${1:-} == help || ${1:-} == -h ]] || exit 1 ;;
esac
__DCIM__

# ----------------------------------------------------------------------------- lab-check
cat > "$LAB_ROOT/bin/lab-check" <<'__CHECK__'
#!/usr/bin/env bash
# Verifies the rack R07 fix. Exit code 0 = solved.
set -uo pipefail
source /opt/aiio-lab/lib/common.sh

fail=0
pass() { printf '  \033[1;32m[PASS]\033[0m %s\n' "$1"; }
bad()  { printf '  \033[1;31m[FAIL]\033[0m %s\n         hint: %s\n' "$1" "$2"; fail=1; }

echo "lab-check: rack R07 power & cooling"

red=$(st_get REDUNDANCY)
if [[ $red == "2N" ]]; then
  pass "power redundancy policy is 2N"
else
  bad "power redundancy policy is '$red'" \
      "relabeling the rack as N makes the numbers look fine and removes the protection; set it back to 2N and reduce the load instead"
fi

total=$(rack_total_w); cap=$(feed_capacity_w)
if (( total <= cap )); then
  pass "a single feed can carry the whole rack: $(kw "$total") kW <= $(kw "$cap") kW"
else
  bad "rack load $(kw "$total") kW exceeds one feed's continuous capacity $(kw "$cap") kW" \
      "node draw = ${NODE_BASE_W} W + 8 x cap x ${DRAW_FACTOR}; solve for the per-GPU cap that fits two nodes on one feed"
fi

for n in $(nodes); do
  pl=$(node_pl "$n")
  if (( pl >= SLA_MIN_PL_W )); then
    pass "$n GPU power cap ${pl} W meets the job SLA (>= ${SLA_MIN_PL_W} W)"
  else
    bad "$n GPU power cap ${pl} W is below the ${SLA_MIN_PL_W} W SLA floor" \
        "capping is a trade-off: protect the feed without starving the training job"
  fi
done

if [[ $(st_get BLANKING) == "installed" ]]; then
  pass "blanking panels installed (no hot-air recirculation)"
else
  bad "blanking panels missing" \
      "open U slots let hot-aisle exhaust leak back to the server intakes; airflow management comes before colder air"
fi

inlet=$(inlet_c)
if (( inlet > ASHRAE_MAX_C )); then
  bad "rack inlet ${inlet} C is above the ASHRAE recommended ${ASHRAE_MAX_C} C" \
      "inlet = CRAH supply + recirculation penalty"
elif (( inlet < ASHRAE_MIN_C )); then
  bad "rack inlet ${inlet} C is below the ASHRAE recommended ${ASHRAE_MIN_C} C" \
      "overcooling wastes chiller/fan energy (worse PUE) and adds condensation risk"
else
  pass "rack inlet ${inlet} C is within ASHRAE recommended ${ASHRAE_MIN_C}-${ASHRAE_MAX_C} C"
fi

for n in $(nodes); do
  t=$(max_gpu_temp_c "$n")
  if (( t < THERMAL_SLOWDOWN_C )); then
    pass "$n hottest GPU ${t} C, no HW Thermal Slowdown"
  else
    bad "$n hottest GPU ${t} C, HW Thermal Slowdown active" \
        "check with: aiio-node $n nvidia-smi -q -d PERFORMANCE,TEMPERATURE"
  fi
done

echo
if (( fail == 0 )); then
  echo "RESULT: SOLVED. Rack R07 survives a feed loss, stays in the ASHRAE envelope and the GPUs run at full clocks."
  grep -q "LAB SOLVED" "$EVENTS_FILE" || log_event INFO lab-check "LAB SOLVED"
  exit 0
fi
echo "RESULT: NOT SOLVED yet. Fix the [FAIL] items and run lab-check again."
exit 1
__CHECK__

chmod 0755 "$LAB_ROOT"/bin/*
chmod 0644 "$LAB_ROOT/lib/common.sh"
for t in "${TOOLS[@]}"; do ln -sfn "$LAB_ROOT/bin/$t" "$BIN_DIR/$t"; done

# ----------------------------------------------------------------------------- BREAK
cat > "$STATE_DIR/state" <<'__STATE__'
NODES=dgx-01,dgx-02
PL_DGX01=700
PL_DGX02=700
CRAH_SUPPLY_C=29
BLANKING=missing
REDUNDANCY=2N
__STATE__
chmod 0644 "$STATE_DIR/state"
: > "$STATE_DIR/events.log"
chmod 0644 "$STATE_DIR/events.log"

# shellcheck source=/dev/null
source "$LAB_ROOT/lib/common.sh"
log_event CHANGE  R07       "2x DGX H100 racked (U12-U22, U31-U42); blanking panels not reinstalled"
log_event CHANGE  dgx-01    "driver upgrade + reboot: GPU power limits back to default 700 W (previous 550 W cap was runtime-only)"
log_event CHANGE  dgx-02    "driver upgrade + reboot: GPU power limits back to default 700 W (previous 550 W cap was runtime-only)"
log_event CHANGE  CRAH-C2   "supply setpoint 22 C -> 29 C (ticket CHG-4471: 'raise setpoint to improve PUE')"
log_event CRIT    PDU-R07-A "2N violated: rack load $(kw "$(rack_total_w)") kW > single-feed continuous $(kw "$(feed_capacity_w)") kW; losing feed B trips feed A"
log_event WARN    R07       "inlet temperature $(inlet_c) C above ASHRAE recommended ${ASHRAE_MAX_C} C"
log_event CRIT    dgx-01    "HW Thermal Slowdown active on GPUs (max $(max_gpu_temp_c dgx-01) C)"
log_event CRIT    dgx-02    "HW Thermal Slowdown active on GPUs (max $(max_gpu_temp_c dgx-02) C)"
log_event WARN    sched     "job llm-pretrain-7b: step time +38% vs baseline"

# ----------------------------------------------------------------------------- briefing
cat <<'__BRIEF__'

==============================================================================
 NCA-AIIO 2.3 · BREAK & FIX: "Rack R07 is one PDU failure away from going dark"
==============================================================================

SITUATION
  Rack R07 holds two DGX H100 systems (8x H100 SXM5 each, ~10.2 kW max per
  system). It is fed by two independent 3-phase PDUs (feed A and feed B) under
  a 2N policy: EITHER feed alone must be able to carry the WHOLE rack, so a
  PDU, UPS or breaker can fail without dropping a single node.

  Overnight: a driver upgrade, a "PUE optimization" change on the cooling unit,
  and a rack install that skipped the blanking panels.

SYMPTOMS YOU WILL SEE
  * DCIM alarm: worst-case single-feed load OVER BUDGET (2N violated).
  * Rack inlet temperature above the ASHRAE recommended envelope.
  * GPUs reporting "HW Thermal Slowdown: Active" and low SM clocks.
  * The training job's step time is 38% worse than baseline.

YOUR TOOLS
  dcim rack show | dcim pdu show | dcim crah show | dcim events
  nvidia-smi ...                       (this VM is node dgx-01)
  aiio-node dgx-02 nvidia-smi ...      (run the same command "on" dgx-02)
  sudo for anything that changes state
  lab-check                            (verifies your fix)

GOAL (all must hold at the same time)
  1. The rack stays 2N: ONE feed must carry the ENTIRE rack load within its
     continuous (derated) rating.
  2. GPU power caps stay >= 500 W on every node (job SLA floor).
  3. Rack inlet temperature within ASHRAE recommended 18-27 C, without
     overcooling.
  4. No GPU in HW Thermal Slowdown.
  5. Fix root causes, not just alarms: airflow first, then setpoint.

RULES
  * Do NOT "fix" power by changing the redundancy policy.
  * Work it out on paper first: what does one feed deliver, what does one
    node draw as a function of the per-GPU cap?

  Start with:  dcim events ; dcim rack show ; dcim pdu show ; nvidia-smi
  Clean up :   sudo <this-script> --cleanup
==============================================================================
__BRIEF__

msg "lab installed and broken. Good luck."
exit 0

# =============================================================================
# SOLUTION (step by step) - read it only after you have tried
# =============================================================================
#
# STEP 0 - Triage: read the evidence before touching anything
#   $ dcim events
#   ... CHANGE dgx-01 driver upgrade + reboot: GPU power limits back to default 700 W ...
#   ... CHANGE CRAH-C2 supply setpoint 22 C -> 29 C (ticket CHG-4471 ...)
#   ... CRIT PDU-R07-A 2N violated: rack load 19.84 kW > single-feed continuous 18.40 kW ...
#
#   $ dcim pdu show
#     Nameplate per feed           : 23.00 kW  (sqrt(3) x 415 V x 32 A)
#     Usable continuous per feed   : 18.40 kW  (80% continuous-load derating)
#     Normal operation (shared)    : 9.92 kW on A, 9.92 kW on B
#     Failover (one feed lost)     : 19.84 kW on the surviving feed  [BREAKER TRIP]
#
#   Key insight: in normal operation each feed only carries ~50%, so the PDUs
#   look healthy (9.92 kW of 18.40 kW). The danger is invisible until a feed
#   fails. In 2N, size against the FAILOVER load, not the normal load.
#
#   $ nvidia-smi --query-gpu=index,power.draw,power.limit,temperature.gpu,clocks_event_reasons.hw_thermal_slowdown --format=csv
#   index, power.draw [W], power.limit [W], temperature.gpu, clocks_event_reasons.hw_thermal_slowdown
#   0, 665.00 W, 700.00 W, 88, Active
#   ...
#   7, 665.00 W, 700.00 W, 91, Active
#
# STEP 1 - Do the power math
#   3-phase power per feed:  P = sqrt(3) x V(L-L) x I x PF
#                            = 1.732 x 415 V x 32 A x 1.0 = ~23.0 kW nameplate
#   Continuous (80%)      :  23.0 x 0.80 = ~18.4 kW usable per feed
#   Node draw model       :  4600 W (CPUs, NVSwitch, NICs/DPUs, NVMe, fans)
#                            + 8 GPUs x cap x 0.95
#   Rack with 2 nodes must fit ONE feed:
#     2 x (4600 + 7.6 x cap) <= 18402
#     7.6 x cap <= 4601   ->  cap <= ~605 W
#   With the SLA floor (>= 500 W), any cap in 500..605 W works.
#   600 W gives max performance; 550 W leaves ~0.8 kW of headroom for fan
#   ramp, transient spikes and future growth. Choose 550 W:
#     2 x (4600 + 7.6 x 550) = 2 x 8780 = 17.56 kW  <= 18.40 kW
#
# STEP 2 - Apply the cap on BOTH nodes
#   $ sudo nvidia-smi -pl 550
#   Power limit for GPU 00000000:18:00.0 was set to 550.00 W from 700.00 W.
#   ...
#   All done.
#   $ sudo aiio-node dgx-02 nvidia-smi -pl 550
#
#   Expected afterwards: "SW Power Cap: Active" in nvidia-smi -q -d PERFORMANCE.
#   That is NORMAL and intended: the GPU is being held at the cap. The bad
#   reason is HW Thermal Slowdown, which is fixed in the next steps.
#
# STEP 3 - Fix airflow first: blanking panels
#   $ sudo dcim rack set-blanking installed
#   Open U slots let hot-aisle exhaust short-circuit back to the cold side
#   (recirculation). Making the supply air colder to compensate wastes energy
#   and still leaves hot spots. Blanking panels, sealed cable cut-outs and
#   aisle containment are the cheapest cooling capacity you will ever buy.
#
# STEP 4 - Bring the CRAH setpoint back into the ASHRAE envelope
#   Inlet = supply setpoint + recirculation penalty (+1 C with panels).
#   Target an inlet of 18..27 C. A setpoint of 24 C gives a 25 C inlet:
#   $ sudo dcim crah set-supply 24
#   CRAH-C2 supply setpoint: 29 C -> 24 C (rack R07 inlet now 25 C)
#   Why not 14 C? Inlet 15 C is below 18 C: overcooling raises chiller and fan
#   energy (worse PUE = total facility power / IT power) and adds condensation
#   risk. Why was 29 C wrong? A higher setpoint does improve PUE, but only up
#   to what the IT equipment tolerates (DGX H100 operating range tops out at
#   30 C ambient; with recirculation the real inlet was 35 C).
#
# STEP 5 - Verify
#   $ dcim rack show
#     Worst-case single-feed load : 17.56 kW of 18.40 kW per feed  [OK]
#     Rack inlet temperature      : 25 C  (ASHRAE recommended 18-27 C)  [OK]
#   $ nvidia-smi
#     temps ~66-70 C, SM ~1755 MHz, HW Thermal = Not Active
#   $ lab-check
#   RESULT: SOLVED. Rack R07 survives a feed loss, stays in the ASHRAE envelope ...
#
# STEP 6 - Fix the root cause that started it (production, not modeled here)
#   * nvidia-smi -pl is runtime-only: a reboot or driver reload restores the
#     default limit. That is exactly what caused this incident. Persist it:
#       - enable persistence (nvidia-persistenced) and apply the cap at boot
#         with a systemd oneshot unit ordered after the NVIDIA services, e.g.
#         ExecStart=/usr/bin/nvidia-smi -pl 550
#       - or manage it fleet-wide with DCGM: dcgmi config --set -g <group> -P 550
#   * Add the caps to the post-upgrade checklist and alert on
#     power.limit != expected, on HW Thermal Slowdown, and on single-feed
#     load above about 90% of the derated rating.
#   * Change tickets that touch cooling setpoints must reference the IT
#     equipment's inlet spec and be validated with rack-level inlet sensors.
#
# CONCEPTS THIS LAB EXERCISES (exam focus)
#   * kW per rack is the planning unit. DGX H100 is ~10.2 kW max; DGX B200 is
#     ~14.3 kW max. A few systems per rack quickly exceed what traditional
#     air-cooled racks (often 10-20 kW) were built for, which is why the
#     newer reference architectures plan high-density racks and move toward
#     direct liquid cooling (DLC).
#   * Redundancy: N, N+1 and 2N. In 2N, every feed is sized for 100% of the
#     load, so normal utilization per feed is <= 50%.
#   * Derating: plan continuous load at ~80% of breaker capacity.
#   * Heat: essentially all IT power becomes heat. 1 W = 3.412 BTU/hr, so
#     17.56 kW is about 59,900 BTU/hr the cooling plant must remove.
#   * PUE = total facility energy / IT equipment energy (1.0 is ideal).
#   * GPU power capping trades a small amount of throughput for density:
#     more GPUs per feed and per rack, often with better perf/W.
#   * Efficiency elsewhere in the node: offloading networking, storage and
#     security to BlueField DPUs frees host CPU cycles. That improves useful
#     work per watt, but it does not remove the need to size the feed for the
#     full system power.
# =============================================================================