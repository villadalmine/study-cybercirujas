#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 2.5: Key components and considerations of a cluster of an
#                       accelerated infrastructure
# Lab type : BREAK & FIX
# Scenario : "The GPU job hangs on two nodes, but the cluster looks healthy"
#
# Run it ONLY on a disposable lab VM. It does not touch the VM's real
# interfaces, routes or firewall. Everything lives in dedicated Linux network
# namespaces (prefix "aiio-") and is removed with "reset".
#
# Usage (as root):
#   ./aiio-2.5-breakfix.sh break    # build the mini-cluster and inject the fault
#   ./aiio-2.5-breakfix.sh status   # show the topology and the MTU of every hop
#   ./aiio-2.5-breakfix.sh check    # validate your fix (exit 0 = solved)
#   ./aiio-2.5-breakfix.sh hint     # progressive hints
#   ./aiio-2.5-breakfix.sh reset    # remove the whole lab
#
# Requirements: Linux with iproute2 (ip, bridge) and iputils (ping).
#               No GPU or NVIDIA drivers needed: the fault is in the fabric.
#
# Official references:
#   - NCA-AIIO exam study guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   - AI Infrastructure and Operations Fundamentals (NVIDIA Academy):
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   - DGX SuperPOD reference architecture (B200):
#     https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#   - DGX H100 component descriptions:
#     https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   - NVLink / NVLink Switch:
#     https://www.nvidia.com/en-us/data-center/nvlink/
#   - Network IO in the modern data center:
#     https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
#   - BlueField DPU offload and isolation:
#     https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
#
# -----------------------------------------------------------------------------
# WHY THIS MATTERS (context for the exam)
# -----------------------------------------------------------------------------
# An accelerated cluster such as a DGX SuperPOD is NOT "a bunch of GPU servers
# plugged into a switch". The reference architecture separates physically and
# logically distinct networks, each with its own purpose and its own tuning:
#
#   1. Compute fabric (east-west, GPU <-> GPU across nodes). InfiniBand or
#      Ethernet with RoCE, built rail-optimized and non-blocking. On a DGX H100
#      that is the 8 ConnectX-7 adapters (400 Gb/s each), one per GPU. NCCL
#      collectives (all-reduce, all-gather) use it via GPUDirect RDMA.
#   2. Storage fabric (north-south toward the parallel filesystem / NFS),
#      separate so checkpoints and dataset reads don't compete with
#      collectives.
#   3. In-band management (SSH, Slurm/Kubernetes control plane, images, etc.).
#   4. Out-of-band management (BMC/IPMI/Redfish, 1 GbE): reachable even when
#      the OS is dead.
#
# Inside the node, GPU <-> GPU uses NVLink/NVSwitch (not the network). Across
# nodes, everything goes through the compute fabric, and every hop on that path
# must agree on the parameters: link speed, MTU, PFC/ECN (RoCE), partition keys
# (InfiniBand), etc. A single switch port with a different MTU makes:
#   - ping, SSH, the scheduler health check... look fine (small packets);
#   - large transfers get SILENTLY dropped (a switch does not fragment, and with
#     RDMA/RoCE there is no fragmentation at all): NCCL hangs or times out and
#     the job "stalls" on exactly the pair of nodes that crosses that port.
#
# In this lab:
#   aiio-node01 / aiio-node02 -> two "GPU nodes"
#   aiio-leaf01               -> compute-fabric leaf switch (Linux bridge br-cmp)
#   aiio-oob                  -> management switch (Linux bridge br-mgmt)
#
#   Compute fabric (jumbo, MTU 9000):  10.100.0.0/24
#   Management     (standard, MTU 1500): 192.168.50.0/24
# =============================================================================

set -euo pipefail

readonly NS_N1="aiio-node01"
readonly NS_N2="aiio-node02"
readonly NS_LEAF="aiio-leaf01"
readonly NS_OOB="aiio-oob"
readonly ALL_NS=("$NS_N1" "$NS_N2" "$NS_LEAF" "$NS_OOB")

