#!/usr/bin/env bash
#
# =============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) - Exam guide version 1.0
#  Domain 3: Cloud Technology and Services
#  Task statement 3.3: Identify AWS compute services   (exam weight: 4.25)
#
#  BREAK & FIX LAB - "the compute stack that stopped serving traffic"
#
#  Source (exam guide):
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
#  Official documentation used to model the behaviour reproduced here:
#    EC2 instances .......... https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html
#    IMDSv2 ................. https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-metadata-v2-how-it-works.html
#    Instance profiles ...... https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html
#    EC2 Auto Scaling ....... https://docs.aws.amazon.com/autoscaling/ec2/userguide/auto-scaling-groups.html
#    ASG health checks ...... https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-health-checks.html
#    ALB target groups ...... https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html
#    Security groups ........ https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html
#    Lambda configuration ... https://docs.aws.amazon.com/lambda/latest/dg/configuration-function-common.html
#    Lambda timeouts ........ https://docs.aws.amazon.com/lambda/latest/dg/troubleshooting-invocation.html
#    Fargate / ECS / EKS .... https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html
#
# -----------------------------------------------------------------------------
#  WHY A LOCAL SIMULATION, AND WHAT IT IS NOT
# -----------------------------------------------------------------------------
#  Task statement 3.3 asks you to *identify* compute services and know when each
#  one applies. Memorising a service list does not build that judgement; seeing
#  the failure signature of each layer does. This lab therefore rebuilds, with
#  systemd units and small Python daemons on a single throwaway VM, the exact
#  control loops the managed services run for you:
#
#      awslab-imds.service      -> the Instance Metadata Service (169.254.169.254)
#      awslab-app@N.service     -> one "EC2 instance" running your workload
#      awslab-asg.service       -> EC2 Auto Scaling: reconciles desired capacity
#      awslab-elb.service       -> Application Load Balancer + target group health
#      awslab-lambda            -> Lambda invoke path (handler / timeout / memory)
#
#  It is a teaching model, NOT AWS. No AWS account, no credentials and no network
#  calls to AWS are involved; every credential string in this lab is a literal
#  placeholder. The value is in the symptoms: a 503 from the load balancer looks
#  identical whether the cause is a security group, a crash-looping instance, a
#  desired capacity of zero, or a dead metadata service - and the diagnostic path
#  that separates them is the same one you use on real EC2.
#
#  Services named in 3.3 that this lab only *contrasts* (they have no instance
#  for you to break, which is the point): Fargate, ECS, EKS, App Runner, Batch,
#  Lightsail, Elastic Beanstalk, Outposts. See the notes in `status`.
#
# -----------------------------------------------------------------------------
#  SAFETY
# -----------------------------------------------------------------------------
#  Run this ONLY on a disposable lab VM you can throw away.
#    * requires root (systemd units, an nftables table of its own, a loopback
#      address) and refuses to run without AWSLAB_CONFIRM=yes or --yes
#    * refuses to run on a real EC2 instance: the mock metadata service binds
#      169.254.169.254 and would shadow the genuine IMDS
#    * touches only: /opt/awslab, /etc/awslab, /var/lib/awslab,
#      /etc/systemd/system/awslab-*, /usr/local/bin/awslab-lambda,
#      nftables table `inet awslab`, and 169.254.169.254/32 on lo
#    * never flushes your firewall: it creates and deletes its OWN nft table
#    * `cleanup` removes exactly those objects and nothing else
#
#  Usage:
#    sudo ./awslab-compute.sh setup --yes     # build the lab
#    sudo ./awslab-compute.sh break [1-5]     # inject one fault (random if omitted)
#    sudo ./awslab-compute.sh status          # "console" view of the whole stack
#    sudo ./awslab-compute.sh hint [1|2]      # progressive hints, no spoilers
#    sudo ./awslab-compute.sh verify          # did you fix it?
#    sudo ./awslab-compute.sh reset           # undo every fault (the giving-up button)
#    sudo ./awslab-compute.sh cleanup         # remove the lab entirely
# =============================================================================

set -Eeuo pipefail

