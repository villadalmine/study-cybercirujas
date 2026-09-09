#!/usr/bin/env bash
#
# ============================================================================
#  teach-plat :: gcp-cdl - Cloud Digital Leader (exam version 2026-08-12)
#  Topic 4.3 - Describe the business value of application programming
#              interfaces (APIs)          |  Exam weight: 6.0
#
#  BREAK & FIX LAB -- "The partner integration outage"
#
#  Why a hands-on lab for a business-value objective?
#  Because the exam objective asks you to explain WHERE the value of an API
#  actually lives, and the honest answer is: not in the backend. The backend
#  is just code. The value -- reuse, monetization, partner onboarding,
#  metering, versioned contracts, rate protection -- lives in the API
#  management layer that sits in front of it (Apigee / API Gateway /
#  Cloud Endpoints on Google Cloud). This lab proves that claim the hard way:
#  you will take a 100% healthy backend and a 100% broken business, because
#  only the management layer is misconfigured.
#
#  The lab models, with free local software on one VM, the exact control
#  points an Apigee API proxy gives you:
#     API key validation      -> who is calling, and are they entitled?
#     Quota / spike arrest    -> what did they buy, and can they exceed it?
#     Versioned routing (/v1) -> the contract you promised partners
#     Backend decoupling      -> the backend never faces the internet
#
#  Official references (all free to read, no account required):
#    - Cloud Digital Leader exam guide:
#      https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#    - Apigee API management documentation:
#      https://cloud.google.com/apigee/docs
#    - API Gateway documentation:
#      https://cloud.google.com/api-gateway/docs
#    - Cloud Endpoints documentation:
#      https://cloud.google.com/endpoints/docs
#    - Google API design guide (resource-oriented, versioned contracts):
#      https://cloud.google.com/apis/design
#    - nginx map module (used here to emulate key -> developer-app lookup):
#      https://nginx.org/en/docs/http/ngx_http_map_module.html
#    - nginx limit_req module (used here to emulate an Apigee Quota policy):
#      https://nginx.org/en/docs/http/ngx_http_limit_req_module.html
#
#  SAFETY CONTRACT
#    * Runs ONLY on a disposable lab VM. It refuses to start otherwise.
#    * It creates its own files and NEVER edits pre-existing configuration:
#        /opt/apilab/                       (backend + published API contract)
#        /etc/systemd/system/apilab-backend.service
#        /etc/nginx/conf.d/apilab-gateway.conf
#        /usr/local/bin/apilab-{consumer,verify,logs}
#      Anything it would overwrite is copied to /var/backups/teach-plat first.
#    * Nothing is destroyed: no disks, no users, no firewall, no packages
#      removed. `--clean` reverses the whole lab.
#    * The three injected faults are configuration-level and reversible with
#      a text editor. No binaries are patched, no data is deleted.
#
#  USAGE
#    sudo LAB_CONFIRM=yes ./break-fix-4.3-api-business-value.sh          # break
#    sudo ./break-fix-4.3-api-business-value.sh --verify                 # grade
#    sudo ./break-fix-4.3-api-business-value.sh --clean                  # remove
#
#  The full worked solution is at the very bottom of this file, commented out.
#  Spend 20-30 minutes on the diagnosis before you scroll. The diagnosis IS
#  the exam content.
# ============================================================================

set -Eeuo pipefail

readonly LAB_ID="gcp-cdl-4.3"
readonly LAB_DIR="/opt/apilab"
readonly BACKUP_DIR="/var/backups/teach-plat/${LAB_ID}"
readonly UNIT="/etc/systemd/system/apilab-backend.service"
readonly GW_CONF="/etc/nginx/conf.d/apilab-gateway.conf"
readonly GW_URL="http://127.0.0.1:8080"
readonly BACKEND_URL="http://127.0.0.1:8081"
readonly PUBLISHED_KEY="PARTNER-KEY-7F3A9C"

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
    C_Y=$'\033[33m'; C_C=$'\033[36m'
else
    C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