readonly CMP_MTU=9000
readonly MGMT_MTU=1500
# ICMP payload that exactly fills a 9000 frame: 9000 - 20 (IPv4) - 8 (ICMP)
readonly JUMBO_PAYLOAD=8972

readonly N1_CMP_IP="10.100.0.11"
readonly N2_CMP_IP="10.100.0.12"
readonly N1_MGMT_IP="192.168.50.11"
readonly N2_MGMT_IP="192.168.50.12"

readonly MARKER="/run/aiio-lab-2.5.marker"

# ---------------------------------------------------------------- helpers ----
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_rst=$'\e[0m'
info() { printf '%s[INFO]%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_ylw" "$c_rst" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$c_red" "$c_rst" "$*"; }
die()  { fail "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (sudo $0 $*)."
}

require_tools() {
  local t
  for t in ip ping; do
    command -v "$t" >/dev/null 2>&1 || die "Missing '$t'. Install iproute2 / iputils."
  done
  ip netns list >/dev/null 2>&1 || die "This kernel/iproute2 does not support 'ip netns'."
}

ns_exists() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

lab_exists() { [[ -f "$MARKER" ]]; }

nsx() { local ns=$1; shift; ip netns exec "$ns" "$@"; }

get_mtu() {
  # get_mtu <ns> <iface>
  ip -n "$1" -o link show dev "$2" 2>/dev/null \
    | sed -n 's/.* mtu \([0-9]\+\) .*/\1/p'
}

ping_ok() {
  # ping_ok <ns> <dst> <payload>   -> 0 if at least one reply comes back
  # -M do = set DF bit: no fragmentation allowed, same as RDMA traffic.
  nsx "$1" ping -n -q -c 3 -i 0.2 -W 1 -M do -s "$3" "$2" >/dev/null 2>&1
}

# ------------------------------------------------------------- build lab ----
build_lab() {
  info "Creating namespaces: ${ALL_NS[*]}"
  local ns
  for ns in "${ALL_NS[@]}"; do
    ns_exists "$ns" && die "Namespace '$ns' already exists. Run '$0 reset' first."
  done
  for ns in "${ALL_NS[@]}"; do
    ip netns add "$ns"
    ip -n "$ns" link set lo up
  done
  touch "$MARKER"

  # --- Leaf switch of the compute fabric ------------------------------------
  ip -n "$NS_LEAF" link add br-cmp type bridge
  ip -n "$NS_LEAF" link set br-cmp type bridge stp_state 0

  # --- OOB / management switch -----------------------------------------------
  ip -n "$NS_OOB" link add br-mgmt type bridge
  ip -n "$NS_OOB" link set br-mgmt type bridge stp_state 0

  # --- Cabling: each node has one compute NIC and one management NIC ---------
  #   node side      switch side
  #   n1-cmp   <-->  lf-n1   (leaf01, compute fabric)
  #   n2-cmp   <-->  lf-n2
  #   n1-mgmt  <-->  oob-n1  (oob, management)
  #   n2-mgmt  <-->  oob-n2
  local n
  for n in 1 2; do
    local node_ns="aiio-node0${n}"

    ip link add "n${n}-cmp" type veth peer name "lf-n${n}"
    ip link set "n${n}-cmp" netns "$node_ns"
    ip link set "lf-n${n}"  netns "$NS_LEAF"

    ip link add "n${n}-mgmt" type veth peer name "oob-n${n}"
    ip link set "n${n}-mgmt" netns "$node_ns"
    ip link set "oob-n${n}"  netns "$NS_OOB"

    # Compute fabric: jumbo frames end to end (node NIC + switch port)
    ip -n "$node_ns" link set "n${n}-cmp" mtu "$CMP_MTU"
    ip -n "$NS_LEAF" link set "lf-n${n}"  mtu "$CMP_MTU"
    ip -n "$NS_LEAF" link set "lf-n${n}"  master br-cmp
    ip -n "$NS_LEAF" link set "lf-n${n}"  up

    # Management: standard MTU
    ip -n "$node_ns" link set "n${n}-mgmt" mtu "$MGMT_MTU"
    ip -n "$NS_OOB"  link set "oob-n${n}"  mtu "$MGMT_MTU"
    ip -n "$NS_OOB"  link set "oob-n${n}"  master br-mgmt
    ip -n "$NS_OOB"  link set "oob-n${n}"  up

    ip -n "$node_ns" link set "n${n}-cmp"  up
    ip -n "$node_ns" link set "n${n}-mgmt" up
  done

  ip -n "$NS_LEAF" link set br-cmp  mtu "$CMP_MTU"
  ip -n "$NS_LEAF" link set br-cmp  up
  ip -n "$NS_OOB"  link set br-mgmt mtu "$MGMT_MTU"
  ip -n "$NS_OOB"  link set br-mgmt up

  ip -n "$NS_N1" addr add "${N1_CMP_IP}/24"  dev n1-cmp
  ip -n "$NS_N2" addr add "${N2_CMP_IP}/24"  dev n2-cmp
  ip -n "$NS_N1" addr add "${N1_MGMT_IP}/24" dev n1-mgmt
  ip -n "$NS_N2" addr add "${N2_MGMT_IP}/24" dev n2-mgmt

  # Give the bridges a moment to move the ports to forwarding
  sleep 1

  # Baseline sanity check BEFORE breaking anything
  if ping_ok "$NS_N1" "$N2_CMP_IP" "$JUMBO_PAYLOAD"; then
    ok "Baseline: jumbo frames node01 -> node02 work over the compute fabric."
  else
    warn "Baseline: jumbo did not pass before the fault. Check your kernel (veth/bridge)."
  fi
}

# ---------------------------------------------------------- inject fault ----
inject_fault() {
  # The "change window": someone replaced the optic/cable on the leaf port
  # facing node02 and reapplied a default template on the switch port,
  # MTU 1500. The node keeps 9000, the rest of the fabric keeps 9000.
  #
  # A Linux bridge (like a real switch) does NOT fragment when forwarding:
  # if the frame exceeds the egress port MTU, it drops it SILENTLY. No ICMP
  # "frag needed", no log line. The perfect black hole.
  ip -n "$NS_LEAF" link set lf-n2 mtu "$MGMT_MTU"
  # Restore the bridge's own MTU in case the kernel auto-lowered it, so the
  # only fault is the port (more realistic: the rest of the switch is fine).
  ip -n "$NS_LEAF" link set br-cmp mtu "$CMP_MTU" 2>/dev/null || true
}

# ------------------------------------------------------------- briefing -----
briefing() {
  cat <<EOF

${c_ylw}================================ INCIDENT ================================${c_rst}
Ticket #AI-2041 (severity: high)

  "Distributed training job (2 nodes, NCCL over the compute fabric) stays at
   0% on the first all-reduce and dies on timeout. Slurm shows both nodes
   IDLE/healthy, SSH into both nodes works, and 'ping' between them over the
   compute network also responds. Last night there was a change window on
   leaf01 of the compute fabric."

Lab topology:

        +--------------- aiio-leaf01 (br-cmp) ---------------+
        |                compute fabric                      |
   lf-n1|                                                    |lf-n2
        |                                                    |
   n1-cmp ${N1_CMP_IP}                           ${N2_CMP_IP} n2-cmp
   [ aiio-node01 ]                                   [ aiio-node02 ]
   n1-mgmt ${N1_MGMT_IP}                       ${N2_MGMT_IP} n2-mgmt
        |                                                    |
  oob-n1|                management / OOB                    |oob-n2
        +---------------- aiio-oob (br-mgmt) ----------------+

Symptoms you are going to see:
  - Normal ping over compute: WORKS
      ip netns exec ${NS_N1} ping -c2 ${N2_CMP_IP}
  - Ping over management: WORKS
      ip netns exec ${NS_N1} ping -c2 ${N2_MGMT_IP}
  - Full-size frame with DF (what NCCL/RDMA does in practice): 100% LOSS
      ip netns exec ${NS_N1} ping -c3 -M do -s ${JUMBO_PAYLOAD} ${N2_CMP_IP}

Your goal:
  1. Find WHICH hop of the compute path breaks the large frames.
  2. Fix it so the compute fabric carries jumbo frames (MTU ${CMP_MTU})
     END TO END in both directions.
  3. WITHOUT "fixing" it by lowering the nodes' MTU to 1500 (that hides the
     problem and costs throughput on a 400 Gb/s fabric) and without touching
     the management network, which must stay at ${MGMT_MTU}.

Useful tools: ip -d link, bridge link, ping -M do -s <size>, tracepath.
Validate with:  $0 check        Hints:  $0 hint
${c_ylw}===========================================================================${c_rst}
EOF
}