LAB_ROOT="/opt/awslab"
LAB_ETC="/etc/awslab"
LAB_STATE="/var/lib/awslab"
LAB_UNITS="/etc/systemd/system"
LAMBDA_BIN="/usr/local/bin/awslab-lambda"
IMDS_IP="169.254.169.254"
NFT_TABLE="awslab"
LISTENER_PORT="8080"
BASE_TARGET_PORT="8100"
MAX_SLOTS="8"
FAULT_FILE="${LAB_STATE}/.fault"

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[ lab ]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail() { printf '%s[fail ]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
ok()   { printf '%s[  ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }
die()  { fail "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Guards
# -----------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root (systemd units, nftables and a loopback address are needed)."
}

require_confirmation() {
    local arg="${1:-}"
    if [ "$arg" != "--yes" ] && [ "${AWSLAB_CONFIRM:-no}" != "yes" ]; then
        die "this rewrites systemd units and networking. Re-run with --yes (or AWSLAB_CONFIRM=yes) on a DISPOSABLE VM only."
    fi
}

refuse_on_real_ec2() {
    local vendor="" uuid=""
    [ -r /sys/devices/virtual/dmi/id/sys_vendor ] && vendor="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || true)"
    [ -r /sys/devices/virtual/dmi/id/product_uuid ] && uuid="$(cat /sys/devices/virtual/dmi/id/product_uuid 2>/dev/null || true)"
    if printf '%s' "$vendor" | grep -qi 'amazon' || printf '%s' "$uuid" | grep -qi '^ec2'; then
        die "this looks like a real EC2 instance. The mock IMDS would shadow 169.254.169.254 and break the instance profile credential chain. Refusing."
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if [ "$(systemd-detect-virt 2>/dev/null || true)" = "amazon" ]; then
            die "systemd-detect-virt reports 'amazon' (real EC2). Refusing."
        fi
    fi
}

require_deps() {
    local missing=""
    for c in python3 systemctl ip curl; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] || die "missing required commands:$missing"
    command -v nft >/dev/null 2>&1 || warn "nftables (nft) not found: fault 1 (security-group ingress) will be skipped."
    command -v ss  >/dev/null 2>&1 || warn "iproute2 'ss' not found: socket listings in \`status\` will be limited."
}

require_free_ports() {
    command -v ss >/dev/null 2>&1 || return 0
    local busy="" p
    for p in "$LISTENER_PORT" $(seq $((BASE_TARGET_PORT + 1)) $((BASE_TARGET_PORT + 2))); do
        if ss -ltnH "sport = :${p}" 2>/dev/null | grep -q . ; then busy="$busy $p"; fi
    done
    [ -z "$busy" ] || die "ports already in use:$busy - free them or run the lab on a clean VM."
}

require_setup() {
    [ -d "$LAB_ROOT" ] && [ -f "${LAB_ROOT}/app.py" ] || die "lab is not installed. Run: $0 setup --yes"
}

# -----------------------------------------------------------------------------
# Lab code - the pieces that never change
# -----------------------------------------------------------------------------
write_code_files() {
    mkdir -p "$LAB_ROOT" "${LAB_ROOT}/app" "${LAB_ROOT}/lambda" "$LAB_ETC" "${LAB_ETC}/functions" "$LAB_STATE"

cat > "${LAB_ROOT}/imds.py" <<'PY'
#!/usr/bin/env python3
"""Stand-in for the EC2 Instance Metadata Service (IMDSv2).

On a real instance this answers on the link-local address 169.254.169.254, is
never routed off the host, and - with IMDSv2 - requires a session token obtained
with a PUT before any GET is served. That token requirement is what defeats the
SSRF class of attacks that plagued IMDSv1.
  https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-metadata-v2-how-it-works.html

Difference from AWS, stated plainly: a real IMDS is per-instance by construction,
so it always knows which instance is asking. This lab multiplexes several
"instances" onto one VM, so the caller sends X-Awslab-Slot to identify itself.
No such header exists on EC2.
"""
import json
import os
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGISTRY = "/var/lib/awslab/instances.json"
REGION = "us-east-1"
AZ = "us-east-1a"
INSTANCE_TYPE = "t3.micro"
ROLE = "awslab-app-instance-profile"
TOKENS = {}


def slot_instance_id(slot):
    try:
        with open(REGISTRY) as fh:
            return json.load(fh)[str(slot)]["instance_id"]
    except Exception:
        return "i-0aa00000000000000"


class Handler(BaseHTTPRequestHandler):
    server_version = "EC2ws"

    def log_message(self, fmt, *args):
        print("imds %s %s" % (self.address_string(), fmt % args), flush=True)

    def _reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_PUT(self):
        if self.path != "/latest/api/token":
            return self._reply(404, "404 - Not Found")
        ttl = self.headers.get("X-aws-ec2-metadata-token-ttl-seconds")
        if ttl is None:
            return self._reply(400, "400 - missing X-aws-ec2-metadata-token-ttl-seconds")
        token = secrets.token_hex(20)
        TOKENS[token] = time.time() + min(int(ttl), 21600)
        self._reply(200, token)

    def do_GET(self):
        token = self.headers.get("X-aws-ec2-metadata-token", "")
        if TOKENS.get(token, 0) < time.time():
            # IMDSv2 enforced: no valid session token, no metadata.
            return self._reply(401, "401 - Unauthorized")
        slot = self.headers.get("X-Awslab-Slot", "1")
        path = self.path.rstrip("/")
        creds = json.dumps({
            "Code": "Success",
            "Type": "AWS-HMAC",
            "AccessKeyId": "ASIA-LAB-PLACEHOLDER",
            "SecretAccessKey": "LAB-PLACEHOLDER-NOT-A-REAL-SECRET",
            "Token": "LAB-PLACEHOLDER-SESSION-TOKEN",
            "Expiration": "2099-01-01T00:00:00Z",
        }, indent=2)
        table = {
            "/latest/meta-data": "instance-id\ninstance-type\nplacement/\niam/",
            "/latest/meta-data/instance-id": slot_instance_id(slot),
            "/latest/meta-data/instance-type": INSTANCE_TYPE,
            "/latest/meta-data/placement/region": REGION,
            "/latest/meta-data/placement/availability-zone": AZ,
            "/latest/meta-data/iam/security-credentials": ROLE,
            "/latest/meta-data/iam/security-credentials/" + ROLE: creds,
        }
        if path in table:
            return self._reply(200, table[path])
        self._reply(404, "404 - Not Found")


if __name__ == "__main__":
    bind = os.environ.get("AWSLAB_IMDS_BIND", "169.254.169.254")
    ThreadingHTTPServer((bind, 80), Handler).serve_forever()
PY

cat > "${LAB_ROOT}/app.py" <<'PY'
#!/usr/bin/env python3
"""The workload running on each "EC2 instance" of the Auto Scaling group.

Two hard dependencies are modelled on purpose, because both are classic
production failure modes:
  1. a configuration file baked into the AMI / written by user data
  2. instance metadata, used here to learn the instance id and AZ
If either is unavailable the process exits non-zero. systemd restarts it, which
is the local equivalent of an instance that boots, fails its application start,
and never reaches InService.
"""
import json
import os
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG = "/opt/awslab/app/config.json"
IMDS = "http://169.254.169.254"
SLOT = os.environ.get("AWSLAB_SLOT", "1")
PORT = int(os.environ.get("AWSLAB_PORT") or (8100 + int(SLOT)))
STARTED = time.time()


def imds_token():
    req = urllib.request.Request(
        IMDS + "/latest/api/token", method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"})
    with urllib.request.urlopen(req, timeout=2) as resp:
        return resp.read().decode()


def imds_get(path, token):
    req = urllib.request.Request(IMDS + path, headers={
        "X-aws-ec2-metadata-token": token,
        "X-Awslab-Slot": SLOT,
    })
    with urllib.request.urlopen(req, timeout=2) as resp:
        return resp.read().decode()


try:
    with open(CONFIG) as fh:
        CFG = json.load(fh)
except Exception as exc:
    print("FATAL: application configuration unreadable (%s): %s" % (CONFIG, exc),
          file=sys.stderr, flush=True)
    sys.exit(1)

try:
    _tok = imds_token()
    INSTANCE_ID = imds_get("/latest/meta-data/instance-id", _tok)
    AZ = imds_get("/latest/meta-data/placement/availability-zone", _tok)
    INSTANCE_TYPE = imds_get("/latest/meta-data/instance-type", _tok)
except Exception as exc:
    print("FATAL: instance metadata unavailable at %s (%s: %s)"
          % (IMDS, type(exc).__name__, exc), file=sys.stderr, flush=True)
    sys.exit(1)


class Handler(BaseHTTPRequestHandler):
    server_version = "awslab-app"

    def log_message(self, fmt, *args):
        print("app slot=%s %s" % (SLOT, fmt % args), flush=True)

    def _json(self, code, payload):
        data = json.dumps(payload, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Instance-Id", INSTANCE_ID)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            body = b"OK\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Instance-Id", INSTANCE_ID)
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/":
            return self._json(200, {
                "service": CFG.get("service", "orders-web"),
                "version": CFG.get("version", "0.0.0"),
                "instance_id": INSTANCE_ID,
                "instance_type": INSTANCE_TYPE,
                "availability_zone": AZ,
                "slot": SLOT,
                "uptime_s": round(time.time() - STARTED, 1),
            })
        self._json(404, {"error": "NotFound", "path": self.path})


if __name__ == "__main__":
    print("listening on 0.0.0.0:%d as %s (%s)" % (PORT, INSTANCE_ID, AZ), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PY

cat > "${LAB_ROOT}/elb.py" <<'PY'
#!/usr/bin/env python3
"""Application Load Balancer stand-in: one listener, one target group.

Health-check semantics copied from ALB target groups: an interval, a timeout, a
healthy threshold and an unhealthy threshold. A target only receives traffic
after N consecutive successes, and only leaves rotation after N consecutive
failures - which is why a broken instance keeps serving for a few seconds, and a
fixed one does not come back instantly.
  https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html

With zero healthy targets the listener answers 503, exactly like a real ALB.
"""
import itertools
import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGISTRY = "/var/lib/awslab/instances.json"
HEALTH_OUT = "/var/lib/awslab/target-health.json"
LISTENER_PORT = int(os.environ.get("AWSLAB_LISTENER_PORT", "8080"))
HC_PATH = "/health"
HC_INTERVAL = 5
HC_TIMEOUT = 2
HEALTHY_THRESHOLD = 2
UNHEALTHY_THRESHOLD = 2

STATE = {}
LOCK = threading.Lock()
COUNTER = itertools.count()


def registered_targets():
    try:
        with open(REGISTRY) as fh:
            return json.load(fh)
    except Exception:
        return {}


def probe(port):
    started = time.time()
    url = "http://127.0.0.1:%d%s" % (port, HC_PATH)
    try:
        with urllib.request.urlopen(url, timeout=HC_TIMEOUT) as resp:
            code = resp.status
            resp.read()
        return code == 200, code, int((time.time() - started) * 1000), ""
    except Exception as exc:
        return False, None, int((time.time() - started) * 1000), \
            "%s: %s" % (type(exc).__name__, exc)


def health_loop():
    while True:
        targets = registered_targets()
        with LOCK:
            for slot in [s for s in STATE if s not in targets]:
                STATE.pop(slot, None)
        for slot, info in targets.items():
            healthy, code, rtt, reason = probe(int(info["port"]))
            with LOCK:
                st = STATE.setdefault(slot, {"state": "initial", "ok": 0, "bad": 0})
                st["instance_id"] = info.get("instance_id")
                st["port"] = info["port"]
                st["rtt_ms"] = rtt
                st["last_code"] = code
                st["reason"] = reason or ("HTTP %s" % code)
                if healthy:
                    st["ok"] += 1
                    st["bad"] = 0
                    if st["ok"] >= HEALTHY_THRESHOLD:
                        st["state"] = "healthy"
                else:
                    st["bad"] += 1
                    st["ok"] = 0
                    if st["bad"] >= UNHEALTHY_THRESHOLD:
                        st["state"] = "unhealthy"
                st["checked_at"] = int(time.time())
        with LOCK:
            snapshot = json.dumps(STATE, indent=2)
        tmp = HEALTH_OUT + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(snapshot + "\n")
        os.replace(tmp, HEALTH_OUT)
        time.sleep(HC_INTERVAL)


class Listener(BaseHTTPRequestHandler):
    server_version = "awselb/2.0"

    def log_message(self, fmt, *args):
        print("elb %s" % (fmt % args), flush=True)

    def _reply(self, code, body, ctype="application/json", target=None):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if target:
            self.send_header("X-Target-Slot", target)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        with LOCK:
            healthy = sorted(s for s, v in STATE.items() if v.get("state") == "healthy")
        if not healthy:
            with LOCK:
                registered = len(STATE)
            return self._reply(503,
                               "503 Service Temporarily Unavailable\n"
                               "target group awslab-tg: %d target(s) registered, "
                               "0 healthy\n" % registered,
                               ctype="text/plain")
        slot = healthy[next(COUNTER) % len(healthy)]
        with LOCK:
            port = int(STATE[slot]["port"])
        try:
            with urllib.request.urlopen(
                    "http://127.0.0.1:%d%s" % (port, self.path), timeout=3) as resp:
                payload = resp.read()
                code = resp.status
            self._reply(code, payload, target=slot)
        except Exception as exc:
            self._reply(502, "502 Bad Gateway (%s)\n" % exc, ctype="text/plain")


if __name__ == "__main__":
    threading.Thread(target=health_loop, daemon=True).start()
    print("listener on 0.0.0.0:%d -> target group awslab-tg" % LISTENER_PORT, flush=True)
    ThreadingHTTPServer(("0.0.0.0", LISTENER_PORT), Listener).serve_forever()
PY

cat > "${LAB_ROOT}/asg.py" <<'PY'
#!/usr/bin/env python3
"""EC2 Auto Scaling group stand-in: a reconciliation loop, nothing more.

An Auto Scaling group is not a scheduler and not a load balancer. It compares
desired capacity against running instances and closes the gap - launching,
terminating, and (only when the health check type is ELB) replacing instances the
load balancer reports unhealthy. Everything below is that loop.
  https://docs.aws.amazon.com/autoscaling/ec2/userguide/auto-scaling-groups.html
  https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-health-checks.html

Note the AWS default reproduced here: HEALTH_CHECK_TYPE=EC2 means the group only
cares that the instance is running. An instance can be running, and utterly
unable to serve traffic, and the group will happily leave it in place.
"""
import json
import os
import subprocess
import time

CONF = "/etc/awslab/asg.conf"
REGISTRY = "/var/lib/awslab/instances.json"
HEALTH = "/var/lib/awslab/target-health.json"
UNIT = "awslab-app@%d.service"
BASE_PORT = 8100
MAX_SLOTS = 8
LAUNCHED = {}


def read_conf():
    conf = {}
    with open(CONF) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            conf[key.strip()] = value.strip().strip('"').strip("'")
    return conf


def systemctl(*args):
    return subprocess.run(["systemctl"] + list(args), capture_output=True, text=True)


def instance_id(slot):
    return "i-0aa%014d" % int(slot)


def reconcile():
    try:
        conf = read_conf()
        min_size = int(conf.get("MIN_SIZE", "0"))
        max_size = int(conf.get("MAX_SIZE", "0"))
        desired = int(conf.get("DESIRED_CAPACITY", "0"))
        hc_type = conf.get("HEALTH_CHECK_TYPE", "EC2").upper()
        grace = int(conf.get("HEALTH_CHECK_GRACE_PERIOD", "30"))
    except Exception as exc:
        print("ValidationError: cannot parse %s (%s) - group left unchanged"
              % (CONF, exc), flush=True)
        return
    if not (0 <= min_size <= desired <= max_size <= MAX_SLOTS):
        print("ValidationError: DESIRED_CAPACITY must satisfy "
              "MIN_SIZE <= DESIRED_CAPACITY <= MAX_SIZE (min=%d desired=%d max=%d) "
              "- group left unchanged" % (min_size, desired, max_size), flush=True)
        return

    registry = {}
    for slot in range(1, MAX_SLOTS + 1):
        unit = UNIT % slot
        wanted = slot <= desired
        active = systemctl("is-active", "--quiet", unit).returncode == 0
        if wanted and not active:
            systemctl("reset-failed", unit)
            result = systemctl("start", unit)
            LAUNCHED[str(slot)] = time.time()
            print("Launching instance %s in slot %d (%s)%s"
                  % (instance_id(slot), slot, unit,
                     "" if result.returncode == 0 else " FAILED: " + result.stderr.strip()),
                  flush=True)
        elif not wanted and active:
            systemctl("stop", unit)
            LAUNCHED.pop(str(slot), None)
            print("Terminating instance %s in slot %d (scale in)"
                  % (instance_id(slot), slot), flush=True)
        if wanted:
            LAUNCHED.setdefault(str(slot), time.time())
            registry[str(slot)] = {
                "instance_id": instance_id(slot),
                "port": BASE_PORT + slot,
                "unit": unit,
                "lifecycle": "InService" if active else "Pending",
                "launched_at": int(LAUNCHED[str(slot)]),
            }

    tmp = REGISTRY + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(json.dumps(registry, indent=2) + "\n")
    os.replace(tmp, REGISTRY)

    if hc_type != "ELB":
        return
    try:
        with open(HEALTH) as fh:
            health = json.load(fh)
    except Exception:
        return
    for slot, status in health.items():
        if status.get("state") != "unhealthy" or slot not in registry:
            continue
        if time.time() - LAUNCHED.get(slot, 0) < grace:
            continue
        print("Instance %s failed the ELB health check - terminating and replacing"
              % registry[slot]["instance_id"], flush=True)
        systemctl("restart", UNIT % int(slot))
        LAUNCHED[slot] = time.time()


if __name__ == "__main__":
    print("Auto Scaling group awslab-asg starting reconciliation loop", flush=True)
    while True:
        try:
            reconcile()
        except Exception as exc:
            print("reconcile error: %s: %s" % (type(exc).__name__, exc), flush=True)
        time.sleep(5)
PY

cat > "${LAB_ROOT}/lambda_runtime.py" <<'PY'
#!/usr/bin/env python3
"""AWS Lambda invoke path stand-in.

The whole point of the contrast with EC2: there is no instance here to log into,
no OS to patch, no capacity to reconcile. The only knobs you own are the ones in
the function configuration - handler, timeout, memory, runtime, architecture -
and the failure signatures come straight from those.
  https://docs.aws.amazon.com/lambda/latest/dg/configuration-function-common.html
  https://docs.aws.amazon.com/lambda/latest/dg/troubleshooting-invocation.html

Fidelity note: real Lambda hard-kills a function that exceeds its memory limit.
This lab only *reports* Max Memory Used, because enforcing an address-space limit
on a shared VM would kill the interpreter itself for reasons unrelated to the
lesson.
"""
import importlib
import json
import math
import os
import resource
import signal
import sys
import time
import traceback
import uuid

FN_DIR = "/etc/awslab/functions"
CODE_DIR = "/opt/awslab/lambda"


class TimeoutError_(Exception):
    pass


def _on_alarm(signum, frame):
    raise TimeoutError_()


class Context:
    def __init__(self, request_id, name, timeout, memory):
        self.aws_request_id = request_id
        self.function_name = name
        self.function_version = "$LATEST"
        self.memory_limit_in_mb = memory
        self._deadline = time.time() + timeout

    def get_remaining_time_in_millis(self):
        return max(0, int((self._deadline - time.time()) * 1000))


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "invoke":
        print("usage: awslab-lambda invoke <function-name> ['<json-payload>']",
              file=sys.stderr)
        return 2
    name = sys.argv[2]
    try:
        payload = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    except json.JSONDecodeError as exc:
        print(json.dumps({"errorType": "InvalidRequestContentException",
                          "errorMessage": "payload is not valid JSON: %s" % exc}))
        return 1
    try:
        with open(os.path.join(FN_DIR, name + ".json")) as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        print(json.dumps({"errorType": "ResourceNotFoundException",
                          "errorMessage": "Function not found: %s" % name}))
        return 1

    handler = str(cfg.get("Handler", ""))
    timeout = float(cfg.get("Timeout", 3))
    memory = int(cfg.get("MemorySize", 128))
    request_id = str(uuid.uuid4())
    sys.path.insert(0, CODE_DIR)

    print("START RequestId: %s Version: $LATEST" % request_id)
    started = time.time()
    status = 0
    body = None
    if "." not in handler:
        print(json.dumps({
            "errorType": "Runtime.HandlerNotFound",
            "errorMessage": "Handler '%s' is not in the form 'module.function'" % handler}))
        return 1
    module_name, func_name = handler.rsplit(".", 1)
    try:
        module = importlib.import_module(module_name)
        entry = getattr(module, func_name)
    except Exception as exc:
        print(json.dumps({
            "errorType": "Runtime.HandlerNotFound",
            "errorMessage": "Unable to import module '%s' or find function '%s' "
                            "(handler = %s): %s" % (module_name, func_name, handler, exc)}))
        return 1

    signal.signal(signal.SIGALRM, _on_alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        body = json.dumps(entry(payload, Context(request_id, name, timeout, memory)))
    except TimeoutError_:
        print("%s Task timed out after %.2f seconds" % (request_id, timeout))
        status = 1
    except Exception:
        traceback.print_exc()
        print(json.dumps({"errorType": "Runtime.UnhandledException",
                          "errorMessage": "see traceback above"}))
        status = 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)

    duration_ms = (time.time() - started) * 1000
    if body is not None:
        print(body)
    print("END RequestId: %s" % request_id)
    print("REPORT RequestId: %s Duration: %.2f ms Billed Duration: %d ms "
          "Memory Size: %d MB Max Memory Used: %d MB"
          % (request_id, duration_ms, math.ceil(duration_ms), memory,
             max(1, resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024)))
    return status


if __name__ == "__main__":
    sys.exit(main())
PY

cat > "${LAB_ROOT}/lambda/orders.py" <<'PY'
"""Function code for awslab-lambda function `orders-api`.

The sleep stands in for a synchronous downstream call (DynamoDB, RDS Proxy, an
external payment API). It is the reason the function's Timeout setting matters:
the code is correct, the configuration decides whether it is allowed to finish.
"""
import time

DOWNSTREAM_LATENCY_S = 2.0


def handler(event, context):
    time.sleep(DOWNSTREAM_LATENCY_S)
    items = event.get("items", [])
    return {
        "statusCode": 200,
        "body": {
            "requestId": context.aws_request_id,
            "orders_processed": len(items),
            "memory_limit_in_mb": context.memory_limit_in_mb,
            "remaining_ms": context.get_remaining_time_in_millis(),
        },
    }
PY

cat > "$LAMBDA_BIN" <<'SH'
#!/bin/sh
# Thin CLI in front of the lab's Lambda runtime, so the student types something
# that reads like `aws lambda invoke`.
exec python3 /opt/awslab/lambda_runtime.py "$@"
SH
    chmod 0755 "$LAMBDA_BIN"
    chmod 0755 "${LAB_ROOT}"/*.py
}

# -----------------------------------------------------------------------------
# Lab configuration - the pieces the faults modify, and `reset` restores
# -----------------------------------------------------------------------------
write_config_files() {
    mkdir -p "${LAB_ROOT}/app" "${LAB_ETC}/functions" "$LAB_STATE"

cat > "${LAB_ROOT}/app/config.json" <<'JSON'
{
  "service": "orders-web",
  "version": "2.4.1",
  "greeting": "orders API - lab build",
  "depends_on": ["imds", "orders-api"]
}
JSON
    cp -f "${LAB_ROOT}/app/config.json" "${LAB_ROOT}/app/config.json.ami-baseline"

cat > "${LAB_ETC}/asg.conf" <<'CONF'
# Auto Scaling group: awslab-asg
# Same four settings the console shows you, and they are validated the same way:
# MIN_SIZE <= DESIRED_CAPACITY <= MAX_SIZE, or the group refuses the update.
MIN_SIZE=1
MAX_SIZE=4
DESIRED_CAPACITY=2
# EC2 (the AWS default) = "is the instance running?".
# ELB = "is the load balancer willing to send it traffic?".
HEALTH_CHECK_TYPE=EC2
HEALTH_CHECK_GRACE_PERIOD=30
CONF

cat > "${LAB_ETC}/functions/orders-api.json" <<'JSON'
{
  "FunctionName": "orders-api",
  "Runtime": "python3.12",
  "Architecture": "arm64",
  "Handler": "orders.handler",
  "Timeout": 10,
  "MemorySize": 256,
  "Description": "Order intake - invoked by API Gateway in the real stack"
}
JSON
}

write_units() {
cat > "${LAB_UNITS}/awslab-imds.service" <<'UNIT'
[Unit]
Description=awslab - mock EC2 Instance Metadata Service (IMDSv2) on 169.254.169.254
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /opt/awslab/imds.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

cat > "${LAB_UNITS}/awslab-app@.service" <<'UNIT'
[Unit]
Description=awslab - orders-web workload on instance slot %i
After=awslab-imds.service
Wants=awslab-imds.service
StartLimitIntervalSec=120
StartLimitBurst=20

[Service]
Type=simple
Environment=AWSLAB_SLOT=%i
ExecStart=/usr/bin/env python3 /opt/awslab/app.py
Restart=always
RestartSec=3
UNIT

cat > "${LAB_UNITS}/awslab-elb.service" <<'UNIT'
[Unit]
Description=awslab - Application Load Balancer listener and target group health checks
After=network-online.target

[Service]
Type=simple
Environment=AWSLAB_LISTENER_PORT=8080
ExecStart=/usr/bin/env python3 /opt/awslab/elb.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

cat > "${LAB_UNITS}/awslab-asg.service" <<'UNIT'
[Unit]
Description=awslab - EC2 Auto Scaling group reconciliation loop
After=awslab-imds.service
Wants=awslab-imds.service

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /opt/awslab/asg.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
}

ensure_imds_address() {
    if ! ip -4 addr show dev lo 2>/dev/null | grep -q "$IMDS_IP"; then
        ip addr add "${IMDS_IP}/32" dev lo
    fi
}

start_stack() {
    systemctl enable --now awslab-imds.service >/dev/null 2>&1
    systemctl enable --now awslab-elb.service  >/dev/null 2>&1
    systemctl enable --now awslab-asg.service  >/dev/null 2>&1
}

restart_stack() {
    systemctl restart awslab-imds.service
    systemctl restart awslab-elb.service
    systemctl restart awslab-asg.service
}

wait_for_listener() {
    local deadline=$(( SECONDS + ${1:-60} )) code
    while [ "$SECONDS" -lt "$deadline" ]; do
        code="$(curl -s -o /dev/null -m 4 -w '%{http_code}' "http://127.0.0.1:${LISTENER_PORT}/" || true)"
        [ "$code" = "200" ] && return 0
        sleep 2
    done
    return 1
}

# -----------------------------------------------------------------------------
# setup
# -----------------------------------------------------------------------------
cmd_setup() {
    require_root
    require_confirmation "${1:-}"
    refuse_on_real_ec2
    require_deps
    require_free_ports

    info "installing lab code under ${LAB_ROOT}"
    write_code_files
    write_config_files
    info "installing systemd units"
    write_units
    info "adding ${IMDS_IP}/32 to lo for the metadata service"
    ensure_imds_address
    info "starting the stack (IMDS, ALB, Auto Scaling group)"
    start_stack

    if wait_for_listener 60; then
        ok "listener http://127.0.0.1:${LISTENER_PORT}/ is serving 200 from the target group"
    else
        warn "listener is not healthy yet - check: journalctl -u awslab-elb -u awslab-asg -n 50"
    fi

    rule
    say "${C_BLD}THE STACK YOU JUST BUILT (task statement 3.3 in one diagram)${C_OFF}"
    rule
    cat <<'MAP'
   client
     |
     v  http://127.0.0.1:8080/            <- ELASTIC LOAD BALANCING (ALB listener)
  [ awslab-elb ] --health checks--> /health
     |                                    <- target group awslab-tg
     +--> 127.0.0.1:8101  awslab-app@1    <- AMAZON EC2 instance (slot 1)
     +--> 127.0.0.1:8102  awslab-app@2    <- AMAZON EC2 instance (slot 2)
                 ^
                 |  launches / terminates / replaces
          [ awslab-asg ]                  <- EC2 AUTO SCALING GROUP (desired capacity)
                 |
                 v  169.254.169.254
          [ awslab-imds ]                 <- INSTANCE METADATA SERVICE (IMDSv2)

   awslab-lambda invoke orders-api '{}'   <- AWS LAMBDA: no instance, no OS,
                                             just handler + timeout + memory
MAP
    rule
    say "Useful commands while you work:"
    say "  curl -s http://127.0.0.1:${LISTENER_PORT}/            # through the load balancer"
    say "  curl -s http://127.0.0.1:8101/health                  # straight to one instance"
    say "  systemctl status 'awslab-app@*' awslab-asg awslab-elb awslab-imds"
    say "  journalctl -u awslab-asg -u awslab-elb -f"
    say "  cat ${LAB_STATE}/target-health.json"
    say "  awslab-lambda invoke orders-api '{\"items\":[1,2,3]}'"
    rule
    ok "lab ready. Inject a fault with: $0 break"
}

# -----------------------------------------------------------------------------
# break
# -----------------------------------------------------------------------------
record_fault() { printf '%s' "$1" | base64 > "$FAULT_FILE"; }
current_fault() { [ -f "$FAULT_FILE" ] && base64 -d < "$FAULT_FILE" || printf 'none'; }

break_1_sg_ingress_blocked() {
    nft add table inet "$NFT_TABLE" 2>/dev/null || true
    nft add chain inet "$NFT_TABLE" input '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
    nft add rule inet "$NFT_TABLE" input tcp dport "$((BASE_TARGET_PORT + 1))-$((BASE_TARGET_PORT + MAX_SLOTS))" counter drop
}

break_2_ami_config_drift() {
    rm -f "${LAB_ROOT}/app/config.json"
    systemctl restart 'awslab-app@1.service' 'awslab-app@2.service' 2>/dev/null || true
}

break_3_asg_capacity_zero() {
    sed -i 's/^DESIRED_CAPACITY=.*/DESIRED_CAPACITY=0/; s/^MIN_SIZE=.*/MIN_SIZE=0/' "${LAB_ETC}/asg.conf"
    systemctl restart awslab-asg.service
}

break_4_lambda_timeout() {
    python3 - <<'PY'
import json
path = "/etc/awslab/functions/orders-api.json"
with open(path) as fh:
    cfg = json.load(fh)
cfg["Timeout"] = 1
with open(path, "w") as fh:
    fh.write(json.dumps(cfg, indent=2) + "\n")
PY
}

break_5_imds_unreachable() {
    ip addr del "${IMDS_IP}/32" dev lo 2>/dev/null || true
    systemctl restart awslab-imds.service 2>/dev/null || true
    systemctl restart 'awslab-app@1.service' 'awslab-app@2.service' 2>/dev/null || true
}

briefing() {
    rule
    say "${C_BLD}FAULT INJECTED${C_OFF}  (scenario is not printed - the symptom is your only input)"
    rule
    case "$1" in
    sg-ingress-blocked)
        cat <<'TXT'
SYMPTOM
  curl http://127.0.0.1:8080/ returns 503, and the body says the target group has
  targets registered but none healthy. Yet `systemctl is-active awslab-app@1` says
  active, the processes are up, and journalctl for the app shows no errors at all.
  Any attempt to reach an instance port directly hangs until it times out - it does
  not refuse the connection, it never answers.

WHAT SUCCESS LOOKS LIKE
  http://127.0.0.1:8080/ returns 200 and, across repeated requests, reports two
  different instance_id values. Both targets healthy in the target-group state.

WHERE TO LOOK
  The distinction that matters: "connection refused" means nothing is listening;
  "connection timed out" means something between you and a live listener is
  silently discarding packets. Prove which one you have with ss and curl, then go
  looking for the thing in the middle. On AWS this is the single most common
  cause of a healthy-looking instance behind an unhealthy target.
TXT
        ;;
    ami-config-drift)
        cat <<'TXT'
SYMPTOM
  The load balancer returns 503. Unlike a firewall problem, the instances are
  visibly not staying up: systemctl shows them restarting over and over, and the
  Auto Scaling log keeps announcing launches. Connections to an instance port are
  refused immediately rather than hanging.

WHAT SUCCESS LOOKS LIKE
  Both awslab-app@1 and awslab-app@2 stay active without restarting, the target
  group reports both healthy, and http://127.0.0.1:8080/ returns 200 with the
  service version string.

WHERE TO LOOK
  A process that exits on startup writes down why before it dies. Read the unit's
  journal - not the status line, the actual log output. The lab keeps a pristine
  copy of anything baked into the "AMI" next to the file it belongs to.
TXT
        ;;
    asg-capacity-zero)
        cat <<'TXT'
SYMPTOM
  The load balancer answers instantly with 503, and this time it reports ZERO
  targets registered - not unhealthy targets, none at all. No app process is
  running. Nothing is crashing, nothing is being restarted, and the journal is
  quiet. The infrastructure is behaving perfectly; it just has nothing to run.

WHAT SUCCESS LOOKS LIKE
  Two instances in service again, both healthy in the target group, and
  http://127.0.0.1:8080/ returning 200 from two distinct instance_id values.

WHERE TO LOOK
  When capacity itself is the missing thing, stop looking at the workload and
  look at what decides how much of it should exist. The Auto Scaling group's
  configuration is a plain text file in /etc/awslab. Read it as the exam reads it:
  minimum, maximum, desired - and remember which one actually drives launches.
TXT
        ;;
    lambda-timeout)
        cat <<'TXT'
SYMPTOM
  The EC2 side of the stack is perfectly healthy: 8080 returns 200 from both
  instances. The serverless side is not. Run:

      awslab-lambda invoke orders-api '{"items":[1,2,3]}'

  and the invocation ends with a line reading "Task timed out after 1.00 seconds"
  and a non-zero exit status. The function code was not changed, and it works
  when run by hand. There is no instance to log into, no OS to inspect.

WHAT SUCCESS LOOKS LIKE
  The same invocation returns a statusCode 200 payload, prints an END and a REPORT
  line, and exits 0 - while the downstream call it makes still takes its normal
  two seconds.

WHERE TO LOOK
  With Lambda you do not own servers; you own a function configuration. Print it
  (/etc/awslab/functions/) and read every field as a lever: Handler, Timeout,
  MemorySize, Runtime. One of them is now lying about how long the work takes.
  Raising it is a configuration change, not a code change - that is the lesson.
TXT
        ;;
    imds-unreachable)
        cat <<'TXT'