hdr()  { printf '\n%s%s== %s ==%s\n' "$C_B" "$C_C" "$*" "$C_RST"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()  { printf '\n%s[fatal]%s %s\n\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

trap 'die "aborted at line $LINENO (command: ${BASH_COMMAND})"' ERR

# ----------------------------------------------------------------------------
# Guards -- this must never run on something the student cares about
# ----------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "run me as root: sudo LAB_CONFIRM=yes $0"
}

require_disposable_lab() {
    if [ -f /etc/teach-plat-lab ]; then
        return 0
    fi
    if [ "${LAB_CONFIRM:-no}" = "yes" ]; then
        printf '%s\n' "lab marker written by ${LAB_ID} on $(date -u +%FT%TZ)" \
            > /etc/teach-plat-lab
        return 0
    fi
    die "refusing to run: this host is not marked as a disposable lab VM.
       This script installs and misconfigures an nginx API gateway. Run it on a
       throwaway VM (GCE e2-micro, Multipass, Vagrant, a nested KVM guest...),
       never on a workstation or anything shared.
       If this VM IS disposable, re-run with:  sudo LAB_CONFIRM=yes $0"
}

require_free_ports() {
    command -v ss >/dev/null 2>&1 || return 0
    local busy
    busy="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(8080|8081)$' || true)"
    if [ -n "$busy" ]; then
        # ours is fine (re-run of the lab), anything else is not
        if ! systemctl is-active --quiet apilab-backend 2>/dev/null \
           && ! [ -f "$GW_CONF" ]; then
            die "ports 8080/8081 are already in use by something that is not this lab:
       $busy
       Free them or use a clean VM."
        fi
    fi
}

backup_if_exists() {
    local path="$1"
    [ -e "$path" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$path" "${BACKUP_DIR}/$(basename "$path").$(date -u +%Y%m%dT%H%M%SZ).bak"
    warn "pre-existing $path backed up under $BACKUP_DIR"
}

# ----------------------------------------------------------------------------
# Package installation (Debian/Ubuntu, RHEL/Fedora, SUSE)
# ----------------------------------------------------------------------------
install_packages() {
    hdr "Provisioning the lab host"
    local missing=()
    command -v nginx   >/dev/null 2>&1 || missing+=("nginx")
    command -v curl    >/dev/null 2>&1 || missing+=("curl")
    command -v jq      >/dev/null 2>&1 || missing+=("jq")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if [ "${#missing[@]}" -eq 0 ]; then
        ok "nginx, curl, jq and python3 already present"
        return 0
    fi

    info "installing: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${missing[@]}"
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install "${missing[@]}"
    else
        die "no supported package manager found; install manually: ${missing[*]}"
    fi
    ok "packages installed"
}

selinux_allow_proxy() {
    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce 2>/dev/null || echo Disabled)" = "Enforcing" ] || return 0
    if command -v setsebool >/dev/null 2>&1; then
        info "SELinux is Enforcing -> allowing nginx outbound connections"
        setsebool -P httpd_can_network_connect 1 || \
            warn "setsebool failed; if the gateway returns 502 with EACCES in the
       error log, that is SELinux, not the lab fault"
    fi
}

# ----------------------------------------------------------------------------
# The backend: a small, perfectly healthy inventory API.
# It is the "product" a company already owns. The API turns it into a channel.
# ----------------------------------------------------------------------------
deploy_backend() {
    hdr "Deploying the backend API (healthy, and it stays healthy)"
    mkdir -p "$LAB_DIR"

    cat > "${LAB_DIR}/backend.py" <<'PY'
#!/usr/bin/env python3
"""
apilab backend -- the system of record behind the public API.

Business framing (gcp-cdl 4.3): this process is the asset the company already
had. Wrapping it in a managed, versioned, metered API is what turns an internal
system into a product other companies can build on -- the reuse/monetization
argument in https://cloud.google.com/apigee/docs .

It listens on loopback ONLY and trusts X-Api-Client, because in this
architecture the gateway is the single front door and the only component that
authenticates callers. In a real deployment you would additionally enforce
service-to-service identity (mTLS / signed JWT), because "the network is the
perimeter" is not a security model.
"""
import json
import os
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("APILAB_BIND", "127.0.0.1")
PORT = int(os.environ.get("APILAB_PORT", "8081"))
API_VERSION = "v1"

INVENTORY = [
    {"sku": "PAL-1042", "description": "Euro pallet, heat treated", "warehouse": "MAD-01", "on_hand": 1180, "unit_price_eur": 14.50},
    {"sku": "CRT-0071", "description": "Insulated crate 60x40",     "warehouse": "MAD-01", "on_hand": 342,  "unit_price_eur": 88.00},
    {"sku": "STR-0003", "description": "Pallet strap, 5m",          "warehouse": "BCN-02", "on_hand": 9871, "unit_price_eur": 2.35},
]

ORDERS = [
    {"order_id": "ORD-88112", "sku": "PAL-1042", "qty": 120, "status": "CONFIRMED"},
    {"order_id": "ORD-88113", "sku": "STR-0003", "qty": 900, "status": "PICKING"},
]


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Handler(BaseHTTPRequestHandler):
    server_version = "apilab-backend/1.0"
    protocol_version = "HTTP/1.1"

    def _json(self, code, payload):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Backend-Api-Version", API_VERSION)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Populated by the gateway after it resolves the API key to a
        # developer app. Empty means the call did NOT come through the gateway.
        consumer = self.headers.get("X-Api-Client", "")
        path = self.path.split("?", 1)[0]

        if path in ("/healthz", "/v1/healthz"):
            self._json(200, {"status": "SERVING", "component": "backend",
                             "version": API_VERSION, "timestamp": now()})
        elif path == "/v1/inventory":
            self._json(200, {"apiVersion": API_VERSION, "consumer": consumer,
                             "timestamp": now(), "items": INVENTORY})
        elif path == "/v1/orders":
            self._json(200, {"apiVersion": API_VERSION, "consumer": consumer,
                             "timestamp": now(), "orders": ORDERS})
        else:
            self._json(404, {"error": "NOT_FOUND", "path": path,
                             "supported": ["/v1/inventory", "/v1/orders", "/healthz"]})

    def log_message(self, fmt, *args):
        sys.stderr.write("backend %s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    sys.stderr.write("backend listening on %s:%d (api %s)\n" % (BIND, PORT, API_VERSION))
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.server_close()
PY
    chmod 0755 "${LAB_DIR}/backend.py"

    # The published contract. This is the artifact the partner integrated
    # against; it is the source of truth for "what should be true".
    cat > "${LAB_DIR}/API_CONTRACT.md" <<'DOC'
# Acme Logistics Inventory API -- published contract (v1)

Product tier purchased by the partner "acme-logistics": **Silver**

| Item                | Committed value                                |
|---------------------|------------------------------------------------|
| Base URL            | http://<gateway-host>:8080                      |
| Version prefix      | /v1  (breaking changes ship as /v2, never in place) |
| Auth                | header `x-api-key: PARTNER-KEY-7F3A9C`          |
| Quota (Silver tier) | 10 requests/second, burst 20                    |
| Endpoints           | GET /v1/inventory , GET /v1/orders              |
| Availability SLO    | 99.9% monthly, measured at the gateway          |
| Unauthenticated     | HTTP 401, JSON error body                       |
| Over quota          | HTTP 429, JSON error body                       |

Every row above is a commercial promise. The exam objective (gcp-cdl 4.3)
is about exactly this: an API is a product with a contract, a price, a
consumer and a support obligation -- not a URL.

Reference: https://cloud.google.com/apis/design and
           https://cloud.google.com/apigee/docs
DOC

    backup_if_exists "$UNIT"
    cat > "$UNIT" <<'UNITEOF'
[Unit]
Description=apilab inventory backend (teach-plat gcp-cdl 4.3)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/apilab/backend.py
Environment=APILAB_BIND=127.0.0.1
Environment=APILAB_PORT=8081
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNITEOF

    systemctl daemon-reload
    systemctl enable --now apilab-backend >/dev/null 2>&1
    sleep 1
    if curl -fsS --max-time 5 "${BACKEND_URL}/healthz" >/dev/null 2>&1; then
        ok "backend is SERVING on ${BACKEND_URL} (loopback only)"
    else
        die "backend failed to start: journalctl -u apilab-backend -n 50"
    fi
}

# ----------------------------------------------------------------------------
# The gateway. This is where the damage is.
#
# The file below is deliberately written to look like a real, recently changed
# production config -- a rushed change window, plausible comments, valid syntax.
# `nginx -t` passes. Everything about it is syntactically correct and
# commercially wrong. That is the lesson.
# ----------------------------------------------------------------------------
deploy_broken_gateway() {
    hdr "Applying change request CHG-4711 to the API gateway"
    backup_if_exists "$GW_CONF"

    cat > "$GW_CONF" <<'NGINXEOF'
# ---------------------------------------------------------------------------
# Acme Logistics -- public API gateway
# Emulates the policy chain of an Apigee API proxy:
#   VerifyAPIKey -> Quota -> RouteRule(target endpoint)
#   https://cloud.google.com/apigee/docs
#
# CHG-4711  promoted from staging  (change window: last Friday, 23:40)
# Reviewer: (pending)
# ---------------------------------------------------------------------------

# --- VerifyAPIKey: API key -> developer app ---------------------------------
# Empty string means "unknown caller". Consumers are onboarded here when a
# contract is signed; this is the metering identity used for billing.
map $http_x_api_key $apilab_client {
    default                  "";
    "PARTNER-KEY-7F3A9G"     "acme-logistics";      # Silver tier
    "INTERNAL-KEY-0001"      "internal-ops";        # internal dashboards
}

# --- Quota: per developer app, refreshed continuously -----------------------
# Silver tier entitlement per the signed contract.
limit_req_zone $apilab_client zone=apilab_quota:10m rate=1r/m;

# --- Target endpoint (backend service) --------------------------------------
upstream apilab_backend {
    server 127.0.0.1:8091 max_fails=3 fail_timeout=10s;
    keepalive 16;
}

server {
    listen 8080 default_server;
    server_name _;

    default_type application/json;
    limit_req_status 429;

    access_log /var/log/nginx/apilab_access.log;
    error_log  /var/log/nginx/apilab_error.log warn;

    add_header X-Api-Gateway "apilab" always;

    # Gateway liveness. Deliberately unauthenticated: it says nothing about
    # the backend, only that the front door process is up. Note how green
    # this stays while the business is down -- pick your SLIs accordingly.
    location = /healthz {
        access_log off;
        return 200 '{"status":"ok","component":"gateway"}';
    }

    # Versioned product surface. The /v1 prefix is a commercial promise:
    # partners are entitled to a stable contract for its whole lifetime.
    location /v1/ {
        if ($apilab_client = "") {
            return 401 '{"error":"UNAUTHENTICATED","message":"missing or unknown x-api-key"}';
        }

        limit_req zone=apilab_quota;

        proxy_pass         http://apilab_backend;
        proxy_http_version 1.1;
        proxy_set_header   Connection        "";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Api-Client      $apilab_client;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_connect_timeout 2s;
        proxy_read_timeout    5s;
    }

    location / {
        return 404 '{"error":"NOT_FOUND","message":"use the versioned path /v1/"}';
    }
}
NGINXEOF

    if ! nginx -t >/dev/null 2>&1; then
        nginx -t || true
        die "nginx rejected the lab config -- report this, the lab must always
       deploy a syntactically valid file"
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    ok "gateway reloaded on ${GW_URL} (nginx -t passed -- of course it did)"
}

# ----------------------------------------------------------------------------
# Student tooling
# ----------------------------------------------------------------------------
deploy_tools() {
    hdr "Installing lab tooling"

    cat > /usr/local/bin/apilab-consumer <<'CONSEOF'
#!/usr/bin/env bash
# Simulates the partner's application calling the published API, exactly as
# documented in /opt/apilab/API_CONTRACT.md. Every failure printed here is a
# failed business transaction, not a failed ping.
set -uo pipefail
KEY="${API_KEY:-PARTNER-KEY-7F3A9C}"
GW="${GATEWAY:-http://127.0.0.1:8080}"
N="${1:-5}"
printf 'partner "acme-logistics" -> %s/v1/inventory  (%s calls, key %s)\n\n' "$GW" "$N" "$KEY"
for i in $(seq 1 "$N"); do
    body="$(mktemp)"
    code="$(curl -s -o "$body" -w '%{http_code}' --max-time 5 \
            -H "x-api-key: ${KEY}" "${GW}/v1/inventory" || echo 000)"
    printf '  call %-3s HTTP %s  %s\n' "$i" "$code" "$(head -c 120 "$body" | tr -d '\n')"
    rm -f "$body"
done
printf '\ncontract says: every one of those must be HTTP 200.\n'
CONSEOF
    chmod 0755 /usr/local/bin/apilab-consumer

    cat > /usr/local/bin/apilab-logs <<'LOGEOF'
#!/usr/bin/env bash
# One place to look at both sides of the door.
set -uo pipefail
echo "=== gateway error log (last 20) ============================"
tail -n 20 /var/log/nginx/apilab_error.log 2>/dev/null || echo "(empty)"
echo
echo "=== gateway access log (last 20) ==========================="
tail -n 20 /var/log/nginx/apilab_access.log 2>/dev/null || echo "(empty)"
echo
echo "=== backend journal (last 20) =============================="
journalctl -u apilab-backend -n 20 --no-pager 2>/dev/null || echo "(no journal)"
LOGEOF
    chmod 0755 /usr/local/bin/apilab-logs

    cat > /usr/local/bin/apilab-verify <<'VEREOF'
#!/usr/bin/env bash
# Grades the repair against the published contract, not against a diff.
# Exit 0 = the API is a working product again.
set -uo pipefail
GW="http://127.0.0.1:8080"
BE="http://127.0.0.1:8081"
KEY="PARTNER-KEY-7F3A9C"
pass=0; fail=0
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Z=$'\033[0m'; else G=""; R=""; Z=""; fi

check() { # check "<name>" <0|1>
    if [ "$2" -eq 0 ]; then printf '  %s[PASS]%s %s\n' "$G" "$Z" "$1"; pass=$((pass+1))
    else printf '  %s[FAIL]%s %s\n' "$R" "$Z" "$1"; fail=$((fail+1)); fi
}

code_for() { # code_for <url> [key]
    if [ -n "${2:-}" ]; then
        curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "x-api-key: $2" "$1" || echo 000
    else
        curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" || echo 000
    fi
}

echo
echo "gcp-cdl 4.3 -- contract verification"
echo "-------------------------------------------------------------"

nginx -t >/dev/null 2>&1; check "gateway configuration is syntactically valid" $?

systemctl is-active --quiet apilab-backend; check "backend service is running" $?

[ "$(code_for "${BE}/healthz")" = "200" ]
check "backend answers on loopback (it was never the problem)" $?

if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\[::\]|\*):8081$'
    if [ $? -eq 0 ]; then check "backend is NOT exposed directly (gateway is the only door)" 1
    else check "backend is NOT exposed directly (gateway is the only door)" 0; fi
else
    check "backend exposure check skipped (no ss binary)" 0
fi

body="$(mktemp)"
code="$(curl -s -o "$body" -w '%{http_code}' --max-time 5 -H "x-api-key: ${KEY}" "${GW}/v1/inventory" || echo 000)"
[ "$code" = "200" ]; check "GET /v1/inventory with the published key returns 200 (got $code)" $?

jq -e '.items | length >= 3' "$body" >/dev/null 2>&1
check "response carries the inventory payload (valid JSON, >=3 items)" $?

jq -e '.consumer == "acme-logistics"' "$body" >/dev/null 2>&1
check "gateway identified the caller as acme-logistics (metering intact)" $?
rm -f "$body"

bad=0
for _ in $(seq 1 20); do
    c="$(code_for "${GW}/v1/inventory" "$KEY")"
    [ "$c" = "200" ] || bad=$((bad+1))
done
[ "$bad" -eq 0 ]; check "20 consecutive contract-rate calls all succeeded ($bad failed)" $?

[ "$(code_for "${GW}/v1/inventory")" = "401" ]
check "no API key -> 401 (authentication was not removed)" $?

[ "$(code_for "${GW}/v1/inventory" "NOT-A-REAL-KEY")" = "401" ]
check "unknown API key -> 401 (unknown callers still rejected)" $?

nginx -T 2>/dev/null | grep -q 'limit_req zone=apilab_quota'
check "a quota policy is still enforced (entitlement not deleted)" $?

nginx -T 2>/dev/null | grep -q 'location /v1/'
check "the /v1 versioned contract still exists" $?

echo "-------------------------------------------------------------"
printf 'passed: %s   failed: %s\n\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    printf '%sAPI restored. The partner integration is billable again.%s\n\n' "$G" "$Z"
    exit 0
fi
printf '%sStill broken. Read the failures above against /opt/apilab/API_CONTRACT.md%s\n\n' "$R" "$Z"
exit 1
VEREOF
    chmod 0755 /usr/local/bin/apilab-verify

    ok "apilab-consumer, apilab-verify and apilab-logs installed"
}

# ----------------------------------------------------------------------------
# Briefing -- symptoms and objective, no causes
# ----------------------------------------------------------------------------
brief_student() {
    hdr "INCIDENT INC-2291 -- you are on call"

cat <<BRIEF

  ${C_B}Business context${C_RST}
  Acme Logistics sells access to its inventory data as a product. One partner
  is live on the Silver tier and calls GET /v1/inventory on every checkout in
  their storefront. The contract is published at:

      ${LAB_DIR}/API_CONTRACT.md

  Last Friday at 23:40 change CHG-4711 was promoted to the gateway. Nobody
  reviewed it. This morning the partner's integration is dead and their
  checkout falls back to "stock unknown". Every failed call is a lost order,
  and the 99.9% availability SLO is measured at the gateway, so the clock is
  running against a service credit.

  ${C_B}What you will observe${C_RST}
  1. ${C_Y}Reproduce it now:${C_RST}  apilab-consumer 5
     Right now every single call with the published key is rejected as
     unauthenticated -- HTTP 401 -- although that key has not changed and the
     partner is definitely sending it.

  2. The gateway health endpoint is ${C_G}green${C_RST}:
        curl -s ${GW_URL}/healthz
     and the backend is ${C_G}green${C_RST} too:
        curl -s ${BACKEND_URL}/healthz
     Both components report healthy while the product is 100% unavailable.
     Sit with that for a second -- it is the single most exam-relevant fact
     in this lab.

  3. This is an ${C_B}onion${C_RST}. CHG-4711 touched more than one policy, and the
     gateway evaluates them in order: authenticate, then meter, then route.
     Each layer you repair will expose the next one. Expect the symptom to
     change -- 401 first, then a mixture of 5xx and 429 -- and do NOT assume
     you have made things worse when it does. You have made progress.

  ${C_B}Your objective${C_RST}
  Restore the product to its published contract. All of the following must be
  true at the same time, and only the gateway may be modified:

    * GET /v1/inventory with x-api-key: ${PUBLISHED_KEY}  ->  HTTP 200
      with the inventory JSON, sustained over at least 20 back-to-back calls.
    * The response must still identify the caller as "acme-logistics"
      (that field is what the invoice is built from -- if it is empty you have
      broken billing while fixing availability).
    * A missing or unknown key must still return 401. Deleting the auth check
      is not a fix, it is a breach.
    * A quota policy must still exist. Deleting the entitlement is not a fix
      either; the whole tiered pricing model depends on it.
    * The backend must stay on loopback. Pointing the partner straight at
      port 8081 "for now" throws away every reason the API layer exists.

  ${C_B}Tools on the box${C_RST}
    apilab-consumer [n]   replay the partner's calls
    apilab-verify         grade yourself against the contract
    apilab-logs           gateway access/error logs + backend journal
    nginx -T              dump the effective, fully resolved configuration
    ss -ltnp              see who is actually listening, and on what

  ${C_B}Where to work${C_RST}
    ${GW_CONF}
  After every edit:  nginx -t && systemctl reload nginx

  ${C_B}Done when${C_RST}
    apilab-verify   exits 0 with 12/12 passing.

  The worked solution is commented at the bottom of this script. Diagnose
  first -- on the exam you are asked why the API layer is where the value
  and the risk concentrate, and this incident is the argument.

BRIEF
}

clean_lab() {
    hdr "Removing the lab"
    systemctl disable --now apilab-backend >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl daemon-reload
    rm -f "$GW_CONF"
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    fi
    rm -rf "$LAB_DIR"
    rm -f /usr/local/bin/apilab-consumer /usr/local/bin/apilab-verify /usr/local/bin/apilab-logs
    rm -f /var/log/nginx/apilab_access.log /var/log/nginx/apilab_error.log
    ok "lab removed. Backups (if any) kept in $BACKUP_DIR"
    info "packages (nginx, jq, curl, python3) were left installed on purpose."
}

main() {
    case "${1:-break}" in
        --verify|verify)
            exec /usr/local/bin/apilab-verify
            ;;
        --clean|clean)
            require_root
            clean_lab
            ;;
        --help|-h)
            sed -n '1,60p' "$0"
            ;;
        break|--break|"")
            require_root
            require_disposable_lab
            require_free_ports
            install_packages
            selinux_allow_proxy
            deploy_backend
            deploy_broken_gateway
            deploy_tools
            brief_student
            ;;
        *)
            die "unknown argument: $1 (use --break, --verify, --clean)"
            ;;
    esac
}

