#!/usr/bin/env bash
# =============================================================================
# CKNE - Topic 1.3: Using Linux Tools (iptables, ip, tcpdump) for Packet-level Issues
# Break & Fix lab: "The server is up, but nobody can reach it"
#
# WHAT THIS SCRIPT DOES
#   Builds a small three-hop network entirely inside Linux network namespaces:
#
#     [bf13-client]                 [bf13-router]                  [bf13-server]
#      eth0 10.10.1.2/24 <--veth--> eth1 10.10.1.1/24
#                                   eth2 10.10.2.1/24 <--veth-->  eth0 10.10.2.2/24
#                                                                  python3 http.server :8080
#
#   It then injects three layered packet-level faults. Each one only becomes
#   visible after you fix the one in front of it, the same way incidents stack
#   up in production. The faults are the same kind you hit on Kubernetes nodes:
#   hidden netfilter rules, bad routes on a host, and PMTU black holes on
#   overlay/tunnel links (VXLAN, Geneve, WireGuard, IPsec).
#
# SAFETY
#   - Everything lives in the network namespaces bf13-client, bf13-router and bf13-server.
#     The host's root namespace, routes and firewall are NOT touched.
#   - Temporary files go only under /tmp/bf13-*.
#   - 'cleanup' deletes the namespaces, stops the HTTP server and removes the files.
#   - Still, run it only on a DISPOSABLE lab VM, never on a production host.
#
# REQUIREMENTS
#   root, iproute2 (ip, ss, nstat), iptables (legacy or nft backend), tcpdump,
#   curl, python3, sha256sum
#
# USAGE
#   sudo ./bf13-packet-level.sh setup [--yes]   # build the lab and break it
#   sudo ./bf13-packet-level.sh check           # check whether you fixed it
#   sudo ./bf13-packet-level.sh brief           # show the scenario again
#   sudo ./bf13-packet-level.sh cleanup         # remove everything
#
# The step-by-step solution is at the END of this file, commented out.
# Try not to read it until you have spent real time with tcpdump.
# =============================================================================

set -Eeuo pipefail

