#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 2.7: Determine networking requirements for AI workloads
# Break & Fix lab: "The jumbo-frame black hole on the GPU compute fabric"
#
# lab-resources: cpus=1 ram_mb=512
#
# What this lab builds (entirely inside network namespaces, the host network
# is never touched):
#
#     [aiio-node-a]                 [aiio-leaf]                  [aiio-node-b]
#     GPU node A                    leaf switch                  GPU node B
#     eth0 10.77.0.1/24 ---veth--- swp1 ==br0== swp2 ---veth--- eth0 10.77.0.2/24
#
# The intended design is an AI "east-west" compute fabric: every hop at
# MTU 9000 (jumbo frames), lossless (no drops), and full line rate. This is
# what RDMA / RoCEv2 / GPUDirect RDMA traffic (NCCL all-reduce between GPU
# nodes) expects. The break step introduces three realistic faults that
# violate those requirements.
#
# Modes (all idempotent):
#   ./lab.sh            same as "break"
#   ./lab.sh break      build the fabric and break it
#   ./lab.sh verify     exit 0 only when the fabric meets the requirements
#   ./lab.sh cleanup    remove everything this lab created
#
# Official references:
#   - NVIDIA DGX SuperPOD reference architecture (B200), network fabrics:
#     https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#   - DGX H100 component descriptions (ConnectX-7, 400 Gb/s per GPU port):
#     https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   - NVLink and NVLink Switch (scale-up vs scale-out):
#     https://www.nvidia.com/en-us/data-center/nvlink/
#   - Accelerating IO in the modern data center (network IO, RDMA, GPUDirect):
#     https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
#   - Offloading and isolating data center workloads with BlueField DPU:
#     https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
#   - NVIDIA AI Infrastructure and Operations Fundamentals course:
#     https://academy.nvidia.com/en/course/ai-infrastructure-operations-fundamentals/?cm=64727
# =============================================================================

set -u

NS_A="aiio-node-a"
NS_B="aiio-node-b"
NS_L="aiio-leaf"
IP_A="10.77.0.1"
IP_B="10.77.0.2"
FABRIC_MTU=9000
# Largest ICMP payload that fits a 9000-byte MTU: 9000 - 20 (IPv4) - 8 (ICMP)
JUMBO_PAYLOAD=$((FABRIC_MTU - 28))

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_bld=$'\e[1m'; c_off=$'\e[0m'
if [ ! -t 1 ]; then c_red=""; c_grn=""; c_yel=""; c_bld=""; c_off=""; fi

info() { printf '%s[lab]%s %s\n' "$c_bld" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 2; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            exec sudo -E bash "$0" "$@"
        fi
        die "this lab must run as root (network namespaces, tc)."
    fi
}

ensure_tools() {
    local missing=""
    command -v ip   >/dev/null 2>&1 || missing="$missing ip"
    command -v tc   >/dev/null 2>&1 || missing="$missing tc"
    command -v ping >/dev/null 2>&1 || missing="$missing ping"
    [ -z "$missing" ] && return 0

    info "installing missing tools:$missing"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 iputils-ping >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q iproute iproute-tc iputils >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q iproute iproute-tc iputils >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add -q iproute2 iputils >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        zypper -q -n install iproute2 iputils >/dev/null 2>&1
    fi
    command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 && command -v ping >/dev/null 2>&1 \
        || die "could not install iproute2/tc/ping; install them and re-run."
}

confirm() {
    # Never block the runner: STUDY_LAB=1 or LAB_DISPOSABLE=yes skip the prompt,
    # and so does the absence of a terminal.
    if [ "${STUDY_LAB:-}" = "1" ] || [ "${LAB_DISPOSABLE:-}" = "yes" ] || [ ! -t 0 ]; then
        return 0
    fi
    printf 'This lab creates network namespaces %s, %s, %s on this machine.\n' "$NS_A" "$NS_L" "$NS_B"
    printf 'It does not touch the host network. Continue? [y/N] '
    local ans=""
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) return 0 ;; *) info "aborted."; exit 1 ;; esac
}

nsx() { local ns="$1"; shift; ip netns exec "$ns" "$@"; }

ns_exists() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

do_cleanup() {
    local ns
    for ns in "$NS_A" "$NS_B" "$NS_L"; do
        ns_exists "$ns" && ip netns del "$ns" 2>/dev/null
    done
    # Leftovers in the root namespace if a previous build was interrupted
    local l
    for l in aiio-a0 aiio-a1 aiio-b0 aiio-b1; do
        ip link show "$l" >/dev/null 2>&1 && ip link del "$l" 2>/dev/null
    done
    return 0
}