main "$@"
exit 0

# ############################################################################
# #                                                                          #
# #                    S O L U T I O N   -- do not read yet                  #
# #                                                                          #
# ############################################################################
#
# Three faults were injected by CHG-4711, all in
# /etc/nginx/conf.d/apilab-gateway.conf, all syntactically valid, all
# commercially fatal. They surface in the order nginx evaluates the policies:
# authenticate -> meter -> route.
#
# ---------------------------------------------------------------------------
# STEP 0 -- Establish what is NOT broken (2 minutes, saves an hour)
# ---------------------------------------------------------------------------
#
#   curl -s http://127.0.0.1:8081/healthz | jq .
#     {"status":"SERVING","component":"backend","version":"v1", ...}
#
#   curl -s http://127.0.0.1:8081/v1/inventory | jq '.items | length'
#     3
#
#   The backend serves correct data when called directly. Therefore the
#   outage is 100% in the API management layer. Write that down before
#   touching anything: on Google Cloud this is the difference between paging
#   the service team and paging whoever owns the Apigee proxy revision.
#
#   Also note what "healthy" meant here: both /healthz endpoints were green
#   throughout a total outage, because neither probe exercises a real business
#   transaction. A synthetic call with a real API key is the SLI that would
#   have caught this. See https://cloud.google.com/apigee/docs for the same
#   idea expressed as API proxy monitoring.
#
# ---------------------------------------------------------------------------
# FAULT 1 -- VerifyAPIKey: the onboarded key does not match the published key
# ---------------------------------------------------------------------------
#
# SYMPTOM: every call with PARTNER-KEY-7F3A9C returns
#          401 {"error":"UNAUTHENTICATED", ...}
#
# DIAGNOSIS:
#   The 401 body is produced by the gateway itself, so the request never
#   reached the backend. Confirm with the access log -- the request is there,
#   the backend journal is silent:
#
#     tail -n 5 /var/log/nginx/apilab_access.log
#       "GET /v1/inventory HTTP/1.1" 401 ...
#     journalctl -u apilab-backend -n 5 --no-pager     # nothing new
#
#   Now compare the key the contract publishes against the key the gateway
#   has onboarded:
#
#     grep -o 'PARTNER-KEY-[A-Z0-9]*' /opt/apilab/API_CONTRACT.md
#       PARTNER-KEY-7F3A9C
#     nginx -T 2>/dev/null | grep -o 'PARTNER-KEY-[A-Z0-9]*'
#       PARTNER-KEY-7F3A9G
#
#   Last character: C in the contract, G in the gateway. A one-character typo
#   during the change window revoked a paying customer.
#
# FIX:
#     sed -i 's/PARTNER-KEY-7F3A9G/PARTNER-KEY-7F3A9C/' \
#         /etc/nginx/conf.d/apilab-gateway.conf
#     nginx -t && systemctl reload nginx
#
#   Verify the layer, not the whole system:
#     curl -s -o /dev/null -w '%{http_code}\n' \
#       -H 'x-api-key: PARTNER-KEY-7F3A9C' http://127.0.0.1:8080/v1/inventory
#     -> no longer 401. Now you see 502 (first call of the minute) and 429
#        (every call after it). Both are new symptoms from deeper layers.
#
# ---------------------------------------------------------------------------
# FAULT 2 -- Quota: the Silver entitlement was written as 1r/m instead of 10r/s
# ---------------------------------------------------------------------------
#
# SYMPTOM: the first call in a minute passes the quota policy; every call
#          after it returns 429. apilab-consumer 5 shows one non-429 followed
#          by four 429s.
#
# DIAGNOSIS:
#     grep limit_req_zone /etc/nginx/conf.d/apilab-gateway.conf
#       limit_req_zone $apilab_client zone=apilab_quota:10m rate=1r/m;
#
#   The contract sells 10 requests/second with burst 20. The gateway is
#   enforcing 1 request/minute -- 600x tighter than what the customer bought.
#   Also note the policy is applied with no burst allowance at all
#   (`limit_req zone=apilab_quota;`), so even legitimate bursts are shed.
#   Confirm the rejections are policy, not failure:
#     grep -c 'limiting requests' /var/log/nginx/apilab_error.log
#
# FIX: restore the sold entitlement, and allow the contracted burst without
#      artificial queueing delay.
#
#     sed -i 's/rate=1r\/m;/rate=10r\/s;/' /etc/nginx/conf.d/apilab-gateway.conf
#     sed -i 's/limit_req zone=apilab_quota;/limit_req zone=apilab_quota burst=20 nodelay;/' \
#         /etc/nginx/conf.d/apilab-gateway.conf
#     nginx -t && systemctl reload nginx
#
#   The effective lines must now read:
#     limit_req_zone $apilab_client zone=apilab_quota:10m rate=10r/s;
#     limit_req zone=apilab_quota burst=20 nodelay;
#
#   Do NOT delete limit_req. Without a quota there is no Silver tier, no Gold
#   tier, no upsell, and one partner's retry storm becomes everyone's outage.
#   Rate limiting is not a restriction on the product -- it IS the product's
#   pricing model, and its blast-radius control.
#   Reference: https://nginx.org/en/docs/http/ngx_http_limit_req_module.html
#
#   Now every call returns 502. One fault left.
#
# ---------------------------------------------------------------------------
# FAULT 3 -- RouteRule: the target endpoint points at a port nothing listens on
# ---------------------------------------------------------------------------
#
# SYMPTOM: HTTP 502 Bad Gateway on every authenticated, in-quota call.
#
# DIAGNOSIS:
#     tail -n 3 /var/log/nginx/apilab_error.log
#       connect() failed (111: Connection refused) while connecting to
#       upstream, upstream: "http://127.0.0.1:8091/v1/inventory"
#
#     ss -ltnp | grep -E '8081|8091'
#       LISTEN 0 5 127.0.0.1:8081 ... users:(("python3",...))
#       (nothing on 8091)
#
#   The gateway is routing to 8091; the backend listens on 8081. A staging
#   port number rode along in the promotion.
#
# FIX:
#     sed -i 's/server 127.0.0.1:8091/server 127.0.0.1:8081/' \
#         /etc/nginx/conf.d/apilab-gateway.conf
#     nginx -t && systemctl reload nginx
#
# ---------------------------------------------------------------------------
# STEP 4 -- Confirm the product, not the process
# ---------------------------------------------------------------------------
#
#     apilab-consumer 10
#       call 1   HTTP 200  {"apiVersion": "v1","consumer": "acme-logistics", ...
#       ... ten times ...
#
#     curl -s -H 'x-api-key: PARTNER-KEY-7F3A9C' \
#       http://127.0.0.1:8080/v1/inventory | jq '{consumer, n: (.items|length)}'
#       { "consumer": "acme-logistics", "n": 3 }
#
#     curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/v1/inventory
#       401                                   # anonymous callers still rejected
#
#     apilab-verify
#       ... 12 PASS, 0 FAIL
#       API restored. The partner integration is billable again.
#
#   The `consumer` field is the acceptance test that matters commercially: it
#   proves the gateway still resolves the key to a developer app, which is
#   what the invoice, the quota and the usage analytics are all keyed on. A
#   "fix" that returns 200 with an empty consumer has restored availability
#   and silently destroyed metering.
#
# ---------------------------------------------------------------------------
# WHY THIS IS THE 4.3 EXAM CONTENT
# ---------------------------------------------------------------------------
#
# Every fault was one token wide, and each one destroyed a different pillar of
# the business case for APIs:
#
#   fault      pillar destroyed        business consequence
#   ---------- ---------------------- ------------------------------------------
#   key typo   controlled access,      paying partner locked out; onboarding
#              partner onboarding      and offboarding are a config change,
#                                      which is the upside AND the exposure
#   1r/m       monetization, tiering,  customer throttled 600x below what they
#              protection              bought; tiers are enforced here or nowhere
#   port 8091  decoupling, routing     the abstraction that lets you move,
#                                      rewrite or re-platform the backend
#                                      without telling partners -- the same
#                                      indirection that turns one bad line
#                                      into a total outage
#
# The positive framing the exam wants: an API turns an existing internal system
# into a reusable, meterable, independently versioned product. It creates new
# revenue channels (partners and third-party developers build on your data),
# it lets internal teams consume each other's capabilities without coupling
# their release cycles, it makes legacy systems usable by modern applications
# without rewriting them, and it produces usage data that is itself a business
# input. On Google Cloud those capabilities are delivered by Apigee for
# full-lifecycle management and monetization, API Gateway for lightweight
# serverless fronting, and Cloud Endpoints for gRPC/OpenAPI services --
# https://cloud.google.com/apigee/docs , https://cloud.google.com/api-gateway/docs ,
# https://cloud.google.com/endpoints/docs
#
# The corollary this lab exists to teach: concentrating that much business
# logic in one layer concentrates the risk there too. The backend never
# flinched, both health checks stayed green, and the company still lost every
# order for a weekend. Govern gateway changes -- review, versioned proxy
# revisions, staged rollout, and synthetic checks that carry a real API key --
# with the same seriousness as a production database migration.
#
# ---------------------------------------------------------------------------
# ONE-LINER RESET (re-break the lab to practise again)
# ---------------------------------------------------------------------------
#     sudo ./break-fix-4.3-api-business-value.sh --clean
#     sudo LAB_CONFIRM=yes ./break-fix-4.3-api-business-value.sh
# ---------------------------------------------------------------------------