# --------------------------------------------------------------- status -----
status() {
  lab_exists || die "There is no lab. Run '$0 break'."
  printf '\n%-14s %-10s %-6s %s\n' "NAMESPACE" "IFACE" "MTU" "ROLE"
  printf '%-14s %-10s %-6s %s\n' "$NS_N1"   n1-cmp  "$(get_mtu "$NS_N1" n1-cmp)"    "node01 compute NIC"
  printf '%-14s %-10s %-6s %s\n' "$NS_LEAF" lf-n1   "$(get_mtu "$NS_LEAF" lf-n1)"   "leaf01 port -> node01"
  printf '%-14s %-10s %-6s %s\n' "$NS_LEAF" br-cmp  "$(get_mtu "$NS_LEAF" br-cmp)"  "leaf01 bridge"
  printf '%-14s %-10s %-6s %s\n' "$NS_LEAF" lf-n2   "$(get_mtu "$NS_LEAF" lf-n2)"   "leaf01 port -> node02"
  printf '%-14s %-10s %-6s %s\n' "$NS_N2"   n2-cmp  "$(get_mtu "$NS_N2" n2-cmp)"    "node02 compute NIC"
  printf '%-14s %-10s %-6s %s\n' "$NS_N1"   n1-mgmt "$(get_mtu "$NS_N1" n1-mgmt)"   "node01 management NIC"
  printf '%-14s %-10s %-6s %s\n' "$NS_N2"   n2-mgmt "$(get_mtu "$NS_N2" n2-mgmt)"   "node02 management NIC"
  echo
  warn "In a real cluster you don't get a table like this: you have to collect it"
  warn "hop by hop (node NIC, switch port, UFM/NVUE...). Try to find the fault"
  warn "first using ping -M do only, and use this table to confirm."
}

