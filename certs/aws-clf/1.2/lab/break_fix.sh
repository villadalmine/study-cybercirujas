#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02, exam guide v1.0)
#  Domain 1 - Cloud Concepts
#  Task Statement 1.2 - Identify design principles of the AWS Cloud
#  Weight of the task statement in the exam blueprint: 6.0
#
#  LAB TYPE : break & fix
#  RUNS ON  : a DISPOSABLE Linux VM with systemd, python3 (>=3.8), curl, ss
#  COST     : USD 0.00 - nothing here talks to AWS. The lab reproduces the
#             control plane behaviour of ALB target groups, EC2 Auto Scaling
#             health replacement and SQS decoupling with local processes, so
#             you can break and repair the *design principles* themselves
#             without an account, an IAM role or a bill.
#
#  WHY A LOCAL SIMULATION IS FAIR FOR THIS TASK STATEMENT
#  ------------------------------------------------------
#  1.2 is not asking you to click through the console. It asks you to
#  recognise designs that are correct and designs that are not: no single
#  point of failure, horizontal scaling, automatic recovery, loose coupling,
#  and "design for failure". Those principles are architecture, not API
#  calls, and they are testable on one VM. Every lab object below has an
#  exact AWS counterpart:
#
#   AWS object                              Lab object
#   -----------------------------------------------------------------------
#   Application Load Balancer (listener)    bin/elb.py on 127.0.0.1:8080
#   Target group + health check settings    etc/elb.conf  (targets=, health_check=)
#   EC2 instance in us-east-1a              awsclf12-app@az-a.service  :9001
#   EC2 instance in us-east-1b              awsclf12-app@az-b.service  :9002
#   EC2 Auto Scaling / EC2 auto recovery    systemd Restart=always in the unit
#   Instance marked Unhealthy (drained)     state/<az>.drain -> /health = HTTP 503
#   Amazon SQS standard queue               queue/  (one JSON file per message)
#   Asynchronous consumer (worker fleet)    awsclf12-worker.service    :9100
#   ALB access logs                         logs/elb-access.log
#   aws elbv2 describe-target-health        GET http://127.0.0.1:8080/elb-status
#
#  OFFICIAL SOURCES (read these, the lab only rehearses them)
#  ----------------------------------------------------------
#   - CLF-C02 Exam Guide (Domain 1, Task 1.2):
#     https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#   - AWS Well-Architected Framework (the six pillars):
#     https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html
#   - Reliability Pillar - design principles (automatically recover from
#     failure, test recovery procedures, scale horizontally, stop guessing
#     capacity, manage change through automation):
#     https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/design-principles.html
#   - Regions and Availability Zones (why "multi-AZ" is the unit of failure
#     isolation):
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
#   - ALB target group health checks:
#     https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
#   - EC2 Auto Scaling health checks and instance replacement:
#     https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-health-checks.html
#   - Amazon SQS - decoupling components of a distributed system:
#     https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
#   - AWS Shared Responsibility Model (you own resiliency *in* the cloud):
#     https://aws.amazon.com/compliance/shared-responsibility-model/
#
#  USAGE
#  -----
#    sudo ./clf-c02-1.2-break-and-fix.sh              # deploy baseline, then break it
#    sudo ./clf-c02-1.2-break-and-fix.sh deploy       # only the correct architecture
#    sudo ./clf-c02-1.2-break-and-fix.sh break        # only the sabotage
#    sudo ./clf-c02-1.2-break-and-fix.sh status       # diagnostic dashboard
#    sudo ./clf-c02-1.2-break-and-fix.sh hint         # commands, not answers
#    sudo ./clf-c02-1.2-break-and-fix.sh verify       # graded game day (exit 0 = fixed)
#    sudo ./clf-c02-1.2-break-and-fix.sh reset        # escape hatch: rebuild baseline
#    sudo ./clf-c02-1.2-break-and-fix.sh cleanup      # remove every trace of the lab
#
#  The full step-by-step solution is at the END of this file, commented out.
#  Do not scroll there until `verify` has beaten you at least twice.
# ==============================================================================

set -euo pipefail

PREFIX="awsclf12"
LAB_ROOT="/opt/awsclf-lab-1.2"
UNIT_DIR="/etc/systemd/system"
DROPIN_DIR="${UNIT_DIR}/${PREFIX}-app@.service.d"
ELB_URL="http://127.0.0.1:8080"
AZ_A_URL="http://127.0.0.1:9001"
AZ_B_URL="http://127.0.0.1:9002"
WORKER_URL="http://127.0.0.1:9100"
UNIT_ELB="${PREFIX}-elb.service"
UNIT_WORKER="${PREFIX}-worker.service"
UNIT_A="${PREFIX}-app@az-a.service"
UNIT_B="${PREFIX}-app@az-b.service"

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_H=$'\033[1;36m'; C_0=$'\033[0m'
if [[ ! -t 1 ]]; then C_OK=""; C_BAD=""; C_WARN=""; C_H=""; C_0=""; fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s== %s ==%s\n' "$C_H" "$*" "$C_0"; }
ok()   { printf '%s[ PASS ]%s %s\n' "$C_OK" "$C_0" "$*"; }
bad()  { printf '%s[ FAIL ]%s %s\n' "$C_BAD" "$C_0" "$*"; }
warn() { printf '%s[ WARN ]%s %s\n' "$C_WARN" "$C_0" "$*"; }
die()  { printf '%s[ ABORT ]%s %s\n' "$C_BAD" "$C_0" "$*" >&2; exit 1; }

# ------------------------------------------------------------------ guardrails
require_root() {
  [[ ${EUID} -eq 0 ]] || die "run as root (systemd units are installed): sudo $0 $*"
}

require_tools() {
  local missing=()
  for t in python3 curl systemctl awk sed grep; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]}"
  [[ -d /run/systemd/system ]] || die "systemd is not the init system here; this lab needs it"
  command -v ss >/dev/null 2>&1 || warn "iproute2 'ss' not found - socket diagnostics will be skipped"
}

