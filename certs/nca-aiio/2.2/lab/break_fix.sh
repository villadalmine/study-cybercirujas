#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 2.2: Scale a GPU infrastructure for different use cases
# Break & Fix lab: "We added a second GPU node and multi-node training broke"
#
# WHAT THIS LAB EMULATES
#   A two-node, two-rail, rail-optimized compute fabric. Production DGX
#   systems work the same way. A DGX H100 has 8 ConnectX-7 ports for the
#   compute (east-west) fabric, one per GPU. In a DGX SuperPOD every
#   "NIC N" of every node is cabled to the same leaf switch ("rail N").
#   Same-rank GPUs on different nodes then talk through a single leaf hop.
#   NCCL builds its rings/trees on that assumption.
#
#   No GPUs, InfiniBand or RDMA are needed. Each "node" is a Linux network
#   namespace. Each "rail leaf switch" is a Linux bridge. Each NIC cable
#   is a veth pair. The lab uses an Ethernet (RoCE-style) jumbo-frame
#   fabric with MTU 9000. A large DF ping stands in for a large NCCL
#   message.
#
# SAFETY
#   - Only touches objects prefixed "aiio-" (netns, bridges) plus veths
#     named n<node>r<rail>-h. It never modifies host NICs, routes or
#     firewall rules.
#   - Run it in a disposable lab VM, as root.
#   - Use "cleanup" to remove everything.
#
# USAGE
#   sudo ./break_fix.sh break     # build healthy fabric, verify, then inject faults
#   sudo ./break_fix.sh check     # grade your fix
#   sudo ./break_fix.sh hint [1-3]
#   sudo ./break_fix.sh cleanup
#
# OFFICIAL REFERENCES
#   NCA-AIIO exam guide:
#     https://dam-cdn.nvd.orangelogic.com/AssetLink/x874j05hy3m3r2sor84kpvp70750m468.pdf
#   AI Infrastructure & Operations Fundamentals course:
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
#   DGX SuperPOD B200 reference architecture (rail-optimized compute fabric):
#     https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#   DGX H100 component descriptions (ConnectX-7, OSFP compute ports):
#     https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   NVLink / NVSwitch (scale-up inside the node vs scale-out across nodes):
#     https://www.nvidia.com/en-us/data-center/nvlink/
#   Network IO in the modern data center:
#     https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
#   BlueField DPU offload and isolation:
#     https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
# =============================================================================

set -euo pipefail

LAB_DIR="/tmp/aiio-lab-2.2"
NODES=(1 2)
RAILS=(0 1)
FABRIC_MTU=9000
JUMBO_PAYLOAD=8972   # 9000 - 20 (IPv4 header) - 8 (ICMP header)

ns()        { echo "aiio-node0$1"; }            # node namespace
bridge()    { echo "aiio-rail$1"; }             # rail leaf switch
host_if()   { echo "n$1r$2-h"; }                # switch-side end of the "cable"
node_if()   { echo "eth-r$1"; }                 # NIC name inside the node
node_ip()   { echo "10.10.$2.$1"; }             # rail N subnet = 10.10.N.0/24

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; RST=$'\e[0m'
info() { printf '%s[*]%s %s\n' "$BLD" "$RST" "$*"; }
ok()   { printf '%s[PASS]%s %s\n' "$GRN" "$RST" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s[ERROR]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (sudo). This lab creates network namespaces and bridges."
}

require_tools() {
  local t
  for t in ip ping awk grep; do
    command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t (install iproute2 / iputils)."
  done
  # iputils `ping -h` exits 2: keep that status away from pipefail.
  { ping -h 2>&1 || true; } | grep -q -- '-M' || die "Your ping does not support '-M do' (need iputils ping)."
}

lab_exists() { ip netns list 2>/dev/null | grep -q '^aiio-node0'; }

