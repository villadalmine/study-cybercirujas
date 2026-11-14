#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO 2.9: Identify high-speed data center network options and their use cases
# Break & Fix lab: "The jumbo-frame black hole on the GPU compute fabric"
#
# lab-resources: cpus=1 ram_mb=512
#
# WHAT THIS LAB BUILDS (entirely inside Linux network namespaces, zero host impact)
#
#   +-------------------+        +----------------------------+        +-------------------+
#   | netns aifab-gpu-a |        |      netns aifab-leaf      |        | netns aifab-gpu-b |
#   |  "DGX node A"     |        |  "leaf switch" (br0)       |        |  "DGX node B"     |
#   |  fab0 10.99.0.1   |--------| swp1                 swp2  |--------|  fab0 10.99.0.2   |
#   +-------------------+  veth  +----------------------------+  veth  +-------------------+
#
#   The lab models the scale-out "east-west" compute fabric of an AI cluster. On a
#   real DGX SuperPOD that fabric is InfiniBand NDR (ConnectX-7 + Quantum-2), or
#   RoCEv2 over lossless Ethernet (Spectrum-X). Both carry RDMA traffic such as
#   NCCL all-reduce. Either way the operator contract is the same:
#     * consistent jumbo MTU end to end (host NIC, switch port, peer NIC)
#     * congestion signalling enabled (ECN marking feeding DCQCN for RoCEv2)
#   A plain veth/bridge cannot do RDMA. Here the MTU behaviour is real.
#   net.ipv4.tcp_ecn is a host-side stand-in for "ECN enabled on the RDMA path".
#
# MODES (all idempotent)
#   sudo ./lab.sh            -> same as "break": builds the fabric and injects the faults
#   sudo ./lab.sh break
#   sudo ./lab.sh verify     -> exit 0 only when every fault is fixed
#   sudo ./lab.sh cleanup    -> removes namespaces and lab files; host stays as it was
#
# References:
#   https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#   https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   https://www.nvidia.com/en-us/data-center/nvlink/
#   https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
#   https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
# =============================================================================
set -u

NS_A="aifab-gpu-a"
NS_B="aifab-gpu-b"
NS_LEAF="aifab-leaf"
LAB_DIR="/opt/aifab-lab"
FABRIC_MTU=9000
# 9000 MTU - 20 bytes IPv4 header - 8 bytes ICMP header
PING_PAYLOAD=8972

log()  { printf '[aifab] %s\n' "$*"; }
die()  { printf '[aifab] ERROR: %s\n' "$*" >&2; exit 2; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ${1:-break})"
  command -v ip   >/dev/null 2>&1 || die "iproute2 ('ip') is required"
  command -v ping >/dev/null 2>&1 || die "iputils 'ping' is required"
}

