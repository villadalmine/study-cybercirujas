#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO · Topic 2.8 — Data center networking protocols and key concepts
# Lab: "The storage fabric that only works for small packets"
# lab-resources: cpus=1 ram_mb=512
#
# Scenario
# --------
# You operate an AI cluster. GPU nodes reach a storage tier over a dedicated
# "storage/compute fabric" network. This network is designed the way production
# AI fabrics are designed:
#
#   * Segmented at Layer 2 with an 802.1Q VLAN (VLAN 100 = storage fabric),
#     separate from the in-band management network.
#   * Jumbo frames end to end (MTU 9000). RoCE (RDMA over Converged Ethernet),
#     NVMe-oF and GPUDirect Storage traffic all assume a consistent, large MTU
#     on every hop: host NIC, VLAN interface, every switch port, and the peer.
#     A single hop with a smaller MTU does not "slow things down"; it silently
#     DROPS every frame larger than its MTU. Lossless/RDMA fabrics (PFC, ECN,
#     Spectrum-X, BlueField/ConnectX offloads) make that worse, not better:
#     the transport retries and stalls instead of fragmenting.
#
# This lab simulates that fabric inside one disposable VM with Linux network
# namespaces:
#
#      netns lab28-gpu                 root netns                netns lab28-stor
#   +--------------------+     +-------------------------+     +--------------------+
#   | eth0.100 (VLAN100) |     |   lab28-br0 (bridge =   |     | eth0.100 (VLAN100) |
#   | 10.100.0.11/24     |     |   simulated leaf switch)|     | 10.100.0.21/24     |
#   | eth0  mtu 9000     |=====| lab28-gp        lab28-sp|=====| eth0  mtu 9000     |
#   +--------------------+ veth|  (switch ports)         |veth +--------------------+
#                              +-------------------------+
#
# The break introduces two realistic misconfigurations at different layers.
# The student must find and fix both without lowering the design MTU.
#
# Runner contract (study-lab):
#   ./lab.sh            -> same as "break"
#   ./lab.sh break      -> build the fabric and break it (idempotent)
#   ./lab.sh verify     -> exit 0 only if the fabric works as designed
#   ./lab.sh cleanup    -> remove everything this lab created (idempotent)
#
# References (official):
#   NVIDIA DGX SuperPOD reference architecture (B200), network fabrics:
#     https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#   DGX H100 component descriptions (ConnectX-7, networking ports):
#     https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   Accelerating IO in the modern data center (network IO):
#     https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
#   BlueField DPU offload and isolation:
#     https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
#   NVLink (scale-up, contrasted with the Ethernet/InfiniBand scale-out fabric):
#     https://www.nvidia.com/en-us/data-center/nvlink/
# =============================================================================

set -uo pipefail

NS_GPU="lab28-gpu"
NS_STOR="lab28-stor"
BR="lab28-br0"
P_GPU="lab28-gp"      # switch port facing the GPU node
P_STOR="lab28-sp"     # switch port facing the storage node
V_GPU="lab28-g0"      # temporary name of the veth end that becomes eth0 in gpu ns
V_STOR="lab28-s0"     # temporary name of the veth end that becomes eth0 in stor ns
VLAN_OK=100
VLAN_BAD=200
MTU_JUMBO=9000
MTU_BAD=1500
IP_GPU="10.100.0.11"
IP_STOR="10.100.0.21"
PREFIX=24
# Largest ICMP payload that fits in a 9000-byte MTU: 9000 - 20 (IPv4) - 8 (ICMP)
JUMBO_PAYLOAD=8972

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -n -E bash "$0" "$@"
    fi
    say "This lab must run as root (it creates network namespaces and bridges)." >&2
    exit 2
  fi
}

need_tools() {
  local missing=0 t
  for t in ip ping; do
    if ! command -v "$t" >/dev/null 2>&1; then
      say "Missing required tool: $t (install iproute2 / iputils-ping)." >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 2
  modprobe 8021q >/dev/null 2>&1 || true
  modprobe bridge >/dev/null 2>&1 || true
}

confirm() {
  # Never wait for a human when the runner drives us, or with no terminal.
  if [ "${STUDY_LAB:-}" = "1" ] || [ "${LAB_DISPOSABLE:-}" = "yes" ] || [ ! -t 0 ]; then
    return 0
  fi
  printf 'This creates namespaces %s/%s and bridge %s on this host. Continue? [y/N] ' \
    "$NS_GPU" "$NS_STOR" "$BR"
  local a
  read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) say "Aborted."; exit 1 ;; esac
}

