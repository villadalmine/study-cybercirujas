#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-3 306 (exam 306-300, v3.0) -- Topic 364.4: Network High Availability
#  BREAK & FIX lab -- keepalived / VRRP floating IP + HAProxy health tracking
# ==============================================================================
#
#  WHAT THIS TEACHES
#  -----------------
#  Network HA on Linux is built on two independent layers:
#    1. A floating "virtual IP" (VIP) that follows the healthy node. On Linux
#       this is VRRP (RFC 5798), implemented by keepalived. The VRRP state
#       machine has three states: MASTER (owns the VIP), BACKUP (waits), and
#       FAULT (a local health check failed -> the node refuses to own the VIP).
#    2. A load balancer / proxy (HAProxy) bound to that VIP, distributing L4/L7
#       traffic to real backends.
#
#  The single most common production outage in this stack is NOT the network
#  and NOT a crash: it is a *health check that lies*. keepalived's `vrrp_script`
#  gates the VRRP instance. If that script exits non-zero and carries no
#  `weight`, keepalived drives the instance into FAULT and RELEASES the VIP --
#  even on a node whose real service is perfectly healthy. The service is up,
#  the box is up, and yet the VIP -- and therefore every client -- is gone.
#
#  This script builds a known-good single-node VRRP master holding a VIP served
#  by HAProxy, proves it works, then introduces ONE controlled fault in the
#  health check. Your job is to diagnose the FAULT state and restore the VIP
#  WITHOUT disabling the health check.
#
#  SAFETY
#  ------
#  Runs ONLY on a disposable lab VM. It adds a spare VIP as an alias, installs
#  keepalived + haproxy, and edits /etc/keepalived/keepalived.conf. It performs
#  NO destructive disk, no persistent firewall, and no change to your real host
#  IP. `teardown` reverts everything. Do NOT run on anything you care about.
#
#  Sources:
#    - LPI Exam 306 objectives: https://www.lpi.org/our-certifications/exam-306-objectives/
#    - keepalived manual:       https://keepalived.readthedocs.io/en/latest/
#    - man keepalived.conf  (vrrp_script / track_script / FAULT state)
#    - HAProxy docs:            https://docs.haproxy.org/
#    - VRRP:                    RFC 5798  https://datatracker.ietf.org/doc/html/rfc5798
#    - ip_nonlocal_bind:        https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------ constants
KA_CONF="/etc/keepalived/keepalived.conf"
HA_CONF="/etc/haproxy/haproxy.cfg"
VRID="51"                         # VRRP virtual_router_id
GOOD_CHECK="pgrep -x haproxy"     # correct: matches the running HAProxy master
BROKEN_CHECK="pgrep -x haproxyd"  # the fault: a typo'd process name, never matches
STATE_DIR="/var/lib/net-ha-lab"

# ------------------------------------------------------------------- helpers
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cya=$'\033[36m'; c_0=$'\033[0m'
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }
log()  { printf '%s[lab]%s %s\n' "$c_cya" "$c_0" "$*"; }
ok()   { printf '%s[ ok]%s %s\n' "$c_grn" "$c_0" "$*"; }
warn() { printf '%s[!! ]%s %s\n' "$c_yel" "$c_0" "$*"; }
die()  { printf '%s[err]%s %s\n' "$c_red" "$c_0" "$*" >&2; exit 1; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo $0 $*)."; }

confirm() {
    [[ "${LAB_CONFIRM:-}" == "yes" ]] && return 0
    for a in "$@"; do [[ "$a" == "--yes" || "$a" == "-y" ]] && return 0; done
    if [[ -t 0 ]]; then
        warn "This modifies keepalived/haproxy and adds a VIP on THIS machine."
        read -r -p "Type YES to confirm this is a disposable lab VM: " ans
        [[ "$ans" == "YES" ]] || die "Not confirmed. Aborting."
    else
        die "Non-interactive: set LAB_CONFIRM=yes or pass --yes to proceed."
    fi
}

# --------------------------------------------------------- environment probe
detect_pm() {
    if   command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf     >/dev/null 2>&1; then echo dnf
    elif command -v yum     >/dev/null 2>&1; then echo yum
    else die "No supported package manager (apt/dnf/yum) found."; fi
}