build_fabric() {
    ip netns add "$NS_A" || die "cannot create namespace $NS_A"
    ip netns add "$NS_B" || die "cannot create namespace $NS_B"
    ip netns add "$NS_L" || die "cannot create namespace $NS_L"

    ip link add aiio-a0 type veth peer name aiio-a1 || die "cannot create veth pair (is the veth module available?)"
    ip link add aiio-b0 type veth peer name aiio-b1 || die "cannot create veth pair"

    ip link set aiio-a0 netns "$NS_A"
    ip link set aiio-a1 netns "$NS_L"
    ip link set aiio-b0 netns "$NS_B"
    ip link set aiio-b1 netns "$NS_L"

    nsx "$NS_A" ip link set aiio-a0 name eth0
    nsx "$NS_B" ip link set aiio-b0 name eth0
    nsx "$NS_L" ip link set aiio-a1 name swp1
    nsx "$NS_L" ip link set aiio-b1 name swp2

    # Leaf switch: a plain Linux bridge with two "switch ports", all jumbo
    nsx "$NS_L" ip link set lo up
    nsx "$NS_L" ip link add br0 type bridge || die "cannot create bridge (bridge module missing?)"
    nsx "$NS_L" ip link set swp1 mtu "$FABRIC_MTU"
    nsx "$NS_L" ip link set swp2 mtu "$FABRIC_MTU"
    nsx "$NS_L" ip link set swp1 master br0
    nsx "$NS_L" ip link set swp2 master br0
    nsx "$NS_L" ip link set swp1 up
    nsx "$NS_L" ip link set swp2 up
    nsx "$NS_L" ip link set br0 up

    # GPU nodes: jumbo frames on the compute NIC
    local ns ipaddr
    for ns in "$NS_A" "$NS_B"; do
        if [ "$ns" = "$NS_A" ]; then ipaddr="$IP_A"; else ipaddr="$IP_B"; fi
        nsx "$ns" ip link set lo up
        nsx "$ns" ip link set eth0 mtu "$FABRIC_MTU"
        nsx "$ns" ip addr add "${ipaddr}/24" dev eth0
        nsx "$ns" ip link set eth0 up
    done

    # Let the bridge learn MACs before the student starts probing
    nsx "$NS_A" ping -c 2 -W 1 -q "$IP_B" >/dev/null 2>&1 || true
}

inject_faults() {
    # Fault 1: one leaf switch port left at the default MTU 1500.
    # The bridge silently drops forwarded frames larger than the egress port
    # MTU: no ICMP "fragmentation needed" is generated by a L2 device, so the
    # result is a classic MTU black hole (small packets work, big ones vanish).
    nsx "$NS_L" ip link set swp2 mtu 1500

    # Fault 2: packet loss on node B's NIC. RoCE/RDMA assumes a lossless fabric
    # (PFC/ECN); even ~1-3% loss collapses NCCL collective throughput.
    if ! nsx "$NS_B" tc qdisc replace dev eth0 root netem loss 3% 2>/dev/null; then
        warn "sch_netem not available in this kernel; skipping the packet-loss fault."
    fi

    # Fault 3: node A's port throttled to 100 Mbit/s, simulating a link that
    # came up at the wrong speed (or a misapplied shaping policy). burst is
    # larger than a jumbo frame so this fault does not mask fault 1.
    if ! nsx "$NS_A" tc qdisc replace dev eth0 root tbf rate 100mbit burst 64kb latency 50ms 2>/dev/null; then
        warn "sch_tbf not available in this kernel; skipping the bandwidth fault."
    fi
}

print_briefing() {
    cat <<EOF

${c_bld}=== Incident ticket: AI-FABRIC-2.7 ===${c_off}

A two-node distributed training job (NCCL all-reduce over the east-west
compute fabric) is hanging at initialization and, when it does progress,
runs at a fraction of the expected bandwidth. The fabric design says:

  * Every hop of the compute fabric runs jumbo frames: MTU ${FABRIC_MTU}, end to end.
  * The fabric is lossless: no packet drops injected anywhere on the path.
  * Ports run at full line rate: no shaping or rate limiting on fabric ports.

Topology (network namespaces on this VM):

  ${NS_A} eth0 ${IP_A} <-> ${NS_L} swp1 [br0] swp2 <-> ${NS_B} eth0 ${IP_B}

Symptoms you should observe:

  * A small ping works:
      ip netns exec ${NS_A} ping -c 3 ${IP_B}
  * A full-size jumbo ping with Don't Fragment set gets 100% loss:
      ip netns exec ${NS_A} ping -c 3 -M do -s ${JUMBO_PAYLOAD} ${IP_B}
  * Repeated pings show intermittent loss and odd latency.

Your goal: make the fabric meet ALL three requirements above, without
lowering the fabric MTU and without deleting the namespaces. Then run:

  $0 verify

Useful tools: ip -d link, ip netns exec, bridge link, tc qdisc show, ping -M do -s.

EOF
}