confirm_disposable() {
  if [ "${STUDY_LAB:-}" = "1" ] || [ "${LAB_DISPOSABLE:-}" = "yes" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "no terminal and STUDY_LAB/LAB_DISPOSABLE not set; refusing to run unattended"
  fi
  printf 'This lab creates network namespaces %s, %s, %s and files under %s.\n' \
    "$NS_A" "$NS_B" "$NS_LEAF" "$LAB_DIR"
  printf 'Run it only on a disposable lab VM. Continue? [y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) die "aborted by user" ;; esac
}

ns_exists() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

mtu_of() {
  # $1 = netns, $2 = device; prints the MTU or "missing"
  local out
  out=$(ip -n "$1" -o link show dev "$2" 2>/dev/null) || { echo missing; return; }
  echo "$out" | sed -n 's/.* mtu \([0-9]\+\) .*/\1/p'
}

do_cleanup() {
  for ns in "$NS_A" "$NS_B" "$NS_LEAF"; do
    if ns_exists "$ns"; then
      ip netns del "$ns" 2>/dev/null || true
    fi
  done
  # Leftover root-namespace veth ends from an interrupted build
  for dev in aifab-a0 aifab-b0 aifab-s1 aifab-s2; do
    ip link del "$dev" 2>/dev/null || true
  done
  rm -rf "$LAB_DIR"
}

build_fabric() {
  ip netns add "$NS_A"
  ip netns add "$NS_B"
  ip netns add "$NS_LEAF"

  # Node A <-> leaf swp1
  ip link add aifab-a0 type veth peer name aifab-s1
  ip link set aifab-a0 netns "$NS_A"
  ip link set aifab-s1 netns "$NS_LEAF"
  ip -n "$NS_A"    link set aifab-a0 name fab0
  ip -n "$NS_LEAF" link set aifab-s1 name swp1

  # Node B <-> leaf swp2
  ip link add aifab-b0 type veth peer name aifab-s2
  ip link set aifab-b0 netns "$NS_B"
  ip link set aifab-s2 netns "$NS_LEAF"
  ip -n "$NS_B"    link set aifab-b0 name fab0
  ip -n "$NS_LEAF" link set aifab-s2 name swp2

  # Leaf "switch": a Linux bridge inside its own namespace. The namespace has an
  # empty netfilter ruleset, so host firewalls (Docker, firewalld) never interfere.
  ip -n "$NS_LEAF" link add br0 type bridge
  for p in swp1 swp2; do
    ip -n "$NS_LEAF" link set "$p" mtu "$FABRIC_MTU"
    ip -n "$NS_LEAF" link set "$p" master br0
    ip -n "$NS_LEAF" link set "$p" up
  done
  ip -n "$NS_LEAF" link set br0 mtu "$FABRIC_MTU"
  ip -n "$NS_LEAF" link set br0 up
  ip -n "$NS_LEAF" link set lo up

  # Hosts: jumbo MTU, addresses, ECN enabled (healthy baseline)
  ip -n "$NS_A" link set lo up
  ip -n "$NS_B" link set lo up
  ip -n "$NS_A" link set fab0 mtu "$FABRIC_MTU"
  ip -n "$NS_B" link set fab0 mtu "$FABRIC_MTU"
  ip -n "$NS_A" addr add 10.99.0.1/24 dev fab0
  ip -n "$NS_B" addr add 10.99.0.2/24 dev fab0
  ip -n "$NS_A" link set fab0 up
  ip -n "$NS_B" link set fab0 up
  ip netns exec "$NS_A" sysctl -qw net.ipv4.tcp_ecn=1
  ip netns exec "$NS_B" sysctl -qw net.ipv4.tcp_ecn=1
}

inject_faults() {
  # FAULT 1: someone "standardised" the leaf port facing node B to 1500.
  # The bridge forwards frames up to 1500 bytes on that port and silently drops
  # larger ones. No ICMP "fragmentation needed" is generated, because a bridge
  # works at L2, so PMTU discovery cannot save you. This is the classic black hole.
  ip -n "$NS_LEAF" link set swp2 mtu 1500

  # FAULT 2: node B had ECN disabled by a "hardening" script.
  # Stand-in for an RDMA path where ECN/DCQCN is off. Under incast, as in NCCL
  # all-reduce, RoCEv2 then falls back to PFC pauses and drops, and tail latency explodes.
  ip netns exec "$NS_B" sysctl -qw net.ipv4.tcp_ecn=0
}

write_lab_files() {
  mkdir -p "$LAB_DIR"

  cat > "$LAB_DIR/fabric.conf" <<EOF
# AI compute fabric design contract (what "healthy" means for this lab)
fabric_mtu=$FABRIC_MTU          # every hop: host fab0, leaf swp1/swp2, leaf br0
congestion_signalling=ecn       # net.ipv4.tcp_ecn=1 on every GPU node namespace
nodes=$NS_A(10.99.0.1) $NS_B(10.99.0.2)
leaf=$NS_LEAF(br0: swp1->$NS_A, swp2->$NS_B)
EOF

  cat > "$LAB_DIR/answers.txt" <<'EOF'
# Fill in ONE network technology per key (lower case is fine).
# Pick from: nvlink, infiniband, roce, bluefield, ethernet
#
# GPU-to-GPU traffic INSIDE one DGX/HGX node (NVSwitch-connected, scale-up)
intra_node_gpu_to_gpu=
# Scale-out compute fabric between DGX nodes in the DGX SuperPOD reference architecture
compute_fabric_between_nodes=
# RDMA carried over lossless Ethernet (Spectrum-X style fabrics)
ethernet_lossless_rdma=
# Offloading and isolating networking/storage/security from the host CPU (DPU)
infrastructure_offload_isolation=
# Out-of-band management network (BMC, switch management ports)
oob_management=
EOF

  cat > "$LAB_DIR/README.txt" <<EOF
TICKET AIOPS-2911: "NCCL all-reduce hangs between node A and node B; ssh works fine"

Symptoms you will observe:
  * Small packets work:
      ip netns exec $NS_A ping -c2 10.99.0.2                      -> OK
  * Full-size jumbo frames with Don't-Fragment set disappear:
      ip netns exec $NS_A ping -c2 -M do -s $PING_PAYLOAD 10.99.0.2   -> 100% packet loss
    (no "Frag needed" error comes back: an L2 hop drops the frame silently)
  * Node B does not signal congestion:
      ip netns exec $NS_B sysctl net.ipv4.tcp_ecn                 -> 0

Your goals:
  1. Find the hop whose MTU breaks the $FABRIC_MTU contract (see fabric.conf) and fix it.
     Do NOT "fix" it by lowering the hosts to 1500: the contract is jumbo end to end.
  2. Re-enable ECN on the GPU node that lost it.
  3. Fill in $LAB_DIR/answers.txt mapping each use case to its network technology.

Check your work:  sudo $0 verify
EOF
}

do_break() {
  require_root break
  confirm_disposable
  log "resetting any previous run"
  do_cleanup
  log "building simulated GPU compute fabric (MTU $FABRIC_MTU)"
  build_fabric || die "fabric build failed (does the kernel support veth/bridge/netns?)"
  if ! ip netns exec "$NS_A" ping -c1 -W2 -M do -s "$PING_PAYLOAD" 10.99.0.2 >/dev/null 2>&1; then
    log "warning: baseline jumbo ping failed before fault injection"
  fi
  inject_faults
  write_lab_files
  echo
  cat "$LAB_DIR/README.txt"
  echo
  log "lab ready. Files: $LAB_DIR/{README.txt,fabric.conf,answers.txt}"
}

answer_of() {
  # prints the trimmed, lower-cased value of key $1 from answers.txt
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$LAB_DIR/answers.txt" 2>/dev/null \
    | head -n1 | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//'
}

do_verify() {
  require_root verify
  local fail=0 m v

  for ns in "$NS_A" "$NS_B" "$NS_LEAF"; do
    if ! ns_exists "$ns"; then
      echo "FAIL namespace $ns missing: run '$0 break' first"
      exit 1
    fi
  done

  # 1. MTU contract on every hop
  for pair in "$NS_A:fab0" "$NS_B:fab0" "$NS_LEAF:swp1" "$NS_LEAF:swp2" "$NS_LEAF:br0"; do
    m=$(mtu_of "${pair%%:*}" "${pair##*:}")
    if [ "$m" = "$FABRIC_MTU" ]; then
      echo "PASS mtu ${pair} = $m"
    else
      echo "FAIL mtu ${pair} = $m (contract: $FABRIC_MTU)"
      fail=1
    fi
  done

  # 2. End-to-end jumbo frames with DF, both directions
  if ip netns exec "$NS_A" ping -c2 -W2 -M do -s "$PING_PAYLOAD" 10.99.0.2 >/dev/null 2>&1; then
    echo "PASS jumbo DF ping A -> B"
  else
    echo "FAIL jumbo DF ping A -> B (payload $PING_PAYLOAD)"
    fail=1
  fi
  if ip netns exec "$NS_B" ping -c2 -W2 -M do -s "$PING_PAYLOAD" 10.99.0.1 >/dev/null 2>&1; then
    echo "PASS jumbo DF ping B -> A"
  else
    echo "FAIL jumbo DF ping B -> A (payload $PING_PAYLOAD)"
    fail=1
  fi

  # 3. ECN on both GPU nodes
  for ns in "$NS_A" "$NS_B"; do
    v=$(ip netns exec "$ns" sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo "?")
    if [ "$v" = "1" ]; then
      echo "PASS ecn $ns = 1"
    else
      echo "FAIL ecn $ns = $v (expected 1)"
      fail=1
    fi
  done

  # 4. Use-case identification
  if [ ! -f "$LAB_DIR/answers.txt" ]; then
    echo "FAIL $LAB_DIR/answers.txt missing"
    fail=1
  else
    check_answer() {
      local key=$1 regex=$2 hint=$3 got
      got=$(answer_of "$key")
      if [ -n "$got" ] && echo "$got" | grep -Eq "$regex"; then
        echo "PASS answer $key = $got"
      else
        echo "FAIL answer $key = '${got}' (hint: $hint)"
        fail=1
      fi
    }
    check_answer intra_node_gpu_to_gpu            '^(nvlink|nvswitch|nvlink/nvswitch|nvlink[ -]?switch)$' "scale-up, inside the node"
    check_answer compute_fabric_between_nodes     '^(infiniband|ib)( .*)?$|^infiniband'                   "SuperPOD compute fabric, ConnectX-7 + Quantum-2"
    check_answer ethernet_lossless_rdma           '^roce(v2)?$'                                           "RDMA over Converged Ethernet"
    check_answer infrastructure_offload_isolation '^(bluefield|bluefield[ -]?dpu|dpu|bluefield-3)$'       "data processing unit"
    check_answer oob_management                   '^ethernet$'                                            "1/10GbE BMC and management ports"
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    log "all checks passed: fabric honours the jumbo/ECN contract and use cases are identified"
    exit 0
  fi
  log "not fixed yet"
  exit 1
}

do_cleanup_mode() {
  require_root cleanup
  do_cleanup
  log "cleanup done: namespaces $NS_A $NS_B $NS_LEAF and $LAB_DIR removed"
}

case "${1:-break}" in
  break)   do_break ;;
  verify)  do_verify ;;
  cleanup) do_cleanup_mode ;;
  *)       echo "usage: $0 [break|verify|cleanup]" >&2; exit 2 ;;