SYMPTOM
  503 from the load balancer, and every application instance is crash-looping.
  The application journal does not complain about its configuration this time - it
  reports that instance metadata is unavailable. Restarting the app does not help.
  The metadata service unit itself is also flapping, and its journal shows it
  failing to start rather than failing to answer.

WHAT SUCCESS LOOKS LIKE
  awslab-imds active and stable, this command answering with a token:

      curl -s -X PUT http://169.254.169.254/latest/api/token \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600'

  both app instances staying up, and 8080 returning 200.

WHERE TO LOOK
  Read the metadata service's own journal first and take its error literally: a
  daemon that cannot start is a different problem from a daemon that answers
  wrongly. Then ask what a service needs before it can bind a specific address,
  and check whether the host still has that address (ip -4 addr show dev lo).
  On real EC2 the 169.254.169.254 endpoint is provided by the hypervisor and
  cannot disappear - which is exactly why losing it here is instructive: it shows
  you how much of the instance depends on it.
TXT
        ;;
    esac
    rule
    say "Diagnose first, then fix. When you think it is repaired: ${C_BLD}$0 verify${C_OFF}"
    say "Stuck? ${C_BLD}$0 hint 1${C_OFF} then ${C_BLD}$0 hint 2${C_OFF}. Full walkthrough: the comments at the end of this script."
    rule
}