do_cleanup() {
  ip netns del "$NS_GPU"  >/dev/null 2>&1 || true
  ip netns del "$NS_STOR" >/dev/null 2>&1 || true
  # Deleting a namespace destroys the veth end inside it, which destroys the
  # peer too; the explicit deletes below cover half-built states.
  local l
  for l in "$P_GPU" "$P_STOR" "$V_GPU" "$V_STOR"; do
    ip link del "$l" >/dev/null 2>&1 || true
  done
  ip link del "$BR" >/dev/null 2>&1 || true
}

build_node() {
  # $1 netns  $2 veth-in-ns  $3 switch-port  $4 ip  $5 vlan-id
  local ns="$1" v="$2" port="$3" addr="$4" vid="$5"
  ip netns add "$ns"
  ip link add "$v" type veth peer name "$port"
  ip link set "$v" netns "$ns"
  ip -n "$ns" link set "$v" name eth0
  ip -n "$ns" link set lo up
  ip -n "$ns" link set eth0 mtu "$MTU_JUMBO"
  ip -n "$ns" link set eth0 up
  ip -n "$ns" link add link eth0 name eth0.100 type vlan id "$vid"
  ip -n "$ns" link set eth0.100 mtu "$MTU_JUMBO"
  ip -n "$ns" addr add "${addr}/${PREFIX}" dev eth0.100
  ip -n "$ns" link set eth0.100 up
  ip link set "$port" mtu "$MTU_JUMBO"
  ip link set "$port" master "$BR"
  ip link set "$port" up
}

do_break() {
  confirm
  do_cleanup

  # Simulated leaf switch: a plain Linux bridge (no VLAN filtering, no STP),
  # so tagged frames are forwarded transparently, like a trunk.
  ip link add "$BR" type bridge stp_state 0 vlan_filtering 0
  ip link set "$BR" up

  build_node "$NS_GPU"  "$V_GPU"  "$P_GPU"  "$IP_GPU"  "$VLAN_OK"

  # FAULT 1 (L2 segmentation): the storage node's interface is NAMED eth0.100
  # but was provisioned with 802.1Q tag 200. The name is just a label; the tag
  # on the wire is what matters.
  build_node "$NS_STOR" "$V_STOR" "$P_STOR" "$IP_STOR" "$VLAN_BAD"

  # FAULT 2 (MTU consistency): the switch port facing storage was left at the
  # default 1500, while every other hop is 9000. The bridge drops any frame
  # larger than the egress port MTU, silently, with no ICMP back.
  ip link set "$P_STOR" mtu "$MTU_BAD"

  cat <<EOF

=====================================================================
 LAB 2.8 — storage fabric broken
=====================================================================
 Design (the source of truth, do not change it):
   * Storage fabric = 802.1Q VLAN ${VLAN_OK} on every node (interface eth0.100)
   * Jumbo frames: MTU ${MTU_JUMBO} on EVERY hop (node NICs, VLAN interfaces,
     and both switch ports of ${BR})
   * GPU node    ${NS_GPU}   ${IP_GPU}/${PREFIX}
   * Storage     ${NS_STOR}  ${IP_STOR}/${PREFIX}

 Symptom reported by the ML team:
   "Checkpoints to storage time out. The storage node is unreachable from
    the GPU node, and even when the network team said they fixed it,
    small requests worked but large transfers hung forever."

 Reproduce it:
   ip netns exec ${NS_GPU} ping -c2 -W1 ${IP_STOR}
   ip netns exec ${NS_GPU} ping -c2 -W1 -M do -s ${JUMBO_PAYLOAD} ${IP_STOR}

 Useful views:
   ip -n ${NS_STOR} -d link show eth0.100      (802.1Q details)
   ip -n ${NS_GPU}  -d link show eth0.100
   ip -o link show master ${BR}                (switch ports and their MTU)
   ip netns exec ${NS_GPU} ip neigh            (did ARP resolve?)

 Goal: make BOTH pings above succeed, with DF set (-M do), WITHOUT lowering
 any MTU below ${MTU_JUMBO} and keeping VLAN ${VLAN_OK}.
 Check your work with:   $0 verify
=====================================================================
EOF
}

