#!/usr/bin/env bash
# =============================================================================
# CKNE 5.1 - Analyzing Network Health Using Metrics
# BREAK & FIX LAB: "The link that looks healthy"
# =============================================================================
#
# WHAT THIS LAB DOES
#   Builds an isolated topology on a DISPOSABLE lab VM:
#
#     host netns                              netns "ckne-metrics-lab"
#     +--------------------+   veth pair     +-------------------------+
#     | ckne-h0 10.231.0.1 |<--------------->| ckne-n0 10.231.0.2      |
#     |  (client + probe)  |                 |  python3 http.server    |
#     +--------------------+                 |  :8080 /blob.bin 256KiB |
#                                            +-------------------------+
#
#   The namespace behaves like a Kubernetes Pod: it has its own network
#   stack, its own qdiscs and its OWN TCP/IP counters (/proc/net/snmp and
#   /proc/net/netstat are per network namespace). A background "SLO probe"
#   downloads the blob every second and logs the HTTP code and latency, as a
#   blackbox exporter would.
#
#   Then it injects TWO impairments, one on each side of the link. The student
#   has to find both using metrics only: qdisc statistics, kernel SNMP
#   counters, per-socket TCP info and ICMP RTT.
#
# SAFETY
#   - The only things it touches: one network namespace, one veth pair, the
#     10.231.0.0/30 subnet, and the /run/ckne-metrics-lab state directory.
#   - It does NOT modify your real interfaces, routes, iptables or sysctls.
#     Your SSH session is not affected.
#   - "cleanup" removes everything. Rebooting the VM also removes everything.
#
# REQUIREMENTS
#   root, iproute2 (ip, tc, ss, nstat), sch_netem kernel module, iputils ping,
#   curl, python3 >= 3.7.
#
# USAGE
#   sudo ./ckne-5.1-break-fix.sh break     # build the lab and inject the faults
#   sudo ./ckne-5.1-break-fix.sh status    # SLO-probe "dashboard"
#   sudo ./ckne-5.1-break-fix.sh verify    # check whether you fixed it
#   sudo ./ckne-5.1-break-fix.sh cleanup   # remove everything
#
# REFERENCES (official sources)
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://man7.org/linux/man-pages/man8/tc-netem.8.html
#   https://man7.org/linux/man-pages/man8/nstat.8.html
#   https://man7.org/linux/man-pages/man8/ss.8.html
#   https://man7.org/linux/man-pages/man8/ip-netns.8.html
#   https://github.com/prometheus/node_exporter
#   https://kubernetes.io/docs/concepts/cluster-administration/system-metrics/
#   https://docs.cilium.io/en/stable/observability/metrics/
# =============================================================================

set -euo pipefail

NS="ckne-metrics-lab"
HOST_IF="ckne-h0"
NS_IF="ckne-n0"
HOST_IP="10.231.0.1"
NS_IP="10.231.0.2"
PORT=8080
STATE_DIR="/run/ckne-metrics-lab"
WWW_DIR="${STATE_DIR}/www"
PROBE_LOG="${STATE_DIR}/probe.log"
URL="http://${NS_IP}:${PORT}/blob.bin"

