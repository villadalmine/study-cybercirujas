#!/usr/bin/env bash
#
# ==============================================================================
#  PCA — Prometheus Certified Associate
#  Domain 5.2: Instrumentation
#  Exercise: break & fix — "The counter that stops counting"
# ==============================================================================
#
#  WHAT THIS TEACHES
#    Instrumentation is the client side of Prometheus: how your application
#    creates metric objects with a client library and exposes them over an
#    HTTP `/metrics` endpoint in the text exposition format. A large share of
#    real-world instrumentation incidents are NOT scrape/network problems —
#    they are client-library misuse. The most common one is creating a metric
#    object on the hot path (per request / per function call) instead of once,
#    at module import time. Prometheus client libraries keep a single global
#    CollectorRegistry, and registering two collectors with the same metric
#    name into it is a hard error.
#
#  This script provisions a tiny instrumented HTTP service INSIDE A DISPOSABLE
#  LAB VM, plants exactly that defect, and hands the running-but-broken service
#  to the student to diagnose and repair. The full solution is at the very
#  bottom of this file, commented out.
#
#  SAFETY MODEL
#    - Runs entirely under a throwaway directory in $HOME. No system packages,
#      no root, no systemd units, no firewall changes.
#    - The service binds to 127.0.0.1 only (never exposed on the network).
#    - Uses an unprivileged port (18000 by default).
#    - A guard refuses to run unless you confirm this is a scratch lab host.
#    - `./this_script.sh cleanup` kills the process and removes the lab dir.
#
#  OFFICIAL REFERENCES
#    - PCA curriculum:  https://github.com/cncf/curriculum
#                       https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#    - Instrumentation best practices:
#                       https://prometheus.io/docs/practices/instrumentation/
#    - Metric & label naming:
#                       https://prometheus.io/docs/practices/naming/
#    - Metric types:    https://prometheus.io/docs/concepts/metric_types/
#    - Exposition format:
#                       https://prometheus.io/docs/instrumenting/exposition_formats/
#    - Python client library (used here as the reference client):
#                       https://github.com/prometheus/client_python
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
LAB_NAME="pca-5.2-instrumentation"
LAB_DIR="${LAB_DIR:-${HOME}/${LAB_NAME}}"
VENV_DIR="${LAB_DIR}/.venv"
APP_FILE="${LAB_DIR}/app.py"
PID_FILE="${LAB_DIR}/app.pid"
LOG_FILE="${LAB_DIR}/app.log"
BIND_ADDR="127.0.0.1"
PORT="${PORT:-18000}"
BASE_URL="http://${BIND_ADDR}:${PORT}"

# ------------------------------------------------------------------------------
# Pretty output (degrades gracefully when stdout is not a terminal)
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET="$(printf '\033[0m')"; C_BOLD="$(printf '\033[1m')"
  C_RED="$(printf '\033[31m')"; C_GRN="$(printf '\033[32m')"
  C_YEL="$(printf '\033[33m')"; C_CYN="$(printf '\033[36m')"
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
fi

