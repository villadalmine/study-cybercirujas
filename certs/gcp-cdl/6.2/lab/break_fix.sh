#!/usr/bin/env bash
# =============================================================================
#  teach-plat :: BREAK & FIX LAB
#  Certification : gcp-cdl — Google Cloud Digital Leader (exam version 2026-08-12)
#  Objective 6.2 : Describe the fundamental concepts of modern operations,
#                  reliability, and resilience in the cloud   (exam weight: 5.0)
#  Official ref  : https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#
#  WHAT THIS SCRIPT DOES
#    Builds a tiny two-tier HTTP workload on a DISPOSABLE lab VM (all listeners
#    bound to 127.0.0.1), puts a load-balancer-style health checker and an
#    Ops-Agent-style telemetry collector in front of it, proves it healthy, and
#    then injects a realistic production incident with four contributing
#    factors. The student must restore service and close the gaps.
#
#  SAFETY CONTRACT
#    * Only these paths are created or modified:
#        /opt/teach-lab  /etc/teach-lab  /var/log/teach-lab  /run/teach-lab
#        /etc/systemd/system/teach-lab-*.service
#        /usr/local/bin/teach-lab-status  /usr/local/bin/teach-lab-slo
#    * Nothing listens outside loopback. No firewall, no package, no repo, no
#      user, no cloud API is touched. `--clean` removes every artifact.
#    * The workload's memory growth is bounded twice (RLIMIT_AS backstop plus an
#      explicit self-terminating cap), so the VM itself is never starved.
#
#  USAGE
#    sudo ./break-fix-6.2-operations-reliability.sh --break    # build + break (default)
#    sudo ./break-fix-6.2-operations-reliability.sh --brief    # reprint the briefing
#    sudo ./break-fix-6.2-operations-reliability.sh --verify   # grade your fix
#    sudo ./break-fix-6.2-operations-reliability.sh --clean    # remove the lab
# =============================================================================

set -Eeuo pipefail
trap 'echo "[fatal] line $LINENO: command failed (exit $?)" >&2' ERR

LAB_HOME=/opt/teach-lab
LAB_ETC=/etc/teach-lab
LAB_LOG=/var/log/teach-lab
LAB_RUN=/run/teach-lab
UNIT_DIR=/etc/systemd/system
APP_URL=http://127.0.0.1:8080
UNITS=(teach-lab-backend teach-lab-app teach-lab-collector teach-lab-lb teach-lab-load)

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=""; R=""; G=""; Y=""; C=""; D=""; N=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[lab]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[stop]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$D" "-----------------------------------------------------------------------------" "$N"; }

# -----------------------------------------------------------------------------
# preflight
# -----------------------------------------------------------------------------
port_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}\$"; }