cmd_break() {
    require_root
    require_setup
    local choice="${1:-}"
    if [ -z "$choice" ]; then
        choice="$(( (RANDOM % 5) + 1 ))"
    fi
    case "$choice" in 1|2|3|4|5) : ;; *) die "unknown scenario '$choice' (valid: 1-5, or omit for random)";; esac
    if [ "$choice" = "1" ] && ! command -v nft >/dev/null 2>&1; then
        warn "nft not available; falling back to scenario 2"
        choice="2"
    fi

    local name
    case "$choice" in
        1) name="sg-ingress-blocked"; break_1_sg_ingress_blocked ;;
        2) name="ami-config-drift";   break_2_ami_config_drift ;;
        3) name="asg-capacity-zero";  break_3_asg_capacity_zero ;;
        4) name="lambda-timeout";     break_4_lambda_timeout ;;
        5) name="imds-unreachable";   break_5_imds_unreachable ;;
    esac
    record_fault "$name"
    sleep 6
    briefing "$name"
}

# -----------------------------------------------------------------------------
# hint
# -----------------------------------------------------------------------------
cmd_hint() {
    require_setup
    local level="${1:-1}" fault
    fault="$(current_fault)"
    [ "$fault" != "none" ] || die "no fault injected. Run: $0 break"
    rule
    case "${fault}:${level}" in
    sg-ingress-blocked:1) say "Compare 'ss -ltnp | grep 810' with 'curl -m 3 -v http://127.0.0.1:8101/health'. If a socket is listening and the connect still times out, the packets are being dropped after they leave your client and before they reach the socket." ;;
    sg-ingress-blocked:2) say "Something is filtering. List every firewall table on the host - not just the one you usually manage - and look for a rule matching the target ports. Think of it as an inbound security group rule that was never meant to be there." ;;
    ami-config-drift:1)   say "'systemctl status awslab-app@1' shows the restart count; 'journalctl -u awslab-app@1 -n 30' shows the reason. Read the FATAL line word for word - it names the exact file it could not read." ;;
    ami-config-drift:2)   say "Look in /opt/awslab/app/. The known-good copy of that file is sitting right next to where the missing one belongs. Restore it, then let the Auto Scaling group do its job (or restart the units yourself)." ;;
    asg-capacity-zero:1)  say "Ask the load balancer how many targets are REGISTERED, not how many are healthy: curl -s http://127.0.0.1:8080/ and cat /var/lib/awslab/instances.json. Zero registered means nothing ever asked for an instance to exist." ;;
    asg-capacity-zero:2)  say "cat /etc/awslab/asg.conf and journalctl -u awslab-asg -n 20. Desired capacity is the field that drives launches; minimum and maximum only bound it. Set desired back to 2 - and make sure it still satisfies min <= desired <= max, or the group will reject the update the way the real API does." ;;
    lambda-timeout:1)     say "The message is precise: 'Task timed out after 1.00 seconds'. That number is not chosen by your code - it comes from the function configuration. Print it: cat /etc/awslab/functions/orders-api.json" ;;
    lambda-timeout:2)     say "The handler sleeps ~2 s simulating a downstream call, so any Timeout below that guarantees failure. Raise Timeout to something with headroom (10). Real Lambda allows up to 900 seconds, and you pay for duration, so headroom is not free - but a timeout below the known latency is simply a broken configuration." ;;
    imds-unreachable:1)   say "journalctl -u awslab-imds -n 20. Distinguish 'it started and answered wrongly' from 'it could not start at all'. The error text names the failing operation." ;;
    imds-unreachable:2)   say "A daemon binding 169.254.169.254:80 needs the host to actually own that address. Check with 'ip -4 addr show dev lo'. Restore the address, then restart the metadata service before the app instances." ;;
    *) say "No hint for level '${level}'. Try 1 or 2." ;;
    esac
    rule
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------
cmd_status() {
    require_setup
    rule
    say "${C_BLD}COMPUTE STACK STATUS${C_OFF}"
    rule
    say "${C_BLD}units${C_OFF}"
    systemctl list-units --no-legend --all 'awslab-*' 2>/dev/null | sed 's/^/  /' || true
    say ""
    say "${C_BLD}Auto Scaling group (/etc/awslab/asg.conf)${C_OFF}"
    grep -v '^#' "${LAB_ETC}/asg.conf" 2>/dev/null | grep -v '^$' | sed 's/^/  /' || say "  (missing)"
    say ""
    say "${C_BLD}registered instances${C_OFF}"
    python3 - <<'PY' || true
import json
try:
    with open("/var/lib/awslab/instances.json") as fh:
        reg = json.load(fh)
except Exception as exc:
    print("  (no registry: %s)" % exc)
    reg = {}
if not reg:
    print("  0 instances - desired capacity is not being met")
for slot in sorted(reg, key=int):
    info = reg[slot]
    print("  slot %s  %s  port %s  %s"
          % (slot, info["instance_id"], info["port"], info["lifecycle"]))
PY
    say ""
    say "${C_BLD}target group awslab-tg${C_OFF}"
    python3 - <<'PY' || true
import json
try:
    with open("/var/lib/awslab/target-health.json") as fh:
        health = json.load(fh)
except Exception:
    health = {}
if not health:
    print("  no targets registered")
for slot in sorted(health, key=int):
    st = health[slot]
    print("  slot %s  %-10s rtt=%sms  %s"
          % (slot, st.get("state"), st.get("rtt_ms"), (st.get("reason") or "")[:70]))
PY
    say ""
    say "${C_BLD}listener http://127.0.0.1:${LISTENER_PORT}/${C_OFF}"
    curl -s -m 5 "http://127.0.0.1:${LISTENER_PORT}/" 2>/dev/null | sed 's/^/  /' || say "  (no answer)"
    say ""
    say "${C_BLD}instance metadata (IMDSv2)${C_OFF}"
    if ip -4 addr show dev lo 2>/dev/null | grep -q "$IMDS_IP"; then
        say "  ${IMDS_IP}/32 present on lo"
    else
        say "  ${IMDS_IP}/32 ABSENT from lo"
    fi
    say ""
    say "${C_BLD}lambda function orders-api${C_OFF}"
    sed 's/^/  /' "${LAB_ETC}/functions/orders-api.json" 2>/dev/null || say "  (missing)"
    if command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        say ""
        say "${C_BLD}host packet filter, table inet ${NFT_TABLE}${C_OFF}"
        nft list table inet "$NFT_TABLE" | sed 's/^/  /'
    fi
    rule
    cat <<'TXT'
NOT SHOWN HERE, AND THAT IS THE POINT (rest of task statement 3.3)
  Fargate / ECS / EKS  - you hand over a container definition; there is no instance
                         in this list to log into, and no ASG of your own to fix.
  AWS Batch            - you submit jobs to a queue; capacity appears and vanishes.
  Elastic Beanstalk    - it creates this exact ASG+ALB+EC2 shape for you, which is
                         why its failures still show up as target-group 503s.
  Lightsail            - fixed-price bundles, the simplification of all of the above.
  Outposts / Wavelength / Local Zones - the same EC2 APIs, run closer to you.
TXT
    rule
}