install_pkgs() {
    local pm; pm="$(detect_pm)"
    log "Installing keepalived, haproxy and tools via '$pm' ..."
    case "$pm" in
        apt) export DEBIAN_FRONTEND=noninteractive
             apt-get update -qq
             apt-get install -y keepalived haproxy iproute2 procps curl >/dev/null ;;
        dnf) dnf install -y keepalived haproxy iproute procps-ng curl >/dev/null ;;
        yum) yum install -y keepalived haproxy iproute procps-ng curl >/dev/null ;;
    esac
    ok "Packages installed."
}

detect_net() {
    IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    [[ -n "${IFACE:-}" ]] || die "Could not detect the default-route interface."
    local cidr; cidr="$(ip -o -4 addr show dev "$IFACE" | awk '{print $4; exit}')"
    [[ -n "$cidr" ]] || die "Interface $IFACE has no IPv4 address."
    HOSTIP="${cidr%/*}"; PREFIX="${cidr#*/}"
    local base; base="$(echo "$HOSTIP" | cut -d. -f1-3)"
    VIP="${LAB_VIP:-$base.240}"     # spare host in the same /24; override with LAB_VIP=
    log "Interface=$IFACE  host=$HOSTIP/$PREFIX  floating VIP=$VIP"
    [[ "$VIP" != "$HOSTIP" ]] || die "Chosen VIP equals the host IP; set LAB_VIP= to another address."
}

vip_present() { ip -4 addr show dev "$IFACE" | grep -qw "$VIP"; }

wait_vip() {   # $1 = present|absent   $2 = timeout seconds
    local want="$1" t="${2:-12}" i=0
    while [[ $i -lt $t ]]; do
        if [[ "$want" == present ]] &&   vip_present; then return 0; fi
        if [[ "$want" == absent  ]] && ! vip_present; then return 0; fi
        sleep 1; i=$((i + 1))
    done
    return 1
}

# ------------------------------------------------------------ config writers
write_haproxy() {
    # HAProxy binds the *floating* VIP:80 and answers with a static 200.
    # Binding to a non-owned address requires ip_nonlocal_bind=1 so that the
    # proxy survives even while the VIP is briefly absent -- a real HA pattern.
    mkdir -p "$STATE_DIR"
    [[ -f "$STATE_DIR/nonlocal_bind.orig" ]] || \
        sysctl -n net.ipv4.ip_nonlocal_bind > "$STATE_DIR/nonlocal_bind.orig"
    sysctl -wq net.ipv4.ip_nonlocal_bind=1

    cat > "$HA_CONF" <<EOF
global
    log /dev/log local0
    maxconn 512
defaults
    mode http
    log global
    timeout connect 5s
    timeout client  30s
    timeout server  30s
frontend fe_lab
    bind ${VIP}:80
    http-request return status 200 content-type "text/plain" string "network-ha-lab: OK from \$HOSTNAME\n"
EOF
    systemctl restart haproxy
    ok "HAProxy is serving on ${VIP}:80"
}

write_keepalived() {
    # $1 = the vrrp_script command to install (good or broken).
    # NOTE: the vrrp_script carries NO 'weight'. A weightless tracked script
    # that FAILS forces the whole vrrp_instance into FAULT and releases the
    # VIP -- which is exactly the failure mode this lab reproduces.
    local check="$1"
    cat > "$KA_CONF" <<EOF
global_defs {
    router_id LAB_NODE_1
}

vrrp_script chk_haproxy {
    script "$check"
    interval 2
    fall 2
    rise 2
    timeout 3
}

vrrp_instance VI_1 {
    state MASTER
    interface $IFACE
    virtual_router_id $VRID
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass Lab#3644
    }
    virtual_ipaddress {
        $VIP/$PREFIX dev $IFACE
    }
    track_script {
        chk_haproxy
    }
}
EOF
    systemctl restart keepalived
}

# ------------------------------------------------------------------- actions
setup_good() {
    install_pkgs
    detect_net
    write_haproxy
    log "Bringing up keepalived as VRRP MASTER (healthy check) ..."
    write_keepalived "$GOOD_CHECK"
    if wait_vip present 12; then
        ok "VIP $VIP is UP and owned by this node (MASTER)."
        log "Smoke test:  curl -s http://$VIP/"
        curl -s --max-time 4 "http://$VIP/" || warn "curl failed (check local firewall)."
    else
        die "VIP did not come up -- the lab could not reach a known-good state."
    fi
}