log()  { printf '%s[lab]%s %s\n' "${C_CYN}" "${C_RESET}" "$*"; }
ok()   { printf '%s[ ok]%s %s\n' "${C_GRN}" "${C_RESET}" "$*"; }
warn() { printf '%s[warn]%s %s\n' "${C_YEL}" "${C_RESET}" "$*"; }
die()  { printf '%s[die]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# ------------------------------------------------------------------------------
# Guard: never run this on a machine you care about.
# ------------------------------------------------------------------------------
confirm_lab_host() {
  if [ "${LAB_OK:-0}" = "1" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "Refusing to run non-interactively. This exercise DAMAGES a service on purpose.
     Re-run on a disposable lab VM with:  LAB_OK=1 $0"
  fi
  warn "This exercise intentionally breaks an instrumented service."
  warn "Run it ONLY on a disposable lab VM you can throw away."
  printf 'Type %sBREAK%s to confirm this is a scratch host: ' "${C_BOLD}" "${C_RESET}"
  read -r answer
  [ "${answer}" = "BREAK" ] || die "Not confirmed. Aborting."
}

# ------------------------------------------------------------------------------
# Teardown
# ------------------------------------------------------------------------------
stop_app() {
  if [ -f "${PID_FILE}" ]; then
    local pid; pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${pid}" 2>/dev/null || true
      log "stopped previous service (pid ${pid})"
    fi
    rm -f "${PID_FILE}"
  fi
}

cleanup_all() {
  stop_app
  if [ -d "${LAB_DIR}" ]; then
    rm -rf "${LAB_DIR}"
    ok "removed lab directory: ${LAB_DIR}"
  fi
  ok "cleanup complete."
}

# ------------------------------------------------------------------------------
# Provision the lab: venv + prometheus_client
# ------------------------------------------------------------------------------
provision() {
  need python3
  need curl
  mkdir -p "${LAB_DIR}"
  if [ ! -d "${VENV_DIR}" ]; then
    log "creating virtualenv in ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  fi
  # shellcheck disable=SC1091
  . "${VENV_DIR}/bin/activate"
  if ! python -c 'import prometheus_client' >/dev/null 2>&1; then
    log "installing prometheus_client into the lab venv"
    pip install --quiet --upgrade pip >/dev/null 2>&1 || true
    pip install --quiet prometheus_client >/dev/null 2>&1 \
      || die "could not install prometheus_client (no network?). Pre-install it and retry."
  fi
  ok "prometheus_client available: $(python -c 'import prometheus_client as p; print(p.__version__)')"
}

# ------------------------------------------------------------------------------
# Write the DEFECTIVE instrumented application.
#
# The defect is deliberate and idiomatic: the business counter is constructed
# INSIDE the request handler, so it is registered into the global default
# CollectorRegistry on every request. The first request registers it fine;
# the second attempts to register the same metric name again and raises
# ValueError: Duplicated timeseries in CollectorRegistry.
# ------------------------------------------------------------------------------
write_broken_app() {
  cat > "${APP_FILE}" <<'PYEOF'
#!/usr/bin/env python3
"""PCA 5.2 lab service — INSTRUMENTED, and intentionally defective.

Endpoints:
  GET /         business endpoint that should count each hit
  GET /metrics  Prometheus exposition endpoint (text format)

Client library: prometheus_client (the reference Python client).
Docs: https://github.com/prometheus/client_python
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST, REGISTRY

BIND_ADDR = "127.0.0.1"
PORT = 18000


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            # Correct: serialize the default registry in the text exposition
            # format and advertise the matching Content-Type.
            payload = generate_latest(REGISTRY)
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        # ----------------------------------------------------------------
        # >>> THE DEFECT IS HERE <<<
        # A brand-new Counter object is constructed on EVERY request. Each
        # construction auto-registers the metric name into the global default
        # CollectorRegistry. The first request works; the second raises
        # ValueError: Duplicated timeseries in CollectorRegistry.
        # ----------------------------------------------------------------
        requests_total = Counter(
            "app_requests",                 # exposed as app_requests_total
            "Total number of business requests served",
        )
        requests_total.inc()

        body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Quiet the default access log; failures still print tracebacks.
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer((BIND_ADDR, PORT), Handler)
    print(f"serving on http://{BIND_ADDR}:{PORT}  (/, /metrics)", flush=True)
    server.serve_forever()
PYEOF
  ok "wrote defective service: ${APP_FILE}"
}

# ------------------------------------------------------------------------------
# Start the service in the background
# ------------------------------------------------------------------------------
start_app() {
  # shellcheck disable=SC1091
  . "${VENV_DIR}/bin/activate"
  stop_app
  : > "${LOG_FILE}"
  nohup python "${APP_FILE}" >>"${LOG_FILE}" 2>&1 &
  echo "$!" > "${PID_FILE}"
  # Wait for the port to come up.
  for _ in $(seq 1 20); do
    if curl -fsS "${BASE_URL}/metrics" >/dev/null 2>&1; then
      ok "service is up (pid $(cat "${PID_FILE}")) at ${BASE_URL}"
      return 0
    fi
    sleep 0.25
  done
  die "service did not come up — inspect ${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# Trigger the failure so the student walks into a broken system immediately.
# ------------------------------------------------------------------------------
demonstrate() {
  log "sending 3 requests to the business endpoint..."
  local i code
  for i in 1 2 3; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/" 2>/dev/null || echo 'ERR')"
    printf '     request #%d -> %s\n' "${i}" "${code}"
  done
}

# ------------------------------------------------------------------------------
# Student briefing
# ------------------------------------------------------------------------------
briefing() {
  cat <<EOF

${C_BOLD}================= PCA 5.2 — INSTRUMENTATION: BREAK & FIX =================${C_RESET}

A small instrumented HTTP service is running on ${C_BOLD}${BASE_URL}${C_RESET}.
It has two endpoints:
    GET /         business endpoint (should count every hit)
    GET /metrics  Prometheus exposition endpoint

${C_YEL}${C_BOLD}SYMPTOM you will observe${C_RESET}
  * The FIRST call to ${BASE_URL}/ returns 200.
  * Every SUBSEQUENT call to / fails: curl reports
        curl: (52) Empty reply from server
    (or a 500 / connection reset, depending on your curl version).
  * ${BASE_URL}/metrics still responds, but the business counter is
    ${C_BOLD}stuck at app_requests_total 1.0${C_RESET} and never grows.
  * The application log shows a Python traceback ending in:
        ValueError: Duplicated timeseries in CollectorRegistry:
        {'app_requests_total', 'app_requests_created'}

${C_GRN}${C_BOLD}YOUR GOAL${C_RESET}
  Repair the INSTRUMENTATION so that:
    1. Repeated GET / requests all return 200 (no more empty replies).
    2. app_requests_total increases by exactly 1 per request on /metrics.
    3. /metrics stays valid text exposition format (Content-Type
       'text/plain; version=0.0.4'), scrapeable by Prometheus.
  Do NOT touch the network, the port, or Prometheus itself — the fault is
  in the client-side instrumentation code only.

${C_CYN}${C_BOLD}INVESTIGATE WITH${C_RESET}
    curl -i  ${BASE_URL}/            # watch it break on the 2nd hit
    curl -s  ${BASE_URL}/metrics | grep app_requests
    tail -n 40 ${LOG_FILE}           # read the traceback — it names the bug
    sed -n '1,80p' ${APP_FILE}       # the defect is in do_GET()
    # Optional lint of the exposition (if promtool is installed):
    curl -s ${BASE_URL}/metrics | promtool check metrics

${C_CYN}${C_BOLD}HINT${C_RESET}
  Where in the code is the Counter() object created? How many times does that
  line run over the life of the process? A Prometheus metric is a long-lived
  object: it must be constructed ${C_BOLD}once${C_RESET}, at import time — not per request.

When you think it is fixed, restart and verify:
    ${PID_FILE%/*}/.venv/bin/python ${APP_FILE}   # or: kill \$(cat ${PID_FILE}); re-run
    for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{http_code}\\n' ${BASE_URL}/; done
    curl -s ${BASE_URL}/metrics | grep '^app_requests_total'

Tear the lab down when finished:
    $0 cleanup

${C_BOLD}=========================================================================${C_RESET}
EOF
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------
main() {
  case "${1:-run}" in
    cleanup)
      cleanup_all
      ;;
    run)
      confirm_lab_host
      provision
      write_broken_app
      start_app
      demonstrate
      briefing
      ;;
    *)
      die "usage: $0 [run|cleanup]"
      ;;
  esac
}

main "$@"

# ==============================================================================
#  SOLUTION (do not read until you have tried) — step by step
# ==============================================================================
#
#  STEP 1 — Reproduce and confirm the symptom
#  ------------------------------------------
#    curl -i http://127.0.0.1:18000/        # first: 200 OK
#    curl -i http://127.0.0.1:18000/        # second: curl (52) Empty reply
#    curl -s http://127.0.0.1:18000/metrics | grep app_requests
#      # app_requests_total 1.0   <- frozen, proving increments stopped
#
#  STEP 2 — Read the log; it names the fault precisely
#  ---------------------------------------------------
#    tail -n 40 ~/pca-5.2-instrumentation/app.log
#      # Traceback ... in do_GET
#      #   requests_total = Counter("app_requests", ...)
#      # ValueError: Duplicated timeseries in CollectorRegistry:
#      #   {'app_requests_total', 'app_requests_created'}
#
#    Diagnosis: the Counter is constructed INSIDE do_GET(), so it is
#    re-registered into the global default CollectorRegistry on every
#    request. Registration of a name that already exists raises ValueError,
#    the handler dies mid-response, and the client sees an empty reply. The
#    counter never advances past 1 because the second construction (and the
#    .inc() after it) never completes.
#
#    Root cause category: client-library misuse — metric objects must be
#    created ONCE, at module scope, and reused. They are long-lived
#    collectors, not per-request values.
#    Ref: https://prometheus.io/docs/practices/instrumentation/
#         https://github.com/prometheus/client_python#counter
#
#  STEP 3 — Fix the instrumentation
#  --------------------------------
#    Move the Counter definition to module scope (constructed exactly once at
#    import) and only call .inc() inside the handler. Corrected app.py:
#
#    ------------------------------------------------------------------------
#    #!/usr/bin/env python3
#    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
#    from prometheus_client import (
#        Counter, generate_latest, CONTENT_TYPE_LATEST, REGISTRY,
#    )
#
#    BIND_ADDR = "127.0.0.1"
#    PORT = 18000
#
#    # Defined ONCE at import time. Registered into the default registry a
#    # single time for the whole process lifetime. Naming follows the
#    # conventions: base unit-less event count, '_total' suffix is added by
#    # the client for counters. Ref: https://prometheus.io/docs/practices/naming/
#    REQUESTS_TOTAL = Counter(
#        "app_requests",
#        "Total number of business requests served",
#    )
#
#    class Handler(BaseHTTPRequestHandler):
#        def do_GET(self):
#            if self.path == "/metrics":
#                payload = generate_latest(REGISTRY)
#                self.send_response(200)
#                self.send_header("Content-Type", CONTENT_TYPE_LATEST)
#                self.send_header("Content-Length", str(len(payload)))
#                self.end_headers()
#                self.wfile.write(payload)
#                return
#
#            REQUESTS_TOTAL.inc()          # reuse the one object; just increment
#            body = b"ok\n"
#            self.send_response(200)
#            self.send_header("Content-Type", "text/plain; charset=utf-8")
#            self.send_header("Content-Length", str(len(body)))
#            self.end_headers()
#            self.wfile.write(body)
#
#        def log_message(self, fmt, *args):
#            return
#
#    if __name__ == "__main__":
#        ThreadingHTTPServer((BIND_ADDR, PORT), Handler).serve_forever()
#    ------------------------------------------------------------------------
#
#    One-line surgical alternative (if you must patch in place): cut the two
#    lines that build `requests_total` inside do_GET, add a module-level
#    `REQUESTS_TOTAL = Counter("app_requests", "...")`, and replace the body
#    line with `REQUESTS_TOTAL.inc()`.
#
#  STEP 4 — Restart and verify the goal is met
#  -------------------------------------------
#    kill "$(cat ~/pca-5.2-instrumentation/app.pid)" 2>/dev/null || true
#    ~/pca-5.2-instrumentation/.venv/bin/python \
#        ~/pca-5.2-instrumentation/app.py &   # or re-run this script's start_app
#
#    for i in 1 2 3 4 5; do
#        curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18000/
#    done
#      # 200 / 200 / 200 / 200 / 200      <- no more empty replies
#
#    curl -s http://127.0.0.1:18000/metrics | grep '^app_requests_total'
#      # app_requests_total 5.0           <- advances 1 per request
#
#    # Optional: prove the exposition is well-formed and lint-clean.
#    curl -s http://127.0.0.1:18000/metrics | promtool check metrics
#
#  STEP 5 — Generalize the lesson
#  ------------------------------
#    * Construct every metric (Counter/Gauge/Histogram/Summary) ONCE, at
#      module import, and reuse the object. Never create metrics on the hot
#      path. Ref: https://prometheus.io/docs/practices/instrumentation/
#    * If you legitimately need per-request or short-lived scopes, differentiate
#      series with LABELS on a single metric object
#      (REQUESTS_TOTAL.labels(method="GET", path="/").inc()), not by building
#      new metric objects — and keep label cardinality bounded.
#      Ref: https://prometheus.io/docs/practices/naming/#labels
#    * In tests or plugin systems where re-import happens, pass an explicit
#      CollectorRegistry (registry=...) to isolate registrations instead of
#      leaning on the global default registry.
#
#  STEP 6 — Tear down the lab
#  --------------------------
#    ./<this_script>.sh cleanup
# ==============================================================================