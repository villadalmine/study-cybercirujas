#!/usr/bin/env bash
#
# =============================================================================
#  PCA — Prometheus Certified Associate
#  Domain 5. Instrumentation and Client Libraries
#  Topic 5.1  Client Libraries   (exam weight: 4)
#
#  BREAK & FIX LAB  —  "The metric name that took the target down"
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  How the official prometheus_client (Python) library instruments an
#  application: metric types (Counter / Gauge / Histogram), the default
#  CollectorRegistry, the /metrics exposition endpoint, and the automatic
#  _total / _created suffixing of counters. You will diagnose and repair a
#  registry name collision — the single most common real-world failure when
#  developers add instrumentation to a service.
#
#  RUN THIS ONLY ON A DISPOSABLE LABORATORY VM.
#  It creates files under a lab directory, installs a Python virtualenv, and
#  binds TCP :8000. It does NOT touch anything outside its lab directory, does
#  not use sudo, and can be removed with:  rm -rf "$LAB_DIR"
#
#  Official references (cite these to the student):
#    - Client libraries overview .. https://prometheus.io/docs/instrumenting/clientlibs/
#    - Python client library ...... https://prometheus.github.io/client_python/
#    - Metric types ............... https://prometheus.io/docs/concepts/metric_types/
#    - Writing client libraries ... https://prometheus.io/docs/instrumenting/writing_clientlibs/
#    - Exposition formats ......... https://prometheus.io/docs/instrumenting/exposition_formats/
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
LAB_DIR="${LAB_DIR:-$HOME/pca-lab-5.1-client-libraries}"
PORT="${PORT:-8000}"
PY_CLIENT_VERSION="0.20.0"
PIP_PKG="prometheus_client==${PY_CLIENT_VERSION}"

