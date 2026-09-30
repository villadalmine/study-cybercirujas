#!/usr/bin/env bash
# =============================================================================
# CKNE lab 5.2: Troubleshooting End-to-End Network Performance with Tracing
# Break & Fix scenario: "The API is slow and large downloads hang"
# =============================================================================
#
# RUN THIS ONLY ON A DISPOSABLE LAB VM. It needs root.
#
# Safety: all the work happens inside three dedicated network namespaces
# (ckne-client, ckne-gw, ckne-backend) plus the directory /run/ckne-lab. It does
# not change the host's interfaces, routes, firewall or sysctls. The
# "cleanup" subcommand removes everything, and so does a reboot, because
# /run is tmpfs and network namespaces do not survive a reboot.
#
# Topology (it maps onto a Kubernetes datapath):
#
#   ckne-client            ckne-gw (router)              ckne-backend
#   "client pod"           "node / CNI hop"              "service pod"
#   10.52.1.2  veth-cl <-> veth-gc 10.52.1.1
#                          veth-gb 10.52.2.1 <-> veth-be 10.52.2.2 :8080
#
# The backend is a small HTTP service. It reads the W3C `traceparent` header,
# writes one JSON "server span" per request to /run/ckne-lab/backend.log and
# returns a `Server-Timing` header. The helper /run/ckne-lab/bin/ckne-trace
# sends one traced request from the client and shows the client-side timing
# next to the server span for the same trace_id. Putting those two side by
# side is the core technique of this topic.
#
# Usage:
#   sudo ./ckne-5.2-break-fix.sh            # setup + break (default)
#   sudo ./ckne-5.2-break-fix.sh setup      # healthy topology only (baseline)
#   sudo ./ckne-5.2-break-fix.sh break      # inject the faults (after setup)
#   sudo ./ckne-5.2-break-fix.sh status     # show topology and health
#   sudo ./ckne-5.2-break-fix.sh verify     # check whether you fixed it
#   sudo ./ckne-5.2-break-fix.sh cleanup    # remove everything
#
# References:
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://www.w3.org/TR/trace-context/                   (traceparent format)
#   https://www.w3.org/TR/server-timing/                   (Server-Timing header)
#   https://man7.org/linux/man-pages/man8/tc-netem.8.html  (netem)
#   https://www.rfc-editor.org/rfc/rfc1191                 (Path MTU Discovery)
#   https://www.rfc-editor.org/rfc/rfc4821                 (PLPMTUD / black holes)
#   https://docs.kernel.org/networking/ip-sysctl.html      (tcp_mtu_probing)
#   https://wiki.nftables.org/wiki-nftables/index.php/Mangling_packet_headers
# =============================================================================

set -euo pipefail

readonly LAB_DIR="/run/ckne-lab"
readonly NS_C="ckne-client"
readonly NS_G="ckne-gw"
readonly NS_B="ckne-backend"
readonly BACKEND_IP="10.52.2.2"
readonly BACKEND_PORT="8080"
readonly LARGE_BYTES=262144

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

nsx() { local ns="$1"; shift; ip netns exec "$ns" "$@"; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run as root (sudo). Use a disposable lab VM."
}

require_tools() {
  local missing=() t
  for t in ip tc nft python3 curl od awk sysctl grep; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    die "Missing tools: ${missing[*]} (Debian/Ubuntu: apt install iproute2 nftables python3 curl procps; Fedora: dnf install iproute iproute-tc nftables python3 curl procps-ng)"
  fi
  for t in tcpdump ss nstat tracepath mtr; do
    command -v "$t" >/dev/null 2>&1 || warn "Optional diagnostic tool not found: $t (recommended for this lab)"
  done
}

ns_exists() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

cleanup() {
  local ns
  for ns in "$NS_C" "$NS_G" "$NS_B"; do
    if ns_exists "$ns"; then
      ip netns pids "$ns" 2>/dev/null | xargs -r kill 2>/dev/null || true
      sleep 0.2
      ip netns pids "$ns" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
      ip netns del "$ns"
    fi
  done
  rm -rf "$LAB_DIR"
}