guard_disposable() {
  if [[ ${LAB_I_UNDERSTAND:-} == "yes-destroy-this-vm" ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    die "non-interactive run requires LAB_I_UNDERSTAND=yes-destroy-this-vm"
  fi
  cat <<EOF

  This script installs systemd units, binds 127.0.0.1:8080/9001/9002/9100 and
  writes only under ${LAB_ROOT}. It then deliberately misconfigures those
  units. It is safe and fully reversible with 'cleanup', but it is meant for a
  THROWAWAY lab VM, never for a workstation you care about or any host running
  real services.

EOF
  local answer=""
  read -r -p "  Type DESTROY to continue: " answer
  [[ ${answer} == "DESTROY" ]] || die "aborted by the operator - nothing was changed"
}

ports_available() {
  command -v ss >/dev/null 2>&1 || return 0
  local port owner
  for port in 8080 9001 9002 9100; do
    if ss -lntH "sport = :${port}" 2>/dev/null | grep -q .; then
      owner=$(ss -lntpH "sport = :${port}" 2>/dev/null | head -n1)
      if ! grep -q 'python3' <<<"${owner}"; then
        die "port ${port} is already used by a foreign process: ${owner}"
      fi
    fi
  done
}

# ------------------------------------------------------------------- utilities
http_code() {
  local out=""
  out=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "$@" 2>/dev/null) || true
  printf '%s' "${out:-000}"
}

http_body() { curl -s -m 4 "$@" 2>/dev/null || true; }

served_by() {
  curl -s -m 4 -D - -o /dev/null "$1" 2>/dev/null \
    | awk 'tolower($1) == "x-instance-id:" { print $2 }' | tr -d '\r' || true
}

wait_http() { # wait_http <url> <expected-code> <seconds>
  local url="$1" want="$2" secs="${3:-20}" i=0
  while (( i < secs * 2 )); do
    [[ $(http_code "${url}") == "${want}" ]] && return 0
    sleep 0.5; i=$((i + 1))
  done
  return 1
}

queue_depth() { find "${LAB_ROOT}/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
processed_count() { find "${LAB_ROOT}/processed" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

# ============================================================== lab artifacts
install_lab() {
  install -d -m 0755 "${LAB_ROOT}"/{bin,etc,env,logs,queue,processed,state}

  cat >"${LAB_ROOT}/bin/app.py" <<'APP_PY'
#!/usr/bin/env python3
"""
Application tier for the CLF-C02 1.2 lab.

One process == one EC2 instance in one Availability Zone. The process is
stateless by design: nothing a request needs is kept on local disk, which is
exactly what makes an instance disposable, replaceable and horizontally
scalable (Well-Architected, Reliability pillar: "scale horizontally to
increase aggregate workload availability").

Endpoints
  GET  /          storefront page, returns the AZ and instance id that served it
  GET  /health    target-group health check target (503 while a drain flag exists)
  POST /checkout  business transaction; behaviour depends on COUPLING:
                    COUPLING=queue -> publish to the queue, return 202 Accepted
                    COUPLING=sync  -> synchronous call to the payments worker,
                                      return 500 if that dependency is down
"""
import json
import os
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AZ = os.environ.get("AZ", "us-east-1a")
PORT = int(os.environ.get("PORT", "9001"))
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
INSTANCE_ID = os.environ.get("INSTANCE_ID", "i-000000000000000")
WORKER_URL = os.environ.get("WORKER_URL", "http://127.0.0.1:9100/pay")
QUEUE_DIR = os.environ.get("QUEUE_DIR", "/opt/awsclf-lab-1.2/queue")
STATE_DIR = os.environ.get("STATE_DIR", "/opt/awsclf-lab-1.2/state")
COUPLING = os.environ.get("COUPLING", "queue").strip().lower()
BOOT_TIME = time.time()
DRAIN_FILE = os.path.join(STATE_DIR, AZ + ".drain")


class Instance(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "clf-lab-app/1.0"

    def _reply(self, status, payload):
        body = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Instance-Id", INSTANCE_ID)
        self.send_header("X-Availability-Zone", AZ)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("%s %s" % (AZ, fmt % args), flush=True)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self._health()
        if path == "/checkout":
            return self._checkout()
        if path in ("/", "/index.html"):
            return self._reply(200, {
                "service": "storefront",
                "availability_zone": AZ,
                "instance_id": INSTANCE_ID,
                "uptime_seconds": round(time.time() - BOOT_TIME, 1),
                "coupling": COUPLING,
            })
        return self._reply(404, {"error": "NotFound", "path": path})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if self.path.split("?", 1)[0] == "/checkout":
            return self._checkout()
        return self._reply(404, {"error": "NotFound", "path": self.path})

    def _health(self):
        # A target that reports itself unhealthy is how an instance leaves
        # rotation without anybody logging in. See ALB target group health
        # checks and EC2 Auto Scaling health replacement.
        if os.path.exists(DRAIN_FILE):
            return self._reply(503, {
                "status": "unhealthy",
                "availability_zone": AZ,
                "instance_id": INSTANCE_ID,
                "reason": "drain flag present: " + DRAIN_FILE,
            })
        return self._reply(200, {
            "status": "healthy",
            "availability_zone": AZ,
            "instance_id": INSTANCE_ID,
        })

    def _checkout(self):
        order = {
            "order_id": "ord-" + uuid.uuid4().hex[:12],
            "amount_usd": 42.00,
            "accepted_by": INSTANCE_ID,
            "availability_zone": AZ,
            "accepted_at": round(time.time(), 3),
        }
        if COUPLING == "queue":
            # Loose coupling: the request path owns durability, not delivery.
            # Equivalent to sqs:SendMessage - the producer survives a consumer
            # outage and the consumer scales independently.
            os.makedirs(QUEUE_DIR, exist_ok=True)
            tmp = os.path.join(QUEUE_DIR, "." + order["order_id"] + ".tmp")
            final = os.path.join(QUEUE_DIR, order["order_id"] + ".json")
            with open(tmp, "w") as fh:
                json.dump(order, fh, indent=2)
            os.rename(tmp, final)  # atomic publish
            order["status"] = "queued"
            return self._reply(202, order)

        # Tight coupling: the HTTP request is only as available as the least
        # available component it calls synchronously.
        req = urllib.request.Request(
            WORKER_URL,
            data=json.dumps(order).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=2) as resp:
                order["status"] = "paid"
                order["receipt"] = json.loads(resp.read().decode())
                return self._reply(200, order)
        except Exception as exc:
            order["status"] = "failed"
            order["error"] = "payments dependency unreachable (%s)" % exc.__class__.__name__
            return self._reply(500, order)


if __name__ == "__main__":
    os.makedirs(QUEUE_DIR, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    print("instance %s in %s listening on %s:%d (coupling=%s)"
          % (INSTANCE_ID, AZ, LISTEN_ADDR, PORT, COUPLING), flush=True)
    ThreadingHTTPServer((LISTEN_ADDR, PORT), Instance).serve_forever()
APP_PY

  cat >"${LAB_ROOT}/bin/elb.py" <<'ELB_PY'
#!/usr/bin/env python3
"""
Layer 7 load balancer that mimics an Application Load Balancer with a single
target group.

It reads etc/elb.conf and hot-reloads it when the mtime changes, the way a
managed service picks up a ModifyTargetGroupAttributes call - no restart, no
connection drain, no operator.

Behaviour that matters for the lab:
  health_check=on   -> targets are probed on health_path every `interval`
                       seconds; only healthy targets receive traffic, and a
                       failed forward is retried against the next healthy
                       target (the ALB does this per request).
  health_check=off  -> the balancer is blind. Every registered target is
                       assumed good, there is no retry, and a dead target
                       produces HTTP 502 for the customer.
"""
import http.client
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = os.environ.get("ELB_CONF", "/opt/awsclf-lab-1.2/etc/elb.conf")
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("ELB_PORT", "8080"))
ACCESS_LOG = os.environ.get("ELB_ACCESS_LOG", "/opt/awsclf-lab-1.2/logs/elb-access.log")

DEFAULTS = {
    "targets": "",
    "health_check": "on",
    "health_path": "/health",
    "interval": "2",
    "timeout": "1",
    "healthy_threshold": "2",
    "unhealthy_threshold": "2",
}

_lock = threading.RLock()
_cfg = dict(DEFAULTS)
_health = {}
_mtime = -1.0
_rr = 0


def _truth(value):
    return str(value).strip().lower() in ("on", "true", "yes", "1", "enabled")


def _targets(cfg):
    return [t.strip() for t in cfg.get("targets", "").split(",") if t.strip()]


def load_config(force=False):
    global _cfg, _mtime
    try:
        mtime = os.stat(CONF).st_mtime
    except OSError:
        return
    with _lock:
        if not force and mtime == _mtime:
            return
        cfg = dict(DEFAULTS)
        try:
            with open(CONF) as fh:
                for raw in fh:
                    line = raw.split("#", 1)[0].strip()
                    if "=" not in line:
                        continue
                    key, value = line.split("=", 1)
                    cfg[key.strip()] = value.strip()
        except OSError:
            return
        _cfg = cfg
        _mtime = mtime
        registered = _targets(cfg)
        for target in registered:
            _health.setdefault(target, {"state": "initial", "ok": 0, "bad": 0,
                                        "reason": "registering", "checked_at": 0})
        for stale in [t for t in _health if t not in registered]:
            _health.pop(stale, None)
        print("config reloaded: targets=[%s] health_check=%s"
              % (", ".join(registered) or "NONE", cfg["health_check"]), flush=True)


def probe(target, path, timeout):
    host, _, port = target.partition(":")
    try:
        conn = http.client.HTTPConnection(host, int(port or 80), timeout=timeout)
        conn.request("GET", path)
        resp = conn.getresponse()
        resp.read()
        conn.close()
        if 200 <= resp.status < 400:
            return True, "HTTP %d" % resp.status
        return False, "Target.ResponseCodeMismatch (HTTP %d)" % resp.status
    except Exception as exc:
        return False, "Target.FailedHealthChecks (%s)" % exc.__class__.__name__


def health_loop():
    while True:
        load_config()
        with _lock:
            cfg = dict(_cfg)
        registered = _targets(cfg)
        interval = float(cfg.get("interval") or 2)
        if not _truth(cfg["health_check"]):
            with _lock:
                for target in registered:
                    _health[target] = {"state": "unused", "ok": 0, "bad": 0,
                                       "reason": "health checks are disabled",
                                       "checked_at": time.time()}
            time.sleep(interval)
            continue
        for target in registered:
            good, why = probe(target, cfg["health_path"], float(cfg.get("timeout") or 1))
            with _lock:
                state = _health.setdefault(target, {"state": "initial", "ok": 0,
                                                    "bad": 0, "reason": "", "checked_at": 0})
                if good:
                    state["ok"] += 1
                    state["bad"] = 0
                    if state["ok"] >= int(cfg["healthy_threshold"]):
                        state["state"] = "healthy"
                else:
                    state["bad"] += 1
                    state["ok"] = 0
                    if state["bad"] >= int(cfg["unhealthy_threshold"]):
                        state["state"] = "unhealthy"
                state["reason"] = why
                state["checked_at"] = time.time()
        time.sleep(interval)


def choose(cfg):
    """Return the candidate list, best first, rotated for round robin."""
    global _rr
    registered = _targets(cfg)
    with _lock:
        if _truth(cfg["health_check"]):
            pool = [t for t in registered if _health.get(t, {}).get("state") == "healthy"]
        else:
            pool = list(registered)
        if not pool:
            return []
        _rr = (_rr + 1) % len(pool)
        return pool[_rr:] + pool[:_rr]


def forward(target, method, path, headers, body):
    host, _, port = target.partition(":")
    conn = http.client.HTTPConnection(host, int(port or 80), timeout=5)
    hop_by_hop = ("host", "connection", "content-length", "keep-alive",
                  "transfer-encoding", "upgrade")
    fwd = {k: v for k, v in headers.items() if k.lower() not in hop_by_hop}
    fwd["X-Forwarded-For"] = "127.0.0.1"
    if body:
        fwd["Content-Length"] = str(len(body))
    conn.request(method, path, body=body or None, headers=fwd)
    resp = conn.getresponse()
    data = resp.read()
    out = [(k, v) for k, v in resp.getheaders()
           if k.lower() not in ("transfer-encoding", "connection", "content-length")]
    conn.close()
    return resp.status, out, data


class Listener(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "clf-lab-elb/1.0"

    def log_message(self, fmt, *args):
        pass  # access logging is done explicitly, like an ALB access log

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def _access(self, method, path, target, status):
        line = "%s %s %s -> %s %s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%S%z"), method, path, target, status)
        try:
            with open(ACCESS_LOG, "a") as fh:
                fh.write(line)
        except OSError:
            pass

    def _json(self, status, payload, extra=None):
        body = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or []):
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _route(self, method):
        load_config()
        with _lock:
            cfg = dict(_cfg)
            health = {k: dict(v) for k, v in _health.items()}
        path = self.path
        if path.split("?", 1)[0] == "/elb-status":
            return self._json(200, {
                "listener": "%s:%d" % (LISTEN_ADDR, LISTEN_PORT),
                "health_check_enabled": _truth(cfg["health_check"]),
                "health_check_path": cfg["health_path"],
                "interval_seconds": cfg["interval"],
                "registered_targets": _targets(cfg),
                "target_health": health,
            })

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        candidates = choose(cfg)
        # Without health checks there is no notion of a bad target, so there is
        # nothing to fail over to: one attempt, then the customer sees the error.
        attempts = candidates if _truth(cfg["health_check"]) else candidates[:1]

        errors = []
        for target in attempts:
            try:
                status, headers, data = forward(target, method, path, self.headers, body)
            except Exception as exc:
                errors.append("%s: %s" % (target, exc.__class__.__name__))
                self._access(method, path, target, "502(connect)")
                continue
            self.send_response(status)
            for key, value in headers:
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("X-Elb-Target", target)
            self.end_headers()
            self.wfile.write(data)
            self._access(method, path, target, status)
            return

        self._access(method, path, "-", "502")
        self._json(502, {
            "error": "502 Bad Gateway",
            "detail": "the load balancer has no target able to serve this request",
            "registered_targets": _targets(cfg),
            "health_check_enabled": _truth(cfg["health_check"]),
            "attempts": attempts,
            "connection_errors": errors,
            "target_health": health,
        }, extra=[("X-Elb-Error", "NoHealthyTargets")])


if __name__ == "__main__":
    os.makedirs(os.path.dirname(ACCESS_LOG), exist_ok=True)
    load_config(force=True)
    threading.Thread(target=health_loop, daemon=True).start()
    print("elb listening on %s:%d, config %s" % (LISTEN_ADDR, LISTEN_PORT, CONF), flush=True)
    ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Listener).serve_forever()
ELB_PY

  cat >"${LAB_ROOT}/bin/worker.py" <<'WORKER_PY'
#!/usr/bin/env python3
"""
Payments worker - the asynchronous consumer.

Two entry points on purpose, so the lab can contrast the two coupling styles
with the same component:
  POST /pay    synchronous RPC. If this process is down, the caller fails.
  queue/       polled every second; messages accumulate while the worker is
               down and are drained when it returns (sqs:ReceiveMessage +
               sqs:DeleteMessage after successful processing).
"""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QUEUE_DIR = os.environ.get("QUEUE_DIR", "/opt/awsclf-lab-1.2/queue")
PROCESSED_DIR = os.environ.get("PROCESSED_DIR", "/opt/awsclf-lab-1.2/processed")
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
PORT = int(os.environ.get("WORKER_PORT", "9100"))

_lock = threading.Lock()
_processed = 0


def consume():
    global _processed
    while True:
        try:
            names = sorted(n for n in os.listdir(QUEUE_DIR) if n.endswith(".json"))
        except OSError:
            names = []
        for name in names:
            src = os.path.join(QUEUE_DIR, name)
            try:
                with open(src) as fh:
                    message = json.load(fh)
            except Exception:
                continue
            message["status"] = "paid"
            message["processed_at"] = round(time.time(), 3)
            message["processed_by"] = "worker-%d" % os.getpid()
            with open(os.path.join(PROCESSED_DIR, name), "w") as fh:
                json.dump(message, fh, indent=2)
            try:
                os.unlink(src)  # delete only after successful processing
            except OSError:
                pass
            with _lock:
                _processed += 1
            print("processed %s (queued at %s)" % (message.get("order_id"),
                                                   message.get("accepted_at")), flush=True)
        time.sleep(1)


class Worker(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "clf-lab-worker/1.0"

    def log_message(self, fmt, *args):
        print("worker %s" % (fmt % args), flush=True)

    def _reply(self, status, payload):
        body = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/stats":
            try:
                backlog = len([n for n in os.listdir(QUEUE_DIR) if n.endswith(".json")])
            except OSError:
                backlog = -1
            with _lock:
                done = _processed
            return self._reply(200, {"processed_since_start": done, "queue_backlog": backlog})
        if path == "/health":
            return self._reply(200, {"status": "healthy"})
        return self._reply(404, {"error": "NotFound", "path": path})

    def do_POST(self):
        global _processed
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            order = json.loads(raw.decode() or "{}")
        except ValueError:
            order = {}
        with _lock:
            _processed += 1
        return self._reply(200, {
            "receipt_id": "rcpt-%d" % int(time.time() * 1000),
            "order_id": order.get("order_id", "unknown"),
            "settled_by": "worker-%d" % os.getpid(),
        })


if __name__ == "__main__":
    os.makedirs(QUEUE_DIR, exist_ok=True)
    os.makedirs(PROCESSED_DIR, exist_ok=True)
    threading.Thread(target=consume, daemon=True).start()
    print("payments worker on %s:%d, polling %s" % (LISTEN_ADDR, PORT, QUEUE_DIR), flush=True)
    ThreadingHTTPServer((LISTEN_ADDR, PORT), Worker).serve_forever()
WORKER_PY

  chmod 0755 "${LAB_ROOT}"/bin/*.py

  # ---- per-instance environment (an EC2 launch template, roughly) ----------
  cat >"${LAB_ROOT}/env/az-a.env" <<ENV_A
AZ=us-east-1a
PORT=9001
LISTEN_ADDR=127.0.0.1
INSTANCE_ID=i-0a1b2c3d4e5f6a7b8
WORKER_URL=${WORKER_URL}/pay
QUEUE_DIR=${LAB_ROOT}/queue
STATE_DIR=${LAB_ROOT}/state
COUPLING=queue
ENV_A

  cat >"${LAB_ROOT}/env/az-b.env" <<ENV_B
AZ=us-east-1b
PORT=9002
LISTEN_ADDR=127.0.0.1
INSTANCE_ID=i-0b9c8d7e6f5a4b3c2
WORKER_URL=${WORKER_URL}/pay
QUEUE_DIR=${LAB_ROOT}/queue
STATE_DIR=${LAB_ROOT}/state
COUPLING=queue
ENV_B

  write_baseline_elb_conf

  # ---- systemd units -------------------------------------------------------
  cat >"${UNIT_DIR}/${PREFIX}-app@.service" <<UNIT_APP
[Unit]
Description=CLF-C02 1.2 lab - application instance %i
Documentation=https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/design-principles.html
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${LAB_ROOT}/env/%i.env
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/env python3 ${LAB_ROOT}/bin/app.py
# Self-healing: the analogue of EC2 Auto Scaling replacing an unhealthy
# instance, or EC2 auto recovery. Nobody should have to log in for this.
Restart=always
RestartSec=2
# Least privilege in the cloud is IAM; on the host it is this block.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=${LAB_ROOT}

[Install]
WantedBy=multi-user.target
UNIT_APP

  cat >"${UNIT_DIR}/${UNIT_ELB}" <<UNIT_ELB_EOF
[Unit]
Description=CLF-C02 1.2 lab - Application Load Balancer simulation
Documentation=https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
Environment=ELB_CONF=${LAB_ROOT}/etc/elb.conf
Environment=ELB_PORT=8080
Environment=LISTEN_ADDR=127.0.0.1
Environment=ELB_ACCESS_LOG=${LAB_ROOT}/logs/elb-access.log
ExecStart=/usr/bin/env python3 ${LAB_ROOT}/bin/elb.py
Restart=always
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=${LAB_ROOT}

[Install]
WantedBy=multi-user.target
UNIT_ELB_EOF

  cat >"${UNIT_DIR}/${UNIT_WORKER}" <<UNIT_WORKER_EOF
[Unit]
Description=CLF-C02 1.2 lab - payments worker (asynchronous consumer)
Documentation=https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
Environment=QUEUE_DIR=${LAB_ROOT}/queue
Environment=PROCESSED_DIR=${LAB_ROOT}/processed
Environment=WORKER_PORT=9100
Environment=LISTEN_ADDR=127.0.0.1
ExecStart=/usr/bin/env python3 ${LAB_ROOT}/bin/worker.py
Restart=always
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=${LAB_ROOT}

[Install]
WantedBy=multi-user.target
UNIT_WORKER_EOF

  systemctl daemon-reload
}

write_baseline_elb_conf() {
  cat >"${LAB_ROOT}/etc/elb.conf" <<'ELB_CONF'
# Target group configuration for the lab load balancer.
# Equivalent AWS calls:
#   aws elbv2 register-targets      --> targets=
#   aws elbv2 modify-target-group   --> health_check / health_path / thresholds
# The balancer hot-reloads this file, so an edit takes effect within ~1 second.
# Two targets in two Availability Zones: no single point of failure.
targets=127.0.0.1:9001,127.0.0.1:9002
health_check=on
health_path=/health
interval=2
timeout=1
healthy_threshold=2
unhealthy_threshold=2
ELB_CONF
}

start_baseline() {
  systemctl enable --now "${UNIT_ELB}" >/dev/null 2>&1 || systemctl restart "${UNIT_ELB}"
  systemctl enable --now "${UNIT_WORKER}" >/dev/null 2>&1 || systemctl restart "${UNIT_WORKER}"
  systemctl enable --now "${UNIT_A}" >/dev/null 2>&1 || systemctl restart "${UNIT_A}"
  systemctl enable --now "${UNIT_B}" >/dev/null 2>&1 || systemctl restart "${UNIT_B}"
}

# ================================================================== commands
cmd_deploy() {
  head1 "Deploying the reference architecture (the state you must get back to)"
  install_lab
  start_baseline
  wait_http "${AZ_A_URL}/health" 200 20 || die "instance in us-east-1a never became healthy"
  wait_http "${AZ_B_URL}/health" 200 20 || die "instance in us-east-1b never became healthy"
  wait_http "${ELB_URL}/" 200 20 || die "load balancer never returned 200"
  ok "two instances registered in two AZs, health checks on, worker consuming the queue"
  say ""
  say "  curl -s ${ELB_URL}/ | head"
  http_body "${ELB_URL}/" | sed 's/^/  /'
}

cmd_break() {
  head1 "Applying the sabotage (five design-principle violations)"
  install_lab >/dev/null
  start_baseline
  wait_http "${ELB_URL}/" 200 20 >/dev/null || true

  # 1. Remove self-healing: the instance will stay dead once it crashes.
  install -d -m 0755 "${DROPIN_DIR}"
  cat >"${DROPIN_DIR}/10-no-self-healing.conf" <<'DROPIN'
# Sabotage: automatic recovery disabled. This is the "pet server" model - a
# crashed instance now waits for a human, which is exactly what EC2 Auto
# Scaling health replacement exists to avoid.
[Service]
Restart=no
DROPIN
  systemctl daemon-reload

  # 2. Collapse the fleet to one AZ and blind the balancer.
  cat >"${LAB_ROOT}/etc/elb.conf" <<'BROKEN_CONF'
# Sabotage: a single target in a single Availability Zone, and no health
# checks. The balancer cannot know a target is dead, so it cannot fail over.
targets=127.0.0.1:9001
health_check=off
health_path=/health
interval=2
timeout=1
healthy_threshold=2
unhealthy_threshold=2
BROKEN_CONF

  # 3. Terminate the standby AZ entirely.
  systemctl disable --now "${UNIT_B}" >/dev/null 2>&1 || true

  # 4. Tighten the coupling: checkout now calls payments synchronously.
  sed -i 's/^COUPLING=.*/COUPLING=sync/' "${LAB_ROOT}/env/az-a.env" "${LAB_ROOT}/env/az-b.env"
  systemctl restart "${UNIT_A}" || true

  # 5. Take the payments dependency down (a real outage of a downstream team).
  systemctl stop "${UNIT_WORKER}" >/dev/null 2>&1 || true

  sleep 2
  # 6. Simulate the Availability Zone failure: SIGKILL the only instance left.
  systemctl kill -s SIGKILL "${UNIT_A}" >/dev/null 2>&1 || true
  sleep 2

  briefing
}

briefing() {
  cat <<EOF

${C_H}================================================================================
 CLF-C02 - Task 1.2 - Break & Fix briefing
================================================================================${C_0}

 SCENARIO
   You inherited a storefront that a previous team "lifted and shifted" into
   the cloud. It runs on instances behind a load balancer, and the design
   principles of the AWS Cloud were never applied to it. Ten minutes ago the
   on-call pager fired.

 THE SYMPTOM YOU WILL SEE

   1) The customer-facing endpoint is down, hard:

        \$ curl -i ${ELB_URL}/
        HTTP/1.1 502 Bad Gateway
        X-Elb-Error: NoHealthyTargets
        {
          "error": "502 Bad Gateway",
          "registered_targets": ["127.0.0.1:9001"],
          "health_check_enabled": false,
          ...
        }

   2) The instance that used to serve traffic is dead and STAYS dead. Nothing
      brings it back on its own:

        \$ systemctl is-active ${UNIT_A}
        failed

   3) There is no second Availability Zone to fall back to - the fleet was
      one instance:

        \$ curl -s ${ELB_URL}/elb-status | grep -A3 registered_targets

   4) Even after you restart the instance by hand, the business transaction
      still fails, because /checkout calls the payments service synchronously
      and payments is having its own outage:

        \$ curl -i -X POST ${ELB_URL}/checkout
        HTTP/1.1 500 Internal Server Error
        {"error": "payments dependency unreachable (URLError)", "status": "failed"}

 WHAT YOU MUST ACHIEVE (this is what 'verify' grades)

   A. ${C_H}No single point of failure.${C_0} Traffic must survive the loss of any ONE
      Availability Zone. The grader will SIGKILL each instance in turn and
      require HTTP 200 from ${ELB_URL}/ throughout.
      -> Well-Architected, Reliability pillar: scale horizontally; use
         multiple Availability Zones.

   B. ${C_H}Automatic recovery.${C_0} A killed instance must be running and healthy
      again within 30 seconds WITHOUT you typing anything.
      -> "Automatically recover from failure": EC2 Auto Scaling / auto
         recovery replaces the instance; here, systemd Restart=always.

   C. ${C_H}Health checks must actually gate traffic.${C_0} The grader marks one
      instance unhealthy (a drain flag makes /health return 503) and requires
      that ZERO requests are routed to it while it is draining.
      -> ALB target group health checks: an unhealthy target is removed from
         rotation automatically.

   D. ${C_H}Loose coupling.${C_0} With the payments worker completely stopped,
      POST /checkout must return 202 Accepted, and the order must be settled
      by itself once the worker comes back. A downstream outage may degrade
      the system; it may not take the front door down.
      -> Decouple components with a queue (Amazon SQS).

   E. ${C_H}Design for failure, and test it.${C_0} 'verify' is your game day. Run it
      until it is green.

 RULES
   - You may edit ${LAB_ROOT}/etc/elb.conf, ${LAB_ROOT}/env/*.env,
     the unit files and drop-ins under ${UNIT_DIR}, and use systemctl.
   - You may NOT edit bin/*.py, and you may NOT keep a shell loop restarting
     things by hand - "a human watching a terminal" is not automatic recovery.

 YOUR TOOLING
     sudo $0 status     # dashboard: units, sockets, target health, logs
     sudo $0 hint       # diagnostic commands, no answers
     sudo $0 verify     # graded game day
     journalctl -u ${PREFIX}-app@az-a -n 50 --no-pager
     curl -s ${ELB_URL}/elb-status | python3 -m json.tool

EOF
}

cmd_status() {
  head1 "Fleet state"
  local unit state enabled restart
  for unit in "${UNIT_ELB}" "${UNIT_A}" "${UNIT_B}" "${UNIT_WORKER}"; do
    state=$(systemctl is-active "${unit}" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "${unit}" 2>/dev/null || echo "n/a")
    restart=$(systemctl show -p Restart --value "${unit}" 2>/dev/null || echo "?")
    printf '  %-34s active=%-10s enabled=%-10s Restart=%s\n' \
      "${unit}" "${state:-unknown}" "${enabled}" "${restart}"
  done

  head1 "Listening sockets (the lab ports only)"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk 'NR==1 || /:(8080|9001|9002|9100)\y/' | sed 's/^/  /'
  else
    say "  ss not installed - skipped"
  fi

  head1 "Target group health (aws elbv2 describe-target-health equivalent)"
  http_body "${ELB_URL}/elb-status" | sed 's/^/  /'

  head1 "Front door"
  printf '  GET  %-32s -> HTTP %s\n' "${ELB_URL}/"         "$(http_code "${ELB_URL}/")"
  printf '  GET  %-32s -> HTTP %s\n' "${AZ_A_URL}/health"  "$(http_code "${AZ_A_URL}/health")"
  printf '  GET  %-32s -> HTTP %s\n' "${AZ_B_URL}/health"  "$(http_code "${AZ_B_URL}/health")"
  printf '  POST %-32s -> HTTP %s\n' "${ELB_URL}/checkout" "$(http_code -X POST "${ELB_URL}/checkout")"

  head1 "Coupling mode and queue"
  grep -H '^COUPLING=' "${LAB_ROOT}"/env/*.env 2>/dev/null | sed 's/^/  /' || true
  printf '  queue backlog=%s   processed=%s\n' "$(queue_depth)" "$(processed_count)"

  head1 "Load balancer access log (last 15 lines)"
  tail -n 15 "${LAB_ROOT}/logs/elb-access.log" 2>/dev/null | sed 's/^/  /' || say "  (empty)"
}

cmd_hint() {
  cat <<EOF

 Diagnostic path - work outside-in, exactly as you would in an incident:

   1. Is the front door failing, or the application?
        curl -i ${ELB_URL}/
        curl -i ${AZ_A_URL}/         # bypass the balancer, hit the instance
        curl -i ${AZ_B_URL}/

   2. What does the balancer think its targets are, and are health checks on?
        curl -s ${ELB_URL}/elb-status | python3 -m json.tool
        cat ${LAB_ROOT}/etc/elb.conf

   3. Are the instances even running, and will they come back by themselves?
        systemctl status ${UNIT_A} --no-pager
        systemctl show -p Restart -p RestartUSec --value ${UNIT_A}
        systemd-delta --type=extended | grep -i ${PREFIX}       # look for drop-ins
        ls -l ${DROPIN_DIR} 2>/dev/null
        journalctl -u ${PREFIX}-app@az-a -n 40 --no-pager

   4. Was a whole Availability Zone removed from service?
        systemctl is-enabled ${UNIT_B}
        grep -n targets ${LAB_ROOT}/etc/elb.conf

   5. Why does the transaction fail even when the front door answers?
        curl -i -X POST ${ELB_URL}/checkout
        grep -H COUPLING ${LAB_ROOT}/env/*.env
        systemctl status ${UNIT_WORKER} --no-pager
        curl -s ${WORKER_URL}/stats

   Ask yourself, for each finding: which AWS design principle does this
   violate, and what is the AWS service that normally enforces it?

EOF
}

# --------------------------------------------------------------- graded check
cmd_verify() {
  local pass=0 fail=0 code azid unit az
  local -a drained=()

  cleanup_drain() {
    local f
    for f in "${drained[@]:-}"; do [[ -n "${f}" ]] && rm -f "${f}"; done
    systemctl start "${UNIT_WORKER}" >/dev/null 2>&1 || true
  }
  trap cleanup_drain EXIT

  head1 "GAME DAY - grading the design principles (this is criterion E)"

  # --- A0: the service answers at all ---------------------------------------
  code=$(http_code "${ELB_URL}/")
  if [[ ${code} == "200" ]]; then
    ok "front door returns HTTP 200 through the load balancer"; pass=$((pass+1))
  else
    bad "front door returns HTTP ${code} - the workload is not serving traffic"; fail=$((fail+1))
  fi

  # --- A1: two AZs registered and healthy -----------------------------------
  local healthy
  healthy=$(http_body "${ELB_URL}/elb-status" | grep -c '"state": "healthy"' || true)
  if [[ ${healthy} -ge 2 ]]; then
    ok "at least two targets are healthy in the target group (multi-AZ fleet)"; pass=$((pass+1))
  else
    bad "only ${healthy} healthy target(s) - a single AZ failure still ends the service"; fail=$((fail+1))
  fi

  # --- A2 + B: kill each AZ in turn, require continuity and self-healing -----
  for az in az-a az-b; do
    unit="${PREFIX}-app@${az}.service"
    if [[ $(systemctl is-active "${unit}" 2>/dev/null || true) != "active" ]]; then
      bad "${unit} is not running - cannot test the loss of ${az}"; fail=$((fail+1)); continue
    fi
    systemctl kill -s SIGKILL "${unit}" >/dev/null 2>&1 || true
    sleep 1
    local outages=0 i
    for i in 1 2 3 4 5 6; do
      code=$(http_code "${ELB_URL}/")
      [[ ${code} == "200" ]] || outages=$((outages+1))
      sleep 0.5
    done
    if [[ ${outages} -eq 0 ]]; then
      ok "SIGKILL on ${az}: 6/6 requests still returned 200 (no single point of failure)"
      pass=$((pass+1))
    else
      bad "SIGKILL on ${az}: ${outages}/6 requests failed - customers saw the failure"
      fail=$((fail+1))
    fi
    # self-healing, unattended
    local waited=0 healed="no"
    while (( waited < 30 )); do
      if [[ $(systemctl is-active "${unit}" 2>/dev/null || true) == "active" ]]; then
        healed="yes"; break
      fi
      sleep 2; waited=$((waited+2))
    done
    if [[ ${healed} == "yes" ]]; then
      ok "${az} recovered automatically in <=${waited}s with no operator action"
      pass=$((pass+1))
    else
      bad "${az} is still down after 30s - recovery depends on a human"
      fail=$((fail+1))
    fi
    sleep 4   # let the health check bring the replaced target back to healthy
  done

  # --- C: unhealthy targets must leave rotation -----------------------------
  local drain_file="${LAB_ROOT}/state/us-east-1b.drain"
  touch "${drain_file}"; drained+=("${drain_file}")
  sleep 6
  local wrong=0 j
  for j in 1 2 3 4 5 6 7 8; do
    azid=$(served_by "${ELB_URL}/")
    [[ ${azid} == "i-0b9c8d7e6f5a4b3c2" ]] && wrong=$((wrong+1))
    sleep 0.3
  done
  rm -f "${drain_file}"; drained=()
  if [[ ${wrong} -eq 0 ]]; then
    ok "a target reporting 503 on /health received 0 requests (health checks gate traffic)"
    pass=$((pass+1))
  else
    bad "${wrong}/8 requests were sent to a target that was reporting itself unhealthy"
    fail=$((fail+1))
  fi
  sleep 5

  # --- D: loose coupling ----------------------------------------------------
  systemctl stop "${UNIT_WORKER}" >/dev/null 2>&1 || true
  sleep 1
  local before after code_checkout
  before=$(processed_count)
  code_checkout=$(http_code -X POST "${ELB_URL}/checkout")
  if [[ ${code_checkout} == "202" ]]; then
    ok "checkout returned 202 Accepted while the payments worker was DOWN (loose coupling)"
    pass=$((pass+1))
  else
    bad "checkout returned HTTP ${code_checkout} with payments down - the tiers are still tightly coupled"
    fail=$((fail+1))
  fi
  systemctl start "${UNIT_WORKER}" >/dev/null 2>&1 || true
  local t=0 settled="no"
  while (( t < 20 )); do
    after=$(processed_count)
    if (( after > before )) && [[ $(queue_depth) == "0" ]]; then settled="yes"; break; fi
    sleep 1; t=$((t+1))
  done
  if [[ ${settled} == "yes" ]]; then
    ok "the buffered order was settled ${t}s after the worker returned, backlog drained to 0"
    pass=$((pass+1))
  else
    bad "the order was never settled after the worker came back (backlog=$(queue_depth))"
    fail=$((fail+1))
  fi

  # --- B2: the automation is declared, not improvised ------------------------
  local rpol
  rpol=$(systemctl show -p Restart --value "${UNIT_A}" 2>/dev/null || echo "?")
  if [[ ${rpol} == "always" || ${rpol} == "on-failure" ]]; then
    ok "recovery policy is declared in the unit (Restart=${rpol}) - manage change through automation"
    pass=$((pass+1))
  else
    bad "Restart=${rpol} on ${UNIT_A} - recovery is not automated"
    fail=$((fail+1))
  fi

  head1 "Scorecard"
  printf '  passed: %s%d%s   failed: %s%d%s\n' "$C_OK" "${pass}" "$C_0" \
         "$([[ ${fail} -eq 0 ]] && printf '%s' "$C_OK" || printf '%s' "$C_BAD")" "${fail}" "$C_0"
  if [[ ${fail} -eq 0 ]]; then
    cat <<EOF

  ${C_OK}Design principles restored.${C_0} What you just proved, in exam vocabulary:
    - Design for failure and nothing fails: a whole AZ was killed twice and the
      customer never saw an error.
    - Implement elasticity / scale horizontally: capacity is a fleet, not a host.
    - Automate recovery: the replacement was declarative, not operational.
    - Decouple your components: a total dependency outage degraded the system
      to "queued", it did not take it down.
    - Test recovery procedures: you ran the game day instead of assuming.
  Sources: https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/design-principles.html

EOF
    return 0
  fi
  say ""
  say "  Not there yet. Re-run 'status' and 'hint'; the solution is commented"
  say "  at the bottom of this script if you are truly stuck."
  return 1
}

cmd_reset() {
  head1 "Escape hatch: rebuilding the correct architecture"
  rm -rf "${DROPIN_DIR}"
  install_lab >/dev/null
  write_baseline_elb_conf
  sed -i 's/^COUPLING=.*/COUPLING=queue/' "${LAB_ROOT}"/env/*.env
  rm -f "${LAB_ROOT}"/state/*.drain
  systemctl daemon-reload
  start_baseline
  systemctl restart "${UNIT_A}" "${UNIT_B}" "${UNIT_ELB}" "${UNIT_WORKER}"
  wait_http "${ELB_URL}/" 200 20 || warn "the front door is still not answering 200"
  ok "baseline restored - run 'verify' to confirm, then 'break' to try again"
}

cmd_cleanup() {
  head1 "Removing the lab"
  systemctl disable --now "${UNIT_A}" "${UNIT_B}" "${UNIT_ELB}" "${UNIT_WORKER}" >/dev/null 2>&1 || true
  rm -rf "${DROPIN_DIR}"
  rm -f "${UNIT_DIR}/${PREFIX}-app@.service" "${UNIT_DIR}/${UNIT_ELB}" "${UNIT_DIR}/${UNIT_WORKER}"
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true
  rm -rf "${LAB_ROOT}"
  ok "units, drop-ins and ${LAB_ROOT} removed - the VM is back to where it started"
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^#//'
}

main() {
  local action="${1:-all}"
  case "${action}" in
    -h|--help|help) usage; exit 0 ;;
    status)  require_root "$@"; cmd_status ;;
    hint)    cmd_hint ;;
    verify)  require_root "$@"; require_tools; cmd_verify ;;
    deploy)  require_root "$@"; require_tools; guard_disposable; ports_available; cmd_deploy ;;
    break)   require_root "$@"; require_tools; guard_disposable; ports_available; cmd_break ;;
    reset)   require_root "$@"; require_tools; cmd_reset ;;
    cleanup) require_root "$@"; cmd_cleanup ;;
    all)     require_root "$@"; require_tools; guard_disposable; ports_available
             cmd_deploy; say ""; say "Baseline is healthy. Breaking it now..."; sleep 2
             cmd_break ;;
    *)       die "unknown action '${action}' - try: deploy | break | status | hint | verify | reset | cleanup" ;;
  esac
}

main "$@"

# ==============================================================================
#  S O L U T I O N   -   do not read before 'verify' has failed on you twice
# ==============================================================================
#
#  STEP 0 - Triage from the outside in. Never guess; ask the system.
#  ----------------------------------------------------------------
#    $ curl -i http://127.0.0.1:8080/
#    HTTP/1.1 502 Bad Gateway
#    X-Elb-Error: NoHealthyTargets
#
#    A 502 from a load balancer means the balancer is alive and the targets are
#    not. Confirm by bypassing it:
#
#    $ curl -sv http://127.0.0.1:9001/ 2>&1 | tail -3
#    * connect to 127.0.0.1 port 9001 failed: Connection refused
#    $ curl -s http://127.0.0.1:8080/elb-status | python3 -m json.tool
#    {
#        "health_check_enabled": false,
#        "registered_targets": ["127.0.0.1:9001"],
#        ...
#    }
#
#    Two findings already: ONE target (single point of failure) and health
#    checks DISABLED (the balancer cannot fail over because it cannot tell a
#    dead target from a live one).
#
#    $ systemctl status awsclf12-app@az-a --no-pager | head -4
#    * awsclf12-app@az-a.service - CLF-C02 1.2 lab - application instance az-a
#         Loaded: loaded (/etc/systemd/system/awsclf12-app@.service; enabled)
#        Drop-In: /etc/systemd/system/awsclf12-app@.service.d
#                 `-10-no-self-healing.conf
#         Active: failed (Result: signal)
#
#    Third finding: a drop-in disabled automatic recovery. In AWS terms, the
#    instance was killed and nothing replaced it - there is no Auto Scaling
#    group, so a failed instance stays failed.
#
#    $ systemctl is-enabled awsclf12-app@az-b
#    disabled
#
#    Fourth finding: the second Availability Zone was decommissioned.
#
#
#  STEP 1 - Restore automatic recovery (criterion B)
#  ------------------------------------------------
#  Principle: "Automatically recover from failure." In AWS this is an EC2 Auto
#  Scaling group with ELB health checks, or EC2 auto recovery for a single
#  instance. Recovery must be declared in configuration, never performed by a
#  human at 03:00.
#
#    $ sudo rm -rf /etc/systemd/system/awsclf12-app@.service.d
#    $ sudo systemctl daemon-reload
#    $ sudo systemctl show -p Restart --value awsclf12-app@az-a
#    always
#
#
#  STEP 2 - Bring the fleet back to two Availability Zones (criterion A)
#  --------------------------------------------------------------------
#  Principle: remove single points of failure; scale horizontally; spread
#  across AZs, because the AZ is AWS's unit of fault isolation.
#
#    $ sudo systemctl enable --now awsclf12-app@az-a awsclf12-app@az-b
#    $ curl -s http://127.0.0.1:9001/health; curl -s http://127.0.0.1:9002/health
#    {"availability_zone": "us-east-1a", "instance_id": "i-0a1b...", "status": "healthy"}
#    {"availability_zone": "us-east-1b", "instance_id": "i-0b9c...", "status": "healthy"}
#
#
#  STEP 3 - Register both targets and turn health checks back on (criteria A+C)
#  ---------------------------------------------------------------------------
#  Principle: the balancer must be able to observe its targets, or redundancy
#  is decorative. Equivalent to `aws elbv2 register-targets` plus
#  `aws elbv2 modify-target-group --health-check-enabled`.
#
#    $ sudo tee /opt/awsclf-lab-1.2/etc/elb.conf >/dev/null <<'EOF'
#    targets=127.0.0.1:9001,127.0.0.1:9002
#    health_check=on
#    health_path=/health
#    interval=2
#    timeout=1
#    healthy_threshold=2
#    unhealthy_threshold=2
#    EOF
#
#  The balancer hot-reloads the file; if you prefer to be explicit:
#
#    $ sudo systemctl restart awsclf12-elb
#    $ sleep 5 && curl -s http://127.0.0.1:8080/elb-status | python3 -m json.tool
#    {
#        "health_check_enabled": true,
#        "registered_targets": ["127.0.0.1:9001", "127.0.0.1:9002"],
#        "target_health": {
#            "127.0.0.1:9001": {"reason": "HTTP 200", "state": "healthy", ...},
#            "127.0.0.1:9002": {"reason": "HTTP 200", "state": "healthy", ...}
#        }
#    }
#
#  Prove the failover by hand before the grader does it for you:
#
#    $ sudo systemctl kill -s SIGKILL awsclf12-app@az-a
#    $ for i in $(seq 8); do curl -s -o /dev/null -w '%{http_code} ' \
#        http://127.0.0.1:8080/; sleep 0.5; done; echo
#    200 200 200 200 200 200 200 200
#    $ systemctl is-active awsclf12-app@az-a
#    active                      # it came back on its own, in ~2 seconds
#
#
#  STEP 4 - Decouple the checkout path from payments (criterion D)
#  --------------------------------------------------------------
#  Principle: "Decouple your components." A synchronous call makes the caller's
#  availability the PRODUCT of every downstream availability. A queue (Amazon
#  SQS) turns a dependency outage into a backlog: the producer keeps accepting
#  work, the consumer catches up, and the two scale independently.
#
#    $ grep -H COUPLING /opt/awsclf-lab-1.2/env/*.env
#    /opt/awsclf-lab-1.2/env/az-a.env:COUPLING=sync
#    /opt/awsclf-lab-1.2/env/az-b.env:COUPLING=sync
#
#    $ sudo sed -i 's/^COUPLING=.*/COUPLING=queue/' /opt/awsclf-lab-1.2/env/*.env
#    $ sudo systemctl restart awsclf12-app@az-a awsclf12-app@az-b
#
#  Note WHY a restart is needed here and not for elb.conf: EnvironmentFile is
#  read by systemd at process start. Changing configuration that is only read
#  at boot is exactly the change-management problem the Reliability pillar
#  tells you to automate rather than perform ad hoc.
#
#  Test it with the dependency still down - this is the point of the exercise:
#
#    $ sudo systemctl stop awsclf12-worker
#    $ curl -i -X POST http://127.0.0.1:8080/checkout
#    HTTP/1.1 202 Accepted
#    {
#      "order_id": "ord-9f2c41ab77e0",
#      "status": "queued",
#      "availability_zone": "us-east-1b"
#    }
#
#  The customer's order was accepted during a total outage of payments.
#
#
#  STEP 5 - Bring the consumer back and let the backlog drain by itself
#  -------------------------------------------------------------------
#    $ sudo systemctl enable --now awsclf12-worker
#    $ sleep 3 && curl -s http://127.0.0.1:9100/stats
#    {"processed_since_start": 1, "queue_backlog": 0}
#    $ ls /opt/awsclf-lab-1.2/processed/
#    ord-9f2c41ab77e0.json
#    $ journalctl -u awsclf12-worker -n 3 --no-pager
#    ... processed ord-9f2c41ab77e0 (queued at 1756900000.123)
#
#  Nobody replayed anything. That is the whole value of the queue.
#
#
#  STEP 6 - Run the game day (criterion E)
#  ---------------------------------------
#    $ sudo ./clf-c02-1.2-break-and-fix.sh verify
#    [ PASS ] front door returns HTTP 200 through the load balancer
#    [ PASS ] at least two targets are healthy in the target group (multi-AZ fleet)
#    [ PASS ] SIGKILL on az-a: 6/6 requests still returned 200 (no single point of failure)
#    [ PASS ] az-a recovered automatically in <=2s with no operator action
#    [ PASS ] SIGKILL on az-b: 6/6 requests still returned 200 (no single point of failure)
#    [ PASS ] az-b recovered automatically in <=2s with no operator action
#    [ PASS ] a target reporting 503 on /health received 0 requests (health checks gate traffic)
#    [ PASS ] checkout returned 202 Accepted while the payments worker was DOWN (loose coupling)
#    [ PASS ] the buffered order was settled 2s after the worker returned, backlog drained to 0
#    [ PASS ] recovery policy is declared in the unit (Restart=always) - manage change through automation
#      passed: 10   failed: 0
#
#  Testing recovery is itself one of the design principles: "Test recovery
#  procedures." An untested failover is a hypothesis, not a control.
#
#
#  THE ONE-SCREEN VERSION OF THE FIX
#  ---------------------------------
#    sudo rm -rf /etc/systemd/system/awsclf12-app@.service.d
#    sudo systemctl daemon-reload
#    sudo sed -i 's/^targets=.*/targets=127.0.0.1:9001,127.0.0.1:9002/;s/^health_check=.*/health_check=on/' \
#         /opt/awsclf-lab-1.2/etc/elb.conf
#    sudo sed -i 's/^COUPLING=.*/COUPLING=queue/' /opt/awsclf-lab-1.2/env/*.env
#    sudo systemctl enable --now awsclf12-app@az-a awsclf12-app@az-b awsclf12-worker awsclf12-elb
#    sudo systemctl restart awsclf12-app@az-a awsclf12-app@az-b awsclf12-elb
#
#
#  HOW EACH REPAIR MAPS TO THE EXAM'S DESIGN PRINCIPLES
#  ----------------------------------------------------
#   Repair in the lab                         Design principle / AWS mechanism
#   -----------------------------------------------------------------------------
#   Two targets in two AZs                    Remove single points of failure;
#                                             scale horizontally; Multi-AZ.
#                                             ELB + EC2 Auto Scaling across AZs.
#   health_check=on, unhealthy target drained Design for failure; automatic
#                                             detection. ALB target group health
#                                             checks + ASG health replacement.
#   Restart=always                            Automatically recover from failure;
#                                             manage change through automation.
#                                             EC2 auto recovery / ASG.
#   COUPLING=queue                            Decouple your components; degrade
#                                             instead of failing. Amazon SQS,
#                                             Amazon SNS, EventBridge.
#   Stateless instances (no local state)      Instances are disposable, which is
#                                             what makes elasticity possible.
#                                             Store state in RDS/DynamoDB/S3/EFS.
#   'verify' as a rehearsed exercise          Test recovery procedures (game days);
#                                             AWS Fault Injection Service does
#                                             this against real infrastructure.
#
#  EXAM-STYLE TRAPS THIS LAB IMMUNISES YOU AGAINST
#  -----------------------------------------------
#   - "We added a second instance, so we are highly available." Not until the
#     balancer health-checks it AND it sits in a different Availability Zone.
#     A second instance in the same AZ survives an instance failure, not an AZ
#     failure. (Step 3 with health_check=off is precisely this trap.)
#   - "We scaled vertically to a larger instance type." That is capacity, not
#     availability; the failure domain is still one host. Horizontal scaling is
#     the AWS design principle.
#   - "The retry logic in the client makes us resilient." Retries against a
#     single dead target produce a slower outage. Failover needs a second
#     target and a health signal.
#   - "Elasticity means the cloud is cheaper." Elasticity means you stop
#     guessing capacity - you provision what is needed now and change it later.
#     Cost benefit is a consequence, not the definition.
#   - "Loose coupling is a developer concern." A queue between tiers is what
#     kept the storefront accepting orders during a total payments outage.
#
#  Cleanup when you are done, this VM should go back to being boring:
#    sudo ./clf-c02-1.2-break-and-fix.sh cleanup
# ==============================================================================