do_verify() {
  local fail=0 ns m

  for ns in "$NS_GPU" "$NS_STOR"; do
    if ! ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns"; then
      bad "namespace $ns does not exist (run: $0 break)"
      return 1
    fi
  done
  if ! ip link show "$BR" >/dev/null 2>&1; then
    bad "bridge $BR does not exist (run: $0 break)"
    return 1
  fi

  # 1) VLAN tag on both nodes must be the design VLAN
  for ns in "$NS_GPU" "$NS_STOR"; do
    if ip -n "$ns" -d link show eth0.100 2>/dev/null | grep -Eq "vlan protocol 802\.1Q id ${VLAN_OK}( |$)"; then
      ok "$ns eth0.100 carries 802.1Q tag ${VLAN_OK}"
    else
      bad "$ns eth0.100 missing or not tagged with VLAN ${VLAN_OK}"
      fail=1
    fi
  done

  # 2) MTU 9000 on every hop (no cheating by lowering the design MTU)
  for ns in "$NS_GPU" "$NS_STOR"; do
    for ifc in eth0 eth0.100; do
      m="$(ip -n "$ns" -o link show "$ifc" 2>/dev/null | sed -n 's/.* mtu \([0-9]*\).*/\1/p')"
      if [ "${m:-0}" -ge "$MTU_JUMBO" ]; then
        ok "$ns $ifc mtu $m"
      else
        bad "$ns $ifc mtu ${m:-?} (design is ${MTU_JUMBO})"
        fail=1
      fi
    done
  done
  for ifc in "$P_GPU" "$P_STOR"; do
    m="$(ip -o link show "$ifc" 2>/dev/null | sed -n 's/.* mtu \([0-9]*\).*/\1/p')"
    if [ "${m:-0}" -ge "$MTU_JUMBO" ] && ip -o link show "$ifc" 2>/dev/null | grep -q "master $BR"; then
      ok "switch port $ifc mtu $m, attached to $BR"
    else
      bad "switch port $ifc mtu ${m:-?} or not attached to $BR"
      fail=1
    fi
  done

  # 3) Addresses still as designed
  ip -n "$NS_GPU"  -o addr show dev eth0.100 2>/dev/null | grep -q "inet ${IP_GPU}/${PREFIX}" \
    && ok "$NS_GPU has ${IP_GPU}/${PREFIX}" || { bad "$NS_GPU lost ${IP_GPU}/${PREFIX}"; fail=1; }
  ip -n "$NS_STOR" -o addr show dev eth0.100 2>/dev/null | grep -q "inet ${IP_STOR}/${PREFIX}" \
    && ok "$NS_STOR has ${IP_STOR}/${PREFIX}" || { bad "$NS_STOR lost ${IP_STOR}/${PREFIX}"; fail=1; }

  # 4) Data plane: small frames, then jumbo frames with DF set, both directions
  if ip netns exec "$NS_GPU" ping -c2 -W1 -q "$IP_STOR" >/dev/null 2>&1; then
    ok "small packets GPU -> storage"
  else
    bad "small packets GPU -> storage fail (L2/VLAN reachability)"
    fail=1
  fi
  if ip netns exec "$NS_GPU" ping -c2 -W1 -q -M do -s "$JUMBO_PAYLOAD" "$IP_STOR" >/dev/null 2>&1; then
    ok "jumbo ${MTU_JUMBO}-byte packets GPU -> storage with DF"
  else
    bad "jumbo packets GPU -> storage fail (MTU mismatch on the path)"
    fail=1
  fi
  if ip netns exec "$NS_STOR" ping -c2 -W1 -q -M do -s "$JUMBO_PAYLOAD" "$IP_GPU" >/dev/null 2>&1; then
    ok "jumbo ${MTU_JUMBO}-byte packets storage -> GPU with DF"
  else
    bad "jumbo packets storage -> GPU fail"
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    say ""
    say "Fabric healthy: VLAN ${VLAN_OK} end to end and MTU ${MTU_JUMBO} on every hop."
    return 0
  fi
  say ""
  say "Not fixed yet."
  return 1
}

need_root "$@"
need_tools

