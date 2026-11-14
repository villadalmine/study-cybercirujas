#!/usr/bin/env bash
# =============================================================================
# NCA-AIIO - Topic 2.10: Explain the purpose and benefits of a DPU in a data center
# Lab type: break & fix (simulated DPU trust domain with Linux network namespaces)
#
# lab-resources: cpus=1 ram_mb=512
#
# What this lab models
# --------------------
# A real NVIDIA BlueField DPU (BlueField-3 in DGX B200 and DGX SuperPOD)
# is a separate computer on the NIC. It has its own Arm cores, memory, OS
# and DOCA software stack. It sits between the host CPU and the network
# fabric. Infrastructure services run on the DPU and not on the host:
# virtual switching (OVS with ASAP2 hardware offload), firewalling and
# micro-segmentation, storage (NVMe-oF / SNAP), encryption (IPsec/TLS) and
# telemetry. This brings two benefits:
#   1. Offload: host CPU cycles go back to applications and AI workloads.
#   2. Isolation: the infrastructure control plane lives in a different
#      trust domain. A compromised or misconfigured host or tenant cannot
#      disable the security policy that the DPU enforces (zero-trust).
#
# Disposable VM topology (no real DPU hardware needed):
#
#   [lab-host]  host0 10.10.1.2 ---- dpu-pf 10.10.1.1 [lab-dpu] dpu-p0 10.10.2.1 ---- net0 10.10.2.2 [lab-net]
#   x86 host / tenant          "PCIe PF/representor"   BlueField Arm   "uplink p0"      fabric: storage API :8080
#   (untrusted domain)                                 (infra domain)                   mgmt service  :9090
#
# Intended (correct) design:
#   - lab-dpu forwards traffic between the host and the fabric (data path).
#   - lab-dpu enforces the policy: the host may reach :8080 and ICMP only.
#     It must NOT reach :9090.
#   - lab-host has NO firewall rules of its own. Policy in the tenant domain
#     is not a security control, because the tenant can delete it.
#
# References:
#   https://developer.nvidia.com/blog/offloading-and-isolating-data-center-workloads-with-bluefield-dpu
#   https://developer.nvidia.com/blog/accelerating-io-in-the-modern-data-center-network-io/
#   https://docs.nvidia.com/dgx/dgxh100-user-guide/introduction-to-dgxh100.html#dgx-h100-component-descriptions
#   https://docs.nvidia.com/dgx-superpod/reference-architecture-scalable-infrastructure-b200/latest/index.html
#
# Usage:  sudo ./break_fix.sh [break|verify|cleanup]     (default: break)
# =============================================================================

set -u

NS_HOST="lab-host"
NS_DPU="lab-dpu"
NS_NET="lab-net"
STATE_DIR="/run/dpu-lab"
WWW_DIR="${STATE_DIR}/www"
HOST_IP="10.10.1.2"
DPU_PF_IP="10.10.1.1"
DPU_P0_IP="10.10.2.1"
NET_IP="10.10.2.2"
ALLOWED_PORT=8080
FORBIDDEN_PORT=9090

log()  { printf '[dpu-lab] %s\n' "$*"; }
fail() { printf '[dpu-lab] FAIL: %s\n' "$*" >&2; }
ok()   { printf '[dpu-lab] OK:   %s\n' "$*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This lab must run as root (it creates network namespaces)." >&2
    exit 2
  fi
}