readonly NS_C="bf13-client"
readonly NS_R="bf13-router"
readonly NS_S="bf13-server"
readonly WWW="/tmp/bf13-www"
readonly HTTP_LOG="/tmp/bf13-http.log"
readonly SUM_FILE="/tmp/bf13-big.sha256"
readonly SERVER_IP="10.10.2.2"
readonly PORT="8080"
readonly ROUTER_WAN_MTU="1400"   # simulates a tunnel/provider hop you do not own

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_bld=$'\e[1m'; c_rst=$'\e[0m'
info() { printf '%s[*]%s %s\n' "$c_bld" "$c_rst" "$*"; }
ok()   { printf '%s[PASS]%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "$c_red" "$c_rst" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_ylw" "$c_rst" "$*"; }
die()  { printf '%s[ERROR]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

need_root() {
    [[ ${EUID} -eq 0 ]] || die "Run as root (sudo $0 $*)."
}

need_tools() {
    local missing=() t
    for t in ip ss nstat iptables iptables-save tcpdump curl python3 sha256sum; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    ((${#missing[@]} == 0)) || die "Missing tools: ${missing[*]}"
}

ns_exists() { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

cleanup() {
    local ns pid
    for ns in "$NS_C" "$NS_R" "$NS_S"; do
        if ns_exists "$ns"; then
            for pid in $(ip netns pids "$ns" 2>/dev/null); do
                kill "$pid" 2>/dev/null || true
            done
            ip netns del "$ns" 2>/dev/null || true
        fi
    done
    # Leftover veths in the root namespace if setup died halfway
    for l in bf13c bf13rc bf13s bf13rs; do
        ip link del "$l" 2>/dev/null || true
    done
    rm -rf "$WWW" "$HTTP_LOG" "$SUM_FILE" /tmp/bf13-check-*
}

brief() {
    cat <<EOF

${c_bld}=================== SCENARIO: "The server is up" ===================${c_rst}

A developer reports: "From the client I can't reach the app at
http://${SERVER_IP}:${PORT}/ . The app team says the server is healthy."

${c_bld}Reproduce the symptom:${c_rst}
  sudo ip netns exec ${NS_C} curl -sS --max-time 5 http://${SERVER_IP}:${PORT}/small.txt
  -> hangs, then: "curl: (28) Connection timed out after 5001 milliseconds"

When you get small requests working, also try the large file:
  sudo ip netns exec ${NS_C} curl -sS --max-time 10 -o /dev/null \\
      -w '%{http_code} %{size_download}\\n' http://${SERVER_IP}:${PORT}/big.bin
  -> may fail in a sneakier way.

${c_bld}Your goal:${c_rst}
  1. small.txt and big.bin (2 MB, checksum verified) download correctly
     from ${NS_C}.
  2. ${c_bld}Do NOT change any interface MTU.${c_rst} The router's eth1 (MTU ${ROUTER_WAN_MTU})
     stands in for a tunnel/provider link you do not control.
  3. Do not turn off IP forwarding and do not move the client or server.
  4. Fix the ROOT CAUSE of each fault. Do not just flush everything.

${c_bld}Tools you should use:${c_rst} ip (link/addr/route/neigh), iptables / iptables-save
(ALL tables), tcpdump on each hop, ss, nstat.

${c_bld}Getting into each node:${c_rst}
  sudo ip netns exec ${NS_C} bash      # client
  sudo ip netns exec ${NS_R} bash      # router
  sudo ip netns exec ${NS_S} bash      # server
  or run single commands:  sudo ip -n ${NS_R} route
                           sudo ip netns exec ${NS_R} tcpdump -ni eth1 -c 20

${c_bld}Method:${c_rst} follow the packet hop by hop (client eth0 -> router eth1 ->
router eth2 -> server eth0 -> and back). The fault is at the first point where
the packet you expect does not show up.

Check your progress:   sudo $0 check
Remove the lab:        sudo $0 cleanup
=====================================================================
EOF
}

setup() {
    local assume_yes="${1:-}"
    if [[ "$assume_yes" != "--yes" ]]; then
        echo "This will create network namespaces ${NS_C}, ${NS_R}, ${NS_S} and"
        echo "start an HTTP server inside ${NS_S}. Run it only on a disposable lab VM."
        read -r -p "Continue? [y/N] " ans
        [[ "$ans" =~ ^[yY]$ ]] || die "Aborted."
    fi

    info "Removing any previous run of this lab..."
    cleanup

    trap 'bad "Setup failed at line $LINENO; cleaning up."; cleanup' ERR

    info "Creating namespaces..."
    for ns in "$NS_C" "$NS_R" "$NS_S"; do
        ip netns add "$ns"
        ip -n "$ns" link set lo up
    done

    info "Wiring the veth pairs..."
    ip link add bf13c type veth peer name bf13rc
    ip link set bf13c netns "$NS_C"
    ip link set bf13rc netns "$NS_R"
    ip -n "$NS_C" link set bf13c name eth0
    ip -n "$NS_R" link set bf13rc name eth1

    ip link add bf13s type veth peer name bf13rs
    ip link set bf13s netns "$NS_S"
    ip link set bf13rs netns "$NS_R"
    ip -n "$NS_S" link set bf13s name eth0
    ip -n "$NS_R" link set bf13rs name eth2

    ip -n "$NS_C" addr add 10.10.1.2/24 dev eth0
    ip -n "$NS_R" addr add 10.10.1.1/24 dev eth1
    ip -n "$NS_R" addr add 10.10.2.1/24 dev eth2
    ip -n "$NS_S" addr add 10.10.2.2/24 dev eth0

    # The client-facing router hop is a "tunnel" with a smaller MTU. The client
    # and the server keep 1500, so neither end ever learns about 1400 on its own.
    # That is the normal state of a VXLAN/WireGuard path, and it is not a fault.
    ip -n "$NS_R" link set eth1 mtu "$ROUTER_WAN_MTU"

    ip -n "$NS_C" link set eth0 up
    ip -n "$NS_R" link set eth1 up
    ip -n "$NS_R" link set eth2 up
    ip -n "$NS_S" link set eth0 up

    ip netns exec "$NS_R" sysctl -qw net.ipv4.ip_forward=1

    ip -n "$NS_C" route add default via 10.10.1.1 dev eth0

    # ---------------------------------------------------------------- FAULT A (ip)
    # The server's default gateway points to an address nobody owns.
    ip -n "$NS_S" route add default via 10.10.2.254 dev eth0

    # ------------------------------------------------------ FAULT B (iptables/raw)
    # Drops new TCP connections to :8080 in the raw table, which
    # 'iptables -L' (filter table only) never shows.
    ip netns exec "$NS_R" iptables -t raw -A PREROUTING -i eth1 -p tcp --dport "$PORT" --syn \
        -m comment --comment "conntrack-bypass: legacy app ports" -j DROP

    # ------------------------------------------------ FAULT C (iptables/PMTU hole)
    # A "hardening" rule that drops ICMP Fragmentation Needed generated by
    # the router itself. This breaks Path MTU Discovery.
    ip netns exec "$NS_R" iptables -A OUTPUT -p icmp --icmp-type fragmentation-needed \
        -m comment --comment "hardening: no ICMP info leak" -j DROP

    info "Preparing content and starting the HTTP server in ${NS_S}..."
    mkdir -p "$WWW"
    echo "hello from bf13-server" > "$WWW/small.txt"
    head -c 2000000 /dev/urandom > "$WWW/big.bin"
    (cd "$WWW" && sha256sum big.bin | awk '{print $1}') > "$SUM_FILE"

    ip netns exec "$NS_S" python3 -m http.server "$PORT" --bind "$SERVER_IP" \
        --directory "$WWW" >"$HTTP_LOG" 2>&1 &
    disown || true

    local i
    for i in $(seq 1 50); do
        if ip netns exec "$NS_S" ss -Hltn "sport = :${PORT}" 2>/dev/null | grep -q "$PORT"; then
            break
        fi
        sleep 0.1
    done
    ip netns exec "$NS_S" ss -Hltn "sport = :${PORT}" | grep -q "$PORT" \
        || die "The HTTP server did not start; see $HTTP_LOG"

    trap - ERR
    ok "Lab built. The server really IS up (ss in ${NS_S} shows LISTEN on ${SERVER_IP}:${PORT})."
    brief
}

check() {
    set +e
    for ns in "$NS_C" "$NS_R" "$NS_S"; do
        ns_exists "$ns" || die "Namespace $ns not found. Run: sudo $0 setup"
    done

    local score=0 total=4

    echo
    info "1/4 Constraint: MTUs unchanged"
    local r_mtu c_mtu s_mtu
    r_mtu=$(ip netns exec "$NS_R" cat /sys/class/net/eth1/mtu 2>/dev/null)
    c_mtu=$(ip netns exec "$NS_C" cat /sys/class/net/eth0/mtu 2>/dev/null)
    s_mtu=$(ip netns exec "$NS_S" cat /sys/class/net/eth0/mtu 2>/dev/null)
    if [[ "$r_mtu" == "$ROUTER_WAN_MTU" && "$c_mtu" == "1500" && "$s_mtu" == "1500" ]]; then
        ok "router eth1=${r_mtu}, client eth0=${c_mtu}, server eth0=${s_mtu}"
        score=$((score + 1))
    else
        bad "MTUs were changed (router eth1=${r_mtu}, client=${c_mtu}, server=${s_mtu})."
        bad "In production you cannot change the MTU of a tunnel you do not own. Revert and fix the cause."
    fi

    info "2/4 Forwarding enabled on the router"
    if [[ "$(ip netns exec "$NS_R" sysctl -n net.ipv4.ip_forward)" == "1" ]]; then
        ok "net.ipv4.ip_forward=1"
        score=$((score + 1))
    else
        bad "net.ipv4.ip_forward is not 1 on ${NS_R}"
    fi

    info "3/4 Small download (small.txt)"
    local body
    body=$(ip netns exec "$NS_C" curl -sS --max-time 5 "http://${SERVER_IP}:${PORT}/small.txt" 2>&1)
    if [[ "$body" == "hello from bf13-server" ]]; then
        ok "small.txt received"
        score=$((score + 1))
    else
        bad "small.txt failed: ${body:-<empty>}"
        echo "      Hint: follow the SYN. Where does it stop showing up? Where does the SYN-ACK go?"
    fi

    info "4/4 Large download (big.bin, 2 MB, sha256)"
    local out="/tmp/bf13-check-big.bin" got want
    rm -f "$out"
    ip netns exec "$NS_C" curl -sS --max-time 15 -o "$out" "http://${SERVER_IP}:${PORT}/big.bin" 2>/tmp/bf13-check-err
    got=$(sha256sum "$out" 2>/dev/null | awk '{print $1}')
    want=$(cat "$SUM_FILE" 2>/dev/null)
    if [[ -n "$got" && "$got" == "$want" ]]; then
        ok "big.bin received intact"
        score=$((score + 1))
    else
        bad "big.bin failed or arrived corrupt: $(tr -d '\n' </tmp/bf13-check-err)"
        echo "      Hint: small works and large does not. What size are the segments that never arrive?"
    fi
    rm -f "$out" /tmp/bf13-check-err

    echo
    # Diagnostic notes (these do not affect the score)
    if ip netns exec "$NS_R" iptables-save -t raw 2>/dev/null | grep -q -- "--dport ${PORT}"; then
        warn "There is still a raw-table rule matching :${PORT} on ${NS_R}."
    fi
    if ip netns exec "$NS_R" iptables-save 2>/dev/null | grep -Eq 'icmp-type (3/4|fragmentation-needed)'; then
        if ip netns exec "$NS_R" iptables-save -t mangle 2>/dev/null | grep -q 'TCPMSS'; then
            warn "You fixed it with MSS clamping, which is valid for TCP. The ICMP black hole is still"
            warn "there, though: UDP (DNS over EDNS, QUIC, VXLAN) will still break. Consider removing the DROP as well."
        fi
    fi
    if ! ip -n "$NS_S" route get 10.10.1.2 2>/dev/null | grep -q "via 10.10.2.1"; then
        warn "The server's route back to 10.10.1.2 does not go via 10.10.2.1."
    fi

    echo "Result: ${score}/${total}"
    if ((score == total)); then
        ok "Lab solved. Run 'sudo $0 cleanup' when you are done."
        return 0
    fi
    return 1
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        setup)   need_root "$@"; need_tools; setup "${2:-}" ;;
        check)   need_root "$@"; check ;;
        brief)   brief ;;
        cleanup) need_root "$@"; cleanup; ok "Lab removed." ;;
        *)
            echo "Usage: sudo $0 {setup [--yes]|check|brief|cleanup}"
            exit 2
            ;;
    esac
}

main "$@"

# =============================================================================
# STEP-BY-STEP SOLUTION (spoilers)
# =============================================================================
#
# Method: follow the packet hop by hop with tcpdump. The fault is at the first
# interface where the packet you expect stops appearing. Keep one terminal
# generating traffic:
#
#   sudo ip netns exec bf13-client curl -sS --max-time 5 http://10.10.2.2:8080/small.txt
#
# -----------------------------------------------------------------------------
# FAULT B: SYN dropped in the router's raw table
# -----------------------------------------------------------------------------
# 1) Client: the SYN leaves, gets retransmitted, and nothing comes back.
#      sudo ip netns exec bf13-client tcpdump -ni eth0 tcp port 8080
#      IP 10.10.1.2.43512 > 10.10.2.2.8080: Flags [S], seq 1234, win 64240,
#         options [mss 1460,sackOK,TS val ... ecr 0,nop,wscale 7], length 0
#      IP 10.10.1.2.43512 > 10.10.2.2.8080: Flags [S], seq 1234, ...   <- retransmission (1s, 3s...)
#
# 2) Router ingress (eth1): the SYN DOES arrive.
#      sudo ip netns exec bf13-router tcpdump -ni eth1 tcp port 8080
#    Router egress (eth2): NOTHING. So the packet dies inside the router.
#      sudo ip netns exec bf13-router tcpdump -ni eth2 tcp port 8080
#
# 3) The obvious check turns up nothing, because 'iptables -L' only shows the filter table:
#      sudo ip netns exec bf13-router iptables -L -n -v
#      (FORWARD policy ACCEPT, no rules)
#    Routing is fine:
#      sudo ip -n bf13-router route get 10.10.2.2 from 10.10.1.2 iif eth1
#      10.10.2.2 from 10.10.1.2 dev eth2 ...
#
# 4) Look at ALL tables. iptables-save dumps them all, and the counters point at the culprit:
#      sudo ip netns exec bf13-router iptables-save -c
#      *raw
#      [5:300] -A PREROUTING -i eth1 -p tcp -m tcp --dport 8080 --tcp-flags FIN,SYN,RST,ACK SYN
#              -m comment --comment "conntrack-bypass: legacy app ports" -j DROP
#    or:
#      sudo ip netns exec bf13-router iptables -t raw -L PREROUTING -n -v --line-numbers
#    With the nft backend you also see it in:  nft list ruleset
#    Remember the order of the hooks: raw PREROUTING runs BEFORE conntrack,
#    mangle, nat and filter. Nothing you do in filter/FORWARD can "unblock" it.
#
# 5) Fix: delete the rule.
#      sudo ip netns exec bf13-router iptables -t raw -D PREROUTING 1
#
# -----------------------------------------------------------------------------
# FAULT A: the server has a bogus default gateway
# -----------------------------------------------------------------------------
# 6) curl still times out. Now the SYN does come out of router eth2 and reaches
#    the server, but no SYN-ACK comes back:
#      sudo ip netns exec bf13-server tcpdump -ni eth0 -e
#      IP 10.10.1.2.43514 > 10.10.2.2.8080: Flags [S], ...
#      ARP, Request who-has 10.10.2.254 tell 10.10.2.2, length 28
#      ARP, Request who-has 10.10.2.254 tell 10.10.2.2, length 28
#    The server DOES answer (the socket is LISTENing and the kernel builds the
#    SYN-ACK), but it needs the MAC of the next hop for 10.10.1.2, and that next hop does not exist.
#
# 7) Confirm with ip:
#      sudo ip -n bf13-server route
#      default via 10.10.2.254 dev eth0
#      10.10.2.0/24 dev eth0 proto kernel scope link src 10.10.2.2
#      sudo ip -n bf13-server route get 10.10.1.2
#      10.10.1.2 via 10.10.2.254 dev eth0 src 10.10.2.2 uid 0
#      sudo ip -n bf13-server neigh
#      10.10.2.254 dev eth0 FAILED            (or INCOMPLETE)
#    Also: 'ss -tn state syn-recv' in the server shows half-open connections.
#
# 8) Fix: point the default route at the real router.
#      sudo ip -n bf13-server route replace default via 10.10.2.1 dev eth0
#    Now small.txt comes back: "hello from bf13-server".
#
# -----------------------------------------------------------------------------
# FAULT C: PMTU black hole (ICMP "fragmentation needed" dropped)
# -----------------------------------------------------------------------------
# 9) big.bin hangs: the TCP handshake and the HTTP headers get through (small packets),
#    the full-size data segments do not.
#      sudo ip netns exec bf13-client curl -sS --max-time 10 -o /dev/null \
#           -w '%{http_code} %{size_download}\n' http://10.10.2.2:8080/big.bin
#      curl: (28) Operation timed out after 10001 milliseconds with 0 out of 2000000 bytes received
#
# 10) Look at SIZES. On the router, at the server side:
#      sudo ip netns exec bf13-router tcpdump -ni eth2 'tcp port 8080 or icmp'
#      IP 10.10.2.2.8080 > 10.10.1.2.43520: Flags [.], seq 1:1449, ack 90, length 1448
#      IP 10.10.2.2.8080 > 10.10.1.2.43520: Flags [.], seq 1:1449, ack 90, length 1448  <- retransmission
#    On the client side (eth1): those segments NEVER show up. And there is no ICMP at all.
#    The handshake negotiated MSS 1460 (both ends have MTU 1500): 1448 of payload + 12 of
#    TCP timestamps + 40 of IP/TCP headers = 1500 bytes > 1400 on eth1. The packets carry DF,
#    so the router cannot fragment them. It has to send ICMP type 3 code 4.
#
# 11) Evidence that the router is discarding them:
#      sudo ip netns exec bf13-router nstat -az IpFragFails
#      IpFragFails                     37                 0.0     <- keeps climbing
#      sudo ip -n bf13-router link show eth1          -> mtu 1400
#      sudo ip netns exec bf13-router iptables -L OUTPUT -n -v --line-numbers
#      1   37  ...  DROP  icmp -- * * 0.0.0.0/0 0.0.0.0/0  icmptype 3 code 4 /* hardening: no ICMP info leak */
#    The server never learns the path MTU. Check its route cache, which has no "mtu":
#      sudo ip -n bf13-server route get 10.10.1.2
#
# 12) Root-cause fix: let the router emit Fragmentation Needed.
#      sudo ip netns exec bf13-router iptables -D OUTPUT 1
#    Verify PMTUD working:
#      sudo ip netns exec bf13-router tcpdump -ni eth2 icmp
#      IP 10.10.2.1 > 10.10.2.2: ICMP 10.10.1.2 unreachable - need to frag (mtu 1400), length 556
#      sudo ip -n bf13-server route get 10.10.1.2
#      10.10.1.2 via 10.10.2.1 dev eth0 src 10.10.2.2 uid 0
#          cache expires 598sec mtu 1400                    <- PMTU learned
#    (If an old test left a stale entry: sudo ip -n bf13-server route flush cache)
#
#    Complementary / alternative fix for TCP (what CNIs and VPN gateways often do):
#      sudo ip netns exec bf13-router iptables -t mangle -A FORWARD -p tcp \
#           --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
#    This rewrites the MSS in the SYN/SYN-ACK to 1360, so TCP never exceeds 1400.
#    It does NOT fix UDP or any other protocol, so dropping ICMP type 3 code 4 is
#    still a bug.
#
# 13) Final check:
#      sudo ./bf13-packet-level.sh check        -> Result: 4/4
#
# -----------------------------------------------------------------------------
# LESSONS FOR KUBERNETES
# -----------------------------------------------------------------------------
# - 'iptables -L' shows only the filter table. kube-proxy, Calico and Cilium write
#   rules to raw, mangle and nat as well. Use 'iptables-save -c' or 'nft list ruleset'.
# - "The pod is Running and the socket is LISTENing" says nothing about the return
#   path. A SYN arriving with no SYN-ACK leaving means look at routes/ARP at the destination.
# - Small works and large does not: think MTU first. Overlays (VXLAN -50 B, Geneve,
#   WireGuard -60/-80 B) make the pod MTU smaller than the node MTU. Any firewall
#   (security group, NetworkPolicy, host rules) that drops ICMP type 3 code 4
#   creates a PMTU black hole.
# - Always follow the same packet interface by interface: the first hop where it
#   disappears tells you which layer to look at.
#
# References:
#   https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
#   https://man7.org/linux/man-pages/man8/ip-route.8.html
#   https://man7.org/linux/man-pages/man8/iptables-extensions.8.html
#   https://www.tcpdump.org/manpages/tcpdump.1.html
#   https://www.rfc-editor.org/rfc/rfc1191   (Path MTU Discovery)
#   https://www.rfc-editor.org/rfc/rfc2923   (TCP problems with PMTUD, black holes)
#   https://kubernetes.io/docs/concepts/services-networking/
# =============================================================================