#!/usr/bin/env bash
# =============================================================================
#  Microsoft Certified: Azure Fundamentals (AZ-900) — exam version 2026-07-20
#  Domain 1: Describe cloud concepts
#  Topic 1.2: Describe the benefits of using cloud services (exam weight 9.4)
#
#  BREAK & FIX LAB — "The four benefits, removed one at a time"
#
#  AZ-900 1.2 is an exam objective about *benefits*: high availability, fault
#  tolerance, reliability (self-healing), scalability/elasticity, and
#  manageability (health probing / management-plane reachability). Those words
#  are abstract until you watch a workload lose them.
#
#  This lab builds a miniature "region" on one throwaic VM using only local
#  primitives, and maps each Azure construct onto something you can break:
#
#     Azure construct                 Lab stand-in
#     ------------------------------  --------------------------------------
#     Azure Load Balancer / App GW    nginx upstream pool on 127.0.0.1:8080
#     VM Scale Set instances          systemd template units az900-app@N
#     VMSS autoscale rules            az900-autoscale.timer + scale.conf
#     Azure health probe              GET /health through the load balancer
#     Network Security Group rule     nginx allow/deny ACL on the probe path
#     Availability guarantee (SLA)    N healthy instances behind the LB
#
#  Everything binds to 127.0.0.1 only. No firewall rule is touched, no package
#  is removed, no data outside the lab paths is written. `cleanup` reverses
#  every change this script makes.
#
#  REQUIREMENTS: a DISPOSABLE lab VM, root, systemd, nginx, python3, curl.
#  DO NOT RUN THIS ON A MACHINE YOU CARE ABOUT.
#
#  Reference (official):
#    https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#    https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-overview
#    https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-autoscale-overview
#    https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-custom-probe-overview
#    https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
#
#  USAGE:
#    sudo ./az900-1.2-break-fix.sh setup     # build the healthy baseline
#    sudo ./az900-1.2-break-fix.sh break     # inject the four faults
#    sudo ./az900-1.2-break-fix.sh status    # inspect current topology
#    sudo ./az900-1.2-break-fix.sh hint      # symptom -> benefit mapping
#    sudo ./az900-1.2-break-fix.sh verify    # graded acceptance checks
#    sudo ./az900-1.2-break-fix.sh cleanup   # remove the whole lab
# =============================================================================

set -euo pipefail

LAB_ROOT="/opt/az900-lab"
CONF_DIR="/etc/az900-lab"
STATE_DIR="/var/lib/az900-lab"
SCALE_CONF="${CONF_DIR}/scale.conf"
SENTINEL="${CONF_DIR}/LAB_VM"
NGX_SITE="/etc/nginx/conf.d/az900-lab.conf"
NGX_UPSTREAM="/etc/nginx/az900-upstream.conf"
NGX_HEALTH_ACL="/etc/nginx/az900-health-acl.conf"
ACCESS_LOG="/var/log/nginx/az900-lab.access.log"
UNIT_APP="/etc/systemd/system/az900-app@.service"
UNIT_SCALE_SVC="/etc/systemd/system/az900-autoscale.service"
UNIT_SCALE_TMR="/etc/systemd/system/az900-autoscale.timer"
DROPIN_DIR="/etc/systemd/system/az900-app@.service.d"

LB_HOST="127.0.0.1"
LB_PORT="8080"
BASE_PORT="8080"          # instance N listens on BASE_PORT + N
MAX_INSTANCES="4"
LB_URL="http://${LB_HOST}:${LB_PORT}"

C_OK=$'\033[0;32m'; C_BAD=$'\033[0;31m'; C_WARN=$'\033[0;33m'
C_HDR=$'\033[1;36m'; C_DIM=$'\033[0;90m'; C_OFF=$'\033[0m'