esac

# =============================================================================
# SOLUTION (step by step). Try it yourself first.
# =============================================================================
#
# 1) Reproduce the symptom and characterise it
#    ip netns exec aifab-gpu-a ping -c2 10.99.0.2                     # OK, small frames pass
#    ip netns exec aifab-gpu-a ping -c2 -M do -s 8972 10.99.0.2       # 100% loss, no error
#    Expected for the broken case:
#      PING 10.99.0.2 (10.99.0.2) 8972(9000) bytes of data.
#      --- 10.99.0.2 ping statistics ---
#      2 packets transmitted, 0 received, 100% packet loss
#    Small frames pass while large DF frames vanish without "Frag needed". That
#    points at an MTU mismatch on an L2 hop: a switch port or bridge. Switches drop
#    oversize frames, and only routers emit ICMP type 3 code 4.
#    Bisect the size to find the real path MTU:
#    ip netns exec aifab-gpu-a ping -c1 -M do -s 1472 10.99.0.2       # OK  -> path MTU is 1500
#    ip netns exec aifab-gpu-a ping -c1 -M do -s 1473 10.99.0.2       # loss
#
# 2) Walk every hop and compare it with fabric.conf
#    ip -n aifab-gpu-a -br link show fab0          # ... mtu 9000? use: ip -n aifab-gpu-a link show fab0
#    ip -n aifab-gpu-b link show fab0              # mtu 9000
#    ip -n aifab-leaf  link show master br0        # swp1 mtu 9000, swp2 mtu 1500  <-- culprit
#    ip -n aifab-leaf  -d link show br0            # bridge itself
#    On real gear the equivalents are `ip link`/`ibv_devinfo`/`ibstat` on the DGX,
#    and `nv show interface swpX` (Cumulus) or `show interfaces ib` (Quantum) on the switch.
#    In InfiniBand the MTU is negotiated per port (4096 bytes for IB).
#
# 3) Fix the switch port. Do not shrink the hosts.
#    ip -n aifab-leaf link set swp2 mtu 9000
#    ip -n aifab-leaf link set br0  mtu 9000        # harmless, keeps the bridge at contract
#    ip netns exec aifab-gpu-a ping -c2 -M do -s 8972 10.99.0.2   # 0% loss now
#    ip netns exec aifab-gpu-b ping -c2 -M do -s 8972 10.99.0.1   # 0% loss
#    Lowering the hosts to 1500 would "work", but it raises the per-packet overhead
#    and breaks the contract the other nodes rely on. RDMA/NCCL throughput depends
#    on large frames.
#
# 4) Re-enable congestion signalling on node B
#    ip netns exec aifab-gpu-a sysctl net.ipv4.tcp_ecn   # 1
#    ip netns exec aifab-gpu-b sysctl net.ipv4.tcp_ecn   # 0  <-- culprit
#    ip netns exec aifab-gpu-b sysctl -w net.ipv4.tcp_ecn=1
#    Real-world analogue for RoCEv2: switches mark ECN (CE) once queues cross a
#    threshold, and the ConnectX NIC runs DCQCN to slow the sender. PFC on the RDMA
#    traffic class is the backstop. You would check it with `mlnx_qos -i <if>` on
#    the host and the switch QoS/ECN profile. InfiniBand has credit-based flow
#    control built in, so it is lossless by design.
#
# 5) Fill in the use-case map (/opt/aifab-lab/answers.txt)
#    intra_node_gpu_to_gpu=nvlink
#        NVLink/NVSwitch is the scale-up fabric. GPUs in one DGX/HGX share memory-semantic
#        bandwidth far above PCIe: 900 GB/s per H100 GPU, 1.8 TB/s per Blackwell GPU.
#    compute_fabric_between_nodes=infiniband
#        DGX SuperPOD compute fabric: NDR InfiniBand, rail-optimised fat tree,
#        ConnectX-7 per GPU, Quantum-2 switches, plus RDMA, GPUDirect RDMA and SHARP
#        in-network reductions.
#    ethernet_lossless_rdma=roce
#        RoCEv2 gives RDMA over routable UDP/IP Ethernet. It needs lossless or
#        congestion-managed tuning (ECN/DCQCN, PFC), as in Spectrum-X.
#    infrastructure_offload_isolation=bluefield
#        BlueField DPU: offloads and isolates networking, storage (NVMe-oF) and
#        security (firewall, encryption) from the host CPU, with a separate trust domain.
#    oob_management=ethernet
#        Plain 1/10 GbE for BMC, switch management and provisioning. It is kept
#        separate from the compute and storage fabrics.
#
# 6) Verify, then clean up
#    sudo ./lab.sh verify     # all PASS, exit 0
#    sudo ./lab.sh cleanup
# =============================================================================