case "${1:-break}" in
  break)   do_break ;;
  verify)  do_verify; exit $? ;;
  cleanup) do_cleanup; say "Lab 2.8 cleaned up." ;;
  *)       say "Usage: $0 [break|verify|cleanup]" >&2; exit 2 ;;
esac

# =============================================================================
# SOLUTION (step by step)
# =============================================================================
#
# 1) Reproduce. Even the small ping fails:
#      ip netns exec lab28-gpu ping -c2 -W1 10.100.0.21
#      ...  2 packets transmitted, 0 received, 100% packet loss
#    And ARP never resolves:
#      ip netns exec lab28-gpu ip neigh
#      10.100.0.21 dev eth0.100 FAILED
#    A FAILED neighbor entry means the problem is at L2 (no ARP reply), not
#    routing, not MTU: ARP frames are tiny.
#
# 2) Inspect the 802.1Q tag on both ends. The interface name lies:
#      ip -n lab28-gpu  -d link show eth0.100 | grep vlan
#         vlan protocol 802.1Q id 100 <REORDER_HDR>
#      ip -n lab28-stor -d link show eth0.100 | grep vlan
#         vlan protocol 802.1Q id 200 <REORDER_HDR>
#    The storage node tags its frames with VLAN 200, so the GPU node (VLAN 100)
#    never sees its ARP replies. The VLAN ID of an existing interface cannot be
#    changed in place; recreate it:
#      ip -n lab28-stor link del eth0.100
#      ip -n lab28-stor link add link eth0 name eth0.100 type vlan id 100
#      ip -n lab28-stor link set eth0.100 mtu 9000
#      ip -n lab28-stor addr add 10.100.0.21/24 dev eth0.100
#      ip -n lab28-stor link set eth0.100 up
#
# 3) Re-test. Now this is the "fixed but large transfers hang" symptom:
#      ip netns exec lab28-gpu ping -c2 -W1 10.100.0.21              -> OK
#      ip netns exec lab28-gpu ping -c2 -W1 -M do -s 8972 10.100.0.21 -> 100% loss
#    -M do sets Don't Fragment; 8972 = 9000 - 20 (IPv4 header) - 8 (ICMP header),
#    i.e. exactly one full jumbo frame. Small works, big is silently dropped:
#    that is the fingerprint of an MTU mismatch on some hop. Note there is no
#    "Frag needed" error: an L2 switch drops oversize frames without telling
#    anyone, exactly what stalls RoCE / NVMe-oF in a real fabric.
#
# 4) Find the hop. Bisect with payload sizes if needed (1472 works, 1473 fails
#    -> some hop is at 1500), then list every interface on the path:
#      ip -n lab28-gpu  -o link show | grep -o '^[0-9]*: [^:]*.*mtu [0-9]*'
#      ip -n lab28-stor -o link show | grep -o '^[0-9]*: [^:]*.*mtu [0-9]*'
#      ip -o link show master lab28-br0
#         ... lab28-gp@if2: ... mtu 9000 master lab28-br0 ...
#         ... lab28-sp@if2: ... mtu 1500 master lab28-br0 ...
#    The switch port facing storage is still at the default 1500.
#
# 5) Fix it to the design MTU (never "fix" by lowering hosts to 1500; that
#    would break the jumbo-frame design every RDMA/storage workload relies on):
#      ip link set lab28-sp mtu 9000
#
# 6) Confirm end to end, both directions, with DF:
#      ip netns exec lab28-gpu  ping -c2 -M do -s 8972 10.100.0.21
#      ip netns exec lab28-stor ping -c2 -M do -s 8972 10.100.0.11
#      ./lab.sh verify      -> exit 0
#
# Takeaways for the exam and for production:
#   * VLANs (802.1Q) segment traffic at L2; the tag on the wire, not the
#     interface name, decides who can talk. Mismatched tags = no ARP = no
#     connectivity at all.
#   * MTU must be consistent on EVERY hop of the fabric (host NIC, VLAN
#     interface, each switch port, the peer). One small hop = small packets
#     work, large ones vanish. Always test with DF set and a full-size payload.
#   * In AI fabrics (InfiniBand or RoCE on Spectrum-X, ConnectX/BlueField NICs)
#     these checks are part of cluster bring-up, alongside PFC/ECN for lossless
#     Ethernet, because RDMA transports do not fragment and retries look like
#     a "slow" or "hung" job rather than a network error.
# =============================================================================