log()  { printf '%s[lab]%s %s\n' "${C_DIM}" "${C_OFF}" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "${C_OK}" "${C_OFF}" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n' "${C_BAD}" "${C_OFF}" "$*"; }
warn() { printf '%s[warn]%s %s\n' "${C_WARN}" "${C_OFF}" "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "${C_HDR}" "$*" "${C_OFF}"; }
die()  { printf '%s[fatal]%s %s\n' "${C_BAD}" "${C_OFF}" "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 $*)"; }
require_setup() { [ -f "${SENTINEL}" ] || die "lab not built yet — run: sudo $0 setup"; }
port_of() { echo $(( BASE_PORT + $1 )); }

# -----------------------------------------------------------------------------
# Dependency + safety handling
# -----------------------------------------------------------------------------
ensure_deps() {
    local missing=() pkg
    command -v nginx   >/dev/null 2>&1 || missing+=("nginx")
    command -v curl    >/dev/null 2>&1 || missing+=("curl")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    [ "${#missing[@]}" -eq 0 ] && return 0
    log "installing missing packages: ${missing[*]}"
    if   command -v dnf     >/dev/null 2>&1; then dnf install -y "${missing[@]}"
    elif command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y "${missing[@]}"
    elif command -v zypper  >/dev/null 2>&1; then zypper -n in "${missing[@]}"
    elif command -v pacman  >/dev/null 2>&1; then
        local mapped=(); for pkg in "${missing[@]}"; do [ "${pkg}" = "python3" ] && pkg="python"; mapped+=("${pkg}"); done
        pacman -Sy --noconfirm "${mapped[@]}"
    else die "no supported package manager; install manually: ${missing[*]}"; fi
}

preflight() {
    [ -d /run/systemd/system ] || die "systemd is not the init system here"
    local p
    for p in "${LB_PORT}" $(seq $(( BASE_PORT + 1 )) $(( BASE_PORT + MAX_INSTANCES ))); do
        if ss -ltn "sport = :${p}" 2>/dev/null | grep -q LISTEN; then
            die "TCP/${p} is already in use — this VM is not clean enough for the lab"
        fi
    done
    if [ ! -f "${SENTINEL}" ] && [ "${AZ900_LAB_CONFIRM:-}" != "yes" ]; then
        cat <<EOF

This script will, on THIS machine:
  - install nginx / python3 / curl if absent
  - write ${LAB_ROOT}, ${CONF_DIR}, ${STATE_DIR}
  - write systemd units az900-app@.service and az900-autoscale.{service,timer}
  - write ${NGX_SITE} and reload nginx
  - listen on 127.0.0.1:${LB_PORT} and 127.0.0.1:$(( BASE_PORT + 1 ))-$(( BASE_PORT + MAX_INSTANCES ))

Use ONLY a disposable lab VM. 'cleanup' removes all of the above.
EOF
        read -r -p "Type 'yes' to continue: " answer
        [ "${answer}" = "yes" ] || die "aborted by user"
    fi
}

selinux_allow_proxy() {
    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce)" = "Enforcing" ] || return 0
    command -v getsebool >/dev/null 2>&1 || return 0
    local prev; prev="$(getsebool httpd_can_network_connect | awk '{print $3}')"
    if [ ! -f "${CONF_DIR}/selinux.prev" ]; then echo "${prev}" > "${CONF_DIR}/selinux.prev"; fi
    if [ "${prev}" != "on" ]; then
        log "SELinux is Enforcing — enabling httpd_can_network_connect (reverted by cleanup)"
        setsebool -P httpd_can_network_connect 1
    fi
}

selinux_restore() {
    [ -f "${CONF_DIR}/selinux.prev" ] || return 0
    local prev; prev="$(cat "${CONF_DIR}/selinux.prev")"
    if [ "${prev}" = "off" ] && command -v setsebool >/dev/null 2>&1; then
        log "restoring SELinux boolean httpd_can_network_connect=off"
        setsebool -P httpd_can_network_connect 0 || true
    fi
}

nginx_apply() {
    if ! nginx -t >/dev/null 2>&1; then
        nginx -t || true
        die "nginx configuration is invalid — fix it before continuing"
    fi
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

# -----------------------------------------------------------------------------
# setup — build the healthy baseline (2 replicas, LB, probe, autoscaler)
# -----------------------------------------------------------------------------
cmd_setup() {
    require_root
    preflight
    ensure_deps

    install -d -m 0755 "${LAB_ROOT}" "${CONF_DIR}" "${STATE_DIR}"

    # ---- the workload: a trivial HTTP server that identifies its own replica
    cat > "${LAB_ROOT}/app.py" <<'PY'
#!/usr/bin/env python3
"""AZ-900 lab workload. One process == one VMSS instance.

Serves:
  GET /         -> 200, body "node-<N>"      (application traffic)
  GET /health   -> 200, body "OK node-<N>"   (what an Azure health probe polls)
"""
import sys
import http.server
import socketserver

NODE = sys.argv[1]
PORT = 8080 + int(NODE)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Az900-Node", "node-%s" % NODE)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.startswith("/health"):
            self._send(200, "OK node-%s\n" % NODE)
        else:
            self._send(200, "node-%s\n" % NODE)

    def log_message(self, *args):
        return


socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
PY
    chmod 0644 "${LAB_ROOT}/app.py"

    # ---- scale rules: the lab equivalent of a VMSS autoscale profile
    cat > "${SCALE_CONF}" <<'EOF'
# AZ-900 lab — autoscale profile (VMSS "scale rule" stand-in).
# MIN_REPLICAS is also the availability floor: with 1 instance there is no
# fault tolerance, no matter how healthy that instance looks.
MIN_REPLICAS=2
MAX_REPLICAS=4
# Scale out when observed request rate reaches this many requests/minute.
SCALE_OUT_RPM=120
# Evaluation interval, must match az900-autoscale.timer.
TICK_SECONDS=15
EOF

    # ---- the autoscaler: recomputes desired capacity and rewrites the LB pool
    cat > "${LAB_ROOT}/autoscale.sh" <<'EOF'
#!/usr/bin/env bash
# AZ-900 lab autoscaler. Reads the LB access log delta since the last tick,
# converts it to requests/minute, picks a desired instance count, converges the
# systemd units to it, and regenerates the load balancer backend pool.
set -euo pipefail

CONF="/etc/az900-lab/scale.conf"
STATE="/var/lib/az900-lab/loglines"
LOG="/var/log/nginx/az900-lab.access.log"
UP="/etc/nginx/az900-upstream.conf"
BASE_PORT=8080
MAX_INSTANCES=4

# shellcheck disable=SC1090
. "${CONF}"

mkdir -p "$(dirname "${STATE}")"
cur=$(wc -l < "${LOG}" 2>/dev/null || echo 0)
prev=$(cat "${STATE}" 2>/dev/null || echo 0)
[ "${cur}" -lt "${prev}" ] && prev=0          # log rotated
delta=$(( cur - prev ))
echo "${cur}" > "${STATE}"
rpm=$(( delta * 60 / TICK_SECONDS ))

desired="${MIN_REPLICAS}"
[ "${rpm}" -ge "${SCALE_OUT_RPM}" ] && desired="${MAX_REPLICAS}"
[ "${desired}" -gt "${MAX_INSTANCES}" ] && desired="${MAX_INSTANCES}"
[ "${desired}" -lt 1 ] && desired=1
echo "observed=${rpm}rpm desired_replicas=${desired}"

for i in $(seq 1 "${MAX_INSTANCES}"); do
    if [ "${i}" -le "${desired}" ]; then
        systemctl is-active --quiet "az900-app@${i}" || systemctl start "az900-app@${i}" || true
    else
        systemctl is-active --quiet "az900-app@${i}" && systemctl stop "az900-app@${i}" || true
    fi
done

tmp="$(mktemp)"
for i in $(seq 1 "${MAX_INSTANCES}"); do
    if systemctl is-active --quiet "az900-app@${i}"; then
        printf 'server 127.0.0.1:%s max_fails=1 fail_timeout=5s;\n' "$(( BASE_PORT + i ))" >> "${tmp}"
    fi
done

# Never publish an empty backend pool: an empty upstream block fails nginx -t
# and would take the whole front end down instead of degrading it.
if [ ! -s "${tmp}" ]; then
    echo "no healthy instances — keeping previous pool"
    rm -f "${tmp}"
    exit 0
fi

if ! cmp -s "${tmp}" "${UP}"; then
    install -m 0644 "${tmp}" "${UP}"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        echo "backend pool updated to ${desired} instance(s)"
    else
        echo "nginx -t failed, pool not applied" >&2
    fi
fi
rm -f "${tmp}"
EOF
    chmod 0755 "${LAB_ROOT}/autoscale.sh"

    # ---- health probe helper (what a monitoring system would call)
    cat > "${LAB_ROOT}/probe.sh" <<EOF
#!/usr/bin/env bash
# AZ-900 lab health probe: polls the LB front end exactly like an Azure
# Load Balancer custom probe does. Anything other than HTTP 200 == UNHEALTHY.
code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${LB_URL}/health" || echo 000)
if [ "\${code}" = "200" ]; then
    echo "HEALTHY (HTTP \${code})"
else
    echo "UNHEALTHY (HTTP \${code})"
    exit 1
fi
EOF
    chmod 0755 "${LAB_ROOT}/probe.sh"

    # ---- systemd units: the "instance" and the "autoscale engine"
    cat > "${UNIT_APP}" <<EOF
[Unit]
Description=AZ-900 lab application replica %i
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LAB_ROOT}/app.py %i
# Self-healing: this single directive is the difference between "the process
# died" and "the platform noticed and replaced it".
Restart=always
RestartSec=2
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    cat > "${UNIT_SCALE_SVC}" <<EOF
[Unit]
Description=AZ-900 lab autoscale evaluation

[Service]
Type=oneshot
ExecStart=${LAB_ROOT}/autoscale.sh
EOF

    cat > "${UNIT_SCALE_TMR}" <<'EOF'
[Unit]
Description=AZ-900 lab autoscale evaluation timer

[Timer]
OnBootSec=15s
OnUnitActiveSec=15s
AccuracySec=1s
Unit=az900-autoscale.service

[Install]
WantedBy=timers.target
EOF

    # ---- load balancer front end
    cat > "${NGX_HEALTH_ACL}" <<'EOF'
# AZ-900 lab — NSG rule stand-in for the health probe path.
# Azure's probe source is the platform address 168.63.129.16; here the probe
# originates on loopback, so loopback is what must be allowed.
allow 127.0.0.1;
allow ::1;
deny all;
EOF

    printf 'server 127.0.0.1:%s max_fails=1 fail_timeout=5s;\nserver 127.0.0.1:%s max_fails=1 fail_timeout=5s;\n' \
        "$(port_of 1)" "$(port_of 2)" > "${NGX_UPSTREAM}"

    cat > "${NGX_SITE}" <<EOF
# AZ-900 lab load balancer front end (managed by az900-1.2-break-fix.sh)
upstream az900_pool {
    include ${NGX_UPSTREAM};
}

server {
    listen ${LB_HOST}:${LB_PORT};
    server_name az900-lab.local;
    access_log ${ACCESS_LOG};

    location = /health {
        include ${NGX_HEALTH_ACL};
        proxy_pass http://az900_pool/health;
        proxy_connect_timeout 1s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }

    location / {
        proxy_pass http://az900_pool;
        proxy_connect_timeout 1s;
        # Fault tolerance at the LB layer: retry a dead backend on a peer
        # instead of returning 502 to the client.
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
    }
}
EOF

    touch "${SENTINEL}"
    selinux_allow_proxy

    systemctl daemon-reload
    systemctl enable --now nginx >/dev/null 2>&1 || systemctl start nginx
    nginx_apply
    systemctl start az900-app@1 az900-app@2
    systemctl enable --now az900-autoscale.timer >/dev/null 2>&1

    sleep 2
    hdr "Baseline built"
    cmd_status
    cat <<EOF

Baseline behaviour you should confirm before breaking anything:

  \$ curl -s ${LB_URL}/ ; curl -s ${LB_URL}/
  node-1
  node-2

  \$ ${LAB_ROOT}/probe.sh
  HEALTHY (HTTP 200)

Then run:  sudo $0 break
EOF
}

# -----------------------------------------------------------------------------
# break — inject four faults, each removing one AZ-900 1.2 benefit
# -----------------------------------------------------------------------------
cmd_break() {
    require_root
    require_setup

    log "injecting FAULT-1 (high availability): collapsing the backend pool"
    systemctl stop az900-app@3 az900-app@4 2>/dev/null || true
    systemctl stop az900-app@2
    printf 'server 127.0.0.1:%s max_fails=1 fail_timeout=5s;\n' "$(port_of 1)" > "${NGX_UPSTREAM}"

    log "injecting FAULT-2 (reliability / self-healing): disabling instance restart"
    install -d -m 0755 "${DROPIN_DIR}"
    cat > "${DROPIN_DIR}/override.conf" <<'EOF'
[Service]
# Injected by the AZ-900 1.2 break & fix lab.
Restart=no
EOF

    log "injecting FAULT-3 (manageability): NSG rule now blocks the health probe"
    cat > "${NGX_HEALTH_ACL}" <<'EOF'
# Injected by the AZ-900 1.2 break & fix lab.
deny all;
EOF

    log "injecting FAULT-4 (scalability / elasticity): autoscale engine disabled"
    systemctl stop az900-autoscale.timer 2>/dev/null || true
    systemctl mask az900-autoscale.timer >/dev/null 2>&1
    sed -i 's/^MIN_REPLICAS=.*/MIN_REPLICAS=1/;
            s/^MAX_REPLICAS=.*/MAX_REPLICAS=1/;
            s/^SCALE_OUT_RPM=.*/SCALE_OUT_RPM=999999/' "${SCALE_CONF}"

    systemctl daemon-reload
    systemctl restart az900-app@1
    nginx_apply
    sleep 2

    cat <<EOF

${C_HDR}=========================== INCIDENT BRIEFING ============================${C_OFF}
A workload that used to look like a well-architected Azure deployment has been
degraded to something that only *looks* healthy from the outside. The front end
still answers on ${LB_URL}/ — that is the trap. Four distinct
benefits from AZ-900 objective 1.2 are gone.

${C_HDR}SYMPTOMS YOU WILL OBSERVE${C_OFF}

  S1  Every response comes from the same node.
        \$ for i in 1 2 3 4; do curl -s ${LB_URL}/; done
        node-1
        node-1
        node-1
        node-1
      Expected on a healthy deployment: node-1 and node-2 interleaved.

  S2  A single instance failure takes the whole service down.
        \$ sudo systemctl stop az900-app@1
        \$ curl -s -o /dev/null -w '%{http_code}\\n' ${LB_URL}/
        502
      There is no second fault domain to absorb the loss.

  S3  A crashed instance never comes back.
        \$ sudo systemctl kill --signal=SIGKILL az900-app@1
        \$ sleep 8; systemctl is-active az900-app@1
        failed
      The platform observed the crash and did nothing about it.

  S4  The health probe cannot reach the endpoint through the front end.
        \$ ${LAB_ROOT}/probe.sh
        UNHEALTHY (HTTP 403)
      But the instance itself is fine:
        \$ curl -s http://127.0.0.1:$(port_of 1)/health
        OK node-1
      The application is healthy and the management plane cannot prove it.

  S5  Load produces latency and errors instead of capacity.
        \$ for i in \$(seq 1 200); do curl -s -o /dev/null ${LB_URL}/; done
        \$ systemctl list-units 'az900-app@*' --no-legend | wc -l
        1
      Demand went up 200x; capacity did not move.

${C_HDR}WHAT YOU MUST ACHIEVE${C_OFF}
Restore the four benefits. \`sudo $0 verify\` grades you and
must report 5/5 PASS:

  CHECK-1  Traffic to ${LB_URL}/ is served by at least 2 distinct
           instances                                    -> high availability
  CHECK-2  Stopping any single instance still yields 20/20 HTTP 200 responses
                                                        -> fault tolerance
  CHECK-3  SIGKILL on an instance is followed by an automatic restart within
           8 seconds                                    -> reliability / self-healing
  CHECK-4  ${LB_URL}/health returns HTTP 200 to the probe
                                                        -> manageability / observability
  CHECK-5  Under sustained load the deployment scales out to >= 3 instances and
           the load balancer pool grows with it         -> elasticity / scalability

${C_HDR}RULES${C_OFF}
  * Do not edit or re-run this script's \`setup\`. Repair the running system.
  * Everything you need is under ${CONF_DIR}, ${LAB_ROOT},
    /etc/systemd/system/az900-* and /etc/nginx/az900-*.
  * Useful starting points:
        systemctl status 'az900-app@*' az900-autoscale.timer
        systemctl cat az900-app@1
        systemctl list-unit-files 'az900-*'
        cat ${NGX_UPSTREAM}
        cat ${NGX_HEALTH_ACL}
        cat ${SCALE_CONF}
        nginx -T | sed -n '/az900/,/^}/p'
        journalctl -u az900-autoscale.service -n 20
  * \`sudo $0 hint\` maps each symptom to the AZ-900 benefit it removed.
${C_HDR}=========================================================================${C_OFF}
EOF
}

# -----------------------------------------------------------------------------
# status / hint
# -----------------------------------------------------------------------------
cmd_status() {
    require_root
    require_setup
    hdr "Instances (VMSS stand-in)"
    local i st
    for i in $(seq 1 "${MAX_INSTANCES}"); do
        st="$(systemctl is-active "az900-app@${i}" 2>/dev/null || true)"
        printf '  az900-app@%s  port %s  %s  (Restart=%s)\n' \
            "${i}" "$(port_of "${i}")" "${st}" \
            "$(systemctl show -p Restart --value "az900-app@${i}" 2>/dev/null || echo '?')"
    done
    hdr "Load balancer backend pool (${NGX_UPSTREAM})"
    sed 's/^/  /' "${NGX_UPSTREAM}" 2>/dev/null || echo "  <missing>"
    hdr "Health probe ACL (${NGX_HEALTH_ACL})"
    grep -v '^#' "${NGX_HEALTH_ACL}" 2>/dev/null | sed '/^$/d;s/^/  /' || echo "  <missing>"
    hdr "Autoscale profile"
    grep -v '^#' "${SCALE_CONF}" 2>/dev/null | sed '/^$/d;s/^/  /'
    printf '  timer state: %s / %s\n' \
        "$(systemctl is-active az900-autoscale.timer 2>/dev/null || echo inactive)" \
        "$(systemctl is-enabled az900-autoscale.timer 2>/dev/null || echo unknown)"
    hdr "Front end"
    printf '  GET %s/       -> HTTP %s\n' "${LB_URL}" \
        "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${LB_URL}/" || echo 000)"
    printf '  GET %s/health -> HTTP %s\n' "${LB_URL}" \
        "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${LB_URL}/health" || echo 000)"
    echo
}

cmd_hint() {
    cat <<EOF

${C_HDR}Symptom -> AZ-900 1.2 benefit -> where the platform enforces it${C_OFF}

  S1/S2  Only one node answers, one failure = outage
         Benefit: high availability & fault tolerance. In Azure this is more
         than one instance across fault/update domains (Availability Set) or
         Availability Zones, published through a Load Balancer backend pool.
         An SLA is a statement about redundancy, not about uptime luck.
         Look at: the backend pool file, and which instances are running.

  S3     A crashed instance stays crashed
         Benefit: reliability / self-healing. VMSS automatic instance repair
         and Service Fabric / AKS controllers exist precisely so that a dead
         replica is replaced without a human. Here the equivalent is the unit's
         Restart= directive, and a drop-in can override it.
         Look at: systemctl cat az900-app@1 — read the FULL output, drop-ins
         are appended after the main unit file.

  S4     Probe gets 403, the app itself is fine
         Benefit: manageability / observability. In Azure a health probe blocked
         by an NSG marks a perfectly healthy instance as down and the load
         balancer removes it from rotation. The failure is in the network rule,
         not in the workload — always test the backend directly before blaming
         the app.
         Look at: the ACL include used by the /health location.

  S5     Load creates errors instead of instances
         Benefit: scalability & elasticity (and the cost benefit that follows
         from scaling back in). Autoscale needs three things alive: the engine,
         a rule that can actually trigger, and a maximum above the minimum.
         Breaking any one of them silently pins capacity.
         Look at: the timer unit state (is-enabled can say 'masked') and every
         value in ${SCALE_CONF}.

EOF
}

# -----------------------------------------------------------------------------
# verify — graded acceptance checks
# -----------------------------------------------------------------------------
gen_load() {
    local seconds="$1" deadline
    deadline=$(( SECONDS + seconds ))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        curl -s -o /dev/null --max-time 2 "${LB_URL}/" || true
    done
}

cmd_verify() {
    require_root
    require_setup
    local pass=0 fail=0 i body code distinct

    hdr "CHECK-1 — high availability: is traffic spread over >= 2 instances?"
    local -a bodies=()
    for i in $(seq 1 20); do
        body="$(curl -s --max-time 3 "${LB_URL}/" || echo ERR)"
        bodies+=("${body}")
    done
    distinct="$(printf '%s\n' "${bodies[@]}" | grep -c . >/dev/null; printf '%s\n' "${bodies[@]}" | sort -u | grep -c 'node-' || true)"
    if [ "${distinct}" -ge 2 ]; then
        ok "20 requests served by ${distinct} distinct instances"; pass=$((pass+1))
    else
        bad "20 requests served by ${distinct} distinct instance(s) — no redundancy behind the LB"; fail=$((fail+1))
    fi

    hdr "CHECK-2 — fault tolerance: does a single instance loss stay invisible?"
    local victim=1 errors=0
    systemctl is-active --quiet az900-app@2 && victim=2
    systemctl stop "az900-app@${victim}" || true
    sleep 1
    for i in $(seq 1 20); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${LB_URL}/" || echo 000)"
        [ "${code}" = "200" ] || errors=$((errors+1))
    done
    systemctl start "az900-app@${victim}" || true
    if [ "${errors}" -eq 0 ]; then
        ok "instance ${victim} down, 20/20 requests still returned HTTP 200"; pass=$((pass+1))
    else
        bad "instance ${victim} down caused ${errors}/20 failed requests — single point of failure"; fail=$((fail+1))
    fi

    hdr "CHECK-3 — reliability: does a killed instance repair itself?"
    local timer_was; timer_was="$(systemctl is-active az900-autoscale.timer 2>/dev/null || true)"
    systemctl stop az900-autoscale.timer 2>/dev/null || true   # isolate self-healing from autoscale
    systemctl start az900-app@1 >/dev/null 2>&1 || true
    sleep 1
    systemctl kill --signal=SIGKILL az900-app@1 2>/dev/null || true
    local recovered=0
    for i in $(seq 1 8); do
        sleep 1
        if systemctl is-active --quiet az900-app@1; then recovered=1; break; fi
    done
    if [ "${recovered}" -eq 1 ]; then
        ok "az900-app@1 was SIGKILLed and came back automatically in ${i}s (Restart=$(systemctl show -p Restart --value az900-app@1))"
        pass=$((pass+1))
    else
        bad "az900-app@1 stayed down for 8s after SIGKILL — no self-healing (Restart=$(systemctl show -p Restart --value az900-app@1))"
        fail=$((fail+1))
        systemctl start az900-app@1 >/dev/null 2>&1 || true
    fi
    [ "${timer_was}" = "active" ] && { systemctl start az900-autoscale.timer >/dev/null 2>&1 || true; }

    hdr "CHECK-4 — manageability: can the health probe reach the endpoint?"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${LB_URL}/health" || echo 000)"
    if [ "${code}" = "200" ]; then
        ok "GET ${LB_URL}/health -> HTTP 200"; pass=$((pass+1))
    else
        bad "GET ${LB_URL}/health -> HTTP ${code} (backend direct: $(curl -s --max-time 2 "http://127.0.0.1:$(port_of 1)/health" | tr -d '\n' || echo unreachable))"
        fail=$((fail+1))
    fi

    hdr "CHECK-5 — elasticity: does sustained load add capacity?"
    if ! systemctl is-active --quiet az900-autoscale.timer; then
        warn "az900-autoscale.timer is $(systemctl is-enabled az900-autoscale.timer 2>/dev/null || echo inactive) — capacity cannot change"
    fi
    log "generating load for 45s and watching instance count..."
    gen_load 45 &
    local load_pid=$!
    local peak=0 running
    for i in $(seq 1 20); do
        sleep 3
        running="$(systemctl list-units 'az900-app@*' --state=active --no-legend 2>/dev/null | wc -l)"
        [ "${running}" -gt "${peak}" ] && peak="${running}"
        [ "${peak}" -ge 3 ] && break
    done
    wait "${load_pid}" 2>/dev/null || true
    if [ "${peak}" -ge 3 ]; then
        ok "scaled out to ${peak} instances under load; pool now: $(tr '\n' ' ' < "${NGX_UPSTREAM}")"
        pass=$((pass+1))
    else
        bad "peak capacity was ${peak} instance(s) under sustained load — deployment cannot scale"
        fail=$((fail+1))
    fi

    hdr "RESULT"
    printf '  %d PASS / %d FAIL\n\n' "${pass}" "${fail}"
    if [ "${fail}" -eq 0 ]; then
        ok "All AZ-900 1.2 benefits restored: availability, fault tolerance, reliability, manageability, elasticity."
        return 0
    fi
    warn "Keep going. Run 'sudo $0 hint' if you are stuck."
    return 1
}

# -----------------------------------------------------------------------------
# cleanup — remove every artifact this script created
# -----------------------------------------------------------------------------
cmd_cleanup() {
    require_root
    log "stopping and removing lab units"
    systemctl unmask az900-autoscale.timer >/dev/null 2>&1 || true
    systemctl disable --now az900-autoscale.timer >/dev/null 2>&1 || true
    systemctl stop az900-autoscale.service >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 "${MAX_INSTANCES}"); do
        systemctl disable --now "az900-app@${i}" >/dev/null 2>&1 || true
    done
    rm -rf "${DROPIN_DIR}"
    rm -f "${UNIT_APP}" "${UNIT_SCALE_SVC}" "${UNIT_SCALE_TMR}"
    systemctl daemon-reload
    systemctl reset-failed 'az900-*' >/dev/null 2>&1 || true

    log "removing nginx front end"
    rm -f "${NGX_SITE}" "${NGX_UPSTREAM}" "${NGX_HEALTH_ACL}"
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    fi

    selinux_restore
    log "removing lab files"
    rm -rf "${LAB_ROOT}" "${STATE_DIR}" "${CONF_DIR}"
    rm -f "${ACCESS_LOG}"*
    ok "lab removed. nginx/python3/curl were left installed on purpose."
}

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

case "${1:-}" in
    setup)   cmd_setup   ;;
    break)   cmd_break   ;;
    status)  cmd_status  ;;
    hint)    cmd_hint    ;;
    verify)  cmd_verify  ;;
    cleanup) cmd_cleanup ;;
    *)       usage       ;;
esac

# =============================================================================
#  SOLUTION — do not read until `verify` reports 5/5, or until you are stuck.
# =============================================================================
#
#  STEP 0 — Establish what is actually broken before changing anything.
#
#    $ sudo ./az900-1.2-break-fix.sh status
#    $ sudo ./az900-1.2-break-fix.sh verify
#
#  Expected on the broken lab: CHECK-1..5 all FAIL, 0 PASS / 5 FAIL.
#  Read `status` carefully — it already shows three of the four faults:
#  a one-line backend pool, `Restart=no`, and MIN=MAX=1 with an unreachable
#  SCALE_OUT_RPM. This mirrors the real diagnostic order in Azure: read the
#  resource configuration before you touch the workload.
#
# -----------------------------------------------------------------------------
#  STEP 1 — FAULT-2, reliability / self-healing (fix this first: it makes every
#           later step stable).
#
#  Find the override. `systemctl cat` prints the unit file AND every drop-in;
#  the last assignment wins:
#
#    $ systemctl cat az900-app@1 | tail -n 5
#    # /etc/systemd/system/az900-app@.service.d/override.conf
#    [Service]
#    # Injected by the AZ-900 1.2 break & fix lab.
#    Restart=no
#
#    $ systemctl show -p Restart --value az900-app@1
#    no
#
#  Remove the drop-in and reload the manager:
#
#    $ sudo rm -rf /etc/systemd/system/az900-app@.service.d
#    $ sudo systemctl daemon-reload
#    $ sudo systemctl restart az900-app@1
#    $ systemctl show -p Restart --value az900-app@1
#    always
#
#  Prove the repair loop works:
#
#    $ sudo systemctl kill --signal=SIGKILL az900-app@1; sleep 4
#    $ systemctl is-active az900-app@1
#    active
#
#  AZ-900 mapping: this is VMSS automatic instance repair / platform-managed
#  reliability. Without it you own the pager.
#  https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-automatic-instance-repairs
#
# -----------------------------------------------------------------------------
#  STEP 2 — FAULT-3, manageability: unblock the health probe.
#
#  First isolate the layer. The backend is healthy, the front end is not:
#
#    $ curl -s http://127.0.0.1:8081/health
#    OK node-1
#    $ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/health
#    403
#
#  A 403 from nginx with a working backend is an access rule, not an app bug:
#
#    $ cat /etc/nginx/az900-health-acl.conf
#    deny all;
#
#  Restore an allow rule for the probe source (loopback here; in Azure it is
#  the platform probe address 168.63.129.16 that your NSG must allow):
#
#    $ sudo tee /etc/nginx/az900-health-acl.conf >/dev/null <<'ACL'
#    allow 127.0.0.1;
#    allow ::1;
#    deny all;
#    ACL
#    $ sudo nginx -t && sudo systemctl reload nginx
#    nginx: configuration file /etc/nginx/nginx.conf test is successful
#
#    $ /opt/az900-lab/probe.sh
#    HEALTHY (HTTP 200)
#
#  AZ-900 mapping: a blocked probe is indistinguishable from a dead instance to
#  the load balancer — it removes the instance from rotation and you lose
#  capacity you are still paying for.
#  https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-custom-probe-overview
#
# -----------------------------------------------------------------------------
#  STEP 3 — FAULT-4, elasticity: bring the autoscale engine back.
#
#  Two independent problems: the engine is masked, and the rule can never fire.
#
#    $ systemctl is-enabled az900-autoscale.timer
#    masked
#    $ grep -v '^#' /etc/az900-lab/scale.conf
#    MIN_REPLICAS=1
#    MAX_REPLICAS=1
#    SCALE_OUT_RPM=999999
#    TICK_SECONDS=15
#
#  `masked` is a symlink to /dev/null — `systemctl start` on a masked unit fails
#  and `enable` will not resurrect it. Unmask first:
#
#    $ sudo systemctl unmask az900-autoscale.timer
#    $ sudo systemctl enable --now az900-autoscale.timer
#    $ systemctl is-active az900-autoscale.timer
#    active
#
#  Then restore an autoscale profile that can actually trigger. MIN_REPLICAS=2
#  is the availability floor (Step 4 depends on it); MAX above MIN is what makes
#  the deployment elastic; the threshold must sit inside the real traffic range:
#
#    $ sudo sed -i 's/^MIN_REPLICAS=.*/MIN_REPLICAS=2/;
#                   s/^MAX_REPLICAS=.*/MAX_REPLICAS=4/;
#                   s/^SCALE_OUT_RPM=.*/SCALE_OUT_RPM=120/' /etc/az900-lab/scale.conf
#
#  Watch one evaluation cycle:
#
#    $ sudo systemctl start az900-autoscale.service
#    $ journalctl -u az900-autoscale.service -n 3 --no-pager
#    observed=0rpm desired_replicas=2
#    backend pool updated to 2 instance(s)
#
#  AZ-900 mapping: elasticity is the benefit; scaling back in when the load
#  drops is where the cost benefit and the consumption-based pricing model
#  actually materialise.
#  https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-autoscale-overview
#
# -----------------------------------------------------------------------------
#  STEP 4 — FAULT-1, high availability: restore the backend pool.
#
#  If Step 3 is done correctly this repairs itself within one 15s tick, because
#  the autoscaler converges instances to MIN_REPLICAS and regenerates the pool:
#
#    $ sleep 20; cat /etc/nginx/az900-upstream.conf
#    server 127.0.0.1:8081 max_fails=1 fail_timeout=5s;
#    server 127.0.0.1:8082 max_fails=1 fail_timeout=5s;
#
#  Manual equivalent, if you want to do it by hand:
#
#    $ sudo systemctl start az900-app@2
#    $ sudo tee /etc/nginx/az900-upstream.conf >/dev/null <<'POOL'
#    server 127.0.0.1:8081 max_fails=1 fail_timeout=5s;
#    server 127.0.0.1:8082 max_fails=1 fail_timeout=5s;
#    POOL
#    $ sudo nginx -t && sudo systemctl reload nginx
#
#  Confirm both the spread and the failover:
#
#    $ for i in 1 2 3 4; do curl -s http://127.0.0.1:8080/; done
#    node-1
#    node-2
#    node-1
#    node-2
#
#    $ sudo systemctl stop az900-app@2
#    $ for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8080/; done; echo
#    200 200 200 200 200 200 200 200 200 200
#    $ sudo systemctl start az900-app@2
#
#  The zero-error result is `proxy_next_upstream` retrying on a healthy peer —
#  the same behaviour Azure Load Balancer gives you when a probe marks an
#  instance down. Redundancy is what makes an SLA meaningful; two instances in
#  one Availability Set are a different SLA from two across Availability Zones,
#  which is a different SLA again from a single VM.
#  https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
#
# -----------------------------------------------------------------------------
#  STEP 5 — Grade the repair.
#
#    $ sudo ./az900-1.2-break-fix.sh verify
#    [ OK ] 20 requests served by 2 distinct instances
#    [ OK ] instance 2 down, 20/20 requests still returned HTTP 200
#    [ OK ] az900-app@1 was SIGKILLed and came back automatically in 3s (Restart=always)
#    [ OK ] GET http://127.0.0.1:8080/health -> HTTP 200
#    [ OK ] scaled out to 4 instances under load; pool now: server 127.0.0.1:8081 ... 8084 ...
#      5 PASS / 0 FAIL
#
#  If CHECK-5 fails while CHECK-1..4 pass, the autoscaler is running but the
#  rule still cannot trigger. Read what it observed rather than guessing:
#
#    $ journalctl -u az900-autoscale.service -n 10 --no-pager
#    observed=232rpm desired_replicas=4
#
#  observed >= SCALE_OUT_RPM and desired still 1 means MAX_REPLICAS was never
#  raised; observed near 0 under load means the access log path or TICK_SECONDS
#  no longer matches the timer interval.
#
# -----------------------------------------------------------------------------
#  STEP 6 — Tear the lab down.
#
#    $ sudo ./az900-1.2-break-fix.sh cleanup
#
# -----------------------------------------------------------------------------
#  EXAM TAKEAWAYS (AZ-900 1.2)
#
#   * High availability is redundancy you can point at: instances in more than
#     one fault domain, published through a load balancer. An SLA number is the
#     consequence of an architecture, never a substitute for one.
#   * Fault tolerance is what the client experiences during that failure —
#     measured in failed requests, not in dashboards.
#   * Reliability includes self-healing: the platform must replace a failed
#     instance without a human. Verify the mechanism is enabled, not merely
#     documented.
#   * Scalability is capacity you *can* add; elasticity is capacity that arrives
#     and then leaves automatically. Autoscale needs an engine, a threshold that
#     can be crossed, and a maximum above the minimum — all three.
#   * Manageability includes the management plane's ability to observe the
#     workload. A healthy application that cannot answer a probe is treated as
#     down; the fault is usually a network rule, so always test the backend
#     directly before blaming the application.
#   * Governance and predictability follow from the same configuration surface:
#     every fault in this lab was one line in a declarative file, which is why
#     Azure Policy, ARM/Bicep templates and infrastructure-as-code exist.
# =============================================================================