do_break() {
    need_root "$@"
    ensure_tools
    confirm
    info "resetting any previous run of this lab..."
    do_cleanup
    info "building the AI compute fabric (MTU ${FABRIC_MTU})..."
    build_fabric
    info "injecting faults..."
    inject_faults
    print_briefing
    exit 0
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
FAILS=0
pass() { printf '  %s[PASS]%s %s\n' "$c_grn" "$c_off" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$c_red" "$c_off" "$*"; FAILS=$((FAILS + 1)); }

check_mtu() {
    local ns="$1" dev="$2" mtu
    mtu="$(nsx "$ns" cat "/sys/class/net/${dev}/mtu" 2>/dev/null || echo "missing")"
    if [ "$mtu" = "$FABRIC_MTU" ]; then
        pass "${ns}/${dev} MTU is ${mtu}"
    else
        fail "${ns}/${dev} MTU is ${mtu}, the fabric requires ${FABRIC_MTU}"
    fi
}

check_qdisc() {
    local ns="$1" dev="$2" out
    out="$(nsx "$ns" tc qdisc show dev "$dev" 2>/dev/null || true)"
    if printf '%s\n' "$out" | grep -Eq '(^| )(netem|tbf|htb|cake|red|choke)( |$)'; then
        fail "${ns}/${dev} has a loss/shaping qdisc: $(printf '%s' "$out" | head -n1)"
    else
        pass "${ns}/${dev} has no loss or shaping qdisc"
    fi
}

check_ping() {
    local ns="$1" dst="$2" size="$3" label="$4" out
    if [ "$size" -gt 56 ]; then
        out="$(nsx "$ns" ping -c 5 -i 0.2 -W 2 -q -M do -s "$size" "$dst" 2>&1 || true)"
    else
        out="$(nsx "$ns" ping -c 5 -i 0.2 -W 2 -q "$dst" 2>&1 || true)"
    fi
    if printf '%s\n' "$out" | grep -q ' 0% packet loss'; then
        pass "$label"
    else
        fail "$label ($(printf '%s\n' "$out" | grep -E 'packet loss|error|too long' | head -n1))"
    fi
}

do_verify() {
    need_root "$@"
    command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 \
        || { echo "iproute2/tc not installed: run '$0 break' first."; exit 1; }

    local ns
    for ns in "$NS_A" "$NS_B" "$NS_L"; do
        if ! ns_exists "$ns"; then
            echo "namespace ${ns} not found: run '$0 break' first (do not delete the namespaces)."
            exit 1
        fi
    done

    echo "${c_bld}Requirement 1: jumbo frames end to end (MTU ${FABRIC_MTU})${c_off}"
    check_mtu "$NS_A" eth0
    check_mtu "$NS_L" swp1
    check_mtu "$NS_L" swp2
    check_mtu "$NS_B" eth0

    echo "${c_bld}Requirement 2 and 3: lossless, full line rate${c_off}"
    check_qdisc "$NS_A" eth0
    check_qdisc "$NS_L" swp1
    check_qdisc "$NS_L" swp2
    check_qdisc "$NS_B" eth0

    echo "${c_bld}Data path${c_off}"
    check_ping "$NS_A" "$IP_B" 56 "small ping ${NS_A} -> ${NS_B}"
    check_ping "$NS_A" "$IP_B" "$JUMBO_PAYLOAD" "jumbo DF ping (${JUMBO_PAYLOAD} B payload) ${NS_A} -> ${NS_B}"
    check_ping "$NS_B" "$IP_A" "$JUMBO_PAYLOAD" "jumbo DF ping (${JUMBO_PAYLOAD} B payload) ${NS_B} -> ${NS_A}"

    echo
    if [ "$FAILS" -eq 0 ]; then
        echo "${c_grn}${c_bld}Fabric meets the AI networking requirements. Lab solved.${c_off}"
        exit 0
    fi
    echo "${c_red}${c_bld}${FAILS} check(s) failed. Keep troubleshooting.${c_off}"
    exit 1
}

do_cleanup_mode() {
    need_root "$@"
    if command -v ip >/dev/null 2>&1; then
        do_cleanup
    fi
    info "lab resources removed; the VM is back to its original state."
    exit 0
}

case "${1:-break}" in
    break)   do_break "$@" ;;
    verify)  do_verify "$@" ;;
    cleanup) do_cleanup_mode "$@" ;;
    *)       echo "usage: $0 [break|verify|cleanup]" >&2; exit 2 ;;