do_break() {
    log "Injecting the fault into the keepalived health check ..."
    write_keepalived "$BROKEN_CHECK"
    wait_vip absent 12 || warn "VIP still present; give keepalived a few more seconds."
    hr
    printf '%s  TOPIC 364.4 -- NETWORK HIGH AVAILABILITY  --  BREAK INJECTED%s\n' "$c_yel" "$c_0"
    hr
    cat <<EOF

SYMPTOM you will observe
  * The floating service is DOWN for every client:
        curl -s --max-time 4 http://$VIP/        -> connection refused / timeout
  * The VIP has vanished from the interface, although nothing crashed:
        ip -4 addr show dev $IFACE | grep $VIP    -> (no output)
  * keepalived reports the instance is NOT master:
        systemctl status keepalived
        journalctl -u keepalived -n 25 --no-pager
      You will see lines such as:
        VRRP_Script(chk_haproxy) failed ... 
        (VI_1) Entering FAULT STATE
        (VI_1) removing VIPs
  * And yet the real service is perfectly healthy:
        systemctl is-active haproxy               -> active
        pgrep -x haproxy                          -> prints one or more PIDs
        ss -ltnp | grep ':80'                     -> haproxy is listening

WHY this matters (the concept under test)
  keepalived's VRRP instance is gated by a track_script. When that script
  exits non-zero (and has no 'weight'), the node enters FAULT and gives up the
  VIP on purpose -- HA is doing its job. The bug is not in HAProxy and not in
  the network: the HEALTH CHECK ITSELF is wrong, so it reports a failure that
  is not real. This is a "false-negative health check", the classic silent
  killer of VRRP-based Network HA.

YOUR OBJECTIVE
  Diagnose why the VRRP instance is in FAULT, and restore the VIP so the node
  returns to MASTER and 'curl http://$VIP/' answers again.
  You must FIX the check so it tells the truth -- NOT delete the track_script,
  NOT hard-code it to 'exit 0', and NOT lower the check to something that never
  runs. In production, blinding your health check is how you get split-brain.

HINTS
  1. Read the FAULT reason:   journalctl -u keepalived -n 30 --no-pager
  2. Open the tracked check:  grep -n 'script' $KA_CONF
  3. Run that exact command by hand and inspect its exit code:
        <the command> ; echo "exit=\$?"
     Compare it against the real process name:  pgrep -x haproxy ; echo \$?
  4. Correct the command, then:  systemctl restart keepalived
  5. Verify recovery:  ip -4 addr show dev $IFACE | grep $VIP ; curl http://$VIP/

  Give up / reset the VIP automatically:   sudo $0 restore
  Tear the whole lab down:                 sudo $0 teardown

EOF
    hr
}

restore_good() {
    detect_net
    log "Restoring the correct health check and reloading keepalived ..."
    write_keepalived "$GOOD_CHECK"
    if wait_vip present 12; then
        ok "Recovered: $VIP is back, node is MASTER again."
        curl -s --max-time 4 "http://$VIP/" || true
    else
        warn "VIP still absent -- inspect: journalctl -u keepalived -n 30 --no-pager"
    fi
}

teardown() {
    detect_net || true
    log "Tearing down the lab ..."
    systemctl stop keepalived 2>/dev/null || true
    systemctl stop haproxy    2>/dev/null || true
    [[ -n "${IFACE:-}" && -n "${VIP:-}" ]] && ip addr del "$VIP/${PREFIX:-24}" dev "$IFACE" 2>/dev/null || true
    if [[ -f "$STATE_DIR/nonlocal_bind.orig" ]]; then
        sysctl -wq "net.ipv4.ip_nonlocal_bind=$(cat "$STATE_DIR/nonlocal_bind.orig")" || true
        rm -f "$STATE_DIR/nonlocal_bind.orig"
    fi
    rm -f "$KA_CONF" "$HA_CONF"
    ok "Services stopped, VIP removed, sysctl restored, configs deleted."
}

