#!/usr/bin/env bash
#
# =====================================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) — Domain 3, Task 3.2
#  "Define the AWS global infrastructure" — exam weight 4.25%
#
#  BREAK & FIX LAB — self-contained, offline, disposable-VM only.
#
#  This lab does NOT touch a real AWS account and spends no AWS money. It builds a
#  faithful *model* of the global infrastructure on loopback addresses:
#
#      Region          = an isolated failure domain with its own regional endpoint
#      Availability Zone = one or more discrete DCs, own power/cooling/networking,
#                          reached through a regional load balancer / target group
#      AZ name vs AZ ID = "sa-east-1a" is per-account; "sae1-az1" is physical
#      Edge location   = a separate, global caching layer in front of an origin Region
#      Data residency  = where the bytes physically sit, decided by Region choice
#
#  Everything the script mutates outside its own directory is a single marked block
#  in /etc/hosts, backed up before the first change and removed by `reset`.
#  Your real ~/.aws/config is never read or written: the lab uses its own
#  AWS_CONFIG_FILE inside the lab directory.
#
#  Official sources used for this material:
#    - CLF-C02 Exam Guide
#      https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#    - Regions and Availability Zones
#      https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
#    - AZ IDs (physical mapping, account-agnostic)
#      https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
#    - Regional service endpoints
#      https://docs.aws.amazon.com/general/latest/gr/rande.html
#    - AWS Local Zones
#      https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
#    - AWS Wavelength
#      https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
#    - AWS Outposts
#      https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
#    - Amazon CloudFront (edge locations / PoPs)
#      https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html
#    - Route 53 latency-based routing
#      https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy-latency.html
#    - Global infrastructure map
#      https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
#
#  Usage:
#      ./break-fix-3.2-global-infrastructure.sh start      # build the lab and break it
#      ./break-fix-3.2-global-infrastructure.sh brief      # re-print the mission
#      ./break-fix-3.2-global-infrastructure.sh status     # what is running, where
#      ./break-fix-3.2-global-infrastructure.sh client     # run the application
#      ./break-fix-3.2-global-infrastructure.sh az list|start <az>|stop <az>
#      ./break-fix-3.2-global-infrastructure.sh verify     # grade your fix
#      ./break-fix-3.2-global-infrastructure.sh hint [1-3]
#      ./break-fix-3.2-global-infrastructure.sh reset      # undo everything
# =====================================================================================

set -euo pipefail

LAB_ID="aws-clf-3.2"
LAB_HOME="${LAB_HOME:-$HOME/aws-clf-lab/3.2-global-infrastructure}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
DOMAIN="aws-lab.internal"
EDGE_POP="GRU50 (Sao Paulo, BR)"
HOME_REGION="sa-east-1"          # the Region this fictional company is legally bound to
MARK_BEGIN="# >>> ${LAB_ID} lab BEGIN (generated, safe to delete) >>>"
MARK_END="# <<< ${LAB_ID} lab END <<<"

# Regional endpoints: one loopback address per Region, port 8443 everywhere,
# exactly like real AWS where every Region answers on the same service port
# but on a different regional DNS name (rds.sa-east-1.amazonaws.com, ...).
REGION_IP_us_east_1="127.0.10.1"
REGION_IP_eu_west_1="127.0.20.1"
REGION_IP_sa_east_1="127.0.30.1"
EDGE_IP="127.0.99.1"
EDGE_BLACKHOLE_IP="127.0.99.254"   # nothing listens here — the injected DNS fault
SVC_PORT=8443

# Simulated client->Region round-trip times, measured from a user in Sao Paulo.
# These are the real reason Region choice is an architecture decision, not a default.
RTT_us_east_1=118
RTT_eu_west_1=196
RTT_sa_east_1=14

# region|region_name|az_name|az_id|port|jurisdiction|service_ms
AZ_TABLE=(
  "us-east-1|US East (N. Virginia)|us-east-1a|use1-az4|8411|US|3"
  "us-east-1|US East (N. Virginia)|us-east-1b|use1-az6|8412|US|3"
  "eu-west-1|Europe (Ireland)|eu-west-1a|euw1-az1|8421|EU|3"
  "eu-west-1|Europe (Ireland)|eu-west-1b|euw1-az2|8422|EU|3"
  "sa-east-1|South America (Sao Paulo)|sa-east-1a|sae1-az1|8431|BR|3"
  "sa-east-1|South America (Sao Paulo)|sa-east-1b|sae1-az2|8432|BR|3"
  "sa-east-1|South America (Sao Paulo)|sa-east-1c|sae1-az3|8433|BR|3"
)
REGIONS=("us-east-1" "eu-west-1" "sa-east-1")

SUDO=""
[[ ${EUID} -ne 0 ]] && SUDO="sudo"

C_RESET=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
C_Y=$'\033[33m';   C_C=$'\033[36m'; C_D=$'\033[2m'

hr()   { printf '%s\n' "${C_D}$(printf '=%.0s' $(seq 1 84))${C_RESET}"; }
say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C_C}[lab]${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_G}[ ok ]${C_RESET} $*"; }
warn() { printf '%s\n' "${C_Y}[warn]${C_RESET} $*"; }
fail() { printf '%s\n' "${C_R}[fail]${C_RESET} $*"; }
die()  { fail "$*"; exit 1; }

# -------------------------------------------------------------------------------------
# Guards. This script edits /etc/hosts and starts listeners. Lab VM only.
# -------------------------------------------------------------------------------------
require_tools() {
  local missing=()
  for t in python3 curl sed awk grep; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing required tools: ${missing[*]}"
  if [[ -n "$SUDO" ]] && ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required to edit ${HOSTS_FILE} (or run this script as root)"
  fi
}

confirm_disposable() {
  [[ "${LAB_CONFIRM:-}" == "yes" ]] && return 0
  hr
  say "${C_B}This lab modifies ${HOSTS_FILE} (one marked block) and starts local listeners"
  say "on 127.0.0.0/8 ports 8411-8433 and 8443. Run it ONLY on a disposable lab VM.${C_RESET}"
  say "Everything is reverted by: $0 reset"
  hr
  read -r -p "Type 'lab' to continue: " answer
  [[ "$answer" == "lab" ]] || die "aborted by the student — nothing was changed"
}