# ---------------------------------------------------------------- hints -----
hint() {
  cat <<EOF
Hint 1: A normal ping uses 84-byte packets. Any MTU >= 84 lets them through.
        What size does a "full" frame on a 9000 MTU fabric have?

Hint 2: Look for the largest size that DOES pass (binary search):
          for s in 1472 1473 4000 8972; do
            ip netns exec ${NS_N1} ping -c1 -W1 -M do -s \$s ${N2_CMP_IP} \\
              >/dev/null && echo "\$s OK" || echo "\$s LOST"
          done
        1472 = 1500 - 28. If 1472 passes and 1473 doesn't, some hop is at 1500.

Hint 3: The nodes' NIC is not the culprit if 'ip -n <node> link' says 9000.
        The ticket mentions a change window on leaf01...
          ip -n ${NS_LEAF} -d link show
          ip netns exec ${NS_LEAF} bridge link show

Hint 4: A switch does not fragment: an egress port with a smaller MTU drops
        the frame. Which port of br-cmp has an MTU different from the rest?
EOF
}

# ---------------------------------------------------------------- check -----
check() {
  lab_exists || die "There is no lab. Run '$0 break'."
  local errors=0 m

  echo; info "Validating the compute fabric (expected MTU ${CMP_MTU} on every hop)..."
  for pair in "$NS_N1:n1-cmp" "$NS_LEAF:lf-n1" "$NS_LEAF:br-cmp" "$NS_LEAF:lf-n2" "$NS_N2:n2-cmp"; do
    m=$(get_mtu "${pair%%:*}" "${pair##*:}")
    if [[ "$m" == "$CMP_MTU" ]]; then
      ok "${pair} mtu ${m}"
    else
      fail "${pair} mtu ${m:-?} (expected ${CMP_MTU})"
      errors=$((errors + 1))
    fi
  done

  info "Validating that management stays at ${MGMT_MTU} (separate network, separate tuning)..."
  for pair in "$NS_N1:n1-mgmt" "$NS_N2:n2-mgmt" "$NS_OOB:oob-n1" "$NS_OOB:oob-n2"; do
    m=$(get_mtu "${pair%%:*}" "${pair##*:}")
    if [[ "$m" == "$MGMT_MTU" ]]; then
      ok "${pair} mtu ${m}"
    else
      fail "${pair} mtu ${m:-?} (expected ${MGMT_MTU}; don't touch the management network)"
      errors=$((errors + 1))
    fi
  done

  info "Data-plane tests (DF bit set, no fragmentation)..."
  if ping_ok "$NS_N1" "$N2_CMP_IP" 56; then ok "compute small  node01 -> node02"
  else fail "compute small  node01 -> node02"; errors=$((errors + 1)); fi

  if ping_ok "$NS_N1" "$N2_CMP_IP" "$JUMBO_PAYLOAD"; then ok "compute jumbo  node01 -> node02 (${JUMBO_PAYLOAD} B)"
  else fail "compute jumbo  node01 -> node02 (${JUMBO_PAYLOAD} B)"; errors=$((errors + 1)); fi

  if ping_ok "$NS_N2" "$N1_CMP_IP" "$JUMBO_PAYLOAD"; then ok "compute jumbo  node02 -> node01 (${JUMBO_PAYLOAD} B)"
  else fail "compute jumbo  node02 -> node01 (${JUMBO_PAYLOAD} B)"; errors=$((errors + 1)); fi

  if ping_ok "$NS_N1" "$N2_MGMT_IP" 1472; then ok "management     node01 -> node02 (1472 B)"
  else fail "management     node01 -> node02 (1472 B)"; errors=$((errors + 1)); fi

  echo
  if (( errors == 0 )); then
    ok "SOLVED: the compute fabric carries jumbo frames end to end and management is intact."
    ok "In production you would now re-run nccl-tests (all_reduce_perf) to confirm bandwidth."
    return 0
  fi
  fail "${errors} check(s) failed. Keep diagnosing ('$0 hint')."
  return 1
}