confirm() {
  if [ "${STUDY_LAB:-}" = "1" ] || [ "${LAB_DISPOSABLE:-}" = "yes" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    echo "No terminal and STUDY_LAB/LAB_DISPOSABLE not set; refusing to run." >&2
    exit 2
  fi
  printf 'This lab creates network namespaces %s, %s, %s on THIS machine.\n' "$NS_HOST" "$NS_DPU" "$NS_NET"
  printf 'Run it only on a disposable lab VM. Continue? [y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) echo "Aborted."; exit 1 ;; esac
}

install_pkg() {
  # $1 = command to check, $2 = package name
  command -v "$1" >/dev/null 2>&1 && return 0
  log "Installing missing dependency: $2"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$2" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$2" >/dev/null 2>&1
  elif command -v zypper >/dev/null 2>&1; then
    zypper -q install -y "$2" >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add -q "$2" >/dev/null 2>&1
  fi
  command -v "$1" >/dev/null 2>&1 || { echo "Could not install $2; please install it and retry." >&2; exit 3; }
}

deps() {
  install_pkg ip iproute2
  install_pkg nft nftables
  install_pkg python3 python3
  install_pkg timeout coreutils
  install_pkg sysctl procps
  install_pkg curl curl
  install_pkg ping iputils-ping
}

ns_exists() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

tcp_probe() {
  # tcp_probe <port> : returns 0 if the host namespace can open a TCP connection to the fabric
  ip netns exec "$NS_HOST" timeout 3 bash -c "exec 3<>/dev/tcp/${NET_IP}/$1" >/dev/null 2>&1
}

teardown() {
  if [ -d "$STATE_DIR" ]; then
    for pidf in "$STATE_DIR"/*.pid; do
      [ -f "$pidf" ] || continue
      pid="$(cat "$pidf" 2>/dev/null)"
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1
      rm -f "$pidf"
    done
  fi
  # Kill any leftover servers that were started inside lab-net
  if ns_exists "$NS_NET"; then
    for pid in $(ip netns pids "$NS_NET" 2>/dev/null); do
      kill "$pid" >/dev/null 2>&1
    done
  fi
  for ns in "$NS_HOST" "$NS_DPU" "$NS_NET"; do
    ns_exists "$ns" && ip netns del "$ns" >/dev/null 2>&1
  done
  # The veth pairs disappear with their namespaces; remove strays left in the root ns just in case
  for dev in host0 dpu-pf dpu-p0 net0; do
    ip link show "$dev" >/dev/null 2>&1 && ip link del "$dev" >/dev/null 2>&1
  done
  rm -rf "$STATE_DIR"
}

build_topology() {
  mkdir -p "$WWW_DIR"
  echo "storage-api: reachable through the DPU data path" > "$WWW_DIR/index.html"

  ip netns add "$NS_HOST"
  ip netns add "$NS_DPU"
  ip netns add "$NS_NET"
  for ns in "$NS_HOST" "$NS_DPU" "$NS_NET"; do
    ip -n "$ns" link set lo up
  done

  # Host <-> DPU ("PCIe physical function / representor")
  ip link add host0 type veth peer name dpu-pf
  ip link set host0 netns "$NS_HOST"
  ip link set dpu-pf netns "$NS_DPU"
  # DPU <-> fabric ("uplink port p0")
  ip link add dpu-p0 type veth peer name net0
  ip link set dpu-p0 netns "$NS_DPU"
  ip link set net0 netns "$NS_NET"

  ip -n "$NS_HOST" addr add "${HOST_IP}/24"   dev host0
  ip -n "$NS_DPU"  addr add "${DPU_PF_IP}/24" dev dpu-pf
  ip -n "$NS_DPU"  addr add "${DPU_P0_IP}/24" dev dpu-p0
  ip -n "$NS_NET"  addr add "${NET_IP}/24"    dev net0

  ip -n "$NS_HOST" link set host0 up
  ip -n "$NS_DPU"  link set dpu-pf up
  ip -n "$NS_DPU"  link set dpu-p0 up
  ip -n "$NS_NET"  link set net0 up

  ip -n "$NS_HOST" route add default via "$DPU_PF_IP"
  ip -n "$NS_NET"  route add default via "$DPU_P0_IP"

  # Fabric services
  ip netns exec "$NS_NET" nohup python3 -m http.server "$ALLOWED_PORT" \
      --bind "$NET_IP" --directory "$WWW_DIR" >/dev/null 2>&1 &
  echo $! > "$STATE_DIR/allowed.pid"
  ip netns exec "$NS_NET" nohup python3 -m http.server "$FORBIDDEN_PORT" \
      --bind "$NET_IP" --directory "$WWW_DIR" >/dev/null 2>&1 &
  echo $! > "$STATE_DIR/forbidden.pid"
  sleep 1
}

dpu_correct_policy() {
  ip netns exec "$NS_DPU" sysctl -qw net.ipv4.ip_forward=1
  ip netns exec "$NS_DPU" nft -f - <<'EOF'
table inet dpu_policy {
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "dpu-pf" ip protocol icmp accept
    iifname "dpu-pf" tcp dport 8080 accept
  }
}
EOF
}

do_break() {
  require_root
  confirm
  deps
  log "Resetting any previous run..."
  teardown
  log "Building the simulated host / DPU / fabric topology..."
  # set -e only inside the subshell, and not under || or if, where bash ignores it.
  ( set -e; build_topology )
  topo_rc=$?
  if [ "$topo_rc" -ne 0 ]; then
    teardown
    echo "ERROR: could not build the network namespaces (need root with NET_ADMIN and SYS_ADMIN; see 'ip netns add')." >&2
    exit 1
  fi
  dpu_correct_policy

  # --- The controlled breakage ----------------------------------------------
  # 1) A "host-centric" engineer disables forwarding on the DPU (data path dead).
  ip netns exec "$NS_DPU" sysctl -qw net.ipv4.ip_forward=0
  # 2) The infrastructure policy is removed from the DPU domain...
  ip netns exec "$NS_DPU" nft delete table inet dpu_policy >/dev/null 2>&1
  # 3) ...and "re-implemented" on the host, inside the tenant's own trust domain.
  ip netns exec "$NS_HOST" nft -f - <<'EOF'
table inet tenant_fw {
  chain output {
    type filter hook output priority 0; policy accept;
    tcp dport 9090 drop
  }
}
EOF

  cat <<EOF

=============================================================================
 DPU break & fix lab is ready
=============================================================================
 Scenario
   Your AI cluster's servers use a BlueField DPU as the infrastructure
   domain. Networking, security policy and storage access are meant to run
   on the DPU and NOT on the host x86 CPU. The DPU then (a) offloads that
   work from the host and (b) isolates it from a possibly compromised tenant.

   A colleague "simplified" the setup. Now:

 Symptoms you will see
   * The host cannot reach the storage API on the fabric:
       sudo ip netns exec ${NS_HOST} curl -m 3 http://${NET_IP}:${ALLOWED_PORT}/
       -> times out
   * The DPU does not forward packets between its PF and its uplink:
       sudo ip netns exec ${NS_DPU} sysctl net.ipv4.ip_forward
       -> net.ipv4.ip_forward = 0
   * The DPU enforces no policy at all:
       sudo ip netns exec ${NS_DPU} nft list ruleset    -> empty
   * The "protection" for the management service (:${FORBIDDEN_PORT}) lives in
     the HOST/tenant namespace. Any tenant with root can delete it:
       sudo ip netns exec ${NS_HOST} nft list ruleset   -> table inet tenant_fw

 Goal (what 'verify' checks)
   1. ${NS_DPU} forwards traffic again (net.ipv4.ip_forward = 1).
   2. The host can ping ${NET_IP} and open TCP :${ALLOWED_PORT}, through the DPU.
   3. The host can NOT open TCP :${FORBIDDEN_PORT}, and that block is enforced
      by an nftables forward-hook chain in ${NS_DPU} (the infrastructure domain).
   4. ${NS_HOST} has NO nftables ruleset. Security policy does not belong in
      the tenant's trust domain.

 Commands
   sudo $0 verify     # check your fix
   sudo $0 cleanup    # remove everything
=============================================================================
EOF
}

do_verify() {
  require_root
  local rc=0

  for ns in "$NS_HOST" "$NS_DPU" "$NS_NET"; do
    if ! ns_exists "$ns"; then
      fail "namespace $ns does not exist; run '$0 break' first"
      exit 1
    fi
  done

  fwd="$(ip netns exec "$NS_DPU" sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  if [ "$fwd" = "1" ]; then
    ok "DPU data path: ${NS_DPU} forwards packets (ip_forward=1)"
  else
    fail "DPU data path: ${NS_DPU} has ip_forward=${fwd:-unknown}; the DPU is not forwarding host traffic"
    rc=1
  fi

  host_rules="$(ip netns exec "$NS_HOST" nft list ruleset 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$host_rules" ]; then
    ok "Trust domain: ${NS_HOST} (tenant) has no firewall rules of its own"
  else
    fail "Trust domain: ${NS_HOST} still has an nftables ruleset; the tenant could delete that policy"
    rc=1
  fi

  if ip netns exec "$NS_DPU" nft list ruleset 2>/dev/null | grep -q 'hook forward'; then
    ok "Policy location: ${NS_DPU} has a forward-hook chain (enforced in the DPU domain)"
  else
    fail "Policy location: no forward-hook nftables chain in ${NS_DPU}"
    rc=1
  fi

  if ip netns exec "$NS_HOST" ping -c1 -W2 "$NET_IP" >/dev/null 2>&1; then
    ok "Connectivity: host -> fabric ICMP works through the DPU"
  else
    fail "Connectivity: host cannot ping ${NET_IP}"
    rc=1
  fi

  if tcp_probe "$ALLOWED_PORT"; then
    ok "Allowed service: host -> ${NET_IP}:${ALLOWED_PORT} reachable"
  else
    fail "Allowed service: host cannot reach ${NET_IP}:${ALLOWED_PORT}"
    rc=1
  fi

  if tcp_probe "$FORBIDDEN_PORT"; then
    fail "Forbidden service: host CAN reach ${NET_IP}:${FORBIDDEN_PORT}; the DPU is not enforcing the policy"
    rc=1
  else
    ok "Forbidden service: host -> ${NET_IP}:${FORBIDDEN_PORT} blocked"
  fi

  # Sanity: the forbidden server must actually be up, otherwise a "blocked" result proves nothing
  if ! ip netns exec "$NS_NET" timeout 3 bash -c "exec 3<>/dev/tcp/${NET_IP}/${FORBIDDEN_PORT}" >/dev/null 2>&1; then
    fail "The :${FORBIDDEN_PORT} service in ${NS_NET} is down; re-run '$0 break' to rebuild the lab"
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    log "PASS: the DPU forwards traffic and enforces policy in its own trust domain."
  else
    log "NOT FIXED yet. Review the failures above."
  fi
  exit "$rc"
}

do_cleanup() {
  require_root
  teardown
  log "Cleanup complete: namespaces, veths, servers and ${STATE_DIR} removed."
  exit 0
}

case "${1:-break}" in
  break)   do_break ;;
  verify)  do_verify ;;
  cleanup) do_cleanup ;;
  *) echo "Usage: $0 [break|verify|cleanup]" >&2; exit 2 ;;
esac

# =============================================================================
# SOLUTION (step by step) - try on your own first!
# =============================================================================
#
# 1) Diagnose where the policy and the data path live:
#      sudo ip netns exec lab-dpu  sysctl net.ipv4.ip_forward   # -> 0  (data path down)
#      sudo ip netns exec lab-dpu  nft list ruleset              # -> empty (no infra policy)
#      sudo ip netns exec lab-host nft list ruleset              # -> table inet tenant_fw (wrong domain)
#      sudo ip netns exec lab-host ip route                      # -> default via 10.10.1.1 (the DPU)
#
# 2) Restore the DPU data path. On a real BlueField this is the OVS bridge
#    between the host representor (pf0hpf) and the uplink (p0), offloaded
#    to the eSwitch with ASAP2:
#      sudo ip netns exec lab-dpu sysctl -w net.ipv4.ip_forward=1
#
# 3) Move the policy into the infrastructure (DPU) domain:
#      sudo ip netns exec lab-dpu nft -f - <<'EOF'
#      table inet dpu_policy {
#        chain forward {
#          type filter hook forward priority 0; policy drop;
#          ct state established,related accept
#          iifname "dpu-pf" ip protocol icmp accept
#          iifname "dpu-pf" tcp dport 8080 accept
#        }
#      }
#      EOF
#
# 4) Remove the tenant-side "security" (anyone with root on the host could do this):
#      sudo ip netns exec lab-host nft delete table inet tenant_fw
#
# 5) Prove the isolation benefit. The tenant tries to bypass the policy and fails:
#      sudo ip netns exec lab-host nft flush ruleset
#      sudo ip netns exec lab-host curl -m 3 http://10.10.2.2:8080/   # -> page content
#      sudo ip netns exec lab-host curl -m 3 http://10.10.2.2:9090/   # -> timeout (DPU drops it)
#
# 6) Check:
#      sudo ./break_fix.sh verify    # all OK, exit code 0
#
# Takeaway for the exam: a DPU is a programmable data-center infrastructure
# processor (Arm cores + NIC + accelerators, programmed with DOCA). It
# offloads networking, storage and security from the host CPU, accelerates
# them in hardware, and isolates them in a separate trust domain. That gives
# zero-trust enforcement even when the host is compromised. In DGX B200
# systems, BlueField-3 DPUs handle the storage and in-band management networks.
# =============================================================================