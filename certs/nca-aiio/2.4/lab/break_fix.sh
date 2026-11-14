#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 2.4: On-prem vs cloud infrastructure for AI
# BREAK & FIX LAB: "The dataset lives in the cloud, the GPUs live on-prem"
#
# Run ONLY on a disposable lab VM. The script creates an isolated network
# namespace ("aiio-cloud") joined to the host by a veth pair, and serves a
# synthetic training dataset from it through a simulated WAN link (tc netem:
# added latency plus a bandwidth cap). It does not touch your real NICs,
# routes or firewall. Everything it creates lives under /opt/aiio-lab and in
# the aiio-cloud netns, and `cleanup` removes all of it.
#
# Usage (as root):
#   ./aiio-2.4-breakfix.sh break     # build the lab and inject the fault
#   ./aiio-2.4-breakfix.sh status    # show lab state and the WAN shaping
#   ./aiio-2.4-breakfix.sh check     # grade your fix (re-runs the job itself)
#   ./aiio-2.4-breakfix.sh cleanup   # remove everything
#   Add --yes to skip the confirmation prompt.
#
# Concepts exercised (see official sources):
#   - Data gravity and data locality. Accelerated systems such as DGX H100 ship
#     with local NVMe cache drives so that training reads stay inside the node
#     and off the network:
#     https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   - On-prem gives you full control of the fabric: NVLink inside the node,
#     InfiniBand/Ethernet compute and storage fabrics between nodes:
#     https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#     https://www.nvidia.com/en-us/data-center/nvlink/
#   - The I/O path is the usual bottleneck that starves GPUs, and the reason
#     for GPUDirect Storage/RDMA and for DPUs:
#     https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
#     https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
#   - On-prem vs cloud trade-offs (CapEx vs OpEx, elasticity, egress, power and
#     cooling, sovereignty, lead time, operations staffing):
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
# =============================================================================
set -euo pipefail