cleanup() {
  local n r
  for n in "${NODES[@]}"; do
    ip netns del "$(ns "$n")" 2>/dev/null || true   # deleting the netns destroys the veth pairs
  done
  for n in "${NODES[@]}"; do
    for r in "${RAILS[@]}"; do
      ip link del "$(host_if "$n" "$r")" 2>/dev/null || true
    done
  done
  for r in "${RAILS[@]}"; do
    ip link del "$(bridge "$r")" 2>/dev/null || true
  done
  rm -rf "$LAB_DIR"
  info "Lab removed."
}

build_fabric() {
  local n r
  mkdir -p "$LAB_DIR"

  for r in "${RAILS[@]}"; do
    ip link add "$(bridge "$r")" type bridge stp_state 0
    ip link set "$(bridge "$r")" up
  done

  for n in "${NODES[@]}"; do
    ip netns add "$(ns "$n")"
    ip -n "$(ns "$n")" link set lo up
    for r in "${RAILS[@]}"; do
      ip link add "$(host_if "$n" "$r")" mtu "$FABRIC_MTU" type veth \
        peer name "$(node_if "$r")" mtu "$FABRIC_MTU" netns "$(ns "$n")"
      ip link set "$(host_if "$n" "$r")" master "$(bridge "$r")"
      ip link set "$(host_if "$n" "$r")" up
      ip -n "$(ns "$n")" addr add "$(node_ip "$n" "$r")/24" dev "$(node_if "$r")"
      ip -n "$(ns "$n")" link set "$(node_if "$r")" up
    done
  done

  for r in "${RAILS[@]}"; do
    ip link set "$(bridge "$r")" mtu "$FABRIC_MTU"
  done

  cat > "$LAB_DIR/cabling-plan.txt" <<EOF
# Rail-optimized compute fabric - INTENDED cabling (source of truth)
# Rule: NIC "eth-rN" of EVERY node lands on leaf switch "aiio-railN".
# Rule: every port on the compute fabric runs MTU ${FABRIC_MTU} end to end.
#
# node        NIC     IP             switch-side port   leaf switch
aiio-node01   eth-r0  10.10.0.1/24   n1r0-h             aiio-rail0
aiio-node01   eth-r1  10.10.1.1/24   n1r1-h             aiio-rail1
aiio-node02   eth-r0  10.10.0.2/24   n2r0-h             aiio-rail0
aiio-node02   eth-r1  10.10.1.2/24   n2r1-h             aiio-rail1
EOF
}

# --- probes ------------------------------------------------------------------
ping_small() { # $1 rail
  ip netns exec "$(ns 1)" ping -c 2 -W 1 -I "$(node_if "$1")" "$(node_ip 2 "$1")" >/dev/null 2>&1
}
ping_jumbo() { # $1 rail
  ip netns exec "$(ns 1)" ping -M do -s "$JUMBO_PAYLOAD" -c 2 -W 1 \
    -I "$(node_if "$1")" "$(node_ip 2 "$1")" >/dev/null 2>&1
}
port_master() { # $1 ifname -> bridge it is enslaved to
  ip -o link show dev "$1" 2>/dev/null | grep -o 'master [^ ]*' | awk '{print $2}'
}
ns_mtu() { # $1 node $2 rail
  ip -n "$(ns "$1")" -o link show dev "$(node_if "$2")" | grep -o 'mtu [0-9]*' | awk '{print $2}'
}

baseline_ok() {
  local r
  for r in "${RAILS[@]}"; do
    ping_small "$r" || return 1
    ping_jumbo "$r" || return 1
  done
}