write_backend() {
  cat >"$LAB_DIR/backend.py" <<'PY'
#!/usr/bin/env python3
"""Lab backend: one JSON server span per request, W3C traceparent aware."""
import json
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LARGE = b"x" * 262144
SMALL = b"ok\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 15  # socket timeout, so a stalled client cannot pin a thread forever

    def do_GET(self):
        t0 = time.monotonic()
        parts = self.headers.get("traceparent", "").split("-")
        if len(parts) == 4 and len(parts[1]) == 32 and len(parts[2]) == 16:
            trace_id, parent_id = parts[1], parts[2]
        else:
            trace_id, parent_id = secrets.token_hex(16), None
        span_id = secrets.token_hex(8)

        if self.path.startswith("/large"):
            body = LARGE
        elif self.path.startswith("/small"):
            body = SMALL
        else:
            self.send_error(404)
            return

        time.sleep(0.005)  # simulated business logic: ~5 ms
        app_ms = (time.monotonic() - t0) * 1000

        status = "ok"
        t1 = time.monotonic()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Server-Timing", f"app;dur={app_ms:.1f}")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
        except OSError as exc:
            status = f"write_error:{exc.__class__.__name__}"
            self.close_connection = True
        write_ms = (time.monotonic() - t1) * 1000

        print(json.dumps({
            "ts": round(time.time(), 3),
            "name": f"GET {self.path}",
            "trace_id": trace_id,
            "parent_span_id": parent_id,
            "span_id": span_id,
            "peer": self.client_address[0],
            "app_ms": round(app_ms, 1),
            "write_ms": round(write_ms, 1),
            "bytes": len(body),
            "status": status,
        }), flush=True)

    def log_message(self, fmt, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY
}

write_trace_helper() {
  cat >"$LAB_DIR/bin/ckne-trace" <<'SH'
#!/usr/bin/env bash
# ckne-trace [/small|/large]: one traced request from the client namespace,
# with the client-side timing shown next to the server span for the same trace_id.
set -uo pipefail
path="${1:-/small}"
trace_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
span_id=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
tp="00-${trace_id}-${span_id}-01"
hdrs=$(mktemp)
echo "traceparent : ${tp}"
ip netns exec ckne-client curl -s -o /dev/null -D "${hdrs}" --max-time 10 \
  -H "traceparent: ${tp}" \
  -w 'client span : connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s bytes=%{size_download} http=%{http_code}\n' \
  "http://10.52.2.2:8080${path}"
rc=$?
echo "curl exit   : ${rc}$( [[ ${rc} -eq 28 ]] && echo ' (timeout)')"
grep -i '^server-timing' "${hdrs}" | tr -d '\r' | sed 's/^/server hdr  : /'
rm -f "${hdrs}"
sleep 0.3
echo "server span :"
grep "${trace_id}" /run/ckne-lab/backend.log || echo "  (no server span logged for this trace_id yet)"
SH
  chmod 0755 "$LAB_DIR/bin/ckne-trace"
}

setup() {
  log "Removing any previous lab state..."
  cleanup
  mkdir -p "$LAB_DIR/bin"

  log "Creating namespaces and veth pairs..."
  local ns
  for ns in "$NS_C" "$NS_G" "$NS_B"; do
    ip netns add "$ns"
    nsx "$ns" ip link set lo up
  done

  ip link add veth-cl netns "$NS_C" type veth peer name veth-gc netns "$NS_G"
  ip link add veth-gb netns "$NS_G" type veth peer name veth-be netns "$NS_B"

  nsx "$NS_C" ip addr add 10.52.1.2/24 dev veth-cl
  nsx "$NS_G" ip addr add 10.52.1.1/24 dev veth-gc
  nsx "$NS_G" ip addr add 10.52.2.1/24 dev veth-gb
  nsx "$NS_B" ip addr add 10.52.2.2/24 dev veth-be

  nsx "$NS_C" ip link set veth-cl up
  nsx "$NS_G" ip link set veth-gc up
  nsx "$NS_G" ip link set veth-gb up
  nsx "$NS_B" ip link set veth-be up

  nsx "$NS_C" ip route add default via 10.52.1.1
  nsx "$NS_B" ip route add default via 10.52.2.1
  nsx "$NS_G" sysctl -qw net.ipv4.ip_forward=1
  # Default kernel behaviour, set explicitly so the lab is deterministic:
  # no TCP black-hole probing, so the sender relies on classic PMTUD (RFC 1191).
  nsx "$NS_B" sysctl -qw net.ipv4.tcp_mtu_probing=0

  log "Starting the backend service in ${NS_B}..."
  write_backend
  write_trace_helper
  : >"$LAB_DIR/backend.log"
  nsx "$NS_B" python3 -u "$LAB_DIR/backend.py" >>"$LAB_DIR/backend.log" 2>&1 </dev/null &
  disown || true

  local i
  for i in $(seq 1 50); do
    if nsx "$NS_C" curl -s -o /dev/null --max-time 1 "http://${BACKEND_IP}:${BACKEND_PORT}/small"; then
      ok "Healthy baseline is up (backend answers at ${BACKEND_IP}:${BACKEND_PORT})."
      return 0
    fi
    sleep 0.1
  done
  die "The backend did not come up. Check $LAB_DIR/backend.log"
}

break_it() {
  ns_exists "$NS_G" || die "Run 'setup' first."
  log "Injecting faults..."

  # Fault 1: artificial latency on the gw -> backend leg only (one direction).
  nsx "$NS_G" tc qdisc replace dev veth-gb root netem delay 150ms

  # Fault 2: PMTUD black hole. The client-facing egress MTU on the router is
  # lower than the endpoints believe, and the ICMP "fragmentation needed"
  # messages that would tell the sender are silently dropped.
  nsx "$NS_G" ip link set dev veth-gc mtu 1280
  nsx "$NS_G" nft -f - <<'NFT'
table ip ckne_lab {
  chain output {
    type filter hook output priority 0; policy accept;
    icmp type destination-unreachable icmp code frag-needed drop comment "hardening-baseline-v2"
  }
}
NFT

  : >"$LAB_DIR/backend.log"
  touch "$LAB_DIR/broken"
  banner
}

banner() {
  cat <<EOF

=============================================================================
 INCIDENT TICKET  #CKNE-5.2
=============================================================================
 Service  : catalog API at http://${BACKEND_IP}:${BACKEND_PORT} (runs in ${NS_B})
 Clients  : ${NS_C}, routed through ${NS_G}

 SYMPTOMS YOU WILL SEE
  1. Every request to /small takes roughly 300 ms end to end. It used to take
     under 10 ms. The application team shows you their traces: the server
     span (app_ms) is ~5 ms. "It's not the app, it's the network."
  2. /small (3 bytes) always completes, but /large (256 KiB) hangs until the
     client times out. Headers arrive; the body does not. The server span
     for /large often says status "ok" anyway.

 YOUR MISSION
  - Use tracing to prove where the time goes: correlate the client span with
    the server span for the same trace_id, then localize the loss hop by hop.
  - Find BOTH root causes in the network path and fix them.
  - Rules: do not restart or modify the backend app, do not delete the
    namespaces, do not re-run 'setup'. Fix the network.

 TOOLS
  - Traced request : $LAB_DIR/bin/ckne-trace /small   (or /large)
  - Server spans   : tail -f $LAB_DIR/backend.log
  - Run commands in a namespace: ip netns exec <ns> <cmd>
    e.g. ip netns exec ${NS_C} ping -c3 ${BACKEND_IP}
  - Useful: ping, tracepath, mtr, ss -tin, nstat, tcpdump, tc, ip link, nft

 DONE WHEN
  sudo $0 verify   reports all checks OK:
   * /small completes in < 80 ms, 3 times in a row
   * /large (${LARGE_BYTES} bytes) completes in < 5 s, 3 times in a row
=============================================================================

EOF
}

status() {
  local ns
  for ns in "$NS_C" "$NS_G" "$NS_B"; do
    if ns_exists "$ns"; then
      echo "--- ${ns}"
      nsx "$ns" ip -br addr show | grep -v '^lo'
      nsx "$ns" ip -o link show | awk '$2 != "lo:" {for (i=1;i<=NF;i++) if ($i=="mtu") print "    " $2 " mtu " $(i+1)}'
    else
      echo "--- ${ns}: missing (run setup)"
    fi
  done
  if ns_exists "$NS_B"; then
    if [[ -n "$(ip netns pids "$NS_B" 2>/dev/null)" ]]; then ok "backend process running"; else bad "backend process NOT running"; fi
  fi
}

verify() {
  ns_exists "$NS_C" && ns_exists "$NS_G" && ns_exists "$NS_B" || die "Lab namespaces missing. Run setup (and break)."
  local fail=0 i t out size rc

  if [[ -n "$(ip netns pids "$NS_B" 2>/dev/null)" ]]; then
    ok "Backend process is running."
  else
    bad "Backend process is not running (you were not supposed to touch it)."
    fail=1
  fi

  for i in 1 2 3; do
    t=$(nsx "$NS_C" curl -s -o /dev/null --max-time 3 -w '%{time_total}' \
        "http://${BACKEND_IP}:${BACKEND_PORT}/small") || t="99"
    if awk -v t="$t" 'BEGIN { exit !(t < 0.080) }'; then
      ok "/small attempt ${i}: ${t}s"
    else
      bad "/small attempt ${i}: ${t}s (expected < 0.080s)"
      fail=1
    fi
  done

  for i in 1 2 3; do
    rc=0
    out=$(nsx "$NS_C" curl -s -o /dev/null --max-time 5 -w '%{size_download} %{time_total}' \
          "http://${BACKEND_IP}:${BACKEND_PORT}/large") || rc=$?
    size="${out%% *}"
    if [[ ${rc} -eq 0 && "${size}" == "${LARGE_BYTES}" ]]; then
      ok "/large attempt ${i}: ${size} bytes in ${out##* }s"
    else
      bad "/large attempt ${i}: curl exit ${rc}, got '${size:-0}' of ${LARGE_BYTES} bytes"
      fail=1
    fi
  done

  # Hygiene checks: reported, but they do not fail the lab.
  local mtu_gc mtu_cl
  mtu_gc=$(nsx "$NS_G" cat /sys/class/net/veth-gc/mtu)
  mtu_cl=$(nsx "$NS_C" cat /sys/class/net/veth-cl/mtu)
  if [[ "$mtu_gc" != "$mtu_cl" ]]; then
    warn "MTU mismatch on the client link: veth-gc=${mtu_gc} vs veth-cl=${mtu_cl}. It works now, but only thanks to PMTUD/MSS; a consistent MTU is the real fix."
  fi
  if nsx "$NS_G" nft list table ip ckne_lab >/dev/null 2>&1 && \
     nsx "$NS_G" nft list table ip ckne_lab | grep -q 'frag-needed drop'; then
    warn "ICMP frag-needed is still dropped on ${NS_G}. Never filter ICMP type 3 code 4: it silently breaks PMTUD."
  fi
  if nsx "$NS_G" tc qdisc show dev veth-gb | grep -q netem; then
    warn "A netem qdisc is still attached to veth-gb."
  fi

  echo
  if ((fail == 0)); then
    ok "All checks passed. Incident resolved."
  else
    bad "Not fixed yet. Keep tracing."
    return 1
  fi
}

main() {
  require_root
  local cmd="${1:-all}"
  case "$cmd" in
    all)     require_tools; setup; break_it ;;
    setup)   require_tools; setup ;;
    break)   require_tools; break_it ;;
    status)  status ;;
    verify)  verify ;;
    cleanup) cleanup; ok "Lab removed." ;;
    *)       die "Unknown command '$cmd'. Use: setup | break | status | verify | cleanup" ;;
  esac
}