usage() {
    cat <<EOF
Topic 364.4 Network HA -- break & fix lab

Usage: sudo $0 <command> [--yes]

  break      (default) build the known-good VRRP+HAProxy VIP, then inject the fault
  restore    put the correct health check back and bring the VIP up again
  teardown   stop services, remove the VIP, delete lab configs, restore sysctl
  help       show this message

Env:  LAB_VIP=<addr>   override the floating IP (default: <subnet>.240)
      LAB_CONFIRM=yes  skip the interactive confirmation
EOF
}

# ----------------------------------------------------------------------- main
cmd="${1:-break}"
case "$cmd" in
    break|"")   need_root "$@"; confirm "$@"; setup_good; do_break ;;
    restore)    need_root "$@"; restore_good ;;
    teardown)   need_root "$@"; teardown ;;
    help|-h|--help) usage ;;
    *)          usage; die "Unknown command: $cmd" ;;
esac

# ==============================================================================
#  SOLUTION -- step by step (do not read until you have tried it yourself)
# ==============================================================================
#
#  Root cause: /etc/keepalived/keepalived.conf tracks a vrrp_script whose
#  command is 'pgrep -x haproxyd'. The real process is named 'haproxy' (no
#  trailing 'd'), so the check ALWAYS exits 1. Because the script has no
#  'weight', two consecutive failures ('fall 2') push vrrp_instance VI_1 into
#  FAULT, and keepalived withdraws the VIP. HAProxy never failed -- the monitor
#  lied about it.
#
#  --- 1. Confirm the VIP is gone but nothing actually crashed --------------
#     ip -4 addr show dev "$IFACE"          # the VIP is NOT listed
#     systemctl is-active haproxy           # -> active
#     pgrep -x haproxy                      # -> real PID(s): HAProxy is fine
#     ss -ltnp | grep ':80'                 # HAProxy is still listening
#
#  --- 2. Ask keepalived WHY it dropped the VIP -----------------------------
#     journalctl -u keepalived -n 30 --no-pager
#       Expected:
#         VRRP_Script(chk_haproxy) failed (exited with status 1)
#         (VI_1) Entering FAULT STATE
#         (VI_1) removing VIPs.
#
#  --- 3. Read the tracked command and reproduce the failure ----------------
#     grep -n 'script' /etc/keepalived/keepalived.conf
#       ->   script "pgrep -x haproxyd"
#     pgrep -x haproxyd ; echo "exit=$?"    # -> exit=1  (nothing matches)
#     pgrep -x haproxy  ; echo "exit=$?"    # -> exit=0  (this is the truth)
#     The monitor is checking a process name that does not exist.
#
#  --- 4. Fix the check so it reflects reality ------------------------------
#     sed -i 's/pgrep -x haproxyd/pgrep -x haproxy/' /etc/keepalived/keepalived.conf
#       (or edit the file: script "pgrep -x haproxyd"  ->  script "pgrep -x haproxy")
#
#     A more robust real-world check would probe the service, not just the
#     process -- e.g.:
#         script "/usr/bin/curl -sf -o /dev/null --max-time 2 http://127.0.0.1:80/"
#     because a process can be alive yet not serving. Either fix is acceptable
#     as long as it tells the TRUTH about HAProxy's health.
#
#  --- 5. Reload keepalived and re-read the config --------------------------
#     systemctl restart keepalived      # (reload/SIGHUP also re-reads the file)
#
#  --- 6. Verify recovery ---------------------------------------------------
#     journalctl -u keepalived -n 15 --no-pager   # -> (VI_1) Entering MASTER STATE
#     ip -4 addr show dev "$IFACE" | grep "$VIP"   # -> the VIP is back
#     curl -s http://"$VIP"/                        # -> network-ha-lab: OK ...
#
#  Recovery must happen within ~ (rise * interval) seconds once the check
#  passes again ('rise 2', 'interval 2' -> ~4 s), after which VI_1 leaves
#  FAULT, re-elects itself MASTER (no higher-priority peer exists), and
#  re-adds the VIP.
#
#  Shortcut to auto-restore:   sudo THIS_SCRIPT restore
#  Full cleanup of the lab:    sudo THIS_SCRIPT teardown
#
#  Takeaway for the exam and for production: in VRRP-based Network HA a healthy
#  service can still be knocked offline by a defective track_script. When a VIP
#  disappears, always confirm the FAULT reason in the keepalived log and RUN the
#  tracked command by hand before touching the network or the load balancer.
# ==============================================================================