warn_br_netfilter() {
  if [[ -r /proc/sys/net/bridge/bridge-nf-call-iptables ]] && \
     [[ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables)" == "1" ]]; then
    warn "br_netfilter is active: host iptables/nftables FORWARD rules (Docker, firewalld) can drop bridged lab traffic."
  fi
}

# --- fault injection -----------------------------------------------------------
inject_faults() {
  # Fault A: miscabling during the scale-out. node02's NIC eth-r0 ended up on the rail1 leaf.
  ip link set "$(host_if 2 0)" nomaster
  ip link set "$(host_if 2 0)" master "$(bridge 1)"

  # Fault B: the new node was provisioned with a default-MTU profile on one rail NIC.
  # The switch side stays at 9000, so small packets pass and big ones are silently dropped.
  ip -n "$(ns 2)" link set "$(node_if 1)" mtu 1500

  # Flush stale neighbor entries so the symptom shows up immediately.
  ip -n "$(ns 1)" neigh flush all 2>/dev/null || true
  ip -n "$(ns 2)" neigh flush all 2>/dev/null || true
  date -Iseconds > "$LAB_DIR/.broken"
}

scenario() {
  cat <<EOF

${BLD}=== SCENARIO ==================================================================${RST}
Your team ran fine-tuning jobs on a single DGX node, aiio-node01. Inside one
node, GPU-to-GPU traffic rides NVLink/NVSwitch (scale-up), so the network
never mattered. The workload grew, so you scaled OUT. A second node,
aiio-node02, was racked, cabled to the compute fabric and provisioned by a
new technician.

The compute fabric is rail-optimized:
  - rail0 leaf = aiio-rail0, subnet 10.10.0.0/24
  - rail1 leaf = aiio-rail1, subnet 10.10.1.0/24
The intended design is in: ${LAB_DIR}/cabling-plan.txt

${BLD}=== SYMPTOMS REPORTED BY THE ML TEAM =========================================${RST}
  1. Single-node jobs on node01 are fine.
  2. 2-node jobs hang at NCCL init on some ranks. Logs show connection
     timeouts between "rank 0" peers (the GPUs bound to NIC eth-r0).
  3. Ranks bound to eth-r1 get through init. They hang or time out as soon
     as the first large all-reduce bucket is sent. Small control messages
     work fine.

Reproduce it yourself from node01, for example:
  ip netns exec aiio-node01 ping -c2 -I eth-r0 10.10.0.2
  ip netns exec aiio-node01 ping -c2 -I eth-r1 10.10.1.2
  ip netns exec aiio-node01 ping -c2 -M do -s ${JUMBO_PAYLOAD} -I eth-r1 10.10.1.2

${BLD}=== YOUR GOAL ================================================================${RST}
Make the 2-node fabric match the design so multi-node training scales:
  - Every node NIC eth-rN must be attached to leaf switch aiio-railN.
  - Every interface on the compute fabric must carry ${FABRIC_MTU}-byte frames end to end.
  - From node01, on BOTH rails: normal ping AND an unfragmented ${JUMBO_PAYLOAD}-byte
    ping (-M do) to node02 must succeed.
Do not delete and rebuild the lab. Fix it in place, as you would in production.

Useful tools: ip -br link, ip -d link, bridge link, ip -n <ns> ..., ping -M do -s
Grade:   sudo $0 check
Hints:   sudo $0 hint 1|2|3
EOF
}

do_break() {
  require_root
  require_tools
  lab_exists && die "Lab already exists. Run '$0 cleanup' first."
  info "Building a healthy 2-node, 2-rail compute fabric..."
  build_fabric
  info "Verifying the healthy baseline (normal + jumbo on every rail)..."
  if ! baseline_ok; then
    warn_br_netfilter
    cleanup
    die "Baseline fabric is not healthy on this VM (host firewall on bridged traffic?). Nothing was broken; lab removed."
  fi
  ok "Baseline healthy."
  info "Simulating the scale-out of aiio-node02..."
  inject_faults
  scenario
}

do_check() {
  require_root
  lab_exists || die "No lab found. Run '$0 break' first."
  local fails=0 n r want got m

  echo "${BLD}-- Cabling (rail alignment) --${RST}"
  for n in "${NODES[@]}"; do
    for r in "${RAILS[@]}"; do
      want="$(bridge "$r")"; got="$(port_master "$(host_if "$n" "$r")")"
      if [[ "$got" == "$want" ]]; then ok "$(ns "$n") $(node_if "$r") -> ${got}"
      else bad "$(ns "$n") $(node_if "$r") -> ${got:-<none>} (expected ${want})"; fails=$((fails+1)); fi
    done
  done

  echo "${BLD}-- MTU consistency --${RST}"
  for n in "${NODES[@]}"; do
    for r in "${RAILS[@]}"; do
      m="$(ns_mtu "$n" "$r")"
      if [[ "$m" == "$FABRIC_MTU" ]]; then ok "$(ns "$n") $(node_if "$r") mtu ${m}"
      else bad "$(ns "$n") $(node_if "$r") mtu ${m} (expected ${FABRIC_MTU})"; fails=$((fails+1)); fi
    done
  done

  echo "${BLD}-- Data path node01 -> node02 --${RST}"
  for r in "${RAILS[@]}"; do
    if ping_small "$r"; then ok "rail${r} reachability"
    else bad "rail${r} reachability ($(node_ip 1 "$r") -> $(node_ip 2 "$r"))"; fails=$((fails+1)); fi
    if ping_jumbo "$r"; then ok "rail${r} jumbo ${JUMBO_PAYLOAD}B DF"
    else bad "rail${r} jumbo ${JUMBO_PAYLOAD}B DF (large messages black-holed)"; fails=$((fails+1)); fi
  done

  echo
  if [[ $fails -eq 0 ]]; then
    ok "Fabric matches the design. Multi-node NCCL traffic would scale across both rails."
  else
    bad "${fails} check(s) failing."
    warn_br_netfilter
    exit 1
  fi
}

do_hint() {
  case "${1:-1}" in
    1) cat <<'EOF'
Hint 1: There are TWO independent faults, one per symptom.
  - "rank 0 can't even connect": that is reachability on rail0, a Layer 2 problem.
    Which leaf is each NIC actually plugged into?  ->  bridge link
  - "small messages OK, big ones hang": that is the classic MTU black hole.
EOF
    ;;
    2) cat <<'EOF'