main "$@"

# =============================================================================
# SOLUTION (spoilers: try it yourself first)
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 1: Reproduce and correlate the client span with the server span
# ---------------------------------------------------------------------------
#   /run/ckne-lab/bin/ckne-trace /small
#
#   Expected (approximately):
#     traceparent : 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
#     client span : connect=0.151s ttfb=0.303s total=0.303s bytes=3 http=200
#     curl exit   : 0
#     server hdr  : Server-Timing: app;dur=5.1
#     server span :
#     {"ts": ..., "name": "GET /small", "trace_id": "4bf92f35...", "app_ms": 5.1, ...}
#
#   How to read it:
#   - total (303 ms) minus app_ms (5 ms) is ~298 ms spent outside the app.
#   - connect=0.151s: the TCP handshake alone takes ~150 ms. The SYN is slow.
#   - ttfb - connect = ~150 ms more: the request travels client->server and
#     is slow again. Two slow one-way trips, both client->backend. The
#     response direction adds nothing measurable.
#   - Hypothesis: a one-way delay of ~150 ms somewhere on the path from the
#     client to the backend.
#
#   The same reasoning applies in Kubernetes with OpenTelemetry: when
#   (client span duration) >> (server span duration) for one trace_id, the
#   gap is network, proxy queueing or connection setup, not code.
#
# ---------------------------------------------------------------------------
# STEP 2: Localize hop by hop
# ---------------------------------------------------------------------------
#   ip netns exec ckne-client ping -c3 10.52.1.1    # near side of gw
#     rtt min/avg/max/mdev = 0.040/0.050/0.061/0.008 ms
#   ip netns exec ckne-client ping -c3 10.52.2.1    # far side of gw (gw answers itself)
#     rtt min/avg/max/mdev = 0.041/0.052/0.066/0.010 ms
#   ip netns exec ckne-client ping -c3 10.52.2.2    # the backend
#     rtt min/avg/max/mdev = 150.1/150.2/150.3/0.08 ms
#
#   Optional: ip netns exec ckne-client mtr -n -c 10 -r 10.52.2.2
#     1.|-- 10.52.1.1   0.0%  10   0.1   0.1 ...
#     2.|-- 10.52.2.2   0.0%  10 150.2 150.2 ...
#
#   Conclusion: the gw itself is fast. The latency sits on the gw <-> backend
#   link, so look at veth-gb (gw egress) and veth-be.
#
# ---------------------------------------------------------------------------
# STEP 3: Inspect the queueing discipline on the suspect interface
# ---------------------------------------------------------------------------
#   ip netns exec ckne-gw tc -s qdisc show dev veth-gb
#     qdisc netem 8001: root refcnt 2 limit 1000 delay 150ms
#      Sent 18230 bytes 160 pkt (dropped 0, overlimits 0 requeues 0)
#
#   netem is an emulator; it has no place on a production path. In real life
#   the equivalent is a forgotten shaping/policing rule, a bandwidth
#   annotation on a CNI (for example kubernetes.io/egress-bandwidth), or a
#   congested uplink. `tc -s` counters tell you whether traffic really goes
#   through it.
#
#   Fix 1:
#   ip netns exec ckne-gw tc qdisc del dev veth-gb root
#
#   Re-test:
#   /run/ckne-lab/bin/ckne-trace /small
#     client span : connect=0.000s ttfb=0.007s total=0.007s bytes=3 http=200
#
# ---------------------------------------------------------------------------
# STEP 4: Second symptom, large responses stall
# ---------------------------------------------------------------------------
#   /run/ckne-lab/bin/ckne-trace /large
#     client span : connect=0.000s ttfb=0.006s total=10.001s bytes=0 http=200
#     curl exit   : 28 (timeout)
#     server span : {"name": "GET /large", "app_ms": 5.1, "write_ms": 0.3, "status": "ok", ...}
#
#   Key trace lesson: the server span says "ok" with write_ms ~0 because
#   write() only copies 256 KiB into the kernel socket buffer. The app has
#   no way to know those bytes never reached the client. Server-side spans
#   cannot see transport-level loss, so you have to go below L7.
#
#   Signature: ttfb is fast (small packets get through), the body never
#   arrives (full-size packets do not). Small works and big hangs is the
#   classic MTU / PMTUD black hole.
#
# ---------------------------------------------------------------------------
# STEP 5: Confirm from the TCP sender's point of view
# ---------------------------------------------------------------------------
#   ip netns exec ckne-client curl -s -o /dev/null --max-time 20 http://10.52.2.2:8080/large &
#   sleep 3
#   ip netns exec ckne-backend ss -tin dst 10.52.1.2
#     ESTAB 0 245760 10.52.2.2:8080 10.52.1.2:41234
#       cubic rto:3200 backoff:4 mss:1448 pmtu:1500 ... unacked:10 retrans:1/5 lost:10 ...
#   ip netns exec ckne-backend nstat -az TcpRetransSegs
#     TcpRetransSegs   42   0.0      <- keeps rising
#
#   A growing send queue, exponential backoff, retransmissions and pmtu:1500
#   all mean the sender still believes 1500 bytes fits the path.
#
# ---------------------------------------------------------------------------
# STEP 6: Packet capture on both sides of the router
# ---------------------------------------------------------------------------
#   ip netns exec ckne-gw tcpdump -ni veth-gb 'tcp port 8080 or icmp'
#     IP 10.52.2.2.8080 > 10.52.1.2.41234: Flags [.], seq 1:1449, ack 1, length 1448
#     IP 10.52.2.2.8080 > 10.52.1.2.41234: Flags [.], seq 1:1449, ack 1, length 1448   <- retransmission
#     (no ICMP back toward 10.52.2.2 at all)
#
#   ip netns exec ckne-gw tcpdump -ni veth-gc 'tcp port 8080'
#     (the length-1448 segments NEVER appear on the client-facing interface)
#
#   The packets enter the router and do not come out. With DF set, a router
#   that cannot forward a packet must reply with ICMP type 3 code 4
#   (fragmentation needed, carrying the next-hop MTU; RFC 1191). No ICMP
#   is leaving, so something is suppressing it.
#
# ---------------------------------------------------------------------------
# STEP 7: Find both halves of the black hole
# ---------------------------------------------------------------------------
#   ip netns exec ckne-gw ip -d link show veth-gc | grep -o 'mtu [0-9]*'
#     mtu 1280
#   ip netns exec ckne-client ip link show veth-cl | grep -o 'mtu [0-9]*'
#     mtu 1500          <- mismatch: the client advertised MSS 1460 in its SYN
#
#   ip netns exec ckne-gw nft list ruleset
#     table ip ckne_lab {
#       chain output {
#         type filter hook output priority filter; policy accept;
#         icmp type destination-unreachable icmp code frag-needed drop comment "hardening-baseline-v2"
#       }
#     }
#
#   Root cause 2 = an MTU mismatch (common in Kubernetes: VXLAN overlays cost
#   50 bytes, Geneve ~50+, WireGuard 60-80, IPsec more) PLUS "hardening" that
#   drops ICMP. Each alone is survivable; together they black-hole every
#   full-size packet.
#
# ---------------------------------------------------------------------------
# STEP 8: Fix it
# ---------------------------------------------------------------------------
#   Proper fix, make the MTU consistent on the link:
#     ip netns exec ckne-gw ip link set dev veth-gc mtu 1500
#
#   Fix the filter too (never drop ICMP frag-needed / ICMPv6 Packet Too Big):
#     ip netns exec ckne-gw nft delete table ip ckne_lab
#
#   Drop any stale PMTU exceptions the sender may have cached:
#     ip netns exec ckne-backend ip route flush cache
#
#   Alternatives when the MTU really must stay lower (e.g. an overlay):
#   a) Let PMTUD work (allow ICMP type 3 code 4). The sender learns 1280 and
#      caches it: `ip netns exec ckne-backend ip route get 10.52.1.2` then
#      shows "mtu 1280" in the route cache.
#   b) Clamp the TCP MSS to the route MTU on the router (TCP only):
#        ip netns exec ckne-gw nft add table ip mss
#        ip netns exec ckne-gw nft add chain ip mss fwd '{ type filter hook forward priority mangle; }'
#        ip netns exec ckne-gw nft add rule ip mss fwd tcp flags syn tcp option maxseg size set rt mtu
#   c) Enable black-hole detection on the endpoints (RFC 4821):
#        sysctl net.ipv4.tcp_mtu_probing=1
#   In Kubernetes, set the pod/veth MTU in the CNI to match the underlay minus
#   the encapsulation overhead (for example Calico `veth_mtu`, Cilium `mtu`,
#   Flannel derives it from the VXLAN device) and do not filter ICMP between
#   nodes.
#
# ---------------------------------------------------------------------------
# STEP 9: Verify
# ---------------------------------------------------------------------------
#   /run/ckne-lab/bin/ckne-trace /large
#     client span : connect=0.000s ttfb=0.006s total=0.008s bytes=262144 http=200
#   sudo ./ckne-5.2-break-fix.sh verify
#     [ OK ] /small attempt 1: 0.006s ...
#     [ OK ] /large attempt 1: 262144 bytes in 0.009s ...
#     [ OK ] All checks passed. Incident resolved.
#
#   Clean up:  sudo ./ckne-5.2-break-fix.sh cleanup
#
# ---------------------------------------------------------------------------
# METHOD TAKEAWAYS (how this maps onto a cluster)
# ---------------------------------------------------------------------------
#   1. Start from traces: propagate `traceparent`, then compare client span
#      against server span for the SAME trace_id. The difference is time
#      outside the application.
#   2. Break the client span into phases (connect / TLS / ttfb / transfer).
#      A slow connect points at the path or SYN handling; a slow transfer
#      with a fast ttfb points at MTU, loss or window problems.
#   3. Localize hop by hop (pod -> node -> remote node -> pod) with ping,
#      mtr or tracepath. In Cilium, `hubble observe --pod <pod> -o json`
#      gives per-flow verdicts and, with L7 visibility enabled, HTTP latency.
#   4. Look at the sender: `ss -tin` (rtt, mss, pmtu, retrans, backoff) and
#      `nstat` counters. Use `kubectl debug node/<node> -it --image=<tools>`
#      or a netshoot ephemeral container to get these tools into a pod netns.
#   5. Capture on both sides of the suspect hop. A packet that goes in and
#      never comes out, with no ICMP in reply, is a black hole.
#   6. Application spans report "ok" when the kernel accepts the bytes, not
#      when the peer receives them. Never close a network incident on L7
#      evidence alone.
# =============================================================================