preflight() {
  [[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
  command -v systemctl >/dev/null || die "systemd is required (this lab models managed instances)"
  command -v python3   >/dev/null || die "python3 is required"
  command -v curl      >/dev/null || die "curl is required"
  [[ -d /run/systemd/system ]] || die "systemd is not the running init"

  for p in 8080 9090; do
    if port_busy "$p" && ! systemctl is-active --quiet teach-lab-app.service; then
      die "port $p is already in use by something that is not this lab — refusing to touch this host"
    fi
  done

  if [[ "${TEACH_LAB_ACK:-}" != "yes" && "${ASSUME_YES:-0}" != "1" ]]; then
    rule
    printf '%sThis script installs services and then deliberately breaks them.%s\n' "$B" "$N"
    printf 'Run it ONLY on a disposable lab VM you can delete afterwards.\n'
    rule
    read -r -p "Type 'break it' to continue: " reply < /dev/tty || die "no tty; re-run with TEACH_LAB_ACK=yes"
    [[ "$reply" == "break it" ]] || die "aborted by the operator"
  fi
}

# -----------------------------------------------------------------------------
# lab payload
# -----------------------------------------------------------------------------
install_payload() {
  info "installing lab payload under $LAB_HOME"
  install -d -m 0755 "$LAB_HOME" "$LAB_ETC" "$LAB_LOG" "$LAB_RUN"

  cat > "$LAB_HOME/backend.py" <<'PYEOF'
#!/usr/bin/env python3
"""teach-lab data tier. Stand-in for the dependency a frontend cannot serve without."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAYLOAD = {
    "source": "data-tier",
    "items": [
        {"sku": "GG-0001", "name": "Cloud Digital Leader mug", "stock": 42},
        {"sku": "GG-0002", "name": "SRE notebook", "stock": 7},
    ],
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "teach-lab-data/1.0"

    def _reply(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path.startswith("/data"):
            self._reply(200, PAYLOAD)
        elif self.path.startswith("/healthz"):
            self._reply(200, {"status": "SERVING"})
        else:
            self._reply(404, {"error": "not found"})


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", 9090), Handler)
    srv.daemon_threads = True
    print("data tier listening on 127.0.0.1:9090", flush=True)
    srv.serve_forever()
PYEOF

  cat > "$LAB_HOME/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""teach-lab frontend instance.

This is the process a Cloud Load Balancing health check probes on /healthz and
that real user traffic hits on /. It cannot serve / without the data tier.
All configuration is environment-driven, exactly like a container image whose
behaviour changes per release without the code changing.
"""
import json
import os
import resource
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP_PORT = int(os.environ.get("APP_PORT", "8080"))
BACKEND_URL = os.environ.get("BACKEND_URL", "http://127.0.0.1:9090/data")
HEALTHZ_MODE = os.environ.get("HEALTHZ_MODE", "deep").strip().lower()
LEAK = os.environ.get("LEAK", "0").strip() == "1"
LEAK_LIMIT_MB = int(os.environ.get("LEAK_LIMIT_MB", "64"))
LOG_PATH = os.environ.get("LOG_PATH", "/var/log/teach-lab/app.log")
RELEASE = os.environ.get("RELEASE", "v1.4.0")

# Backstop #1: the kernel refuses this process more than 512 MiB of address
# space, whatever the cgroup limit says. A lab must never take the VM with it.
resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))

_leaked = []


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def emit(severity, message, **fields):
    """Structured log line, shaped like a Cloud Logging LogEntry."""
    record = {"timestamp": _now(), "severity": severity, "release": RELEASE, "message": message}
    record.update(fields)
    line = json.dumps(record, sort_keys=True)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError as exc:  # observability must never take the service down
        print("log write failed: %s" % exc, file=sys.stderr, flush=True)
    print(line, flush=True)


def probe_backend(timeout=2.0):
    started = time.monotonic()
    try:
        with urllib.request.urlopen(BACKEND_URL, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
        return True, body, (time.monotonic() - started) * 1000.0
    except urllib.error.HTTPError as exc:
        return False, "backend returned HTTP %s" % exc.code, (time.monotonic() - started) * 1000.0
    except Exception as exc:
        return False, "%s: %s" % (type(exc).__name__, exc), (time.monotonic() - started) * 1000.0


def maybe_leak():
    """Backstop #2: bounded, explicit, self-terminating. Simulates the OOM kill
    of a leaky release without ever pressuring the host."""
    if not LEAK:
        return
    _leaked.append(bytearray(2 * 1024 * 1024))
    held = len(_leaked) * 2
    if held >= LEAK_LIMIT_MB:
        emit("CRITICAL", "container memory limit exceeded - terminating",
             leaked_mib=held, limit_mib=LEAK_LIMIT_MB, exitCode=137)
        sys.stdout.flush()
        os._exit(137)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "teach-lab-frontend/1.0"

    def _reply(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

    def _finish(self, status, obj, started, **extra):
        latency = (time.monotonic() - started) * 1000.0
        self._reply(status, obj)
        emit("ERROR" if status >= 500 else "INFO", "request served",
             httpRequest={"requestMethod": "GET", "requestUrl": self.path,
                          "status": status, "latency_ms": round(latency, 2)},
             **extra)

    def _serve(self, started):
        maybe_leak()
        ok, detail, backend_ms = probe_backend()
        if ok:
            self._finish(200, json.loads(detail), started, backend_latency_ms=round(backend_ms, 2))
        else:
            self._finish(503, {"error": "data tier unavailable", "detail": detail}, started,
                         dependency=BACKEND_URL, dependency_error=detail)

    def _healthz(self, started):
        if HEALTHZ_MODE == "shallow":
            # Liveness only: "is this process answering sockets?" It says nothing
            # about whether the instance can actually serve a user request.
            self._finish(200, {"status": "SERVING", "check": "shallow"}, started)
            return
        ok, detail, _ = probe_backend(timeout=1.5)
        if ok:
            self._finish(200, {"status": "SERVING", "check": "deep"}, started)
        else:
            self._finish(503, {"status": "NOT_SERVING", "check": "deep", "detail": detail}, started)

    def do_GET(self):
        started = time.monotonic()
        if self.path.startswith("/healthz"):
            self._healthz(started)
        elif self.path.startswith("/debug"):
            self._reply(200, {"release": RELEASE, "backend_url": BACKEND_URL,
                              "healthz_mode": HEALTHZ_MODE, "leak": LEAK,
                              "leaked_mib": len(_leaked) * 2, "pid": os.getpid()})
        elif self.path == "/" or self.path.startswith("/api"):
            self._serve(started)
        else:
            self._finish(404, {"error": "not found"}, started)


if __name__ == "__main__":
    emit("NOTICE", "frontend starting", port=APP_PORT, backend_url=BACKEND_URL,
         healthz_mode=HEALTHZ_MODE, leak=LEAK)
    srv = ThreadingHTTPServer(("127.0.0.1", APP_PORT), Handler)
    srv.daemon_threads = True
    srv.serve_forever()
PYEOF

  cat > "$LAB_HOME/collector.py" <<'PYEOF'
#!/usr/bin/env python3
"""teach-lab telemetry collector - stand-in for the Google Cloud Ops Agent.

Tails the application log, normalises each request into a metric point, and
stamps a heartbeat. If this process is not running, the dashboards do not go
red: they go EMPTY, which is the failure mode that fools on-call engineers.
"""
import json
import os
import time
from datetime import datetime, timezone

SRC = "/var/log/teach-lab/app.log"
DST = "/var/log/teach-lab/metrics.jsonl"
HEARTBEAT = "/var/log/teach-lab/collector.heartbeat"
offset = 0

while True:
    with open(HEARTBEAT, "w", encoding="utf-8") as hb:
        hb.write(datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z") + "\n")
    try:
        size = os.path.getsize(SRC)
        if size < offset:      # truncated or rotated underneath us
            offset = 0
        with open(SRC, "r", encoding="utf-8") as src, open(DST, "a", encoding="utf-8") as dst:
            src.seek(offset)
            while True:
                line = src.readline()
                if not line or not line.endswith("\n"):
                    break
                offset = src.tell()
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                req = rec.get("httpRequest")
                if not req or str(req.get("requestUrl", "")).startswith("/healthz"):
                    continue
                dst.write(json.dumps({"timestamp": rec.get("timestamp"),
                                      "status": req.get("status"),
                                      "latency_ms": req.get("latency_ms"),
                                      "path": req.get("requestUrl")}) + "\n")
    except FileNotFoundError:
        pass
    time.sleep(2)
PYEOF

  cat > "$LAB_HOME/slo_report.py" <<'PYEOF'
#!/usr/bin/env python3
"""teach-lab SLO report: availability SLI, error budget and burn rate.

SLI    = good requests / valid requests        (good = HTTP status < 500)
Budget = 100% - SLO target
Burn   = (1 - SLI) / (1 - SLO). Burn rate 1 spends the budget exactly on
         schedule; burn rate 14.4 spends a 30-day budget in ~2 days.
"""
import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

METRICS = "/var/log/teach-lab/metrics.jsonl"
HEARTBEAT = "/var/log/teach-lab/collector.heartbeat"

ap = argparse.ArgumentParser()
ap.add_argument("--window-minutes", type=float, default=15.0)
ap.add_argument("--slo", type=float, default=99.5, help="availability target in percent")
ap.add_argument("--min-sli", type=float, default=None, help="exit non-zero below this SLI")
ap.add_argument("--max-staleness", type=float, default=60.0, help="seconds")
ap.add_argument("--json", action="store_true")
args = ap.parse_args()

now = datetime.now(timezone.utc)
cutoff = now - timedelta(minutes=args.window_minutes)


def parse_ts(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


staleness = None
if os.path.exists(HEARTBEAT):
    with open(HEARTBEAT, encoding="utf-8") as fh:
        beat = parse_ts(fh.read().strip())
    if beat:
        staleness = (now - beat).total_seconds()

total = good = 0
latencies = []
if os.path.exists(METRICS):
    with open(METRICS, encoding="utf-8") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            ts = parse_ts(rec.get("timestamp"))
            if ts is None or ts < cutoff:
                continue
            total += 1
            status = rec.get("status") or 0
            if status and status < 500:
                good += 1
            if rec.get("latency_ms") is not None:
                latencies.append(rec["latency_ms"])

sli = (good / total * 100.0) if total else None
budget = 100.0 - args.slo
burn = ((100.0 - sli) / budget) if (sli is not None and budget > 0) else None
p99 = sorted(latencies)[int(len(latencies) * 0.99) - 1] if latencies else None
stale = staleness is None or staleness > args.max_staleness

report = {"window_minutes": args.window_minutes, "slo_target_pct": args.slo,
          "valid_requests": total, "good_requests": good, "sli_pct": sli,
          "burn_rate": burn, "p99_latency_ms": p99,
          "telemetry_staleness_s": staleness, "telemetry_stale": stale}

if args.json:
    print(json.dumps(report, indent=2))
else:
    print("=== teach-lab SLO report ==================================")
    print("  window                : last %.0f min" % args.window_minutes)
    print("  SLO target            : %.3f%% availability" % args.slo)
    print("  valid requests        : %d" % total)
    print("  good requests (<500)  : %d" % good)
    print("  SLI (availability)    : %s" % ("%.3f%%" % sli if sli is not None else "NO DATA"))
    print("  error budget          : %.3f%% of requests may fail" % budget)
    print("  burn rate             : %s" % ("%.2fx" % burn if burn is not None else "n/a"))
    print("  p99 latency           : %s" % ("%.1f ms" % p99 if p99 is not None else "n/a"))
    print("  telemetry age         : %s" % ("%.0fs" % staleness if staleness is not None else "NEVER REPORTED"))
    if stale:
        print("  *** TELEMETRY STALE - THIS REPORT IS NOT EVIDENCE OF HEALTH ***")
        print("  *** absence of signal is not a green signal                 ***")
    print("===========================================================")

rc = 0
if stale:
    rc = 2
if args.min_sli is not None and (sli is None or sli < args.min_sli):
    rc = 3
sys.exit(rc)
PYEOF

  cat > "$LAB_HOME/lb_healthcheck.sh" <<'SHEOF'
#!/usr/bin/env bash
# Stand-in for a Google Cloud Load Balancing health check.
# check-interval 5s, timeout 2s, unhealthy-threshold 3, healthy-threshold 2.
set -uo pipefail
STATE_FILE=/run/teach-lab/lb_state
LOG=/var/log/teach-lab/lb.log
fails=0; oks=0; state=UNKNOWN
mkdir -p /run/teach-lab
while true; do
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:8080/healthz || echo 000)
  if [ "$code" = "200" ]; then oks=$((oks + 1)); fails=0; else fails=$((fails + 1)); oks=0; fi
  if [ "$fails" -ge 3 ] && [ "$state" != "UNHEALTHY" ]; then
    state=UNHEALTHY
    echo "$(date -Is) probe=$code state=UNHEALTHY action=instance-removed-from-serving-pool" | tee -a "$LOG"
  elif [ "$oks" -ge 2 ] && [ "$state" != "HEALTHY" ]; then
    state=HEALTHY
    echo "$(date -Is) probe=$code state=HEALTHY action=instance-added-to-serving-pool" | tee -a "$LOG"
  fi
  printf 'state=%s last_probe=%s at=%s\n' "$state" "$code" "$(date -Is)" > "$STATE_FILE"
  sleep 5
done
SHEOF

  cat > "$LAB_HOME/loadgen.sh" <<'SHEOF'
#!/usr/bin/env bash
# Synthetic user traffic: one request every 2 seconds, from the client's point
# of view. This is the black-box probe, not the health check.
set -uo pipefail
LOG=/var/log/teach-lab/client.log
while true; do
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:8080/ || echo 000)
  printf '%s client_status=%s\n' "$(date -Is)" "$code" >> "$LOG"
  sleep 2
done
SHEOF

  cat > /usr/local/bin/teach-lab-slo <<'SHEOF'
#!/usr/bin/env bash
exec /usr/bin/env python3 /opt/teach-lab/slo_report.py "$@"
SHEOF

  cat > /usr/local/bin/teach-lab-status <<'SHEOF'
#!/usr/bin/env bash
set -uo pipefail
echo "=== units ================================================="
for u in teach-lab-backend teach-lab-app teach-lab-collector teach-lab-lb teach-lab-load; do
  printf '  %-24s %-10s %-10s restart=%s\n' "$u" \
    "$(systemctl is-active "$u.service" 2>/dev/null)" \
    "$(systemctl is-enabled "$u.service" 2>/dev/null)" \
    "$(systemctl show -p Restart --value "$u.service" 2>/dev/null)"
done
echo "=== load balancer view ===================================="
cat /run/teach-lab/lb_state 2>/dev/null || echo "  no health check state yet"
echo "=== live probes ==========================================="
printf '  GET /        -> %s\n' "$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:8080/ || echo 000)"
printf '  GET /healthz -> %s\n' "$(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:8080/healthz || echo 000)"
echo "  effective config:"
curl -s -m 3 http://127.0.0.1:8080/debug 2>/dev/null | sed 's/^/    /' || echo "    process not answering"
echo "=== last client-side results =============================="
tail -n 5 /var/log/teach-lab/client.log 2>/dev/null | sed 's/^/  /' || echo "  none"
echo "=== last application errors ==============================="
grep -h '"severity": "\(ERROR\|CRITICAL\)"' /var/log/teach-lab/app.log 2>/dev/null | tail -n 3 | sed 's/^/  /' || echo "  none"
echo
teach-lab-slo --window-minutes 15
SHEOF

  chmod 0755 "$LAB_HOME"/*.py "$LAB_HOME"/*.sh /usr/local/bin/teach-lab-slo /usr/local/bin/teach-lab-status
  : > "$LAB_LOG/app.log";     : > "$LAB_LOG/metrics.jsonl"
  : > "$LAB_LOG/client.log";  : > "$LAB_LOG/lb.log"
}

write_env() {
  # $1 = backend url, $2 = healthz mode, $3 = leak flag, $4 = release tag
  cat > "$LAB_ETC/app.env" <<EOF
# teach-lab frontend configuration (read by systemd EnvironmentFile)
APP_PORT=8080
BACKEND_URL=$1
HEALTHZ_MODE=$2
LEAK=$3
LEAK_LIMIT_MB=64
LOG_PATH=$LAB_LOG/app.log
RELEASE=$4
EOF
  chmod 0644 "$LAB_ETC/app.env"
}

install_units() {
  info "installing systemd units"

  cat > "$UNIT_DIR/teach-lab-backend.service" <<'EOF'
[Unit]
Description=teach-lab data tier
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /opt/teach-lab/backend.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/teach-lab-app.service" <<'EOF'
[Unit]
Description=teach-lab frontend instance
After=network.target teach-lab-backend.service

[Service]
Type=simple
EnvironmentFile=/etc/teach-lab/app.env
ExecStart=/usr/bin/env python3 /opt/teach-lab/app.py
# NOTE: no restart policy. The unit was authored by hand and never revisited.
Restart=no
MemoryMax=192M

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/teach-lab-collector.service" <<'EOF'
[Unit]
Description=teach-lab telemetry collector (Ops Agent stand-in)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 /opt/teach-lab/collector.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/teach-lab-lb.service" <<'EOF'
[Unit]
Description=teach-lab load balancer health check
After=network.target

[Service]
Type=simple
ExecStart=/opt/teach-lab/lb_healthcheck.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/teach-lab-load.service" <<'EOF'
[Unit]
Description=teach-lab synthetic user traffic
After=network.target teach-lab-app.service

[Service]
Type=simple
ExecStart=/opt/teach-lab/loadgen.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

wait_http() {
  # $1 = path, $2 = expected code, $3 = seconds
  local path="$1" want="$2" secs="${3:-20}" code
  for ((i = 0; i < secs * 2; i++)); do
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$APP_URL$path" || echo 000)
    [[ "$code" == "$want" ]] && return 0
    sleep 0.5
  done
  return 1
}

start_stack() {
  info "starting the stack"
  systemctl enable --now teach-lab-backend.service   >/dev/null 2>&1
  systemctl enable --now teach-lab-collector.service >/dev/null 2>&1
  systemctl enable --now teach-lab-app.service       >/dev/null 2>&1
  systemctl enable --now teach-lab-lb.service        >/dev/null 2>&1
  systemctl enable --now teach-lab-load.service      >/dev/null 2>&1
}

baseline() {
  info "proving the baseline healthy BEFORE breaking anything"
  write_env "http://127.0.0.1:9090/data" "deep" "0" "v1.3.9"
  install_units
  start_stack
  systemctl restart teach-lab-app.service
  wait_http "/" 200 25        || die "baseline failed: / is not 200 on a clean build — inspect 'journalctl -u teach-lab-app'"
  wait_http "/healthz" 200 10 || die "baseline failed: /healthz is not 200 on a clean build"
  ok "baseline green: GET / = 200, GET /healthz = 200, telemetry flowing"
}

# -----------------------------------------------------------------------------
# the break
# -----------------------------------------------------------------------------
inject() {
  rule
  info "${B}rolling out release v1.4.0${N} (this is the break)"

  # Fault 1: config regression — the data tier port was fat-fingered in the
  #          release. The frontend now fails every user request with 503.
  # Fault 2: the same release swapped the deep health check for a shallow one,
  #          so the load balancer will keep this broken instance in the pool.
  # Fault 3: the release leaks 2 MiB per request and self-terminates at 64 MiB.
  write_env "http://127.0.0.1:9099/data" "shallow" "1" "v1.4.0"

  # Fault 4: the telemetry collector was stopped during "maintenance" and never
  #          re-enabled, so the SLO dashboards go quiet instead of red.
  systemctl stop teach-lab-collector.service    >/dev/null 2>&1 || true
  systemctl disable teach-lab-collector.service >/dev/null 2>&1 || true

  systemctl restart teach-lab-app.service
  ok "v1.4.0 is live"
  info "letting the incident develop for 75 seconds — do not interrupt"
  sleep 75
}

# -----------------------------------------------------------------------------
# briefing
# -----------------------------------------------------------------------------
brief() {
  rule
  printf '%sINCIDENT BRIEFING — gcp-cdl 6.2 — modern operations, reliability, resilience%s\n' "$B" "$N"
  rule
  cat <<'EOF'
SITUATION
  Service      : shop-frontend, one instance, fronted by an HTTP(S) load
                 balancer health check, backed by a local data tier.
  Change       : release v1.4.0 was rolled out minutes ago.
  Page         : "customers report checkout errors" — but every dashboard you
                 own is green, and nobody can tell you when it started.

SYMPTOMS YOU WILL OBSERVE
  1. Users get HTTP 503 on every request:
         curl -i http://127.0.0.1:8080/
     while the load balancer probe stays a confident 200:
         curl -i http://127.0.0.1:8080/healthz
     The instance is in the serving pool and cannot serve. Look at
     /run/teach-lab/lb_state and /var/log/teach-lab/lb.log: HEALTHY.
  2. Roughly one minute into traffic the process disappears with exit code 137
     (out of memory) and does NOT come back. `systemctl status teach-lab-app`
     shows the unit inactive/failed; the client log flips from 503 to 000
     (connection refused).
  3. `teach-lab-slo` prints an implausibly clean report and stamps
     "TELEMETRY STALE". Availability is not 100% — it is unmeasured. Absence
     of signal is being read as health.

YOUR MISSION — five objectives
  O1  MITIGATE FIRST. Get GET / answering 200 with the data-tier payload
      again. In an incident, restoring service precedes root cause.
  O2  KILL THE ROOT CAUSE. Find why the frontend cannot reach its dependency
      and correct the configuration of release v1.4.0. Hint: /debug prints the
      process's effective configuration; the data tier really is listening.
  O3  MAKE THE HEALTH SIGNAL MEANINGFUL. The health check must report
      NOT_SERVING when the instance cannot actually serve a request, so that
      the load balancer takes it out of rotation instead of sending users to
      it. A liveness probe that only proves "the socket answers" is worthless
      for routing decisions.
  O4  ADD AUTOHEALING AND STOP THE LEAK. A crashed instance must come back
      without a human — that is what a managed instance group's autohealing
      does for you, and it is the difference between an MTTR of seconds and an
      MTTR of "whenever someone reads the page". Then remove the defect
      itself: autohealing that restarts a leaking process every 60 seconds is
      a bandage, not a fix.
  O5  RESTORE OBSERVABILITY. Get telemetry flowing again AND make it survive a
      reboot. Then confirm the SLO report stops printing TELEMETRY STALE.

SUCCESS CRITERIA (graded automatically)
  Let the service run clean for ~2 minutes, then:
      sudo /path/to/this/script.sh --verify
  It checks, behaviourally and not by reading your notes:
      * GET / returns 200 with the data-tier payload
      * SLI over the last 2 minutes >= 95% and telemetry is fresh
      * the leak flag is off in the RUNNING process (via /debug)
      * the collector is active AND enabled, heartbeat under 60s old
      * stopping the data tier makes /healthz go non-200 within ~4s
      * kill -9 of the main PID brings the service back within 15s

TOOLBOX
      teach-lab-status                     # one-screen incident view
      teach-lab-slo --window-minutes 15    # SLI, error budget, burn rate
      teach-lab-slo --json                 # same, machine readable
      systemctl status teach-lab-app
      journalctl -u teach-lab-app -n 50 --no-pager
      curl -s http://127.0.0.1:8080/debug | python3 -m json.tool
      tail -f /var/log/teach-lab/client.log
      cat /etc/teach-lab/app.env
      systemctl cat teach-lab-app.service
      ss -ltnp | grep -E '8080|9090'

VOCABULARY THIS LAB IS TESTING (exam wording)
  SLI / SLO / error budget / burn rate  — the report is the SLI; 99.5% is the
      SLO; the 0.5% is the budget you are allowed to spend; the burn rate says
      how fast you are spending it. A frozen dashboard spends budget silently.
  Golden signals — latency, traffic, errors, saturation. Fault 3 is saturation
      turning into errors; fault 4 removed your ability to see any of them.
  Observability vs monitoring — you had monitoring (a green check) and no
      observability (no way to ask "why are users failing while I am green?").
  Reliability vs resilience — reliability is not failing; resilience is
      recovering automatically when you do. O3 is reliability of the signal,
      O4 is resilience of the instance.
  MTTR / MTTD — every objective here shortens one of them.
  Autohealing / managed instance groups — O4 is the single-VM analogue of a
      MIG health check plus autohealing policy.
  Toil — restarting a service by hand every night is toil: manual, repetitive,
      automatable, and it scales with traffic. Automate it away.
  Blameless postmortem — four contributing factors, zero people to blame: a
      config typo, a weakened probe, a leak, and an agent nobody re-enabled.

RULES
  Fix it in place. Do not delete the lab, do not reinstall it, do not edit this
  script. Reverting the whole release is not available to you: v1.4.0 also
  carries features the business wants, so you fix forward.
EOF
  rule
  printf '%sWhat the box looks like right now:%s\n' "$B" "$N"
  rule
  teach-lab-status || true
  rule
}

# -----------------------------------------------------------------------------
# grading
# -----------------------------------------------------------------------------
FAILED=0
check() { # $1 = label, $2 = 0/1 result, $3 = detail
  if [[ "$2" -eq 0 ]]; then printf '%s  PASS %s%s  %s\n' "$G" "$N" "$1" "${3:-}"
  else printf '%s  FAIL %s%s  %s\n' "$R" "$N" "$1" "${3:-}"; FAILED=$((FAILED + 1)); fi
}

verify() {
  [[ -f "$LAB_HOME/app.py" ]] || die "lab is not installed — run with --break first"
  rule
  printf '%sGRADING — gcp-cdl 6.2 break & fix%s\n' "$B" "$N"
  rule

  # O1 — service restored
  local code body
  code=$(curl -s -o /tmp/teach-lab-body -m 3 -w '%{http_code}' "$APP_URL/" || echo 000)
  body=$(cat /tmp/teach-lab-body 2>/dev/null || true); rm -f /tmp/teach-lab-body
  if [[ "$code" == "200" && "$body" == *"data-tier"* ]]; then
    check "O1 service restored" 0 "GET / = 200 and payload comes from the data tier"
  else
    check "O1 service restored" 1 "GET / = $code (expected 200 with the data-tier payload)"
  fi

  # O5/SLO — measured before the destructive probes dirty the window
  if teach-lab-slo --window-minutes 2 --min-sli 95 --max-staleness 60 >/tmp/teach-lab-slo 2>&1; then
    check "O5 SLI and telemetry" 0 "fresh telemetry, SLI >= 95% over the last 2 minutes"
  else
    check "O5 SLI and telemetry" 1 "$(grep -E 'SLI|TELEMETRY|valid requests' /tmp/teach-lab-slo | tr '\n' ' ')"
  fi
  rm -f /tmp/teach-lab-slo

  # O4a — the defect itself is gone, checked on the live process
  if curl -s -m 3 "$APP_URL/debug" | grep -q '"leak": false'; then
    check "O4 leak removed" 0 "the running process reports leak=false"
  else
    check "O4 leak removed" 1 "the running process still has the leak enabled (see /debug)"
  fi

  # O5b — collector running and persistent
  local c_active c_enabled hb_age=999
  c_active=$(systemctl is-active teach-lab-collector.service 2>/dev/null || true)
  c_enabled=$(systemctl is-enabled teach-lab-collector.service 2>/dev/null || true)
  [[ -f "$LAB_LOG/collector.heartbeat" ]] && hb_age=$(( $(date +%s) - $(stat -c %Y "$LAB_LOG/collector.heartbeat") ))
  if [[ "$c_active" == "active" && "$c_enabled" == "enabled" && $hb_age -lt 60 ]]; then
    check "O5 collector" 0 "active, enabled, heartbeat ${hb_age}s old"
  else
    check "O5 collector" 1 "active=$c_active enabled=$c_enabled heartbeat_age=${hb_age}s"
  fi

  # O3 — deep health check, proven behaviourally
  info "probing the health check: stopping the data tier for a moment"
  systemctl stop teach-lab-backend.service
  local hz=200
  for _ in {1..10}; do
    hz=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$APP_URL/healthz" || echo 000)
    [[ "$hz" != "200" ]] && break
    sleep 0.5
  done
  systemctl start teach-lab-backend.service
  if [[ "$hz" != "200" ]]; then
    check "O3 meaningful health check" 0 "with the dependency down /healthz returned $hz"
  else
    check "O3 meaningful health check" 1 "the dependency was down and /healthz still returned 200"
  fi
  wait_http "/" 200 20 || warn "the service is slow to recover after the probe; give it a moment"

  # O4b — autohealing, proven behaviourally
  local pid
  pid=$(systemctl show -p MainPID --value teach-lab-app.service 2>/dev/null || echo 0)
  if [[ "${pid:-0}" =~ ^[0-9]+$ && "${pid:-0}" -gt 0 ]]; then
    info "probing autohealing: kill -9 on PID $pid"
    kill -9 "$pid" 2>/dev/null || true
    sleep 2
    if wait_http "/" 200 15; then
      check "O4 autohealing" 0 "the instance came back on its own after SIGKILL (restart=$(systemctl show -p Restart --value teach-lab-app.service))"
    else
      check "O4 autohealing" 1 "still down 15s after SIGKILL — no restart policy is doing its job"
    fi
  else
    check "O4 autohealing" 1 "the unit has no running main process to kill"
  fi

  rule
  if [[ $FAILED -eq 0 ]]; then
    printf '%sALL OBJECTIVES MET.%s The instance serves, tells the truth about its own\n' "$G" "$N"
    say "health, heals itself, and is measurable. Now write the two-paragraph"
    say "postmortem: contributing factors, detection gap, and the one change that"
    say "would have contained the blast radius before any human was paged."
    rule
    return 0
  fi
  printf '%s%d objective(s) still open.%s Run: teach-lab-status\n' "$R" "$FAILED" "$N"
  rule
  return 1
}

clean() {
  info "removing the lab"
  for u in "${UNITS[@]}"; do
    systemctl disable --now "$u.service" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$u.service"
  done
  systemctl daemon-reload
  rm -rf "$LAB_HOME" "$LAB_ETC" "$LAB_LOG" "$LAB_RUN"
  rm -f /usr/local/bin/teach-lab-status /usr/local/bin/teach-lab-slo
  ok "every lab artifact is gone"
}

usage() {
  cat <<EOF
usage: sudo $0 [--break|--brief|--verify|--clean] [--yes]

  --break   build the lab, prove it healthy, inject the incident (default)
  --brief   reprint the incident briefing and the current state
  --verify  grade your fix against the six behavioural criteria
  --clean   remove every artifact this lab created
  --yes     skip the interactive confirmation (or export TEACH_LAB_ACK=yes)
EOF
}

main() {
  local action="break"
  for arg in "$@"; do
    case "$arg" in
      --break)  action="break" ;;
      --brief)  action="brief" ;;
      --verify) action="verify" ;;
      --clean)  action="clean" ;;
      --yes|-y) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $arg (try --help)" ;;
    esac
  done
  export ASSUME_YES="${ASSUME_YES:-0}"

  case "$action" in
    break)
      preflight
      install_payload
      baseline
      inject
      brief
      ;;
    brief)  [[ -x /usr/local/bin/teach-lab-status ]] || die "lab is not installed"; brief ;;
    verify) [[ $EUID -eq 0 ]] || die "run as root"; verify ;;
    clean)
      [[ $EUID -eq 0 ]] || die "run as root"
      if [[ "${TEACH_LAB_ACK:-}" != "yes" && "$ASSUME_YES" != "1" ]]; then
        read -r -p "Delete the lab and all its logs? [y/N] " r < /dev/tty
        [[ "$r" =~ ^[yY]$ ]] || die "aborted"
      fi
      clean
      ;;
  esac
}

main "$@"
exit 0

# =============================================================================
#  SOLUTION — do not read until you have tried, or until --verify passes
# =============================================================================
#
#  TRIAGE ORDER MATTERS. Restore service, then measure, then remove the defect,
#  then close the detection gap. Root-causing while customers are down is the
#  classic novice inversion.
#
#  -- STEP 0: SEE THE WHOLE BOARD ---------------------------------------------
#
#     teach-lab-status
#
#  Expected output while broken:
#       teach-lab-app            inactive   enabled   restart=no
#       teach-lab-collector      inactive   disabled  restart=always
#     load balancer view:
#       state=HEALTHY last_probe=200 at=2026-09-09T...
#     live probes:
#       GET /        -> 000        <-- the process is gone
#       GET /healthz -> 000
#     SLO report:
#       SLI (availability)    : 100.000%   <-- a lie: 0 valid requests collected
#       *** TELEMETRY STALE - THIS REPORT IS NOT EVIDENCE OF HEALTH ***
#
#  Read the crash reason before restarting anything — the evidence is in the
#  journal and it is destroyed by nothing, but read it while it is in front of
#  you:
#
#     journalctl -u teach-lab-app -n 20 --no-pager | tail -5
#
#  Expected, the last line the process ever wrote:
#       {"exitCode": 137, "leaked_mib": 64, "limit_mib": 64, "message":
#        "container memory limit exceeded - terminating", "severity": "CRITICAL", ...}
#
#  Exit 137 = 128 + 9 = killed for memory. That is fault 3, and it tells you the
#  restart will only buy you about a minute until you also fix the leak.
#
#  -- STEP 1 (O1): MITIGATE ---------------------------------------------------
#
#     systemctl start teach-lab-app.service
#     curl -i http://127.0.0.1:8080/
#
#  Expected: HTTP/1.1 503 Service Unavailable
#       {"error": "data tier unavailable", "detail": "URLError: <urlopen error
#        [Errno 111] Connection refused>"}
#
#  The process is up and still cannot serve: the crash was a consequence, not
#  the customer-facing cause. Two independent faults, which is normal.
#
#  -- STEP 2 (O2): ROOT CAUSE OF THE 503 --------------------------------------
#
#     curl -s http://127.0.0.1:8080/debug | python3 -m json.tool
#
#  Expected:
#       { "backend_url": "http://127.0.0.1:9099/data",
#         "healthz_mode": "shallow", "leak": true, "release": "v1.4.0" }
#
#  Now confirm where the dependency actually listens — never assume:
#
#     ss -ltnp | grep -E '9090|9099'
#     # 127.0.0.1:9090 is LISTEN (python3, teach-lab-backend); 9099 is nothing.
#     curl -s http://127.0.0.1:9090/data | head -c 80
#     # {"source": "data-tier", "items": [{"sku": "GG-0001", ...
#
#  The data tier is healthy. v1.4.0 shipped a wrong port. Fix the configuration:
#
#     sed -i 's|^BACKEND_URL=.*|BACKEND_URL=http://127.0.0.1:9090/data|' /etc/teach-lab/app.env
#
#  -- STEP 3 (O3 + O4a): FIX THE PROBE AND THE LEAK IN THE SAME EDIT ----------
#
#     sed -i 's|^HEALTHZ_MODE=.*|HEALTHZ_MODE=deep|' /etc/teach-lab/app.env
#     sed -i 's|^LEAK=.*|LEAK=0|'                    /etc/teach-lab/app.env
#     cat /etc/teach-lab/app.env
#
#  Why deep: a shallow check answers "is the process alive?" A load balancer is
#  not asking that — it is asking "should I send a customer here?" When the two
#  questions have different answers, the balancer keeps a broken instance in the
#  serving pool and the outage becomes invisible to every routing decision you
#  own. A health check used for routing must exercise the critical path,
#  including the dependencies without which the instance cannot serve. (Keep the
#  cost bounded: short timeout, no fan-out to third parties, or a slow dependency
#  turns one incident into a cascading failure across every instance at once.)
#
#  -- STEP 4 (O4b): AUTOHEALING ------------------------------------------------
#
#  systemd's restart policy is the single-VM analogue of a managed instance
#  group autohealing policy. Use a drop-in so the change is visible and revertible:
#
#     mkdir -p /etc/systemd/system/teach-lab-app.service.d
#     cat > /etc/systemd/system/teach-lab-app.service.d/10-autoheal.conf <<'EOF'
#     [Service]
#     Restart=always
#     RestartSec=5
#     StartLimitIntervalSec=0
#     EOF
#     systemctl daemon-reload
#     systemctl restart teach-lab-app.service
#     systemctl show -p Restart --value teach-lab-app.service     # -> always
#
#  Note the ordering discipline: the leak was removed in step 3 BEFORE
#  autohealing was enabled. Reversed, you get a crash loop that hides the defect
#  behind a green-looking service — availability restored, root cause buried.
#
#  -- STEP 5 (O5): RESTORE OBSERVABILITY, PERMANENTLY -------------------------
#
#     systemctl enable --now teach-lab-collector.service
#     systemctl is-enabled teach-lab-collector.service    # -> enabled
#
#  `--now` starts it; `enable` is what makes it survive the next reboot. The
#  original fault was not "the agent stopped", it was "the agent stopped and
#  nothing noticed for hours". Prove the signal is alive again:
#
#     sleep 20 && teach-lab-slo --window-minutes 5
#
#  Expected, once traffic has been clean for a couple of minutes:
#       valid requests        : 60
#       good requests (<500)  : 60
#       SLI (availability)    : 100.000%
#       error budget          : 0.500% of requests may fail
#       burn rate             : 0.00x
#       telemetry age         : 3s
#     and NO staleness banner.
#
#  -- STEP 6: VERIFY ----------------------------------------------------------
#
#     sudo ./break-fix-6.2-operations-reliability.sh --verify
#
#  Expected: six PASS lines. The grader stops the data tier to prove your probe
#  is deep, and SIGKILLs the process to prove autohealing works — both restore
#  themselves, so the lab stays usable.
#
#  -- WHAT THIS MAPS TO ON THE EXAM -------------------------------------------
#
#  * Reliability is measured, not asserted. An SLI is a ratio of good events to
#    valid events; the SLO is the target; 100% is never the target, because the
#    error budget is what buys you the right to ship changes at all. A team with
#    budget left ships; a team that has burned it freezes features and spends
#    the next cycle on reliability. That is the whole negotiation between
#    velocity and stability, in one number.
#  * Burn rate is the alerting primitive. Do not page on "an error happened";
#    page on "at this rate the budget is gone in N hours". Fast-burn and
#    slow-burn windows exist so that a two-minute blip does not wake anyone and
#    a slow bleed does not go unnoticed for a month.
#  * Absence of telemetry is an incident. Fault 4 is the one students
#    consistently under-rate: it did not cause the outage, it caused the outage
#    to be invisible, which is what turned minutes of MTTR into hours. Alert on
#    the freshness of your signals, not only on their values.
#  * Resilience is designed in, not bolted on. Autohealing, health-check-driven
#    load balancing, multi-zone instance groups, autoscaling and graceful
#    degradation are the same idea at different blast radii: assume the
#    component fails, and make recovery automatic. Google Cloud gives you
#    regional managed instance groups, health checks, Cloud Load Balancing and
#    autoscaling precisely so that a single instance dying is a non-event.
#  * Recovery objectives frame the trade-off. RTO is how long you may be down;
#    RPO is how much data you may lose. Backup/restore is cheap with a long RTO;
#    warm standby is faster and costlier; active-active multi-region is fastest
#    and costliest. The right answer is the cheapest pattern that meets the
#    objective the business actually funded — never the most redundant one
#    available.
#  * Toil is the target of automation. The manual nightly restart you replaced
#    with Restart=always is textbook toil: manual, repetitive, automatable, no
#    enduring value, and it grows with traffic. SRE caps toil (~50%) so that
#    engineering time survives operational load.
#  * Postmortems are blameless because there was no single culprit here: a typo
#    in a config, a probe that was weakened for a good-sounding reason, a leak in
#    a dependency, and an agent left disabled after maintenance. Four ordinary
#    decisions, one outage. You fix systems, not people.
#
#  -- CLEAN UP ----------------------------------------------------------------
#
#     sudo ./break-fix-6.2-operations-reliability.sh --clean
#
#  Official reference for this objective:
#    https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
# =============================================================================