Hint 2: Compare reality with the plan, port by port:
  bridge link | grep -E 'n[12]r[01]-h'
  cat /tmp/aiio-lab-2.2/cabling-plan.txt
  ip -br link | grep -E 'aiio|n[12]r'               # switch side MTUs
  for n in 1 2; do ip -n aiio-node0$n -br link; done   # host side, but look at mtu with: ip -n aiio-node0$n link
EOF
    ;;
    3) cat <<'EOF'
Hint 3: Re-patching a port in Linux is "ip link set <port> master <bridge>".
Setting a NIC MTU inside a node is "ip -n <ns> link set <if> mtu <value>".
A veth drops frames bigger than the MTU of the receiving end. Check BOTH
ends of every cable.
EOF
    ;;
    *) die "hint takes 1, 2 or 3" ;;
  esac
}

case "${1:-}" in
  break)   do_break ;;
  check)   do_check ;;
  hint)    do_hint "${2:-1}" ;;
  cleanup) require_root; cleanup ;;
  *) echo "Usage: sudo $0 {break|check|hint [1-3]|cleanup}"; exit 2 ;;
esac

exit 0

# =============================================================================
# SOLUTION (step by step) - read only after you have tried
# =============================================================================
#
# STEP 0 - Reproduce and split the problem
#   ip netns exec aiio-node01 ping -c2 -I eth-r0 10.10.0.2
#     -> 100% packet loss ("Destination Host Unreachable": ARP never resolves)
#   ip netns exec aiio-node01 ping -c2 -I eth-r1 10.10.1.2
#     -> OK
#   ip netns exec aiio-node01 ping -c2 -M do -s 8972 -I eth-r1 10.10.1.2
#     -> 100% packet loss, with NO "message too long" error. This is a silent black hole.
#   Two different signatures mean two different faults: L2 reachability on
#   rail0, and MTU on rail1.
#
# STEP 1 - Find the miscabled port (fault A)
#   bridge link | grep -E 'n[12]r[01]-h'
#   Expected output, showing the fault:
#     ... n1r0-h@if.. : <...> mtu 9000 master aiio-rail0 state forwarding ...
#     ... n1r1-h@if.. : <...> mtu 9000 master aiio-rail1 state forwarding ...
#     ... n2r0-h@if.. : <...> mtu 9000 master aiio-rail1 state forwarding ...   <-- WRONG LEAF
#     ... n2r1-h@if.. : <...> mtu 9000 master aiio-rail1 state forwarding ...
#   node02's eth-r0 (10.10.0.2) sits in the rail1 broadcast domain. node01's
#   eth-r0 sits in rail0. ARP can never meet.
#
#   Why it matters in production: in a rail-optimized SuperPOD, GPU N of
#   every node reaches GPU N of every other node through ONE leaf hop.
#   Suppose a cable lands on the wrong leaf. At best, traffic crosses the
#   spine (more hops, contention, the bandwidth plan breaks). At worst, as
#   here, the rails are isolated and NCCL rank-pairs can't connect at all.
#
# STEP 2 - Re-patch the port to the correct leaf
#   ip link set n2r0-h nomaster
#   ip link set n2r0-h master aiio-rail0
#   ip link set n2r0-h up
#   bridge link | grep n2r0-h          # -> master aiio-rail0
#   ip netns exec aiio-node01 ping -c2 -I eth-r0 10.10.0.2   # -> OK
#
# STEP 3 - Find the MTU mismatch (fault B)
#   ip -br link | grep -E 'n[12]r[01]-h'          # all switch-side ports: mtu 9000
#   for n in 1 2; do echo "== node0$n"; ip -n aiio-node0$n -o link show | grep -o '^[0-9]*: [^:]*\|mtu [0-9]*'; done
#     -> aiio-node02 eth-r1 shows mtu 1500 while everything else is 9000.
#   node01 sends 9000-byte frames. The switch forwards them. node02's NIC
#   cannot accept frames larger than 1500, so it drops them. Nobody sends
#   an ICMP "fragmentation needed", because the drop happens at L2.
#   Small packets (NCCL bootstrap, handshakes) fit, so init succeeds. The
#   first large all-reduce chunk hangs. This is the classic "works for
#   small, hangs for big" signature.
#
# STEP 4 - Align the MTU end to end
#   ip -n aiio-node02 link set eth-r1 mtu 9000
#   ip netns exec aiio-node01 ping -c2 -M do -s 8972 -I eth-r1 10.10.1.2   # -> OK
#   ip netns exec aiio-node01 ping -c2 -M do -s 8972 -I eth-r0 10.10.0.2   # -> OK
#   (8972 = 9000 - 20 bytes IPv4 header - 8 bytes ICMP header.)
#
# STEP 5 - Grade
#   sudo ./break_fix.sh check     # every line PASS
#
# STEP 6 - Lessons for scaling GPU infrastructure
#   - Scale-up (NVLink/NVSwitch inside a node) hides network problems.
#     Scale-out (multiple nodes) depends entirely on the compute fabric.
#     Validate the fabric BEFORE the first multi-node job.
#   - Cable to a plan. Rail N of every node goes to leaf N, and you verify
#     it automatically, never by eye. On real hardware: ibstat / ibdev2netdev
#     to map HCAs to ports, and LLDP or the fabric manager (UFM) to see what
#     each port is connected to.
#   - MTU is an end-to-end property: host NIC, switch port and every hop.
#     On InfiniBand the IB MTU (commonly 4096) is set by the subnet manager.
#     On RoCE Ethernet you set jumbo frames consistently on hosts and switches.
#   - Test with LARGE messages. Before releasing a node to the scheduler,
#     run ib_write_bw / ib_send_bw on every rail, then nccl-tests
#     (all_reduce_perf -b 8 -e 8G) across nodes. A plain ping proves almost
#     nothing.
#   - Provisioning drift (a "default" network profile on a new node) is a
#     scale-out risk. Treat node config as code, the same for every node,
#     and gate node admission on a fabric health check.
#   - Offloading infrastructure services (networking, storage, security)
#     to BlueField DPUs keeps that config isolated and consistent per node
#     as the cluster grows.
#
# STEP 7 - Clean up
#   sudo ./break_fix.sh cleanup
# =============================================================================