# -----------------------------------------------------------------------------
# verify
# -----------------------------------------------------------------------------
cmd_verify() {
    require_setup
    local failures=0
    rule
    say "${C_BLD}VERIFYING${C_OFF} (health thresholds take a few seconds after a fix - waiting up to 90s)"
    rule

    if wait_for_listener 90; then
        ok "load balancer listener returns 200"
    else
        fail "load balancer listener is not returning 200"
        failures=$((failures + 1))
    fi

    if python3 - "$LISTENER_PORT" <<'PY'
import json
import sys
import urllib.request

port = sys.argv[1]
ids = set()
for _ in range(8):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%s/" % port, timeout=4) as resp:
            ids.add(json.loads(resp.read().decode())["instance_id"])
    except Exception:
        pass
print("    instance ids seen through the listener: %s" % (sorted(ids) or "none"))
sys.exit(0 if len(ids) >= 2 else 1)
PY
    then
        ok "two distinct instances are in service behind the target group"
    else
        fail "fewer than two instances are serving traffic"
        failures=$((failures + 1))
    fi

    if python3 - <<'PY'
import json
import sys
try:
    with open("/var/lib/awslab/target-health.json") as fh:
        health = json.load(fh)
except Exception:
    sys.exit(1)
bad = [s for s, v in health.items() if v.get("state") != "healthy"]
sys.exit(1 if (bad or len(health) < 2) else 0)
PY
    then
        ok "every registered target is healthy"
    else
        fail "at least one target is not healthy"
        failures=$((failures + 1))
    fi

    if curl -s -m 4 -X PUT "http://${IMDS_IP}/latest/api/token" \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' | grep -q '.'; then
        ok "IMDSv2 issues session tokens"
    else
        fail "instance metadata service is not answering on ${IMDS_IP}"
        failures=$((failures + 1))
    fi

    local lambda_out lambda_rc=0
    lambda_out="$("$LAMBDA_BIN" invoke orders-api '{"items":[1,2,3]}' 2>&1)" || lambda_rc=$?
    if [ "$lambda_rc" -eq 0 ] && printf '%s' "$lambda_out" | grep -q '"statusCode": 200'; then
        ok "lambda orders-api returns statusCode 200"
    else
        fail "lambda orders-api invocation failed:"
        printf '%s\n' "$lambda_out" | sed 's/^/      /' >&2
        failures=$((failures + 1))
    fi

    rule
    if [ "$failures" -eq 0 ]; then
        ok "ALL CHECKS PASSED - the stack is serving again."
        say ""
        say "${C_BLD}Exam takeaway for task statement 3.3${C_OFF}"
        cat <<'TXT'
  Every one of these faults produced the same customer-visible symptom - a 503
  from the load balancer - and each lived in a different service:

    the security group / firewall .... traffic never reached a healthy process
    the EC2 instance itself ......... the process could not start
    EC2 Auto Scaling ................ no instance was ever asked to exist
    the metadata service ............ the instance could not learn who it was
    AWS Lambda ...................... no instance at all; a configuration limit

  So the exam question "which compute service applies here?" is really: at which
  layer does the decision live? Capacity -> Auto Scaling. Traffic distribution and
  health -> ELB. The OS and the process -> EC2, and therefore yours to patch. No
  OS, only a function configuration -> Lambda. Containers with no instance to
  manage -> Fargate. Whole environment created for you -> Elastic Beanstalk.
TXT
        record_fault "none"
        return 0
    fi
    fail "${failures} check(s) still failing - keep going, or run: $0 hint 2"
    return 1
}