esac

# =============================================================================
# SOLUTION (step by step) - read only after trying
# =============================================================================
#
# 1. Reproduce and characterise the symptom. Small packets pass, large ones
#    with DF set vanish: that is the signature of an MTU mismatch somewhere on
#    the path, not of a routing or ARP problem.
#
#      ip netns exec aiio-node-a ping -c 3 10.77.0.2                 # OK
#      ip netns exec aiio-node-a ping -c 3 -M do -s 8972 10.77.0.2   # 100% loss
#
#    8972 = 9000 (MTU) - 20 (IPv4 header) - 8 (ICMP header). The local NIC
#    accepts it (otherwise ping would print "message too long"), so the drop
#    is further down the path. A L2 switch does not send ICMP "fragmentation
#    needed", so Path MTU Discovery cannot save you: the packet just disappears.
#
# 2. Walk the path hop by hop and compare MTUs:
#
#      ip netns exec aiio-node-a ip -br link show eth0   # mtu 9000
#      ip netns exec aiio-leaf   ip -d link show swp1    # mtu 9000
#      ip netns exec aiio-leaf   ip -d link show swp2    # mtu 1500  <-- culprit
#      ip netns exec aiio-node-b ip -br link show eth0   # mtu 9000
#      ip netns exec aiio-leaf   bridge link show
#
#    Fix the leaf port (the bridge device br0 follows its ports automatically):
#
#      ip netns exec aiio-leaf ip link set swp2 mtu 9000
#
#    In production the equivalent is the switch port / interface MTU on the
#    leaf (e.g. Spectrum switch running Cumulus Linux or SONiC) and the NIC MTU
#    on every host, all consistent across the fabric.
#
# 3. Look for anything that drops or shapes traffic on the path:
#
#      for ns in aiio-node-a aiio-node-b; do
#          echo "== $ns"; ip netns exec $ns tc -s qdisc show dev eth0
#      done
#      ip netns exec aiio-leaf tc -s qdisc show dev swp1
#      ip netns exec aiio-leaf tc -s qdisc show dev swp2
#
#    Expected findings:
#      node-b eth0: "qdisc netem ... loss 3%"         -> lossy fabric
#      node-a eth0: "qdisc tbf ... rate 100Mbit ..."  -> port throttled
#
#    Remove both, which restores the default qdisc:
#
#      ip netns exec aiio-node-b tc qdisc del dev eth0 root
#      ip netns exec aiio-node-a tc qdisc del dev eth0 root
#
#    Why it matters: RoCEv2 (RDMA over Converged Ethernet) is designed for a
#    lossless fabric (PFC + ECN / congestion control). Go-back-N retransmission
#    makes RDMA throughput collapse with even small loss rates, and NCCL
#    collectives run at the speed of the slowest link, so one throttled port
#    slows the whole job. DGX nodes give each GPU its own 400 Gb/s ConnectX-7
#    port on a rail-optimized compute fabric, separate from the storage, in-band
#    management and out-of-band management networks.
#
# 4. Confirm end to end, in both directions:
#
#      ip netns exec aiio-node-a ping -c 5 -M do -s 8972 10.77.0.2   # 0% loss
#      ip netns exec aiio-node-b ping -c 5 -M do -s 8972 10.77.0.1   # 0% loss
#      ./lab.sh verify                                                # exit 0
#
# 5. Wrong "fixes" that verify rejects on purpose:
#      - Lowering every interface to MTU 1500: traffic flows, but the design
#        requirement (jumbo frames on the AI fabric) is violated and per-packet
#        overhead rises for bulk GPU-to-GPU transfers.
#      - Deleting and recreating the namespaces by hand: that is not
#        troubleshooting, and the briefing forbids it.
#
# 6. When done:  ./lab.sh cleanup
# =============================================================================