banner() { printf '\n\033[1m%s\033[0m\n' "============================================================"; printf '\033[1m%s\033[0m\n' "$1"; printf '\033[1m%s\033[0m\n\n' "============================================================"; }
info()   { printf '  \033[36m[*]\033[0m %s\n' "$1"; }
ok()     { printf '  \033[32m[+]\033[0m %s\n' "$1"; }
warn()   { printf '  \033[33m[!]\033[0m %s\n' "$1"; }
die()    { printf '  \033[31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

# --- Safety gate: refuse to run unless the operator confirms it is a lab VM ---
if [[ "${PCA_LAB_CONFIRM:-}" != "yes" && "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
    banner "SAFETY CONFIRMATION REQUIRED"
    warn "This script modifies a lab directory, installs a venv, and binds TCP :${PORT}."
    warn "It is intended for a DISPOSABLE lab VM only."
    if [[ -t 0 ]]; then
        read -r -p "  Type 'yes' to confirm you are on a disposable lab VM: " reply
        [[ "$reply" == "yes" ]] || die "Confirmation not given. Aborting."
    else
        die "Non-interactive shell. Re-run with --yes or PCA_LAB_CONFIRM=yes."
    fi
fi

# --- Prerequisites -----------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v curl    >/dev/null 2>&1 || die "curl is required."

banner "STEP 0 — Provisioning the lab environment"
mkdir -p "$LAB_DIR"
cd "$LAB_DIR"
info "Lab directory: $LAB_DIR"

if [[ ! -x "$LAB_DIR/venv/bin/python" ]]; then
    info "Creating Python virtualenv ..."
    python3 -m venv venv
fi
info "Installing ${PIP_PKG} (isolated in the venv) ..."
./venv/bin/python -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
./venv/bin/python -m pip install --quiet "$PIP_PKG" \
    || die "Could not install ${PIP_PKG}. On an offline VM, pre-seed a wheel or a local index."
ok "prometheus_client ${PY_CLIENT_VERSION} ready."

# --- Write the KNOWN-GOOD instrumented service -------------------------------
# Note: the Counter is deliberately named "app_requests" (WITHOUT the _total
# suffix). The Python client appends _total and _created automatically, so the
# exposition shows app_requests_total{...} and app_requests_created{...}. This
# suffixing behaviour is itself a common PCA gotcha.
cat > "$LAB_DIR/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""PCA 5.1 lab service: a minimal instrumented worker.

Exposes Prometheus metrics on :8000/metrics using the official
prometheus_client library and drives synthetic traffic in a daemon thread.
"""
import random
import threading
import time

from prometheus_client import Counter, Gauge, Histogram, start_http_server

# --- Instrumentation: metric definitions on the default CollectorRegistry ----
REQUESTS = Counter(
    "app_requests",
    "Total number of processed requests.",
    ["method"],
)
INFLIGHT = Gauge(
    "app_inflight_requests",
    "Number of requests currently being processed.",
)
LATENCY = Histogram(
    "app_request_duration_seconds",
    "Request handling latency in seconds.",
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0),
)

METHODS = ["GET", "POST", "PUT", "DELETE"]


def handle_one_request():
    method = random.choice(METHODS)
    INFLIGHT.inc()
    start = time.perf_counter()
    time.sleep(random.uniform(0.001, 0.2))      # simulate work
    LATENCY.observe(time.perf_counter() - start)
    REQUESTS.labels(method=method).inc()
    INFLIGHT.dec()


def load_generator():
    while True:
        handle_one_request()
        time.sleep(0.2)


def main():
    start_http_server(PORT_PLACEHOLDER)
    print("metrics server listening on :PORT_PLACEHOLDER/metrics", flush=True)
    threading.Thread(target=load_generator, daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
PYEOF
# Bake the chosen port into the app.
sed -i "s/PORT_PLACEHOLDER/${PORT}/g" "$LAB_DIR/app.py"

# --- Helper scripts the student will use -------------------------------------
cat > "$LAB_DIR/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
# Run the service in the FOREGROUND so you can see any crash traceback live.
set -euo pipefail
cd "$(dirname "$0")"
exec ./venv/bin/python app.py
RUNEOF
chmod +x "$LAB_DIR/run.sh"

cat > "$LAB_DIR/verify.sh" <<'VERIFYEOF'
#!/usr/bin/env bash
# Success criteria checker for the lab.
set -euo pipefail
URL="http://localhost:PORT_PLACEHOLDER/metrics"

if ! curl -sf "$URL" >/dev/null; then
    echo "FAIL: $URL is not reachable — is the service running (./run.sh)?"
    exit 1
fi
before=$(curl -s "$URL" | awk '/^app_requests_total/ {s+=$2} END {print s+0}')
sleep 3
after=$(curl -s "$URL" | awk '/^app_requests_total/ {s+=$2} END {print s+0}')
echo "app_requests_total  before=$before  after=$after"

if ! curl -s "$URL" | grep -q '^app_inflight_requests'; then
    echo "FAIL: gauge 'app_inflight_requests' is missing from the exposition."
    exit 1
fi
if awk "BEGIN{exit !($after > $before)}"; then
    echo "PASS: /metrics is up, the counter is increasing, and both series exist."
else
    echo "FAIL: app_requests_total is not increasing — is the load thread alive?"
    exit 1
fi
VERIFYEOF
sed -i "s/PORT_PLACEHOLDER/${PORT}/g" "$LAB_DIR/verify.sh"
chmod +x "$LAB_DIR/verify.sh"

# --- Prove the service works BEFORE we break it ------------------------------
banner "STEP 1 — Confirming the service is healthy (baseline)"
./venv/bin/python app.py > app.log 2>&1 &
GOOD_PID=$!
for _ in $(seq 1 10); do
    curl -sf "http://localhost:${PORT}/metrics" >/dev/null 2>&1 && break
    sleep 1
done
if ! curl -sf "http://localhost:${PORT}/metrics" >/dev/null 2>&1; then
    warn "Baseline service did not come up. Log follows:"; cat app.log
    kill "$GOOD_PID" 2>/dev/null || true
    die "Could not establish a healthy baseline (is :${PORT} already in use?)."
fi
ok "Endpoint http://localhost:${PORT}/metrics is UP. Sample lines:"
curl -s "http://localhost:${PORT}/metrics" | grep -E '^app_requests_total|^app_inflight_requests' | head -n 4 | sed 's/^/      /'
info "Stopping the healthy baseline before introducing the fault ..."
kill "$GOOD_PID" 2>/dev/null || true
wait "$GOOD_PID" 2>/dev/null || true

# Keep a pristine copy so the student can diff and, if stuck, restore.
cp "$LAB_DIR/app.py" "$LAB_DIR/app.py.good"

# --- INTRODUCE THE CONTROLLED FAULT ------------------------------------------
# A realistic copy/paste mistake: a developer adds/renames a metric and gives
# the Gauge the SAME name that the Counter already uses. On the default
# registry, two collectors may not reserve the same base name.
banner "STEP 2 — Injecting a controlled fault"
sed -i 's/"app_inflight_requests"/"app_requests"/' "$LAB_DIR/app.py"
ok "Fault injected: the in-flight Gauge now collides with the requests Counter."

# --- Demonstrate the failure so the student sees the exact error -------------
banner "STEP 3 — Observed failure (captured for you)"
( timeout 8 ./venv/bin/python app.py > crash.log 2>&1 ) || true
info "Foreground start output (crash.log):"
sed 's/^/      /' crash.log || true

# =============================================================================
#  YOUR TASK, STUDENT
# =============================================================================
banner "YOUR MISSION"
cat <<EOF
  Working directory : ${LAB_DIR}
  Start the service : ./run.sh          (runs in the foreground)
  Check your fix    : ./verify.sh
  View the app log  : cat app.log       (or watch the foreground output)

  SYMPTOM YOU WILL SEE
  --------------------
  * ./run.sh exits IMMEDIATELY with a Python traceback ending in:

        ValueError: Duplicated timeseries in CollectorRegistry: {'app_requests'}

  * The HTTP server never binds, so from another shell:

        \$ curl http://localhost:${PORT}/metrics
        curl: (7) Failed to connect to localhost port ${PORT}: Connection refused

  * From Prometheus' point of view the scrape target would be DOWN
    (up{...} == 0) — the exporter process is not even listening.

  WHAT YOU MUST ACHIEVE (success criteria)
  ----------------------------------------
  1. ./run.sh starts and prints: "metrics server listening on :${PORT}/metrics"
  2. curl http://localhost:${PORT}/metrics returns HTTP 200.
  3. The Counter series 'app_requests_total{method="..."}' is present AND its
     value increases between two scrapes a few seconds apart.
  4. A DISTINCT gauge 'app_inflight_requests' is also present.
  5. ./verify.sh prints: PASS
  You must keep BOTH signals (request count AND in-flight count). Deleting one
  metric is not an acceptable fix.

  HINT: prometheus_client registers every metric on one default registry, and
  no two collectors may claim the same name. Find the two definitions that now
  share a name and decide which one was misnamed.

  A pristine copy of the original file is at: app.py.good  (last resort).
EOF

exit 0

# #############################################################################
# #  SOLUTION — STEP BY STEP  (read only after attempting the fix)
# #############################################################################
#
# 1. REPRODUCE
#    -------------------------------------------------------------------------
#    $ cd "$LAB_DIR"
#    $ ./run.sh
#    Traceback (most recent call last):
#      File ".../app.py", line 20, in <module>
#        INFLIGHT = Gauge(
#      ...
#      File ".../prometheus_client/registry.py", line ..., in register
#        raise ValueError('Duplicated timeseries in CollectorRegistry: ' ...)
#    ValueError: Duplicated timeseries in CollectorRegistry: {'app_requests'}
#
#    The crash happens at IMPORT/DEFINITION time — before start_http_server()
#    is ever reached — which is why the port never opens and the target is DOWN.
#
# 2. DIAGNOSE — locate the collision
#    -------------------------------------------------------------------------
#    $ grep -n '"app_requests"' app.py
#      13:    "app_requests",                 <-- Counter  ("Total number of processed requests.")
#      19:    "app_requests",                 <-- Gauge    ("Number of requests currently being processed.")
#
#    Two collectors (a Counter and a Gauge) both reserve the base name
#    "app_requests". Registering the Counter reserves the names
#    {app_requests, app_requests_total, app_requests_created}; the Gauge then
#    tries to reserve {app_requests} and the intersection is non-empty, so the
#    default CollectorRegistry rejects it. The Gauge — semantically an
#    "in-flight" counter — is the one that was misnamed.
#
# 3. ROOT CAUSE
#    -------------------------------------------------------------------------
#    Metric names must be unique per registry. The prometheus_client default
#    registry enforces this at registration to prevent a broken /metrics
#    exposition (which Prometheus would reject as a scrape parse error). The
#    _total/_created suffixes are added by the library, so a Counter literally
#    named "app_requests" already owns "app_requests_total".
#
# 4. FIX — restore a distinct, descriptive name for the gauge
#    -------------------------------------------------------------------------
#    Edit line 19 so the Gauge's metric name is unique. Change:
#          INFLIGHT = Gauge("app_requests", ...)
#    back to:
#          INFLIGHT = Gauge("app_inflight_requests", ...)
#
#    Do it by hand, or surgically restore the pristine baseline:
#          $ cp app.py.good app.py
#
#    (Do NOT run a blanket sed swap of "app_requests" -> "app_inflight_requests":
#     that would rename the Counter too and break the exposition differently.
#     The Python variable INFLIGHT is unchanged, so .inc()/.dec() still work.)
#
# 5. RESTART
#    -------------------------------------------------------------------------
#    $ ./run.sh
#    metrics server listening on :8000/metrics
#
# 6. VERIFY
#    -------------------------------------------------------------------------
#    In a second shell:
#      $ curl -s http://localhost:8000/metrics | grep -E '^app_requests_total|^app_inflight_requests'
#      app_requests_total{method="GET"} 7.0
#      app_requests_total{method="POST"} 5.0
#      app_inflight_requests 1.0
#
#      $ ./verify.sh
#      app_requests_total  before=42  after=57
#      PASS: /metrics is up, the counter is increasing, and both series exist.
#
# 7. DEEPER LESSON / ALTERNATIVE VALID FIXES
#    -------------------------------------------------------------------------
#    * If two independently-registered subsystems genuinely need the same name
#      in the same process, isolate them with a dedicated CollectorRegistry:
#          from prometheus_client import CollectorRegistry
#          reg = CollectorRegistry(); g = Gauge("app_requests", "...", registry=reg)
#      then expose that registry (e.g. generate_latest(reg)).
#    * In test/reload scenarios a stale registration can be cleared with
#      registry.unregister(collector) before re-defining.
#    * Naming convention (from the exposition-format / metric-type docs):
#      counters end in _total, base/unit is a suffix (…_seconds, …_bytes), and
#      each metric name maps to exactly ONE collector per registry.
#      Refs: https://prometheus.io/docs/concepts/metric_types/
#            https://prometheus.github.io/client_python/
# #############################################################################