# ---------------------------------------------------------------- reset -----
reset_lab() {
  local ns
  for ns in "${ALL_NS[@]}"; do
    if ns_exists "$ns"; then
      ip netns del "$ns" && info "Namespace $ns removed."
    fi
  done
  rm -f "$MARKER"
  ok "Lab removed. The VM's real interfaces were never touched."
}

# ----------------------------------------------------------------- main -----
main() {
  local action="${1:-break}"
  case "$action" in
    break)
      require_root "$@"; require_tools
      lab_exists && die "The lab already exists. Use '$0 reset' to start over."
      build_lab
      inject_fault
      briefing
      ;;
    status) require_root "$@"; status ;;
    hint)   hint ;;
    check)  require_root "$@"; check ;;
    reset)  require_root "$@"; reset_lab ;;
    *)      die "Unknown action '$action'. Use: break | status | hint | check | reset" ;;
  esac
}

main "$@"

# =============================================================================
# SOLUTION (do not read until you've tried)
# =============================================================================
#
# 1) Reproduce the symptom and characterize it.
#    A normal ping works because it sends 84-byte packets:
#
#      # ip netns exec aiio-node01 ping -c2 10.100.0.12
#      2 packets transmitted, 2 received, 0% packet loss
#
#    A full-size frame with the DF bit set (Don't Fragment, which is what
#    RDMA/RoCE or GPUDirect traffic effectively does: it is never fragmented)
#    gets lost:
#
#      # ip netns exec aiio-node01 ping -c3 -M do -s 8972 10.100.0.12
#      3 packets transmitted, 0 received, 100% packet loss
#
#    Note that there is NO "message too long" error or "Frag needed" ICMP:
#    the local NIC accepts 9000, so the frame leaves; it is dropped further
#    along the path, silently. That's why Slurm/Kubernetes health checks and
#    SSH don't see it.
#
# 2) Find the effective path MTU (binary search):
#
#      # for s in 1472 1473 8972; do
#          ip netns exec aiio-node01 ping -c1 -W1 -M do -s $s 10.100.0.12 \
#            >/dev/null && echo "$s OK" || echo "$s LOST"; done
#      1472 OK
#      1473 LOST
#      8972 LOST
#
#    1472 + 28 = 1500 -> some hop has MTU 1500.
#
# 3) Rule out the endpoints (the nodes' NICs):
#
#      # ip -n aiio-node01 link show n1-cmp | grep -o 'mtu [0-9]*'
#      mtu 9000
#      # ip -n aiio-node02 link show n2-cmp | grep -o 'mtu [0-9]*'
#      mtu 9000
#
# 4) Inspect the switch (leaf01). The ticket says there was a change window:
#
#      # ip netns exec aiio-leaf01 bridge link show
#      ... lf-n1@...: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 master br-cmp state forwarding ...
#      ... lf-n2@...: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br-cmp state forwarding ...
#
#    Port lf-n2 (facing node02) was left at 1500. The bridge, like a real
#    switch, does not fragment when forwarding: it drops any frame larger than
#    the egress port MTU.
#
# 5) Fix it ON THE SWITCH PORT (the root cause), not on the nodes:
#
#      # ip -n aiio-leaf01 link set lf-n2 mtu 9000
#      # ip -n aiio-leaf01 link set br-cmp mtu 9000
#
#    (The second line is defensive: on some kernels the bridge auto-adjusts
#    its own MTU to the minimum of its ports.)
#
# 6) Verify in both directions and with the validator:
#
#      # ip netns exec aiio-node01 ping -c3 -M do -s 8972 10.100.0.12
#      3 packets transmitted, 3 received, 0% packet loss
#      # ip netns exec aiio-node02 ping -c3 -M do -s 8972 10.100.0.11
#      3 packets transmitted, 3 received, 0% packet loss
#      # ./aiio-2.5-breakfix.sh check
#      [ OK ] SOLVED: ...
#
# 7) Clean up:
#
#      # ./aiio-2.5-breakfix.sh reset
#
# -----------------------------------------------------------------------------
# WHY "lower the nodes to 1500" IS THE WRONG ANSWER
# -----------------------------------------------------------------------------
#   - It makes the symptom go away, but it degrades the whole fabric: more
#     headers per byte transferred, more packets per second for the NIC and
#     the switch to process, lower effective throughput for collectives.
#   - It leaves the fabric inconsistent: the next node added with the correct
#     template (9000) will break again against that port.
#   - The rule in an accelerated cluster is: the MTU is a FABRIC property,
#     defined once and applied identically on every hop (node NICs, leaf and
#     spine ports, and on DPUs/BlueField if they sit in the data path).
#
# -----------------------------------------------------------------------------
# HOW IT MAPS TO PRODUCTION
# -----------------------------------------------------------------------------
#   - In RoCE over Spectrum Ethernet, the hosts run jumbo frames (9000) and the
#     RoCE MTU (4096) must fit inside the frame; one port at 1500 breaks RDMA
#     completely. Additionally, RoCE needs consistent PFC/ECN on every hop.
#   - In InfiniBand, the MTU is negotiated per port (up to 4096) and the
#     Subnet Manager / UFM shows ports with degraded MTU or speed; checks
#     like `ibstat`, `ibdiagnet` or the UFM views play the role that
#     'bridge link show' plays here.
#   - The real symptom shows up in NCCL: all_reduce_perf from nccl-tests with
#     very low bandwidth or a hang, NCCL_DEBUG=INFO showing timeouts on a
#     specific rank pair. Validating the fabric with nccl-tests after any
#     change window is standard practice in DGX SuperPOD deployments.
#   - Separate networks (compute, storage, in-band, OOB) let you diagnose with
#     the management network while the compute fabric is broken, exactly as
#     you did in this lab over 192.168.50.0/24.
# =============================================================================