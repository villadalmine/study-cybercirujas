#!/usr/bin/env bash
#
# LPIC-3 306 (exam 306-300, v3.0)
# Topic 361.2 — Load Balanced Clusters
# Break & Fix lab: HAProxy Layer-7 load balancer with health-checked backends
#
# WHAT THIS SCRIPT DOES
#   1. Builds a self-contained HAProxy load-balancing cluster on ONE disposable
#      lab VM: a frontend on 127.0.0.1:8080 spreading traffic round-robin over
#      two backend web servers on 127.0.0.1:8081 and 127.0.0.1:8082.
#   2. Proves it works (round-robin, both servers UP, HTTP 200).
#   3. Introduces ONE controlled, reversible fault into the backend health check.
#   4. Hands the VM to you with a broken load balancer and a briefing.
#
# SAFETY
#   * Everything binds to loopback (127.0.0.1). No firewall, routing, kernel or
#     network changes. Nothing outside this VM is touched.
#   * The ONLY system file modified is /etc/haproxy/haproxy.cfg, and the original
#     is preserved once in /etc/haproxy/haproxy.cfg.pre-lab.bak before first run.
#   * Re-runnable (idempotent) and fully reversible with:  sudo "$0" reset
#
#   RUN THIS ONLY ON A THROWAWAY LAB VM.  Requires root.
#
#   Usage:
#     sudo ./361.2-lb-breakfix.sh            # interactive confirmation
#     sudo ./361.2-lb-breakfix.sh --yes      # skip confirmation (CI/automation)
#     sudo ./361.2-lb-breakfix.sh reset      # tear down lab, restore original cfg
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LAB_DIR="/root/lb-361.2"
CFG="/etc/haproxy/haproxy.cfg"
ORIG_BAK="${CFG}.pre-lab.bak"
SOCK="/run/haproxy/admin.sock"
FRONTEND="127.0.0.1:8080"
declare -A BACKENDS=( [web1]=8081 [web2]=8082 )

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_bld=$'\e[1m'; c_off=$'\e[0m'
log()  { printf '%s[*]%s %s\n' "$c_bld" "$c_off" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

need_root() { [[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."; }

install_pkgs() {
    # Best-effort dependency install across the common package managers.
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y "$@"
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y "$@"
    elif command -v yum     >/dev/null 2>&1; then yum install -y "$@"
    elif command -v zypper  >/dev/null 2>&1; then zypper -n install "$@"
    else return 1; fi
}

ensure_deps() {
    local missing=()
    command -v haproxy >/dev/null 2>&1 || missing+=(haproxy)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v curl    >/dev/null 2>&1 || missing+=(curl)
    command -v socat   >/dev/null 2>&1 || missing+=(socat)
    if ((${#missing[@]})); then
        warn "Missing packages: ${missing[*]} — attempting install"
        install_pkgs "${missing[@]}" || die "Could not auto-install ${missing[*]}. Install them and re-run."
    fi
    for b in haproxy python3 curl socat; do
        command -v "$b" >/dev/null 2>&1 || die "Still missing '$b' after install attempt."
    done
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${FRONTEND}/" || echo 000; }

stat_line() {
    # pxname,svname,...,status(18)  — one row per proxy/server
    echo "show stat" | socat stdio "$SOCK" 2>/dev/null | awk -F, 'NF>1 {printf "    %-14s %-6s status=%s check=%s/%s\n",$1,$2,$18,$37,$38}'
}

wait_backends_up() {
    log "Waiting for both backends to be reported UP by HAProxy..."
    for _ in $(seq 1 20); do
        if [[ "$(echo 'show stat' | socat stdio "$SOCK" 2>/dev/null | awk -F, '$2=="web1"||$2=="web2"{print $18}' | sort -u | tr '\n' ' ')" == "UP " ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# Backend web servers (distinct bodies so round-robin is visible)
# ---------------------------------------------------------------------------
start_backends() {
    mkdir -p "$LAB_DIR"
    for name in "${!BACKENDS[@]}"; do
        local port="${BACKENDS[$name]}" dir="$LAB_DIR/$name"
        mkdir -p "$dir"
        printf 'RESPONSE-FROM-%s (port %s)\n' "${name^^}" "$port" > "$dir/index.html"
        # Kill any leftover instance from a previous run (idempotent).
        [[ -f "$dir/server.pid" ]] && kill "$(cat "$dir/server.pid")" 2>/dev/null || true
        ( cd "$dir" && nohup python3 -m http.server "$port" --bind 127.0.0.1 >server.log 2>&1 & echo $! >server.pid )
        disown 2>/dev/null || true
    done
    sleep 1
    for name in "${!BACKENDS[@]}"; do
        local port="${BACKENDS[$name]}"
        [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/")" == "200" ]] \
            || die "Backend $name on :$port did not come up (see $LAB_DIR/$name/server.log)."
    done
    ok "Both backend web servers answer 200 directly (127.0.0.1:8081, :8082)."
}

# ---------------------------------------------------------------------------
# HAProxy configuration — HEALTHY baseline (HAProxy 2.2+ syntax)
# ---------------------------------------------------------------------------
write_good_config() {
    mkdir -p /run/haproxy
    [[ -f "$CFG" && ! -f "$ORIG_BAK" ]] && cp -a "$CFG" "$ORIG_BAK" && warn "Original haproxy.cfg saved to $ORIG_BAK"
    cat > "$CFG" <<'EOF'
#--- LPIC-3 361.2 Load Balanced Clusters — lab config (HEALTHY baseline) ---
global
    log /dev/log local0
    maxconn 2000
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    daemon

defaults
    log     global
    mode    http
    option  httplog
    timeout connect 5s
    timeout client  30s
    timeout server  30s

frontend lb_frontend
    bind 127.0.0.1:8080
    default_backend web_backend

backend web_backend
    balance roundrobin
    option httpchk
    http-check send meth GET uri /
    http-check expect status 200
    server web1 127.0.0.1:8081 check inter 2s fall 2 rise 1
    server web2 127.0.0.1:8082 check inter 2s fall 2 rise 1
EOF
    haproxy -c -f "$CFG" >/dev/null 2>&1 || die "Baseline config failed syntax check (haproxy -c)."
    systemctl restart haproxy
    ok "HAProxy started with a valid, healthy configuration."
}

verify_baseline() {
    wait_backends_up || die "Backends never converged to UP on the healthy baseline."
    log "Baseline load-balancer state:"; stat_line
    log "Baseline round-robin probe:"
    local seen=""
    for _ in 1 2 3 4; do seen+="$(curl -s "http://${FRONTEND}/")"$'\n'; done
    printf '%s' "$seen" | sed 's/^/    /'
    grep -q RESPONSE-FROM-WEB1 <<<"$seen" && grep -q RESPONSE-FROM-WEB2 <<<"$seen" \
        || die "Round-robin not observed on baseline; aborting before breaking anything."
    ok "Baseline verified: traffic alternates across web1/web2, both UP, HTTP 200."
}

# ---------------------------------------------------------------------------
# THE BREAK — one controlled, reversible fault in the L7 health check
# ---------------------------------------------------------------------------
break_it() {
    # Point the HTTP health check at a URI the backends do not serve.
    # The web servers keep answering real traffic on '/', but the probe now
    # requests '/healthz' -> 404 -> 'http-check expect status 200' fails ->
    # HAProxy marks BOTH servers DOWN -> clients get 503 with no backend left.
    sed -i 's#http-check send meth GET uri /#http-check send meth GET uri /healthz#' "$CFG"
    haproxy -c -f "$CFG" >/dev/null 2>&1 \
        || die "Broken config unexpectedly failed syntax check (this fault is meant to be SYNTACTICALLY valid)."
    systemctl reload haproxy
    log "Waiting for the fault to take effect (health checks flapping to DOWN)..."
    for _ in $(seq 1 15); do [[ "$(http_code)" == "503" ]] && break; sleep 1; done
}

# ---------------------------------------------------------------------------
# Reset — restore the VM to its pre-lab state
# ---------------------------------------------------------------------------
reset_lab() {
    need_root
    for name in "${!BACKENDS[@]}"; do
        [[ -f "$LAB_DIR/$name/server.pid" ]] && kill "$(cat "$LAB_DIR/$name/server.pid")" 2>/dev/null || true
    done
    if [[ -f "$ORIG_BAK" ]]; then
        cp -a "$ORIG_BAK" "$CFG"; systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null || true
        ok "Original haproxy.cfg restored from $ORIG_BAK."
    else
        warn "No pre-lab backup found; leaving $CFG in place. Backends stopped."
    fi
    rm -rf "$LAB_DIR"
    ok "Lab torn down."
    exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
AUTO_YES="${AUTO_YES:-no}"
case "${1:-}" in
    reset)  reset_lab ;;
    --yes)  AUTO_YES=yes ;;
    "" )    : ;;
    * )     die "Unknown argument '$1' (expected: --yes | reset)";;
esac

need_root
if [[ "$AUTO_YES" != "yes" ]]; then
    warn "This modifies /etc/haproxy/haproxy.cfg and starts local services."
    warn "Only continue on a DISPOSABLE lab VM."
    read -rp "Type YES to proceed: " ans
    [[ "$ans" == "YES" ]] || die "Aborted by user."
fi

ensure_deps
log "Building the healthy load-balanced cluster..."
start_backends
write_good_config
verify_baseline

log "Injecting the controlled fault..."
break_it

# ---------------------------------------------------------------------------
# Student briefing
# ---------------------------------------------------------------------------
cat <<EOF

================================================================================
${c_bld}BREAK & FIX — 361.2 Load Balanced Clusters${c_off}
================================================================================

The cluster was healthy a moment ago. It is now broken. Your job: restore it.

${c_bld}SYMPTOM YOU WILL SEE${c_off}
  * A client request to the load balancer now fails:
        curl -i http://${FRONTEND}/
    returns  ${c_red}HTTP/1.1 503 Service Unavailable${c_off}  with the HAProxy body
    "No server is available to handle this request."
  * The two web servers themselves are perfectly healthy — hit them directly:
        curl http://127.0.0.1:8081/    -> 200  RESPONSE-FROM-WEB1
        curl http://127.0.0.1:8082/    -> 200  RESPONSE-FROM-WEB2
  * So the backends are fine, yet the load balancer refuses to forward traffic.

Current load-balancer state (note the status column):
$(stat_line)

${c_bld}WHAT YOU MUST ACHIEVE${c_off}
  1. Get both servers in backend 'web_backend' reported ${c_grn}UP${c_off} again.
  2. Make this succeed and alternate between the two backends:
        for i in 1 2 3 4; do curl -s http://${FRONTEND}/; done
     -> four HTTP 200 responses, RESPONSE-FROM-WEB1 / RESPONSE-FROM-WEB2 in turn.

${c_bld}YOUR TOOLBOX${c_off}
  * Config under test .......... ${CFG}
  * Live runtime API (socket) .. echo "show stat" | socat stdio ${SOCK}
                                  echo "show servers state" | socat stdio ${SOCK}
  * Service logs ............... journalctl -u haproxy -n 40 --no-pager
  * Validate before reloading .. haproxy -c -f ${CFG}
  * Apply changes .............. systemctl reload haproxy
  * Give up / reset the lab .... sudo $0 reset

Hint: HAProxy only sends traffic to backends it believes are healthy. Ask the
runtime API *why* it believes they are not. The answer is in the check status.
================================================================================
EOF
exit 0

# =============================================================================
# SOLUTION — step by step  (read only after you have tried)
# =============================================================================
#
# ROOT CAUSE
#   The Layer-7 health check probes a URI the backends do not serve. The line
#       http-check send meth GET uri /healthz
#   makes HAProxy request GET /healthz from each server. Those python web
#   servers only serve '/', so /healthz returns 404. The rule
#       http-check expect status 200
#   therefore fails, both servers are marked DOWN, and with an empty backend
#   HAProxy answers every client with 503 Service Unavailable. Real user traffic
#   to '/' would have worked — but health checks, not user requests, decide
#   whether a server is eligible. This is one of the most common real-world
#   load-balancer incidents: a health endpoint that does not exist (or was
#   renamed/moved) silently drains every backend.
#
# STEP 1 — Confirm the LB, not the app, is the problem
#   curl -i http://127.0.0.1:8080/        # -> 503 from HAProxy
#   curl -s http://127.0.0.1:8081/        # -> 200 (app is healthy)
#   curl -s http://127.0.0.1:8082/        # -> 200 (app is healthy)
#
# STEP 2 — Confirm HAProxy itself is running (the process is fine; state is not)
#   systemctl status haproxy --no-pager
#
# STEP 3 — Ask HAProxy WHY it dropped the backends (runtime stats socket)
#   echo "show stat" | socat stdio /run/haproxy/admin.sock \
#       | awk -F, 'NF>1{print $1,$2,$18,$37,$38}'
#   # web_backend web1 DOWN L7STS 404
#   # web_backend web2 DOWN L7STS 404
#   The check status "L7STS / 404" is the smoking gun: a Layer-7 (HTTP) check
#   that got an unexpected status code 404. Equivalent evidence in the log:
#   journalctl -u haproxy | grep -i 'health check'
#   # ... Health check for server web_backend/web1 failed, reason: Layer7 wrong
#   #     status, code: 404, ... check duration: ...ms, status: 0/2 DOWN.
#
# STEP 4 — Fix the health check. Any of these is correct; the cleanest is to
#          probe a path the servers actually serve:
#   sudoedit /etc/haproxy/haproxy.cfg
#       # change:
#       #   http-check send meth GET uri /healthz
#       # back to:
#       http-check send meth GET uri /
#   Alternatives that also resolve it (know them for the exam):
#     (a) Create the endpoint the check expects (make the app serve /healthz).
#     (b) Relax the expectation, e.g.  http-check expect rstatus (2|3|4)[0-9][0-9]
#         (accept 4xx too) — usually WRONG for prod: a 404 is not "healthy".
#     (c) Drop to a Layer-4 TCP check ('option tcp-check' / no httpchk) if you
#         only care that the port is open — weaker, but valid.
#
# STEP 5 — Validate the config BEFORE touching the running service
#   haproxy -c -f /etc/haproxy/haproxy.cfg
#   # Configuration file is valid
#
# STEP 6 — Apply without dropping existing connections
#   systemctl reload haproxy      # graceful; 'restart' also works but is harsher
#
# STEP 7 — Verify recovery
#   echo "show stat" | socat stdio /run/haproxy/admin.sock \
#       | awk -F, 'NF>1 && ($2=="web1"||$2=="web2"){print $2,$18}'
#   # web1 UP
#   # web2 UP
#   for i in 1 2 3 4; do curl -s http://127.0.0.1:8080/; done
#   # RESPONSE-FROM-WEB1
#   # RESPONSE-FROM-WEB2
#   # RESPONSE-FROM-WEB1
#   # RESPONSE-FROM-WEB2
#
# TAKEAWAYS
#   * In a load-balanced cluster, backend eligibility is governed by the health
#     check, not by whether the app can serve real traffic. A bad check drains
#     healthy servers and returns 503 — an outage caused entirely by the LB.
#   * Diagnose from the balancer's own view of the world: the stats socket
#     ("show stat" / "show servers state") and the check status field, plus the
#     health-check log lines. Do not stop at "the app returns 200 directly".
#   * The same failure mode and diagnosis apply across the 361.2 tools:
#       - keepalived LVS:  real_server { HTTP_GET { url { path /healthz }...} }
#                          a wrong path/status_code drops the real server from
#                          the IPVS table (verify with:  ipvsadm -L -n).
#       - ldirectord:      'request'/'receive' directives define the check;
#                          a mismatch removes the real server likewise.
#     Different syntax, identical lesson: the health check is the control plane
#     that decides which real servers receive traffic.
#
# Sources (official):
#   * LPI Exam 306-300 Objectives: https://www.lpi.org/our-certifications/exam-306-objectives/
#   * HAProxy Configuration Manual (option httpchk / http-check):
#     https://docs.haproxy.org/2.8/configuration.html
#   * HAProxy Runtime API (show stat / show servers state):
#     https://docs.haproxy.org/2.8/management.html
# =============================================================================