# -------------------------------------------------------------------------------------
# Lab asset generation
# -------------------------------------------------------------------------------------
region_ip() {
  case "$1" in
    us-east-1) echo "$REGION_IP_us_east_1" ;;
    eu-west-1) echo "$REGION_IP_eu_west_1" ;;
    sa-east-1) echo "$REGION_IP_sa_east_1" ;;
    *) die "unknown region: $1" ;;
  esac
}

region_rtt() {
  case "$1" in
    us-east-1) echo "$RTT_us_east_1" ;;
    eu-west-1) echo "$RTT_eu_west_1" ;;
    sa-east-1) echo "$RTT_sa_east_1" ;;
    *) die "unknown region: $1" ;;
  esac
}

write_assets() {
  mkdir -p "$LAB_HOME"/{bin,run,logs,backups,app,edge,aws}
  for r in "${REGIONS[@]}"; do mkdir -p "$LAB_HOME/regions/$r"; done

  cat > "$LAB_HOME/bin/az_node.py" <<'PY'
#!/usr/bin/env python3
"""One process = one EC2 instance in one Availability Zone.

It advertises both identifiers that matter in production:
  * ZoneName ("sa-east-1a")  -> account-scoped label, randomized per account
  * ZoneId   ("sae1-az1")    -> the physical zone, identical across all accounts
See https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

P = argparse.ArgumentParser()
P.add_argument("--region", required=True)
P.add_argument("--region-name", required=True)
P.add_argument("--az-name", required=True)
P.add_argument("--az-id", required=True)
P.add_argument("--jurisdiction", required=True)
P.add_argument("--bind", default="127.0.0.1")
P.add_argument("--port", type=int, required=True)
P.add_argument("--service-ms", type=int, default=3)
A = P.parse_args()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "lab-az-node/1.0"

    def log_message(self, fmt, *args):  # keep the student's console clean
        pass

    def reply(self, code, payload):
        body = (json.dumps(payload, indent=2) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Amz-Lab-Region", A.region)
        self.send_header("X-Amz-Lab-Az-Name", A.az_name)
        self.send_header("X-Amz-Lab-Az-Id", A.az_id)
        self.send_header("X-Amz-Lab-Jurisdiction", A.jurisdiction)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            self.reply(200, {"status": "healthy", "az_id": A.az_id})
            return
        time.sleep(A.service_ms / 1000.0)
        self.reply(200, {
            "service": "orders-api",
            "region": A.region,
            "region_name": A.region_name,
            "availability_zone": A.az_name,
            "availability_zone_id": A.az_id,
            "data_jurisdiction": A.jurisdiction,
            "orders": [
                {"id": "o-1001", "customer_country": "BR", "total_brl": 149.90},
                {"id": "o-1002", "customer_country": "BR", "total_brl": 89.50},
            ],
        })


ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer((A.bind, A.port), Handler).serve_forever()
PY

  cat > "$LAB_HOME/bin/region_router.py" <<'PY'
#!/usr/bin/env python3
"""Mock regional service endpoint: one ELB + one target group, per Region.

Two properties of the real thing are reproduced on purpose:
  1. A load balancer and its target group are REGIONAL objects. They can only
     register targets inside their own Region, across that Region's AZs.
  2. If every registered target fails its health check, the endpoint answers
     503 - it does not silently spill traffic into another Region.
The target list is re-read on every request, so registering a target takes
effect immediately (the analogue of `aws elbv2 register-targets`).
"""
import argparse
import itertools
import json
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

P = argparse.ArgumentParser()
P.add_argument("--region", required=True)
P.add_argument("--region-name", required=True)
P.add_argument("--bind", required=True)
P.add_argument("--port", type=int, default=8443)
P.add_argument("--targets-file", required=True)
P.add_argument("--rtt-ms", type=int, default=10)
A = P.parse_args()

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
COUNTER = itertools.count()
LOCK = threading.Lock()


def read_targets():
    targets = []
    try:
        with open(A.targets_file) as handle:
            for line in handle:
                line = line.split("#", 1)[0].strip()
                if line:
                    targets.append(line)
    except FileNotFoundError:
        pass
    return targets


def healthy(target):
    try:
        with OPENER.open("http://%s/health" % target, timeout=0.5) as resp:
            return resp.status == 200
    except Exception:
        return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "lab-elb/1.0"

    def log_message(self, fmt, *args):
        pass

    def raw_reply(self, code, body, headers):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Amz-Lab-Endpoint", "orders.%s.%s" % (A.region, "aws-lab.internal"))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        time.sleep(A.rtt_ms / 2000.0)  # client -> Region leg
        states = [(t, healthy(t)) for t in read_targets()]
        alive = [t for t, up in states if up]
        if not alive:
            payload = {
                "error": "ServiceUnavailable",
                "message": ("no healthy targets registered in %s (%s) for target group "
                            "tg-orders" % (A.region, A.region_name)),
                "target_health": [
                    {"target": t, "state": "healthy" if up else "unhealthy"} for t, up in states
                ],
                "hint": "an Availability Zone is a failure domain; a target group that "
                        "lives in only one AZ inherits that AZ's blast radius",
            }
            body = (json.dumps(payload, indent=2) + "\n").encode()
            time.sleep(A.rtt_ms / 2000.0)
            self.raw_reply(503, body, {"X-Amz-Lab-Region": A.region})
            return

        with LOCK:
            target = alive[next(COUNTER) % len(alive)]
        try:
            with OPENER.open("http://%s%s" % (target, self.path), timeout=3) as resp:
                body = resp.read()
                headers = {k: v for k, v in resp.headers.items()
                           if k.lower().startswith("x-amz-lab")}
                code = resp.status
        except Exception as exc:  # target died mid-flight
            body = (json.dumps({"error": "BadGateway", "detail": str(exc)}) + "\n").encode()
            headers = {"X-Amz-Lab-Region": A.region}
            code = 502
        headers["X-Amz-Lab-Target"] = target
        time.sleep(A.rtt_ms / 2000.0)  # Region -> client leg
        self.raw_reply(code, body, headers)


ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer((A.bind, A.port), Handler).serve_forever()
PY

  cat > "$LAB_HOME/bin/edge_node.py" <<'PY'
#!/usr/bin/env python3
"""Mock CloudFront edge location (point of presence).

An edge location is NOT a Region: it holds no durable customer data, it runs no
EC2 instances, and it is reached through a single global DNS name. It terminates
the connection close to the user and pulls from a regional origin on a cache miss.
https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html
"""
import argparse
import json
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

P = argparse.ArgumentParser()
P.add_argument("--pop", required=True)
P.add_argument("--bind", required=True)
P.add_argument("--port", type=int, default=8443)
P.add_argument("--origin-file", required=True)
P.add_argument("--ttl", type=int, default=30)
P.add_argument("--edge-ms", type=int, default=4)
A = P.parse_args()

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
CACHE = {}
LOCK = threading.Lock()


def origin():
    with open(A.origin_file) as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if line.startswith("origin="):
                return line.split("=", 1)[1].strip()
    raise RuntimeError("no origin= line in %s" % A.origin_file)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "lab-cloudfront/1.0"

    def log_message(self, fmt, *args):
        pass

    def emit(self, code, body, headers):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Amz-Cf-Pop", A.pop)
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        time.sleep(A.edge_ms / 1000.0)
        now = time.monotonic()
        with LOCK:
            entry = CACHE.get(self.path)
        if entry and entry[0] > now:
            _, code, body, headers = entry
            headers = dict(headers, **{"X-Cache": "Hit from lab-edge"})
            self.emit(code, body, headers)
            return
        try:
            with OPENER.open("http://%s%s" % (origin(), self.path), timeout=5) as resp:
                body = resp.read()
                headers = {k: v for k, v in resp.headers.items()
                           if k.lower().startswith("x-amz-lab")}
                code = resp.status
        except Exception as exc:
            payload = {
                "error": "OriginUnreachable",
                "message": "The request could not be satisfied. The edge location "
                           "could not connect to the origin.",
                "origin_error": str(exc),
            }
            self.emit(502, (json.dumps(payload, indent=2) + "\n").encode(),
                      {"X-Cache": "Error from lab-edge"})
            return
        if code == 200:
            with LOCK:
                CACHE[self.path] = (now + A.ttl, code, body, headers)
        headers = dict(headers, **{"X-Cache": "Miss from lab-edge"})
        self.emit(code, body, headers)


ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer((A.bind, A.port), Handler).serve_forever()
PY

  # The "application": a client SDK pinned to whatever Region its config says.
  cat > "$LAB_HOME/app/orders-client.sh" <<'SH'
#!/usr/bin/env bash
# Minimal client. Like every AWS SDK, it builds a REGIONAL endpoint from the
# configured Region and talks to that endpoint only.
set -uo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$APP_DIR/app.env"
PATH_REQ="${1:-/orders}"
if [[ "${USE_EDGE:-no}" == "yes" ]]; then
  URL="http://edge.aws-lab.internal:8443${PATH_REQ}"
else
  URL="http://orders.${AWS_REGION}.aws-lab.internal:8443${PATH_REQ}"
fi
echo "endpoint: $URL"
curl -sS --noproxy '*' -m 10 -D /tmp/orders-client.hdr -w '\n--- http %{http_code} in %{time_total}s ---\n' "$URL"
grep -iE '^(x-amz-lab-|x-amz-cf-pop|x-cache)' /tmp/orders-client.hdr || true
SH
  chmod +x "$LAB_HOME/app/orders-client.sh"

  cat > "$LAB_HOME/edge/origin.conf" <<EOF
# CloudFront-style origin for distribution E1LABGLOBAL.
# The edge caches from ONE regional origin; the origin is where the data lives.
origin=orders.${HOME_REGION}.${DOMAIN}:${SVC_PORT}
EOF

  cat > "$LAB_HOME/README-lab.txt" <<EOF
Files you may need to edit while fixing this lab:
  ${LAB_HOME}/app/app.env                        client Region pinning
  ${LAB_HOME}/aws/config                         lab-only AWS CLI profile (AWS_CONFIG_FILE)
  ${LAB_HOME}/regions/<region>/target-group.txt  registered targets, one host:port per line
  ${HOSTS_FILE}                                  DNS records for the lab (marked block)
Fleet control: $0 az list | az start <az-name> | az stop <az-name>
EOF
}

write_target_groups() {
  # Healthy baseline: every Region serves from all of its AZs.
  for r in "${REGIONS[@]}"; do
    local file="$LAB_HOME/regions/$r/target-group.txt"
    {
      echo "# target group tg-orders (${r}) - one host:port per line"
      echo "# A target group is REGIONAL: only targets in ${r} may be registered."
      for record in "${AZ_TABLE[@]}"; do
        IFS='|' read -r reg _rn az _id port _j _s <<<"$record"
        [[ "$reg" == "$r" ]] && echo "127.0.0.1:${port}   # ${az}"
      done
    } > "$file"
  done
}

# -------------------------------------------------------------------------------------
# /etc/hosts management (the only change outside $LAB_HOME)
# -------------------------------------------------------------------------------------
hosts_block() {
  local edge_ip="$1"
  {
    echo "$MARK_BEGIN"
    echo "# Regional endpoints - one DNS name per Region, exactly like AWS."
    for r in "${REGIONS[@]}"; do
      printf '%-14s orders.%s.%s\n' "$(region_ip "$r")" "$r" "$DOMAIN"
    done
    echo "# Global/edge endpoint - resolved by Route 53 to the nearest PoP."
    printf '%-14s edge.%s\n' "$edge_ip" "$DOMAIN"
    echo "$MARK_END"
  }
}

hosts_remove_block() {
  [[ -f "$LAB_HOME/backups/hosts.original" ]] || \
    $SUDO cp -a "$HOSTS_FILE" "$LAB_HOME/backups/hosts.original"
  $SUDO cp -a "$HOSTS_FILE" "$LAB_HOME/backups/hosts.$(date +%Y%m%d-%H%M%S)"
  $SUDO sed -i "/^# >>> ${LAB_ID} lab BEGIN/,/^# <<< ${LAB_ID} lab END/d" "$HOSTS_FILE"
}

hosts_install() {
  local edge_ip="$1" tmp
  mkdir -p "$LAB_HOME/backups"
  hosts_remove_block
  tmp="$(mktemp)"
  hosts_block "$edge_ip" > "$tmp"
  $SUDO tee -a "$HOSTS_FILE" < "$tmp" >/dev/null
  rm -f "$tmp"
}

# -------------------------------------------------------------------------------------
# Process control
# -------------------------------------------------------------------------------------
pidfile() { echo "$LAB_HOME/run/$1.pid"; }

is_up() {
  local name="$1" pf; pf="$(pidfile "$name")"
  [[ -f "$pf" ]] || return 1
  local pid; pid="$(cat "$pf" 2>/dev/null || echo 0)"
  [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]] || return 1
  [[ -d "/proc/$pid" ]] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$LAB_HOME" || return 1
  return 0
}

start_bg() {
  local name="$1"; shift
  is_up "$name" && return 0
  nohup "$@" >>"$LAB_HOME/logs/$name.log" 2>&1 &
  echo $! > "$(pidfile "$name")"
}

stop_bg() {
  local name="$1" pf pid
  pf="$(pidfile "$name")"
  if is_up "$name"; then
    pid="$(cat "$pf")"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do [[ -d "/proc/$pid" ]] || break; sleep 0.1; done
    [[ -d "/proc/$pid" ]] && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pf"
}

wait_port() {
  local ip="$1" port="$2" tries="${3:-60}"
  for _ in $(seq 1 "$tries"); do
    if (exec 3<>"/dev/tcp/${ip}/${port}") 2>/dev/null; then exec 3>&- ; return 0; fi
    sleep 0.1
  done
  return 1
}

start_az() {
  local az_name="$1" found=0
  for record in "${AZ_TABLE[@]}"; do
    IFS='|' read -r reg rname az azid port juris svcms <<<"$record"
    [[ "$az" == "$az_name" ]] || continue
    found=1
    start_bg "az-$az" python3 "$LAB_HOME/bin/az_node.py" \
      --region "$reg" --region-name "$rname" --az-name "$az" --az-id "$azid" \
      --jurisdiction "$juris" --bind 127.0.0.1 --port "$port" --service-ms "$svcms"
    wait_port 127.0.0.1 "$port" || die "AZ node $az failed to listen on port $port"
  done
  [[ $found -eq 1 ]] || die "unknown Availability Zone: $az_name"
}

start_fleet() {
  for record in "${AZ_TABLE[@]}"; do
    IFS='|' read -r _reg _rn az _id _p _j _s <<<"$record"
    start_az "$az"
  done
  for r in "${REGIONS[@]}"; do
    local ip; ip="$(region_ip "$r")"
    local rname="South America (Sao Paulo)"
    [[ "$r" == "us-east-1" ]] && rname="US East (N. Virginia)"
    [[ "$r" == "eu-west-1" ]] && rname="Europe (Ireland)"
    start_bg "elb-$r" python3 "$LAB_HOME/bin/region_router.py" \
      --region "$r" --region-name "$rname" --bind "$ip" --port "$SVC_PORT" \
      --targets-file "$LAB_HOME/regions/$r/target-group.txt" --rtt-ms "$(region_rtt "$r")"
    wait_port "$ip" "$SVC_PORT" || die "regional endpoint for $r failed to start"
  done
  start_bg "edge" python3 "$LAB_HOME/bin/edge_node.py" \
    --pop "$EDGE_POP" --bind "$EDGE_IP" --port "$SVC_PORT" \
    --origin-file "$LAB_HOME/edge/origin.conf" --ttl 30
  wait_port "$EDGE_IP" "$SVC_PORT" || die "edge location failed to start"
}

stop_fleet() {
  for record in "${AZ_TABLE[@]}"; do
    IFS='|' read -r _reg _rn az _id _p _j _s <<<"$record"
    stop_bg "az-$az"
  done
  for r in "${REGIONS[@]}"; do stop_bg "elb-$r"; done
  stop_bg "edge"
}

# -------------------------------------------------------------------------------------
# Probing helpers
# -------------------------------------------------------------------------------------
probe() {
  # probe <url> -> "<http_code> <seconds> <region> <az_id> <jurisdiction> <cache>"
  local url="$1" hdr code_time code tt region az juris cache
  hdr="$(mktemp)"
  code_time="$(curl -s -o /dev/null --noproxy '*' -m 8 -D "$hdr" \
                 -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)"
  code="$(awk '{print $1}' <<<"${code_time:-000 0}")"
  tt="$(awk '{print $2}' <<<"${code_time:-000 0}")"
  region="$(grep -i '^x-amz-lab-region:' "$hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}' || true)"
  az="$(grep -i '^x-amz-lab-az-id:' "$hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}' || true)"
  juris="$(grep -i '^x-amz-lab-jurisdiction:' "$hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}' || true)"
  cache="$(grep -i '^x-cache:' "$hdr" 2>/dev/null | tr -d '\r' | cut -d' ' -f2- || true)"
  rm -f "$hdr"
  echo "${code:-000} ${tt:-0} ${region:--} ${az:--} ${juris:--} ${cache:--}"
}

cfg_get() { # cfg_get <key> from app.env
  grep -E "^$1=" "$LAB_HOME/app/app.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'
}

aws_cfg_region() {
  awk '/^\[profile clf-lab\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*region[[:space:]]*=/{
        sub(/^[^=]*=[[:space:]]*/,"");print;exit}' "$LAB_HOME/aws/config" 2>/dev/null
}

hosts_edge_ip() {
  grep -E "[[:space:]]edge\.${DOMAIN}([[:space:]]|$)" "$HOSTS_FILE" 2>/dev/null \
    | grep -v '^#' | tail -1 | awk '{print $1}'
}

# -------------------------------------------------------------------------------------
# THE BREAK
# -------------------------------------------------------------------------------------
break_it() {
  # ---- Fault 1: the client is pinned to the wrong Region -----------------------------
  # A single misconfigured Region moves both latency and data residency. The call
  # still succeeds, which is exactly why this class of bug reaches production.
  cat > "$LAB_HOME/app/app.env" <<EOF
# orders-api client configuration (deployed by CI on 2026-09-01)
AWS_REGION=eu-west-1
USE_EDGE=no
EOF
  cat > "$LAB_HOME/aws/config" <<'EOF'
[profile clf-lab]
region = eu-west-1
output = json
EOF

  # ---- Fault 2: sa-east-1 is a single-AZ deployment, and that AZ is impaired ---------
  cat > "$LAB_HOME/regions/${HOME_REGION}/target-group.txt" <<EOF
# target group tg-orders (${HOME_REGION}) - one host:port per line
# A target group is REGIONAL: only targets in ${HOME_REGION} may be registered.
127.0.0.1:8431   # sa-east-1a
EOF
  stop_bg "az-sa-east-1a"

  # ---- Fault 3: the global (edge) DNS record points at a black hole ------------------
  hosts_install "$EDGE_BLACKHOLE_IP"
}

# -------------------------------------------------------------------------------------
# Briefing / status / hints / verification
# -------------------------------------------------------------------------------------
briefing() {
  hr
  say "${C_B}AWS CLF-C02 - Task 3.2: Define the AWS global infrastructure (4.25% of the exam)${C_RESET}"
  say "${C_B}BREAK & FIX: 'ordersapi' after a botched multi-Region rollout${C_RESET}"
  hr
  cat <<EOF
SCENARIO
  You run 'orders-api' for a Brazilian retailer. Contractually and by regulation,
  customer order data must stay in Brazil, so the home Region is ${HOME_REGION}
  (South America, Sao Paulo). A global endpoint fronted by an edge location serves
  the read path. Last night's rollout changed three things and nobody noticed until
  the pager fired.

  The lab is a faithful model of the real topology, on loopback only:

    edge.${DOMAIN}:${SVC_PORT}          edge location ${EDGE_POP}
        |  cache miss -> origin
    orders.<region>.${DOMAIN}:${SVC_PORT}  regional endpoint (ELB + target group)
        |  round-robin across registered targets
    AZ nodes 127.0.0.1:84xx                one process per Availability Zone

    Region       AZs available in the lab            RTT from Sao Paulo
    us-east-1    us-east-1a(use1-az4) us-east-1b(use1-az6)   ~${RTT_us_east_1} ms
    eu-west-1    eu-west-1a(euw1-az1) eu-west-1b(euw1-az2)   ~${RTT_eu_west_1} ms
    sa-east-1    sa-east-1a(sae1-az1) sa-east-1b(sae1-az2) sa-east-1c(sae1-az3)  ~${RTT_sa_east_1} ms

SYMPTOMS YOU WILL SEE
  1. The application answers, but slowly (hundreds of ms) and the payload reports
     "region": "eu-west-1", "data_jurisdiction": "EU" for BR customer orders.
         \$ "$LAB_HOME/app/orders-client.sh"
  2. As soon as the client points at ${HOME_REGION} you will get:
         HTTP 503  "no healthy targets registered in ${HOME_REGION} ... tg-orders"
     because the Region is serving from a single AZ and that AZ is impaired.
  3. The global endpoint is dead at the DNS layer:
         \$ curl -sS --noproxy '*' http://edge.${DOMAIN}:${SVC_PORT}/orders
         curl: (7) Failed to connect to edge.${DOMAIN} port ${SVC_PORT}: Connection refused
     The regional endpoints resolve fine - only the edge record is wrong.

YOUR OBJECTIVE (all five must hold)
  [1] The client, and the lab AWS CLI profile, are pinned to ${HOME_REGION}.
  [2] Requests are served from ${HOME_REGION} with jurisdiction BR, in < 60 ms.
  [3] ${HOME_REGION} serves from at least TWO distinct Availability Zone IDs
      (10 consecutive requests must show >= 2 different AZ IDs).
  [4] Every target registered in the ${HOME_REGION} target group is a
      ${HOME_REGION} AZ - a target group cannot span Regions.
  [5] The global endpoint edge.${DOMAIN} answers 200 and reports a cache
      Hit from lab-edge on the second identical request.

TOOLS AT YOUR DISPOSAL
  $0 status              what is listening, what DNS says, what the config says
  $0 client              run the application once
  $0 az list             fleet inventory with per-AZ state
  $0 az start <az-name>  bring an Availability Zone back (e.g. sa-east-1b)
  $0 az stop  <az-name>  take one down
  $0 verify              grade yourself; exit code 0 means fixed
  $0 hint 1|2|3          progressive hints
  $0 reset               undo the lab completely
  Editable files:        $LAB_HOME/app/app.env
                         $LAB_HOME/aws/config
                         $LAB_HOME/regions/${HOME_REGION}/target-group.txt
                         ${HOSTS_FILE}  (marked block, needs sudo)

REAL AWS COMMANDS THIS LAB IS MODELLING (run these against a real account later)
  # Which Regions exist, and which are opt-in (disabled until you enable them)?
  \$ aws ec2 describe-regions --all-regions \\
        --query 'Regions[?OptInStatus==\`not-opted-in\`].RegionName' --output text
  af-south-1  ap-east-1  ap-south-2  eu-south-2  me-central-1  ...

  # Which AZs does a Region have, and what are their PHYSICAL ids?
  \$ aws ec2 describe-availability-zones --region ${HOME_REGION} \\
        --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,State]' --output text
  sa-east-1a   sae1-az1   availability-zone   available
  sa-east-1b   sae1-az2   availability-zone   available
  sa-east-1c   sae1-az3   availability-zone   available
  # ZoneName is per-account; ZoneId is not. Two accounts sharing a subnet must
  # compare ZoneIds, never ZoneNames.

  # Local Zones and Wavelength Zones are opt-in extensions of a parent Region:
  \$ aws ec2 describe-availability-zones --region us-west-2 --all-availability-zones \\
        --filters Name=zone-type,Values=local-zone \\
        --query 'AvailabilityZones[].[ZoneName,ZoneId,ParentZoneName,OptInStatus]' --output text
  us-west-2-lax-1a   usw2-lax1-az1   us-west-2   not-opted-in
  us-west-2-lax-1b   usw2-lax1-az2   us-west-2   not-opted-in

  # Where does this instance actually live? (IMDSv2)
  \$ TOKEN=\$(curl -sX PUT http://169.254.169.254/latest/api/token \\
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
  \$ curl -s -H "X-aws-ec2-metadata-token: \$TOKEN" \\
        http://169.254.169.254/latest/meta-data/placement/availability-zone-id
  sae1-az1

  # Where does an S3 bucket's data live? (us-east-1 famously returns null)
  \$ aws s3api get-bucket-location --bucket orders-br-prod
  { "LocationConstraint": "sa-east-1" }

  # Which Region is my CLI actually using?
  \$ aws configure get region --profile clf-lab
  sa-east-1
  # Precedence: --region flag > AWS_REGION env > profile config > no default.

  # Edge layer inventory (CloudFront is global; --region is ignored for it):
  \$ aws cloudfront list-distributions \\
        --query 'DistributionList.Items[].[Id,DomainName,PriceClass,Status]' --output text
  E1LABGLOBAL   d111111abcdef8.cloudfront.net   PriceClass_All   Deployed

EXAM ANGLE
  Region       = geographic area, >= 3 AZs, isolated failure and pricing domain,
                 data does not leave it unless you replicate it explicitly.
  AZ           = one or more discrete DCs, independent power/cooling/network,
                 single-digit-ms latency between AZs of a Region.
  Local Zone   = latency-sensitive compute close to a metro, parent Region attached.
  Wavelength   = infrastructure inside a telco 5G network, for mobile-edge latency.
  Outposts     = AWS-managed racks in YOUR data centre, for residency and hybrid.
  Edge/PoP     = CloudFront, Global Accelerator, Route 53 - global, cache/route only.
  Selection criteria: compliance/data residency, latency to users, service
  availability in that Region, and price (which differs per Region).
EOF
  hr
}

status() {
  hr
  say "${C_B}Fleet${C_RESET}"
  printf '  %-14s %-14s %-10s %-20s %s\n' REGION AZ-NAME AZ-ID ENDPOINT STATE
  for record in "${AZ_TABLE[@]}"; do
    IFS='|' read -r reg _rn az azid port _j _s <<<"$record"
    local state="${C_R}stopped${C_RESET}"
    is_up "az-$az" && state="${C_G}running${C_RESET}"
    printf '  %-14s %-14s %-10s %-20s %b\n' "$reg" "$az" "$azid" "127.0.0.1:$port" "$state"
  done
  say ""
  say "${C_B}Regional endpoints${C_RESET}"
  for r in "${REGIONS[@]}"; do
    local st="${C_R}down${C_RESET}"
    is_up "elb-$r" && st="${C_G}up${C_RESET}"
    printf '  %-14s %-18s targets=%s  %b\n' "$r" "$(region_ip "$r"):$SVC_PORT" \
      "$(grep -cvE '^\s*(#|$)' "$LAB_HOME/regions/$r/target-group.txt" 2>/dev/null || echo 0)" "$st"
  done
  local est="${C_R}down${C_RESET}"; is_up "edge" && est="${C_G}up${C_RESET}"
  printf '  %-14s %-18s pop=%s  %b\n' "edge" "$EDGE_IP:$SVC_PORT" "$EDGE_POP" "$est"
  say ""
  say "${C_B}Configuration${C_RESET}"
  printf '  app.env AWS_REGION        : %s\n' "$(cfg_get AWS_REGION)"
  printf '  aws/config [clf-lab]      : %s\n' "$(aws_cfg_region)"
  printf '  edge.%s DNS  : %s (live edge listens on %s)\n' "$DOMAIN" \
    "$(hosts_edge_ip)" "$EDGE_IP"
  say ""
  say "${C_B}Live probes${C_RESET}"
  local p
  for r in "${REGIONS[@]}"; do
    p="$(probe "http://orders.${r}.${DOMAIN}:${SVC_PORT}/orders")"
    printf '  %-14s http=%s time=%ss region=%s az=%s jur=%s\n' "$r" $p
  done
  p="$(probe "http://edge.${DOMAIN}:${SVC_PORT}/orders")"
  printf '  %-14s http=%s time=%ss region=%s az=%s jur=%s cache=%s\n' "edge" $p
  hr
}

hint() {
  case "${1:-1}" in
    1) say "HINT 1/3 - Follow the request, do not guess."
       say "  The payload tells you which Region and which AZ served it. Compare that"
       say "  with where the data is legally required to be. Ask the client what Region"
       say "  it was configured with, and remember there is more than one place a Region"
       say "  can be pinned (application config, SDK profile, environment variable)." ;;
    2) say "HINT 2/3 - 503 is progress, not a regression."
       say "  Once you point at the home Region you are hitting a target group whose"
       say "  registered targets are all in a single AZ. An AZ is a failure domain: if"
       say "  the deployment only lives in one, the Region's availability is that AZ's"
       say "  availability. You need capacity in >= 2 AZs AND both registered."
       say "  Look at: $LAB_HOME/regions/${HOME_REGION}/target-group.txt"
       say "  and at:  $0 az list" ;;
    3) say "HINT 3/3 - The edge is not a Region."
       say "  The regional names resolve correctly; only edge.${DOMAIN} does not."
       say "  Compare the address in the ${LAB_ID} block of ${HOSTS_FILE} with the address"
       say "  the edge process is actually bound to ($0 status). Fix the record, then"
       say "  request the same path twice: the second one must be a cache Hit." ;;
    *) say "hints are 1, 2 or 3" ;;
  esac
}

verify() {
  local pass=0 fail=0
  check() { # check <label> <condition-result> <detail>
    if [[ "$2" == "0" ]]; then ok "$1"; pass=$((pass+1));
    else fail "$1 -> $3"; fail=$((fail+1)); fi
  }
  hr; say "${C_B}Grading Task 3.2${C_RESET}"; hr

  # [1] Region pinning
  local app_region cli_region rc
  app_region="$(cfg_get AWS_REGION)"; cli_region="$(aws_cfg_region)"
  [[ "$app_region" == "$HOME_REGION" && "$cli_region" == "$HOME_REGION" ]] && rc=0 || rc=1
  check "[1] client and CLI profile pinned to ${HOME_REGION}" "$rc" \
        "app.env=${app_region:-unset} aws/config=${cli_region:-unset}"

  # [2] Served from the home Region, in-jurisdiction, low latency
  local p code tt region az juris
  read -r code tt region az juris _ <<<"$(probe "http://orders.${HOME_REGION}.${DOMAIN}:${SVC_PORT}/orders")"
  [[ "$code" == "200" && "$region" == "$HOME_REGION" && "$juris" == "BR" ]] && rc=0 || rc=1
  check "[2a] ${HOME_REGION} endpoint returns 200 with jurisdiction BR" "$rc" \
        "http=$code region=${region} jurisdiction=${juris}"
  awk -v t="$tt" 'BEGIN{exit !(t < 0.060)}' && rc=0 || rc=1
  check "[2b] latency under 60 ms (in-Region user)" "$rc" "measured ${tt}s"

  # [3] Multi-AZ: at least two distinct physical zone IDs answer
  local seen=() i azid
  for i in $(seq 1 10); do
    read -r _ _ _ azid _ _ <<<"$(probe "http://orders.${HOME_REGION}.${DOMAIN}:${SVC_PORT}/orders")"
    [[ "$azid" != "-" && -n "$azid" ]] && seen+=("$azid")
  done
  local distinct
  distinct="$(printf '%s\n' "${seen[@]:-}" | sort -u | grep -c . || true)"
  [[ "${distinct:-0}" -ge 2 ]] && rc=0 || rc=1
  check "[3] ${HOME_REGION} serves from >= 2 Availability Zone IDs" "$rc" \
        "distinct AZ IDs observed: ${distinct:-0} ($(printf '%s\n' "${seen[@]:-}" | sort -u | tr '\n' ' '))"

  # [4] Target group stays inside its Region
  local bad=0 line hostport port
  while read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    port="${line##*:}"
    case "$port" in 8431|8432|8433) ;; *) bad=1 ;; esac
  done < "$LAB_HOME/regions/${HOME_REGION}/target-group.txt"
  [[ "$bad" == "0" ]] && rc=0 || rc=1
  check "[4] every registered target lives in ${HOME_REGION}" "$rc" \
        "a target group is a regional object; cross-Region targets are impossible in AWS"

  # [5] Edge layer restored and caching
  local cache1 cache2
  read -r code _ region _ juris cache1 <<<"$(probe "http://edge.${DOMAIN}:${SVC_PORT}/orders")"
  read -r code tt region az juris cache2 <<<"$(probe "http://edge.${DOMAIN}:${SVC_PORT}/orders")"
  [[ "$code" == "200" && "$region" == "$HOME_REGION" ]] && rc=0 || rc=1
  check "[5a] global endpoint edge.${DOMAIN} returns 200 from ${HOME_REGION} origin" "$rc" \
        "http=$code region=${region} (DNS points at $(hosts_edge_ip), edge listens on ${EDGE_IP})"
  [[ "$cache2" == *"Hit from lab-edge"* ]] && rc=0 || rc=1
  check "[5b] second request served from the edge cache" "$rc" "X-Cache=${cache2}"

  hr
  if [[ "$fail" -eq 0 ]]; then
    ok "${C_B}All ${pass} checks passed - the workload is in-Region, multi-AZ and edge-fronted.${C_RESET}"
    say "Run '$0 reset' when you are done."
    return 0
  fi
  fail "${pass} passed, ${fail} failed. Use '$0 hint 1|2|3' and try again."
  return 1
}

az_cmd() {
  local sub="${1:-list}" target="${2:-}"
  case "$sub" in
    list)
      printf '  %-14s %-14s %-10s %-18s %s\n' REGION AZ-NAME AZ-ID TARGET STATE
      for record in "${AZ_TABLE[@]}"; do
        IFS='|' read -r reg _rn az azid port _j _s <<<"$record"
        local state="stopped"; is_up "az-$az" && state="running"
        local registered="no"
        grep -qE "127\.0\.0\.1:${port}([^0-9]|$)" \
          "$LAB_HOME/regions/$reg/target-group.txt" 2>/dev/null && registered="registered"
        printf '  %-14s %-14s %-10s %-18s %s / %s\n' "$reg" "$az" "$azid" \
          "127.0.0.1:$port" "$state" "$registered"
      done ;;
    start) [[ -n "$target" ]] || die "usage: $0 az start <az-name>"
           start_az "$target"; ok "Availability Zone $target is serving again" ;;
    stop)  [[ -n "$target" ]] || die "usage: $0 az stop <az-name>"
           stop_bg "az-$target"; warn "Availability Zone $target is impaired" ;;
    *) die "usage: $0 az list|start <az>|stop <az>" ;;
  esac
}

reset_lab() {
  info "stopping lab processes"
  stop_fleet
  info "removing the ${LAB_ID} block from ${HOSTS_FILE}"
  hosts_remove_block
  ok "system restored. Lab files kept at ${LAB_HOME} (backups of ${HOSTS_FILE} inside)."
  say "Delete them with: $0 nuke"
}

nuke_lab() {
  stop_fleet || true
  hosts_remove_block || true
  case "$LAB_HOME" in
    *aws-clf-lab*) rm -rf "$LAB_HOME"; ok "lab directory removed" ;;
    *) die "refusing to delete '$LAB_HOME' - it does not look like the lab directory" ;;
  esac
}

usage() {
  sed -n '/^#  Usage:/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  case "${1:-start}" in
    start)
      require_tools; confirm_disposable
      info "building lab assets in ${LAB_HOME}"
      write_assets; write_target_groups
      info "starting Regions, Availability Zones and the edge location"
      start_fleet
      info "injecting faults"
      break_it
      ok "lab is up and broken. Mission briefing follows."
      briefing ;;
    brief|briefing) briefing ;;
    status) status ;;
    client) "$LAB_HOME/app/orders-client.sh" "${2:-/orders}" ;;
    az) shift; az_cmd "$@" ;;
    verify|check) verify ;;
    hint) hint "${2:-1}" ;;
    reset) require_tools; reset_lab ;;
    nuke) require_tools; nuke_lab ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"

# =====================================================================================
#  SOLUTION - do not read until you have tried, or until you are stuck past hint 3.
# =====================================================================================
#
#  STEP 0 - Observe before touching anything.
#
#    $ ./break-fix-3.2-global-infrastructure.sh status
#    $ ./break-fix-3.2-global-infrastructure.sh client
#      endpoint: http://orders.eu-west-1.aws-lab.internal:8443/orders
#      { "region": "eu-west-1", "availability_zone_id": "euw1-az1",
#        "data_jurisdiction": "EU", ... }
#      --- http 200 in 0.203s ---
#
#    Two findings in one response: ~200 ms for a Brazilian user (a Region choice
#    problem) and BR order data being served out of the EU (a data residency
#    problem). Region selection drives both. Reference:
#    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
#
#  STEP 1 - Fix the Region pinning (client + CLI profile).
#
#    $ sed -i 's/^AWS_REGION=.*/AWS_REGION=sa-east-1/' ~/aws-clf-lab/3.2-global-infrastructure/app/app.env
#    $ sed -i 's/^region = .*/region = sa-east-1/'     ~/aws-clf-lab/3.2-global-infrastructure/aws/config
#
#    Real-world equivalents, in increasing order of precedence:
#      profile config   ->  aws configure set region sa-east-1 --profile clf-lab
#      environment      ->  export AWS_REGION=sa-east-1
#      explicit flag    ->  aws s3 ls --region sa-east-1
#    Verify what the CLI resolved:
#      $ AWS_CONFIG_FILE=~/aws-clf-lab/3.2-global-infrastructure/aws/config \
#          aws configure get region --profile clf-lab
#      sa-east-1
#
#    $ ./break-fix-3.2-global-infrastructure.sh client
#      endpoint: http://orders.sa-east-1.aws-lab.internal:8443/orders
#      { "error": "ServiceUnavailable",
#        "message": "no healthy targets registered in sa-east-1 ... tg-orders",
#        "target_health": [ { "target": "127.0.0.1:8431", "state": "unhealthy" } ] }
#      --- http 503 in 0.016s ---
#
#    The 503 is the second fault surfacing, not a regression: latency already
#    dropped from ~200 ms to ~16 ms because the request now stays in-Region.
#
#  STEP 2 - Turn the single-AZ deployment into a multi-AZ one.
#
#    $ ./break-fix-3.2-global-infrastructure.sh az list
#      sa-east-1  sa-east-1a  sae1-az1  127.0.0.1:8431  stopped / registered
#      sa-east-1  sa-east-1b  sae1-az2  127.0.0.1:8432  running / no
#      sa-east-1  sa-east-1c  sae1-az3  127.0.0.1:8433  running / no
#
#    Capacity exists in sae1-az2 and sae1-az3; it was simply never registered, so
#    the Region's availability collapsed to that of a single AZ. Recover the
#    impaired zone AND spread the target group:
#
#    $ ./break-fix-3.2-global-infrastructure.sh az start sa-east-1a
#    $ cat > ~/aws-clf-lab/3.2-global-infrastructure/regions/sa-east-1/target-group.txt <<'EOF'
#      # target group tg-orders (sa-east-1)
#      127.0.0.1:8431   # sa-east-1a / sae1-az1
#      127.0.0.1:8432   # sa-east-1b / sae1-az2
#      127.0.0.1:8433   # sa-east-1c / sae1-az3
#      EOF
#
#    Real-world equivalent (targets must be in the load balancer's own Region;
#    there is no such thing as a cross-Region target group):
#      $ aws elbv2 register-targets --region sa-east-1 \
#            --target-group-arn arn:aws:elasticloadbalancing:sa-east-1:111122223333:targetgroup/tg-orders/abc \
#            --targets Id=i-0aaa,AvailabilityZone=sa-east-1b Id=i-0bbb,AvailabilityZone=sa-east-1c
#      $ aws elbv2 describe-target-health --region sa-east-1 \
#            --target-group-arn ... --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
#      i-0aaa  healthy
#      i-0bbb  healthy
#
#    $ ./break-fix-3.2-global-infrastructure.sh client
#      { "region": "sa-east-1", "availability_zone_id": "sae1-az2",
#        "data_jurisdiction": "BR", ... }
#      --- http 200 in 0.018s ---
#    Repeat it a few times: sae1-az1 / sae1-az2 / sae1-az3 alternate. Spreading
#    across AZ IDs (not AZ names) is what actually buys independence, because
#    "sa-east-1a" maps to a different physical zone in a different account:
#    https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
#
#  STEP 3 - Repair the global/edge endpoint.
#
#    $ curl -sS --noproxy '*' http://edge.aws-lab.internal:8443/orders
#      curl: (7) Failed to connect to edge.aws-lab.internal port 8443: Connection refused
#    $ getent hosts edge.aws-lab.internal
#      127.0.99.254    edge.aws-lab.internal        <- black hole
#    $ ./break-fix-3.2-global-infrastructure.sh status | grep edge
#      edge   127.0.99.1:8443   pop=GRU50 (Sao Paulo, BR)   up   <- where it really listens
#
#    $ sudo sed -i 's/^127\.0\.99\.254\([[:space:]]\+edge\.aws-lab\.internal\)/127.0.99.1\1/' /etc/hosts
#
#    Real-world equivalent: the distribution was healthy all along; the Route 53
#    alias record pointed somewhere else. Only the DNS layer was broken - which is
#    the point: an edge location is a separate global layer, not part of a Region.
#      $ aws route53 list-resource-record-sets --hosted-zone-id Z123456ABCDEF \
#            --query "ResourceRecordSets[?Name=='cdn.example.com.']"
#      $ aws cloudfront get-distribution --id E1LABGLOBAL \
#            --query 'Distribution.[Status,DomainName,DistributionConfig.Origins.Items[].DomainName]'
#      Deployed  d111111abcdef8.cloudfront.net  [ "orders.sa-east-1.example.internal" ]
#
#    $ curl -sSI --noproxy '*' http://edge.aws-lab.internal:8443/orders | grep -i x-cache
#      X-Cache: Miss from lab-edge      # first request: fetched from the sa-east-1 origin
#    $ curl -sSI --noproxy '*' http://edge.aws-lab.internal:8443/orders | grep -i x-cache
#      X-Cache: Hit from lab-edge       # second: served by the PoP, origin untouched
#
#  STEP 4 - Grade the fix.
#
#    $ ./break-fix-3.2-global-infrastructure.sh verify
#      [ ok ] [1] client and CLI profile pinned to sa-east-1
#      [ ok ] [2a] sa-east-1 endpoint returns 200 with jurisdiction BR
#      [ ok ] [2b] latency under 60 ms (in-Region user)
#      [ ok ] [3] sa-east-1 serves from >= 2 Availability Zone IDs
#      [ ok ] [4] every registered target lives in sa-east-1
#      [ ok ] [5a] global endpoint edge.aws-lab.internal returns 200 from sa-east-1 origin
#      [ ok ] [5b] second request served from the edge cache
#      All 7 checks passed - the workload is in-Region, multi-AZ and edge-fronted.
#
#    $ ./break-fix-3.2-global-infrastructure.sh reset
#
#  WHAT THE THREE FAULTS TEACH, IN EXAM TERMS
#    Fault 1 (Region pinning): choosing a Region is choosing latency, legal
#      jurisdiction, price and service availability at once. A Region is an
#      isolated geographic area; data does not leave it unless you replicate it.
#    Fault 2 (single AZ): an AZ is a discrete failure domain with its own power,
#      cooling and networking, connected to sibling AZs by low-latency private
#      links. High availability inside a Region means >= 2 AZs; the Well-Architected
#      Reliability pillar's cheapest win is spreading a target group across them.
#    Fault 3 (edge layer): edge locations / PoPs are global and separate from
#      Regions - they cache and route, they do not store your system of record.
#      Their failure modes are DNS and origin reachability, not AZ capacity.
#    Not exercised here but on the exam: Local Zones (metro-adjacent compute tied
#      to a parent Region), Wavelength Zones (inside a telco 5G network) and
#      Outposts (AWS racks in your own data centre for residency/hybrid) - all
#      opt-in extensions of the same Region model.
# =====================================================================================