if [[ -t 1 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

info() { printf '%s[*]%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()   { printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run as root (sudo). The lab creates a netns and qdiscs."
}

preflight() {
  local cmd
  for cmd in ip tc ss nstat ping curl python3 awk sed setsid head sort; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: ${cmd}"
  done
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' \
    || die "python3 >= 3.7 is required (http.server --directory)."
  modprobe sch_netem 2>/dev/null || true
  if ip -o addr show | grep -v -e " ${HOST_IF} " | grep -q " 10\.231\.0\."; then
    die "10.231.0.0/30 is already in use on this machine. Not touching it."
  fi
  if ip netns list 2>/dev/null | grep -qw "${NS}" || [[ -d "${STATE_DIR}" ]]; then
    die "The lab already exists. Run '$0 cleanup' first."
  fi
}

# ---------------------------------------------------------------------------
# Measurement helpers (verify uses them, and they show the baseline)
# ---------------------------------------------------------------------------

# Prints "<loss%> <avg_rtt_ms>"
ping_stats() {
  local count=$1 out loss avg
  out=$(ping -c "$count" -i 0.2 -W 1 -q "$NS_IP" 2>&1 || true)
  loss=$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' <<<"$out")
  avg=$(awk -F'/' '/^(rtt|round-trip)/ {print $5}' <<<"$out")
  echo "${loss:-100} ${avg:-NA}"
}

# Prints "<failed> <max_s> <avg_s>"
download_n() {
  local n=$1 i out code t fails=0
  local times=()
  for ((i = 0; i < n; i++)); do
    out=$(curl -s -o /dev/null --max-time 5 -w '%{http_code} %{time_total}' "$URL" || true)
    code=${out%% *}
    t=${out##* }
    [[ "$code" == "200" ]] || fails=$((fails + 1))
    times+=("${t:-5}")
  done
  printf '%s\n' "${times[@]}" \
    | awk -v f="$fails" '{s += $1; if ($1 > m) m = $1} END {printf "%d %.3f %.3f\n", f, m, s / NR}'
}

# Absolute value of a kernel counter INSIDE the namespace (nstat -a: absolute,
# -s: do not touch the history file, -z: also print zero counters)
ns_counter() {
  local v
  v=$(ip netns exec "$NS" nstat -asz "$1" 2>/dev/null | awk -v k="$1" '$1 == k {print $2}')
  echo "${v:-0}"
}

# ---------------------------------------------------------------------------
# Lab lifecycle
# ---------------------------------------------------------------------------

cleanup() {
  local pid
  if [[ -f "${STATE_DIR}/probe.pid" ]]; then
    pid=$(<"${STATE_DIR}/probe.pid")
    kill -- "-${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
  fi
  if ip netns list 2>/dev/null | grep -qw "${NS}"; then
    for pid in $(ip netns pids "${NS}" 2>/dev/null); do
      kill "${pid}" 2>/dev/null || true
    done
    sleep 0.5
    ip netns del "${NS}" 2>/dev/null || true
  fi
  ip link del "${HOST_IF}" 2>/dev/null || true
  rm -rf "${STATE_DIR}"
  info "Lab removed (netns ${NS}, veth ${HOST_IF}/${NS_IF}, ${STATE_DIR})."
}

build_topology() {
  info "Creating netns ${NS} and veth ${HOST_IF} <-> ${NS_IF}"
  ip netns add "${NS}"
  ip link add "${HOST_IF}" type veth peer name "${NS_IF}"
  ip link set "${NS_IF}" netns "${NS}"
  ip addr add "${HOST_IP}/30" dev "${HOST_IF}"
  ip link set "${HOST_IF}" up
  ip netns exec "${NS}" ip link set lo up
  ip netns exec "${NS}" ip addr add "${NS_IP}/30" dev "${NS_IF}"
  ip netns exec "${NS}" ip link set "${NS_IF}" up
}

start_backend() {
  local i
  mkdir -p "${WWW_DIR}"
  head -c 262144 /dev/urandom > "${WWW_DIR}/blob.bin"
  info "Starting the backend http.server at ${NS_IP}:${PORT} inside ${NS}"
  setsid ip netns exec "${NS}" python3 -m http.server "${PORT}" \
    --bind "${NS_IP}" --directory "${WWW_DIR}" \
    > "${STATE_DIR}/server.log" 2>&1 < /dev/null &
  echo $! > "${STATE_DIR}/server.pid"
  for ((i = 0; i < 20; i++)); do
    if curl -s -o /dev/null --max-time 1 "$URL"; then
      return 0
    fi
    sleep 0.3
  done
  die "The backend did not respond. See ${STATE_DIR}/server.log"
}

start_probe() {
  info "Starting the SLO probe (1 download/s) -> ${PROBE_LOG}"
  : > "${PROBE_LOG}"
  setsid bash -c '
    while true; do
      r=$(curl -s -o /dev/null --max-time 5 -w "%{http_code} %{time_total}" "$1")
      printf "%s %s\n" "$(date +%T)" "${r:-000 5.000}" >> "$2"
      sleep 1
    done
  ' _ "$URL" "$PROBE_LOG" > /dev/null 2>&1 < /dev/null &
  echo $! > "${STATE_DIR}/probe.pid"
}

record_baseline() {
  local p d
  info "Measuring the HEALTHY baseline (keep it for comparison)..."
  p=$(ping_stats 20)
  d=$(download_n 10)
  {
    echo "BASELINE $(date -Is)"
    echo "ping: loss=${p%% *}% avg_rtt_ms=${p##* }"
    echo "download x10 (256KiB): failed=$(awk '{print $1}' <<<"$d") max_s=$(awk '{print $2}' <<<"$d") avg_s=$(awk '{print $3}' <<<"$d")"
    echo "netns TcpRetransSegs=$(ns_counter TcpRetransSegs) TcpInCsumErrors=$(ns_counter TcpInCsumErrors) IpInHdrErrors=$(ns_counter IpInHdrErrors)"
  } | tee "${STATE_DIR}/baseline.txt"
}

inject_faults() {
  info "Injecting faults..."
  # Fault 1: backend -> client direction. Egress of the interface INSIDE the
  # netns: latency with jitter plus random loss. Invisible from the host's
  # "tc qdisc show", exactly like a qdisc on a Pod's eth0.
  ip netns exec "${NS}" tc qdisc add dev "${NS_IF}" root netem delay 80ms 25ms loss 6%
  # Fault 2: client -> backend direction. Egress of the host-side veth:
  # corrupts bits in 3% of packets. It does not show up as "dropped" in any
  # qdisc; the RECEIVER stack (the netns) counts and discards them.
  tc qdisc add dev "${HOST_IF}" root netem corrupt 3%
}

mission_brief() {
  cat <<EOF

${BOLD}==================== MISSION: CKNE 5.1 ====================${RESET}

${BOLD}Context${RESET}
  The "backend" service (${URL}) lives in the network namespace
  "${NS}" (think of it as a Pod). Clients reach it through the veth
  ${HOST_IF} (node side) <-> ${NS_IF} (Pod side).
  The platform team reports: "the SLO is burning, but the interfaces are
  UP and ip -s link shows no errors".

${BOLD}Symptoms you will see${RESET}
  - The probe (${PROBE_LOG}) went from ~milliseconds to seconds.
    Occasional failures (code 000) under the 5 s timeout.
  - ICMP RTT went from < 1 ms to tens of ms, with packet loss.
  - "ip -s link show ${HOST_IF}" looks clean. Don't trust it blindly.

${BOLD}Your goal${RESET}
  1. Prove WITH METRICS where the degradation is. There is more than one
     cause and each one is on a different side of the link. Write down which
     counter or statistic proved each one.
  2. Remove the impairments without destroying the lab: the namespace, the
     veth pair and the backend must keep working.
  3. Run: sudo $0 verify   (it must pass every check)

${BOLD}Tools you are allowed to use${RESET}
  tc -s qdisc, ip -s link, nstat, ss -tin, ping, curl -w,
  ip netns exec ${NS} <command>, and the dashboard: sudo $0 status

${BOLD}Rules${RESET}
  - Do not run "cleanup" or recreate the netns: in production you don't
    delete the Pod to "fix" the network without knowing why.
  - Useful hint: which network stack are the counters you're reading from?

Baseline saved in: ${STATE_DIR}/baseline.txt
============================================================
EOF
}

status() {
  [[ -f "${PROBE_LOG}" ]] || die "No lab running. Use: $0 break"
  local lines
  lines=$(tail -n 60 "${PROBE_LOG}")
  [[ -n "$lines" ]] || die "The probe has no samples yet; wait a few seconds."
  echo "${BOLD}SLO probe - last $(wc -l <<<"$lines") samples${RESET}"
  awk '{n++; if ($2 == "200") okc++} END {printf "  availability: %.1f%% (%d/%d)\n", 100 * okc / n, okc, n}' <<<"$lines"
  awk '{print $3}' <<<"$lines" | sort -n | awk '
    {a[NR] = $1}
    END {
      p50 = a[int(NR * 0.50) > 0 ? int(NR * 0.50) : 1]
      p95 = a[int(NR * 0.95) > 0 ? int(NR * 0.95) : 1]
      printf "  latency p50: %.3fs  p95: %.3fs  max: %.3fs\n", p50, p95, a[NR]
    }'
  echo "  last 5 samples:"
  tail -n 5 "${PROBE_LOG}" | sed 's/^/    /'
  echo "  baseline:"
  sed 's/^/    /' "${STATE_DIR}/baseline.txt"
}

verify() {
  local fails=0 p loss avg d dfail dmax r0 r1 c0 c1 q
  ip netns list 2>/dev/null | grep -qw "${NS}" \
    || die "The netns ${NS} does not exist. You deleted the lab; run cleanup + break again."
  ip link show "${HOST_IF}" >/dev/null 2>&1 || die "${HOST_IF} does not exist. The lab was destroyed."
  curl -s -o /dev/null --max-time 5 "$URL" \
    || { bad "The backend does not respond at ${URL}. The fix cannot take the service down."; exit 1; }

  echo "${BOLD}Checking the client -> backend path${RESET}"
  q=$(tc qdisc show dev "${HOST_IF}")
  if grep -Eq 'netem|tbf' <<<"$q"; then
    bad "An impairment qdisc is still on the node-side egress: ${q}"
    fails=$((fails + 1))
  else
    ok "Node-side egress with no impairment (${q%% refcnt*})"
  fi

  echo "${BOLD}Checking the backend -> client path${RESET}"
  q=$(ip netns exec "${NS}" tc qdisc show dev "${NS_IF}")
  if grep -Eq 'netem|tbf' <<<"$q"; then
    bad "Something is still degrading the backend -> client path."
    fails=$((fails + 1))
  else
    ok "Pod-side egress with no impairment (${q%% refcnt*})"
  fi

  echo "${BOLD}Measuring (about 15 seconds)...${RESET}"
  r0=$(ns_counter TcpRetransSegs)
  c0=$(( $(ns_counter TcpInCsumErrors) + $(ns_counter IpInHdrErrors) + $(ns_counter IpExtInCsumErrors) ))
  p=$(ping_stats 30)
  loss=${p%% *}
  avg=${p##* }
  d=$(download_n 20)
  dfail=$(awk '{print $1}' <<<"$d")
  dmax=$(awk '{print $2}' <<<"$d")
  r1=$(ns_counter TcpRetransSegs)
  c1=$(( $(ns_counter TcpInCsumErrors) + $(ns_counter IpInHdrErrors) + $(ns_counter IpExtInCsumErrors) ))

  if awk -v l="$loss" 'BEGIN {exit !(l + 0 == 0)}'; then
    ok "ICMP loss 0%"
  else
    bad "ICMP loss ${loss}%"; fails=$((fails + 1))
  fi
  if [[ "$avg" != "NA" ]] && awk -v a="$avg" 'BEGIN {exit !(a + 0 < 5)}'; then
    ok "Average RTT ${avg} ms (< 5 ms)"
  else
    bad "Average RTT ${avg} ms (expected < 5 ms on a local veth)"; fails=$((fails + 1))
  fi
  if [[ "$dfail" -eq 0 ]] && awk -v m="$dmax" 'BEGIN {exit !(m + 0 < 0.5)}'; then
    ok "20/20 downloads OK, max ${dmax}s"
  else
    bad "Downloads: ${dfail} failed, max ${dmax}s (expected 0 failures and < 0.5s)"; fails=$((fails + 1))
  fi
  if (( r1 - r0 <= 2 )); then
    ok "Backend TCP retransmissions during the test: $((r1 - r0))"
  else
    bad "Backend TCP retransmissions during the test: $((r1 - r0))"; fails=$((fails + 1))
  fi
  if (( c1 - c0 == 0 )); then
    ok "Checksum/header errors received by the backend: 0"
  else
    bad "Checksum/header errors received by the backend: $((c1 - c0))"; fails=$((fails + 1))
  fi

  echo
  if (( fails == 0 )); then
    echo "${GREEN}${BOLD}LAB PASSED.${RESET} Now explain which metric proved each fault."
  else
    echo "${RED}${BOLD}${fails} check(s) failed.${RESET} Keep investigating."
    exit 1
  fi
}

do_break() {
  require_root
  preflight
  trap 'warn "The build failed; rolling back."; cleanup' ERR
  mkdir -p "${STATE_DIR}"
  build_topology
  start_backend
  record_baseline
  inject_faults
  start_probe
  trap - ERR
  mission_brief
}

case "${1:-}" in
  break)   do_break ;;
  status)  require_root; status ;;
  verify)  require_root; verify ;;
  cleanup) require_root; cleanup ;;
  *)
    echo "Usage: sudo $0 {break|status|verify|cleanup}"
    exit 2
    ;;