# -----------------------------------------------------------------------------
# reset / cleanup
# -----------------------------------------------------------------------------
cmd_reset() {
    require_root
    require_setup
    info "removing any lab firewall table"
    command -v nft >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    info "restoring the metadata address"
    ensure_imds_address
    info "restoring pristine configuration"
    write_config_files
    systemctl unmask awslab-imds.service 2>/dev/null || true
    info "restarting the stack"
    systemctl reset-failed 'awslab-app@*' 2>/dev/null || true
    restart_stack
    record_fault "none"
    if wait_for_listener 60; then
        ok "stack restored: http://127.0.0.1:${LISTENER_PORT}/ is serving 200"
    else
        warn "still not healthy - inspect: journalctl -u awslab-asg -u awslab-elb -n 50"
    fi
}

cmd_cleanup() {
    require_root
    info "stopping and removing lab units"
    systemctl disable --now awslab-asg.service awslab-elb.service awslab-imds.service >/dev/null 2>&1 || true
    for slot in $(seq 1 "$MAX_SLOTS"); do
        systemctl stop "awslab-app@${slot}.service" >/dev/null 2>&1 || true
    done
    rm -f "${LAB_UNITS}/awslab-imds.service" "${LAB_UNITS}/awslab-app@.service" \
          "${LAB_UNITS}/awslab-elb.service" "${LAB_UNITS}/awslab-asg.service"
    systemctl daemon-reload
    systemctl reset-failed 'awslab-*' >/dev/null 2>&1 || true
    info "removing the lab firewall table"
    command -v nft >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    info "removing ${IMDS_IP}/32 from lo"
    ip addr del "${IMDS_IP}/32" dev lo 2>/dev/null || true
    info "removing lab files"
    rm -rf "$LAB_ROOT" "$LAB_ETC" "$LAB_STATE"
    rm -f "$LAMBDA_BIN"
    ok "lab removed. Nothing outside the paths listed in the header was touched."
}