LAB=/opt/aiio-lab
NS=aiio-cloud
VETH_HOST=veth-onprem
VETH_NS=veth-cloud
HOST_IP=10.200.0.1
CLOUD_IP=10.200.0.2
PORT=8080
SHARDS=8
SHARD_MB=1
WAN_DELAY=40ms
WAN_RATE=8mbit
ASSUME_YES=no

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_off=$'\e[0m'
info(){ printf '%s[*]%s %s\n' "$c_cyn" "$c_off" "$*"; }
ok(){   printf '%s[PASS]%s %s\n' "$c_grn" "$c_off" "$*"; }
bad(){  printf '%s[FAIL]%s %s\n' "$c_red" "$c_off" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*"; }
die(){  printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || die "Run as root (sudo $0 $*)."; }

require_tools(){
  local t missing=()
  for t in ip tc python3 curl sha256sum awk sed head; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  ((${#missing[@]} == 0)) || die "Missing tools: ${missing[*]} (install iproute2/iproute-tc, python3, curl, coreutils)."
}

confirm(){
  [[ $ASSUME_YES == yes ]] && return 0
  if command -v systemd-detect-virt >/dev/null 2>&1 && ! systemd-detect-virt -q; then
    warn "This does not look like a virtual machine."
  fi
  warn "This lab creates netns '$NS', veth '$VETH_HOST', subnet ${HOST_IP%.*}.0/30 and $LAB."
  read -r -p "Is this a disposable lab VM? Type 'yes' to continue: " ans
  [[ $ans == yes ]] || die "Aborted."
}

# -----------------------------------------------------------------------------
write_job(){
  mkdir -p "$LAB/bin" "$LAB/etc" "$LAB/run"

  # Job config: points straight at the "cloud" object store. This is the bug.
  cat >"$LAB/etc/job.env" <<EOF
# Training job configuration (sourced by $LAB/bin/train-job.sh)
# Supported schemes: http://  https://  file://
DATASET_URI=http://$CLOUD_IP:$PORT
EPOCHS=3
# Simulated GPU compute time per shard, in seconds
COMPUTE_PER_SHARD_S=0.5
EOF

  cat >"$LAB/bin/train-job.sh" <<'EOF'
#!/usr/bin/env bash
# Simulated data-parallel training loop.
# Each epoch reads every shard listed in MANIFEST.sha256 from DATASET_URI,
# verifies its integrity and "computes" on it. GPU utilization is
# compute_time / wall_time: time spent waiting for I/O is GPU idle time.
set -euo pipefail
LAB=/opt/aiio-lab
# shellcheck disable=SC1091
source "$LAB/etc/job.env"
: "${DATASET_URI:?DATASET_URI not set}" "${EPOCHS:?EPOCHS not set}" "${COMPUTE_PER_SHARD_S:?COMPUTE_PER_SHARD_S not set}"

now(){ date +%s.%N; }
rx_bytes(){ cat /sys/class/net/veth-onprem/statistics/rx_bytes 2>/dev/null || echo 0; }
add(){ awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN{printf "%.3f", a + (c - b)}'; }

fetch(){
  case "$DATASET_URI" in
    http://*|https://*) curl -sSf --max-time 120 "${DATASET_URI%/}/$1" ;;
    file://*)           cat "${DATASET_URI#file://}/$1" ;;
    *) echo "train-job: unsupported DATASET_URI scheme: $DATASET_URI" >&2; exit 2 ;;
  esac
}

rx0=$(rx_bytes)
t0=$(now)
manifest=$(fetch MANIFEST.sha256)
[[ -n $manifest ]] || { echo "train-job: empty manifest" >&2; exit 2; }

io=0; compute=0; processed=0
echo "train-job: DATASET_URI=$DATASET_URI EPOCHS=$EPOCHS"
for ((e = 1; e <= EPOCHS; e++)); do
  te=$(now); eio=0; ecomp=0
  while read -r -u 3 sum name; do
    [[ -z ${name:-} ]] && continue
    ts=$(now)
    got=$(fetch "$name" | sha256sum | awk '{print $1}')
    if [[ $got != "$sum" ]]; then
      echo "train-job: INTEGRITY ERROR on $name (expected $sum, got $got)" >&2
      exit 3
    fi
    tio=$(now)
    sleep "$COMPUTE_PER_SHARD_S"
    tcomp=$(now)
    eio=$(add "$eio" "$ts" "$tio")
    ecomp=$(add "$ecomp" "$tio" "$tcomp")
    processed=$((processed + 1))
  done 3<<<"$manifest"
  tend=$(now)
  io=$(awk -v a="$io" -v b="$eio" 'BEGIN{printf "%.3f", a+b}')
  compute=$(awk -v a="$compute" -v b="$ecomp" 'BEGIN{printf "%.3f", a+b}')
  awk -v e="$e" -v n="$EPOCHS" -v s="$te" -v t="$tend" -v io="$eio" -v c="$ecomp" \
    'BEGIN{w=t-s; printf "  epoch %d/%d: wall %.2fs  io-wait %.2fs  GPU util %.0f%%\n", e, n, w, io, (w>0?100*c/w:0)}'
done
t1=$(now)
rx1=$(rx_bytes)
awk -v s="$t0" -v t="$t1" -v io="$io" -v c="$compute" -v p="$processed" -v ep="$EPOCHS" -v eg="$((rx1 - rx0))" \
  'BEGIN{w=t-s; printf "RESULT shards=%d epochs=%d wall=%.2f io=%.2f compute=%.2f util=%.0f egress_bytes=%d\n", p, ep, w, io, c, (w>0?100*c/w:0), eg}'
EOF
  chmod 0755 "$LAB/bin/train-job.sh"
}

build_cloud(){
  info "Generating synthetic dataset ($SHARDS shards x ${SHARD_MB}MiB) in the 'cloud' bucket..."
  mkdir -p "$LAB/cloud"
  local i
  for ((i = 0; i < SHARDS; i++)); do
    head -c "${SHARD_MB}M" /dev/urandom >"$LAB/cloud/$(printf 'shard-%03d.bin' "$i")"
  done
  (cd "$LAB/cloud" && sha256sum shard-*.bin >MANIFEST.sha256)

  info "Creating netns '$NS' and veth pair $VETH_HOST <-> $VETH_NS..."
  ip netns add "$NS"
  ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
  ip link set "$VETH_NS" netns "$NS"
  ip addr add "$HOST_IP/30" dev "$VETH_HOST"
  ip link set "$VETH_HOST" up
  ip netns exec "$NS" ip link set lo up
  ip netns exec "$NS" ip addr add "$CLOUD_IP/30" dev "$VETH_NS"
  ip netns exec "$NS" ip link set "$VETH_NS" up

  info "Starting the 'cloud object store' (HTTP) at $CLOUD_IP:$PORT..."
  nohup ip netns exec "$NS" python3 -m http.server "$PORT" --bind "$CLOUD_IP" \
    --directory "$LAB/cloud" >"$LAB/run/cloud-http.log" 2>&1 &
  echo $! >"$LAB/run/cloud-http.pid"

  local tries=0
  until curl -sSf --max-time 2 "http://$CLOUD_IP:$PORT/MANIFEST.sha256" >/dev/null 2>&1; do
    tries=$((tries + 1)); ((tries < 20)) || die "Cloud HTTP server did not come up; see $LAB/run/cloud-http.log"
    sleep 0.5
  done
}

inject_fault(){
  # The "fault" is reality: a WAN between the on-prem GPUs and the cloud bucket.
  ip netns exec "$NS" tc qdisc replace dev "$VETH_NS" root netem delay "$WAN_DELAY" rate "$WAN_RATE"
}

briefing(){
  cat <<EOF

${c_ylw}==================================== SCENARIO ====================================${c_off}
Your team runs training on an on-prem GPU node (this VM). To "save local
storage", someone pointed the training job straight at a dataset held in a
public-cloud object store. The link between on-prem and cloud is a WAN
(${WAN_DELAY} one-way added latency, ${WAN_RATE} sustained throughput).

${c_cyn}Job:${c_off}     $LAB/bin/train-job.sh
${c_cyn}Config:${c_off}  $LAB/etc/job.env
${c_cyn}Cloud:${c_off}   http://$CLOUD_IP:$PORT/  (MANIFEST.sha256 + shard-*.bin)

${c_red}SYMPTOMS YOU WILL SEE${c_off}
  - Run the job: every epoch takes many seconds and "GPU util" sits around 30%.
    The GPUs spend most of their time idle waiting for I/O.
  - RESULT reports egress_bytes of roughly ${SHARD_MB}MiB x $SHARDS shards x EPOCHS on
    every run: you pull (and in a real cloud, PAY egress for) the same data
    again on every epoch and on every run.
  - Nothing is "down". Ping works and HTTP returns 200. That is what makes
    this class of problem easy to miss in production.

${c_grn}GOAL (what 'check' grades)${c_off}
  1. Do NOT remove the WAN shaping in netns '$NS'. You cannot delete the
     speed of light or your ISP contract. Fix the architecture, not physics.
  2. Stage the dataset ONCE onto local storage under $LAB/cache
     (the role of a DGX node's local NVMe cache), with the shards' integrity
     verified against MANIFEST.sha256.
  3. Point the job at the local copy (file://...) and keep EPOCHS >= 3.
  4. A full job run must reach >= 80% GPU util with ~0 bytes crossing the WAN.

Hints: ping, curl -w '%{time_total} %{speed_download}', tc qdisc show (inside
the netns), sha256sum -c. Think about data gravity: move compute to the data,
or move the data once and close to the compute.

Start with:   $LAB/bin/train-job.sh
Grade with:   $0 check
${c_ylw}==================================================================================${c_off}
EOF
}

# -----------------------------------------------------------------------------
cmd_break(){
  require_root; require_tools
  if ip netns list 2>/dev/null | grep -qw "$NS" || [[ -e $LAB ]]; then
    die "Lab already exists. Run '$0 cleanup' first."
  fi
  if ip -4 addr show | grep -q "inet ${HOST_IP%.*}\."; then
    die "Subnet ${HOST_IP%.*}.0/30 already in use on this host; refusing to continue."
  fi
  ip link show "$VETH_HOST" >/dev/null 2>&1 && die "Interface $VETH_HOST already exists."
  confirm
  mkdir -p "$LAB/run"
  write_job
  build_cloud
  inject_fault
  ok "Lab ready. The fault is in place."
  briefing
}

cmd_status(){
  require_root
  ip netns list 2>/dev/null | grep -qw "$NS" || die "Lab not present. Run '$0 break'."
  info "WAN shaping on the cloud side:"
  ip netns exec "$NS" tc qdisc show dev "$VETH_NS" | sed 's/^/    /'
  info "Job config ($LAB/etc/job.env):"
  grep -v '^#' "$LAB/etc/job.env" | sed 's/^/    /'
  info "Local cache contents:"
  if [[ -d $LAB/cache ]]; then ls -l "$LAB/cache" | sed 's/^/    /'; else echo "    (none)"; fi
  info "Bytes received from the 'cloud' since lab start: $(cat /sys/class/net/$VETH_HOST/statistics/rx_bytes)"
}

cmd_check(){
  require_root
  ip netns list 2>/dev/null | grep -qw "$NS" || die "Lab not present. Run '$0 break'."
  local fail=0 qd uri epochs path out result util egress shards

  qd=$(ip netns exec "$NS" tc qdisc show dev "$VETH_NS" 2>/dev/null || true)
  if grep -q netem <<<"$qd" && grep -q delay <<<"$qd"; then
    ok "WAN shaping still in place (you fixed the design, not physics)."
  else
    bad "The WAN netem qdisc was removed. Restore it: ip netns exec $NS tc qdisc replace dev $VETH_NS root netem delay $WAN_DELAY rate $WAN_RATE"
    fail=1
  fi

  uri=$(bash -c "source '$LAB/etc/job.env'; echo \"\$DATASET_URI\"")
  epochs=$(bash -c "source '$LAB/etc/job.env'; echo \"\$EPOCHS\"")
  if [[ $uri == file://* ]]; then
    path=${uri#file://}
    ok "Job reads from local storage: $uri"
  else
    bad "Job still reads across the WAN: DATASET_URI=$uri"
    fail=1; path=""
  fi
  if [[ $epochs =~ ^[0-9]+$ ]] && ((epochs >= 3)); then
    ok "EPOCHS=$epochs (>= 3)."
  else
    bad "EPOCHS must stay >= 3 (found '$epochs'). Training less is not a fix."
    fail=1
  fi

  if [[ -n $path ]]; then
    if [[ $(readlink -f "$path") != "$LAB/cache" ]]; then
      bad "The local dataset must live in $LAB/cache (found $path)."
      fail=1
    elif [[ ! -f $path/MANIFEST.sha256 ]]; then
      bad "No MANIFEST.sha256 in $path."
      fail=1
    elif ! cmp -s "$path/MANIFEST.sha256" "$LAB/cloud/MANIFEST.sha256"; then
      bad "Local MANIFEST.sha256 does not match the cloud's manifest."
      fail=1
    elif (cd "$path" && sha256sum --quiet -c MANIFEST.sha256 >/dev/null 2>&1); then
      ok "All $SHARDS shards present and verified in $path."
    else
      bad "Shards in $path are missing or corrupt (sha256sum -c fails)."
      fail=1
    fi
  fi

  if ((fail == 0)); then
    info "Running the training job to measure it (this takes a few seconds)..."
    if out=$("$LAB/bin/train-job.sh" 2>&1); then
      echo "$out" | sed 's/^/    /'
      result=$(grep '^RESULT' <<<"$out" || true)
      util=$(sed -n 's/.* util=\([0-9]*\).*/\1/p' <<<"$result")
      egress=$(sed -n 's/.* egress_bytes=\([0-9]*\).*/\1/p' <<<"$result")
      shards=$(sed -n 's/.*shards=\([0-9]*\).*/\1/p' <<<"$result")
      if [[ $shards == $((SHARDS * epochs)) ]]; then ok "Processed $shards shards ($SHARDS x $epochs epochs)."
      else bad "Processed ${shards:-?} shards, expected $((SHARDS * epochs))."; fail=1; fi
      if [[ -n $util ]] && ((util >= 80)); then ok "GPU util ${util}% (>= 80%)."
      else bad "GPU util ${util:-?}% is below 80%."; fail=1; fi
      if [[ -n $egress ]] && ((egress < 65536)); then ok "WAN traffic during the run: ${egress} bytes (~0)."
      else bad "WAN traffic during the run: ${egress:-?} bytes; the job still pulls data from the cloud."; fail=1; fi
    else
      echo "$out" | sed 's/^/    /'
      bad "The training job failed."
      fail=1
    fi
  fi

  echo
  if ((fail == 0)); then
    ok "LAB SOLVED. Data is staged once, close to the GPUs; the WAN carries ~nothing per run."
    cat <<'EOF'

Takeaways for the exam:
  - On-prem advantages: data locality, predictable latency and bandwidth (NVLink,
    InfiniBand/RoCE fabrics you design), no egress fees, data sovereignty and
    control, lower cost per GPU-hour at sustained high utilization.
  - On-prem challenges: CapEx, procurement lead time, power and cooling (a
    DGX H100 draws about 10 kW at peak), floor space, operations staffing.
  - Cloud advantages: OpEx, elasticity and bursting, fast start, managed
    services, no hardware lifecycle to run.
  - Cloud challenges: GPU capacity and quotas, egress costs, shared tenancy,
    data gravity, cost at sustained 24x7 utilization.
  - Hybrid: keep the data and the steady-state workload where the data lives,
    burst elsewhere, and stage or cache the datasets explicitly.
EOF
  else
    bad "Not solved yet. Re-read the goals: $0 status"
    exit 1
  fi
}

cmd_cleanup(){
  require_root
  if [[ -f $LAB/run/cloud-http.pid ]]; then
    kill "$(cat "$LAB/run/cloud-http.pid")" 2>/dev/null || true
  fi
  if ip netns list 2>/dev/null | grep -qw "$NS"; then
    ip netns pids "$NS" 2>/dev/null | xargs -r kill 2>/dev/null || true
    sleep 0.5
    ip netns del "$NS"
  fi
  ip link del "$VETH_HOST" 2>/dev/null || true
  [[ -d $LAB ]] && rm -rf --one-file-system "$LAB"
  ok "Lab removed (netns $NS, veth $VETH_HOST, $LAB)."
}

usage(){ echo "Usage: $0 {break|status|check|cleanup} [--yes]"; exit 2; }

ACTION=""
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=yes ;;
    break|status|check|cleanup) ACTION=$arg ;;
    *) usage ;;
  esac
done
case "$ACTION" in
  break)   cmd_break ;;
  status)  cmd_status ;;
  check)   cmd_check ;;
  cleanup) cmd_cleanup ;;
  *)       usage ;;
esac

# =============================================================================
# SOLUTION (step by step). Try it on your own first.
# =============================================================================
#
# 1) Reproduce and measure the symptom:
#      sudo /opt/aiio-lab/bin/train-job.sh
#    Each epoch takes ~13 s at ~30% "GPU util", and egress_bytes is ~25 MB
#    (8 MiB x 3 epochs, plus HTTP overhead). The job is I/O-bound.
#
# 2) Characterize the link. Do not guess:
#      ping -c 3 10.200.0.2
#        -> rtt ~40 ms: a WAN, not a datacenter fabric (microseconds)
#      curl -o /dev/null -s -w '%{time_total}s %{speed_download}B/s\n' \
#           http://10.200.0.2:8080/shard-000.bin
#        -> ~1.1 s per 1 MiB shard, ~1 MB/s (the 8 Mbit/s cap)
#      sudo ip netns exec aiio-cloud tc qdisc show dev veth-cloud
#        -> qdisc netem ... delay 40ms rate 8Mbit
#    Conclusion: per-epoch reads across the WAN starve the GPUs. In a real
#    cloud, every epoch would also be billed as egress. That qdisc stands in
#    for physics and contracts, so you must not delete it.
#
# 3) Stage the dataset once onto local storage (the node's NVMe cache):
#      sudo mkdir -p /opt/aiio-lab/cache && cd /opt/aiio-lab/cache
#      sudo curl -sSfO http://10.200.0.2:8080/MANIFEST.sha256
#      for f in $(awk '{print $2}' MANIFEST.sha256); do
#        sudo curl -sSfO "http://10.200.0.2:8080/$f"
#      done
#      sha256sum -c MANIFEST.sha256        # every line must say: OK
#    You pay the WAN cost exactly once (~8 MiB) instead of on every epoch and
#    every run.
#
# 4) Point the job at the local copy:
#      sudo sed -i 's|^DATASET_URI=.*|DATASET_URI=file:///opt/aiio-lab/cache|' \
#           /opt/aiio-lab/etc/job.env
#      grep DATASET_URI /opt/aiio-lab/etc/job.env
#
# 5) Verify:
#      sudo /opt/aiio-lab/bin/train-job.sh
#        -> each epoch ~4 s, GPU util ~95%+, egress_bytes=0
#      sudo ./aiio-2.4-breakfix.sh check
#
# 6) Clean up:
#      sudo ./aiio-2.4-breakfix.sh cleanup
#
# Production translation:
#   - Stage datasets onto the node's local NVMe (DGX cache RAID), or onto a
#     parallel filesystem on the storage fabric, before the job starts.
#     Schedulers do this with prolog/stage-in steps; Kubernetes uses
#     init containers or dataset caching layers.
#   - Keep compute next to the data: if the data lives in the cloud, run the
#     training in that region. If it lives on-prem, burst only workloads whose
#     data can move cheaply.
#   - Budget egress and WAN bandwidth explicitly in hybrid designs. Use the
#     storage and compute fabrics (GPUDirect Storage, RDMA, DPU offload) so
#     that I/O keeps up with the GPUs.
# =============================================================================