esac

exit 0

# =============================================================================
# SOLUTION (don't read it until you've tried)
# =============================================================================
#
# ---- Step 0: quantify the symptom (golden signals) -------------------------
#
#   sudo ./ckne-5.1-break-fix.sh status
#     availability: 93.3% (56/60)
#     latency p50: 1.180s  p95: 3.900s  max: 5.004s
#
#   Compare it with the baseline (~0.005s per download, RTT ~0.05 ms). Latency
#   and errors are up; the service is "up" but unhealthy. That rules out
#   "the link is down" and points at loss or latency on the path.
#
# ---- Step 1: the interface counters lie by omission ------------------------
#
#   ip -s link show ckne-h0
#     RX:  bytes packets errors dropped  missed   mcast
#       ...          0       0       0
#     TX:  bytes packets errors dropped carrier collsns
#       ...          0       0       0
#
#   Zero errors and zero drops. Reason: netem drops packets INSIDE the qdisc,
#   before the driver. Those drops are counted in the qdisc statistics, not in
#   the device's tx_dropped. In Prometheus this means
#   node_network_transmit_drop_total will NOT show it; you need the qdisc
#   (node_exporter's qdisc collector, disabled by default) or node_netstat
#   counters.
#
# ---- Step 2: qdiscs on the node side ---------------------------------------
#
#   tc -s qdisc show dev ckne-h0
#     qdisc netem 8002: root refcnt 2 limit 1000 corrupt 3%
#      Sent 912345 bytes 8123 pkt (dropped 0, overlimits 0 requeues 0)
#
#   FAULT #1 FOUND: netem corrupt 3% on the node egress (client -> backend).
#   Note "dropped 0": corruption does not drop at the sender. The damage is
#   counted by the RECEIVER, in its own network stack.
#
# ---- Step 3: the counters live in the right netns --------------------------
#
#   A common mistake: running nstat on the host and seeing nothing unusual.
#   /proc/net/snmp and /proc/net/netstat are PER NETWORK NAMESPACE. The
#   backend (the one sending the 256 KiB and therefore retransmitting) has
#   its counters inside the netns:
#
#   # nstat stores its history in /tmp/.nstat.u<uid>; use a separate history
#   # file per netns so the deltas don't get mixed up
#   export NSTAT_HISTORY=/tmp/nstat.ckne-ns
#   ip netns exec ckne-metrics-lab nstat -n          # reset the baseline
#   sleep 20                                        # let the probe generate traffic
#   ip netns exec ckne-metrics-lab nstat | grep -E 'Retrans|CsumErrors|HdrErrors|Lost|Timeout|SACK'
#     IpInHdrErrors                   3        0.0
#     IpExtInCsumErrors               3        0.0
#     TcpRetransSegs                  412      0.0
#     TcpInCsumErrors                 9        0.0
#     TcpExtTCPLostRetransmit         17       0.0
#     TcpExtTCPTimeouts               6        0.0
#     TcpExtTCPSACKReorder            21       0.0
#
#   (The exact numbers vary.) Interpretation:
#   - *CsumErrors / IpInHdrErrors: the backend receives corrupted packets.
#     This confirms fault #1 from the receiver side. Some corrupted frames get
#     the bit flipped in the Ethernet header and are dropped silently; this
#     metric is a lower bound.
#   - TcpRetransSegs very high and TCPTimeouts > 0: the backend's OWN sent
#     segments are getting lost. Corruption in the client->backend direction
#     explains lost ACKs, but not this volume. There is something else on the
#     backend -> client path.
#   - TCPSACKReorder: reordering, a classic sign of jitter.
#
#   Useful ratio (the same thing you would use in PromQL):
#     retransmission rate = TcpRetransSegs / TcpOutSegs
#   Healthy on a LAN: < 0.1%. Here you'll see several percent.
#
# ---- Step 4: per-socket view (ss) ------------------------------------------
#
#   While a download is in flight:
#   ip netns exec ckne-metrics-lab ss -tin sport = :8080
#     ESTAB 0 101352 10.231.0.2:8080 10.231.0.1:49812
#      cubic wscale:7,7 rto:412 rtt:103.5/21.7 ... cwnd:4 ssthresh:7
#      ... retrans:1/9 lost:1 ... reordering:5
#
#   rtt:103.5ms on a veth that doesn't leave the machine (baseline < 0.1 ms)
#   and a cwnd collapsed to single digits. Latency AND loss on the
#   backend -> client path.
#
# ---- Step 5: the qdisc the host can't see ----------------------------------
#
#   tc qdisc show                       # on the host: ckne-n0 does not appear
#   ip netns exec ckne-metrics-lab tc -s qdisc show dev ckne-n0
#     qdisc netem 8001: root refcnt 2 limit 1000 delay 80ms  25ms loss 6%
#      Sent 2345678 bytes 2100 pkt (dropped 131, overlimits 0 requeues 0)
#
#   FAULT #2 FOUND: netem on the egress INSIDE the netns (the "Pod eth0").
#   Here "dropped" does count: loss 6% is dropped in the qdisc.
#   The 25ms jitter explains the reordering (TCPSACKReorder).
#
# ---- Step 6: fix it ---------------------------------------------------------
#
#   tc qdisc del dev ckne-h0 root
#   ip netns exec ckne-metrics-lab tc qdisc del dev ckne-n0 root
#
#   Deleting the root qdisc on a veth restores the default "noqueue":
#   tc qdisc show dev ckne-h0
#     qdisc noqueue 0: root refcnt 2
#
#   If you only fix one of the two, verify still fails: with only fault #1
#   fixed, RTT stays around 80 ms; with only fault #2 fixed, the backend keeps
#   receiving corrupted packets and retransmitting.
#
# ---- Step 7: check ----------------------------------------------------------
#
#   sudo ./ckne-5.1-break-fix.sh verify
#     [PASS] Node-side egress with no impairment
#     [PASS] Pod-side egress with no impairment
#     [PASS] ICMP loss 0%
#     [PASS] Average RTT 0.048 ms (< 5 ms)
#     [PASS] 20/20 downloads OK, max 0.012s
#     [PASS] Backend TCP retransmissions during the test: 0
#     [PASS] Checksum/header errors received by the backend: 0
#     LAB PASSED.
#
#   sudo ./ckne-5.1-break-fix.sh cleanup
#
# ---- How it maps to a Kubernetes cluster -----------------------------------
#
#   - Each Pod is a netns. Node-level node_exporter reads the counters of the
#     HOST netns: node_netstat_Tcp_RetransSegs does NOT include retransmissions
#     from Pods with their own netns. To look inside a Pod:
#       PID=$(crictl inspect --output go-template \
#             --template '{{.info.pid}}' <container-id>)
#       nsenter -t "$PID" -n nstat -az TcpRetransSegs
#       nsenter -t "$PID" -n tc -s qdisc
#       nsenter -t "$PID" -n ss -tin
#     or an ephemeral container: kubectl debug -it <pod> --image=nicolaka/netshoot
#   - The kubelet (cAdvisor) exposes per-Pod interface counters:
#       container_network_receive_packets_dropped_total
#       container_network_transmit_packets_dropped_total
#       container_network_receive_errors_total
#     They have the same blind spot as ip -s link: drops inside a netem/tbf
#     qdisc are NOT counted there.
#   - Useful PromQL on the node (host netns):
#       rate(node_netstat_Tcp_RetransSegs[5m])
#         / rate(node_netstat_Tcp_OutSegs[5m])
#     InCsumErrors is not in node_exporter's --collector.netstat.fields regex
#     by default; you have to extend it to see it.
#   - With Cilium, the drop reason is observed in the datapath:
#       cilium_drop_count_total{reason="..."} and, with Hubble enabled,
#       hubble_drop_total and hubble_tcp_flags_total (a rise in RST/SYN
#       retries). A netem qdisc does not go through Cilium's eBPF drop
#       accounting either: always cross-check with tc -s qdisc.
#   - Real-world equivalents of this lab: the bandwidth CNI plugin (tbf on the
#     host veth + ifb for ingress), a NIC with a broken checksum offload
#     (InCsumErrors), or MTU/encapsulation problems on the overlay
#     (retransmissions with no drops on the interface).
#
# ---- Takeaways ---------------------------------------------------------------
#   1. "Interface UP and 0 errors" != "healthy network". Drops can live in
#      the qdisc, and corruption shows up only at the receiver.
#   2. TCP/IP counters are per netns: measure from the stack that sends
#      (retransmissions) AND from the one that receives (checksum errors).
#   3. Correlate the four sources: tc -s qdisc (where it drops), nstat (what
#      the stack sees), ss -ti (effect per connection: rtt, cwnd, retrans),
#      and blackbox probing (effect on the SLO).
# =============================================================================