usage() {
    cat <<TXT
AWS CLF-C02 - task statement 3.3 (Identify AWS compute services) - break & fix lab

  $0 setup --yes      build the lab (DISPOSABLE VM ONLY)
  $0 break [1-5]      inject one fault, random if no number is given
  $0 status           console-style view of ASG, target group, listener, Lambda
  $0 hint [1|2]       progressive hints for the injected fault
  $0 verify           check whether the stack is serving again
  $0 reset            undo every fault and restore the pristine stack
  $0 cleanup          remove the lab entirely

Scenarios: 1 security-group ingress  2 instance config drift  3 desired capacity
           4 Lambda timeout          5 instance metadata unreachable
TXT
}

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        setup)   cmd_setup "${1:-}" ;;
        break)   cmd_break "${1:-}" ;;
        status)  cmd_status ;;
        hint)    cmd_hint "${1:-1}" ;;
        verify)  cmd_verify ;;
        reset)   cmd_reset ;;
        cleanup) cmd_cleanup ;;
        help|-h|--help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

# =============================================================================
#  SOLUTIONS - read only after you have tried. One section per scenario.
#  Each follows the same shape: observe, narrow, prove, fix, confirm.
# =============================================================================
#
# -----------------------------------------------------------------------------
# GENERAL OPENING MOVE (all scenarios)
# -----------------------------------------------------------------------------
#   1. Ask the load balancer what it thinks:
#        curl -si http://127.0.0.1:8080/ | head -5
#      A 503 body that says "N target(s) registered, 0 healthy" separates the
#      first branch immediately:
#        N = 0  -> nothing was ever launched  -> capacity problem (scenario 3)
#        N > 0  -> instances exist but fail health checks (scenarios 1, 2, 5)
#      A healthy 200 here means the EC2 path is fine and the failure is on the
#      serverless path (scenario 4).
#   2. Ask the group and the target state:
#        cat /var/lib/awslab/instances.json
#        cat /var/lib/awslab/target-health.json
#        systemctl list-units 'awslab-*'
#   3. Only then look at a single instance. This is the same order you would use
#      in the console: ALB -> target group -> Auto Scaling group -> instance.
#
# -----------------------------------------------------------------------------
# SCENARIO 1 - sg-ingress-blocked  (security group / firewall)
# -----------------------------------------------------------------------------
#   OBSERVE
#     curl -si http://127.0.0.1:8080/            -> 503, 2 registered, 0 healthy
#     systemctl is-active awslab-app@1           -> active
#     journalctl -u awslab-app@1 -n 20           -> clean, "listening on 0.0.0.0:8101"
#
#   NARROW - the decisive test is refused vs. timed out:
#     ss -ltnp | grep 810
#       LISTEN 0 5 0.0.0.0:8101 ... users:(("python3",pid=...))
#     curl -m 3 -v http://127.0.0.1:8101/health
#       * Connection timed out after 3000 milliseconds
#     A socket in LISTEN plus a connect timeout = packets are being dropped in
#     the kernel path, not refused by the application. Refused would mean nothing
#     is bound. This is precisely the signature of a security group that does not
#     allow the load balancer's port.
#
#   PROVE
#     nft list ruleset | grep -A5 'table inet awslab'
#       table inet awslab {
#         chain input { type filter hook input priority filter; policy accept;
#           tcp dport 8101-8108 counter packets N bytes M drop
#         }
#       }
#     The counter increments every time you retry the curl - that is your proof.
#
#   FIX - delete the offending rule. Deleting the lab's own table is the cleanest
#   equivalent of removing a bad security group rule; never flush the whole ruleset
#   on a machine you care about:
#     nft delete table inet awslab
#     # or, surgically:  nft -a list table inet awslab   # find the rule handle
#     #                  nft delete rule inet awslab input handle <N>
#
#   CONFIRM
#     curl -s http://127.0.0.1:8101/health        -> OK   (immediately)
#     sleep 12 && curl -s http://127.0.0.1:8080/  -> 200  (after 2 healthy checks)
#     ./awslab-compute.sh verify
#
#   WHY THE DELAY: the target group needs HealthyThresholdCount consecutive
#   successes (2 here, interval 5 s) before it puts a target back in rotation.
#   On a real ALB this is why "I fixed it but it is still 503" is normal for up to
#   interval x threshold seconds.
#
#   EXAM POINT: an EC2 instance can be perfectly healthy and still be unreachable.
#   Security groups are stateful and allow-list only - there is no deny rule; the
#   absence of an allow rule IS the drop. Instance status checks pass, the ELB
#   health check does not, and that gap is the whole lesson.
#
# -----------------------------------------------------------------------------
# SCENARIO 2 - ami-config-drift  (the instance itself)
# -----------------------------------------------------------------------------
#   OBSERVE
#     curl -si http://127.0.0.1:8080/   -> 503, targets registered, none healthy
#     systemctl status awslab-app@1
#       Active: activating (auto-restart) ... or failed
#     curl -m 3 http://127.0.0.1:8101/health
#       curl: (7) Failed to connect ... Connection refused     <- refused, not timeout
#
#   NARROW - refused means the process is not listening; read why it died:
#     journalctl -u awslab-app@1 -n 20 --no-pager
#       FATAL: application configuration unreadable
#              (/opt/awslab/app/config.json): [Errno 2] No such file or directory
#     journalctl -u awslab-asg -n 20
#       Launching instance i-0aa...0001 in slot 1   (repeatedly - the group is
#       doing its job; the workload is what fails)
#
#   FIX - restore the file the "AMI" was supposed to carry, then let the loop heal:
#     ls -l /opt/awslab/app/
#     cp /opt/awslab/app/config.json.ami-baseline /opt/awslab/app/config.json
#     systemctl reset-failed 'awslab-app@*'
#     systemctl restart awslab-app@1 awslab-app@2
#
#   CONFIRM
#     systemctl is-active awslab-app@1 awslab-app@2      -> active active
#     sleep 12 && curl -s http://127.0.0.1:8080/         -> 200 with version 2.4.1
#     ./awslab-compute.sh verify
#
#   EXAM POINT: with EC2 (IaaS) the operating system, the runtime and everything
#   the application needs on disk are YOUR responsibility under the shared
#   responsibility model. AWS keeps the instance running; it has no idea your
#   process is exiting. That division - "the instance is up" vs. "the application
#   works" - is exactly why ELB health checks exist, and why an Auto Scaling group
#   configured with EC2-type health checks will never rescue you from this.
#
# -----------------------------------------------------------------------------
# SCENARIO 3 - asg-capacity-zero  (EC2 Auto Scaling)
# -----------------------------------------------------------------------------
#   OBSERVE
#     curl -si http://127.0.0.1:8080/
#       503 ... target group awslab-tg: 0 target(s) registered, 0 healthy
#     cat /var/lib/awslab/instances.json      -> {}
#     systemctl list-units 'awslab-app@*'     -> nothing
#     journalctl -u awslab-asg -n 10          -> quiet, or a ValidationError line
#
#   NARROW - zero registered targets is not a workload failure. Nothing crashed;
#   nothing was ever asked to exist. Go to the thing that decides how many:
#     cat /etc/awslab/asg.conf
#       MIN_SIZE=0
#       MAX_SIZE=4
#       DESIRED_CAPACITY=0        <- here
#
#   FIX
#     sed -i 's/^DESIRED_CAPACITY=.*/DESIRED_CAPACITY=2/; s/^MIN_SIZE=.*/MIN_SIZE=1/' \
#         /etc/awslab/asg.conf
#     systemctl restart awslab-asg        # (the loop also re-reads the file on its own)
#     journalctl -u awslab-asg -f         # watch: "Launching instance i-0aa...0001"
#
#   Keep min <= desired <= max. Break that ordering and the loop logs
#   "ValidationError: DESIRED_CAPACITY must satisfy MIN_SIZE <= DESIRED_CAPACITY
#   <= MAX_SIZE - group left unchanged", which is the same class of error the real
#   API returns and a very common way to "fix" this into a second outage.
#
#   CONFIRM
#     sleep 15 && curl -s http://127.0.0.1:8080/     -> 200
#     curl -s http://127.0.0.1:8080/ | grep instance_id   # run twice: two ids
#     ./awslab-compute.sh verify
#
#   EXAM POINT: minimum, maximum and desired capacity are three different things.
#   Desired capacity is what the group actively drives toward; minimum is the floor
#   it will never go below (including after a scale-in policy fires) and maximum is
#   the ceiling a scaling policy may reach. Scaling policies move desired capacity -
#   they do not move the bounds. Availability comes from spreading that capacity
#   across Availability Zones, which is why the group, not the instance, is the
#   unit of resilience.
#
# -----------------------------------------------------------------------------
# SCENARIO 4 - lambda-timeout  (AWS Lambda)
# -----------------------------------------------------------------------------
#   OBSERVE
#     curl -s http://127.0.0.1:8080/ | head -3          -> 200, EC2 side is fine
#     awslab-lambda invoke orders-api '{"items":[1,2,3]}'
#       START RequestId: 1f0c... Version: $LATEST
#       1f0c... Task timed out after 1.00 seconds
#       END RequestId: 1f0c...
#       REPORT ... Duration: 1002.41 ms Billed Duration: 1003 ms Memory Size: 256 MB
#     echo $?                                            -> 1
#
#   NARROW - there is no instance to inspect and no OS to log into; the only thing
#   you own is the function configuration:
#     cat /etc/awslab/functions/orders-api.json
#       "Handler": "orders.handler",
#       "Timeout": 1,              <- the code needs ~2 s of downstream latency
#       "MemorySize": 256
#     grep DOWNSTREAM /opt/awslab/lambda/orders.py
#       DOWNSTREAM_LATENCY_S = 2.0
#
#   FIX - a configuration change, not a code change:
#     python3 - <<'EOF'
#     import json
#     p = "/etc/awslab/functions/orders-api.json"
#     c = json.load(open(p)); c["Timeout"] = 10
#     open(p, "w").write(json.dumps(c, indent=2) + "\n")
#     EOF
#     # On real AWS this is exactly:
#     #   aws lambda update-function-configuration \
#     #       --function-name orders-api --timeout 10
#
#   CONFIRM
#     awslab-lambda invoke orders-api '{"items":[1,2,3]}'
#       {"statusCode": 200, "body": {"orders_processed": 3, "remaining_ms": 79xx}}
#       REPORT ... Duration: 2003.11 ms Billed Duration: 2004 ms
#     echo $?                                            -> 0
#     ./awslab-compute.sh verify
#
#   EXAM POINTS
#     * Timeout is a per-function ceiling, maximum 900 seconds (15 minutes). Work
#       that legitimately runs longer belongs on ECS/Fargate, AWS Batch or EC2 -
#       a favourite exam distinction.
#     * You are billed for requests and for duration (rounded up to the ms) x the
#       memory configured. Memory and vCPU are coupled: raising MemorySize also
#       raises CPU, so an over-tight memory setting can itself cause timeouts, and
#       more memory sometimes costs LESS because the function finishes sooner.
#     * A wrong Handler string produces Runtime.HandlerNotFound instead - the other
#       classic configuration failure, and equally invisible from the code.
#     * Nothing here involved patching, capacity or a health check. That absence is
#       the definition of serverless for the exam: no servers to provision or manage,
#       automatic scaling, pay for what you use.
#
# -----------------------------------------------------------------------------
# SCENARIO 5 - imds-unreachable  (instance metadata / instance profile)
# -----------------------------------------------------------------------------
#   OBSERVE
#     curl -si http://127.0.0.1:8080/          -> 503, targets registered, unhealthy
#     journalctl -u awslab-app@1 -n 10
#       FATAL: instance metadata unavailable at http://169.254.169.254
#              (URLError: <urlopen error [Errno 101] Network is unreachable>)
#     systemctl status awslab-imds
#       Active: activating (auto-restart)
#     journalctl -u awslab-imds -n 10
#       OSError: [Errno 99] Cannot assign requested address
#
#   NARROW - "cannot assign requested address" is a bind failure, not a logic bug.
#   The daemon is asking for an address the host no longer has:
#     ip -4 addr show dev lo
#       inet 127.0.0.1/8 scope host lo          <- 169.254.169.254 is gone
#
#   FIX
#     ip addr add 169.254.169.254/32 dev lo
#     systemctl restart awslab-imds
#     systemctl reset-failed 'awslab-app@*'
#     systemctl restart awslab-app@1 awslab-app@2
#
#   CONFIRM - always with IMDSv2's two steps, never a bare GET:
#     TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
#               -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
#     curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
#          http://169.254.169.254/latest/meta-data/instance-id
#     sleep 12 && curl -s http://127.0.0.1:8080/       -> 200
#     ./awslab-compute.sh verify
#
#   A GET without that token returns 401 by design. If you ever see a 401 from a
#   real instance, the SDK or script is speaking IMDSv1 to an instance where
#   HttpTokens=required.
#
#   EXAM POINTS: 169.254.169.254 is link-local - it never leaves the instance and
#   is not billed as traffic. It is how an instance learns its own identity
#   (instance id, type, AZ, region) and, critically, how the AWS SDKs obtain the
#   temporary credentials of the attached IAM instance profile. That is why you
#   attach a ROLE to an instance instead of copying access keys onto it: the
#   credentials are short-lived, rotated automatically, and never stored on disk.
#   Lose the metadata path and an instance loses its identity and its permissions
#   at once - which is also why IMDSv2's session-token requirement matters as an
#   SSRF defence.
#
# -----------------------------------------------------------------------------
# ONE-LINE SUMMARY TO CARRY INTO THE EXAM
# -----------------------------------------------------------------------------
#   The 503 is never the diagnosis. Walk the layers in order - load balancer,
#   target group, Auto Scaling group, instance, and finally the process - and the
#   layer where the answer changes is the AWS compute service the question is
#   actually about.
# =============================================================================