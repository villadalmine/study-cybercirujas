#!/usr/bin/env bash
#
# PCA — Prometheus Certified Associate
# Domain 1, Topic 1.7: Timestamp Metrics  (exam weight: 4)
#
# BREAK & FIX LAB — run ONLY on a disposable, throwaway lab VM.
# This script binds everything to 127.0.0.1, touches no system services,
# and keeps all state inside a single lab directory. Tear it down with:
#     bash "$0" --reset
#
# What it teaches: every Prometheus sample is a (timestamp, value) pair.
# In the exposition format the timestamp is an OPTIONAL third field, in
# milliseconds. When a target sets it, `honor_timestamps` (default: true)
# tells Prometheus to trust it instead of using the scrape time. A wrong
# clock or a bad exporter therefore lands your samples in the past, and
# instant queries at "now" go stale even though the target is UP.
#
# Sources (official):
#   - PCA curriculum:  https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#   - Exposition format (optional ms timestamp):
#       https://prometheus.io/docs/instrumenting/exposition_formats/
#   - honor_timestamps in scrape_config:
#       https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
#   - Staleness / instant-query lookback (default 5m):
#       https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
#   - timestamp() function:
#       https://prometheus.io/docs/prometheus/latest/querying/functions/#timestamp
#   - Runtime reload (POST /-/reload with --web.enable-lifecycle):
#       https://prometheus.io/docs/prometheus/latest/management_api/

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-$HOME/pca-lab-1.7-timestamp-metrics}"
PROM_PORT="${PROM_PORT:-9090}"
EXPORTER_PORT="${EXPORTER_PORT:-9101}"   # 9101, not 9100, to avoid a real node_exporter
EXPORTER_ADDR="127.0.0.1:${EXPORTER_PORT}"
PROM_ADDR="127.0.0.1:${PROM_PORT}"
DOCKER_NAME="pca-lab-1-7-prometheus"
SKEW_SECONDS="${SKEW_SECONDS:-3600}"     # the injected fault: samples trail real time by 1h

RUNTIME=""   # resolved to "binary" or "docker"

# --------------------------------------------------------------------------
# Teardown
# --------------------------------------------------------------------------
cleanup() {
  echo ">> Tearing down the lab ..."
  if [ -f "$LAB_DIR/exporter.pid" ]; then
    kill "$(cat "$LAB_DIR/exporter.pid")" 2>/dev/null || true
  fi
  if [ -f "$LAB_DIR/prometheus.pid" ]; then
    kill "$(cat "$LAB_DIR/prometheus.pid")" 2>/dev/null || true
  fi
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$DOCKER_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$LAB_DIR"
  echo ">> Done. The lab directory and processes are gone."
}

if [ "${1:-}" = "--reset" ] || [ "${1:-}" = "--clean" ]; then
  cleanup
  exit 0
fi

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required."; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "ERROR: curl is required.";    exit 1; }

if command -v prometheus >/dev/null 2>&1; then
  RUNTIME="binary"
elif command -v docker >/dev/null 2>&1; then
  RUNTIME="docker"
else
  echo "ERROR: need either a 'prometheus' binary in PATH or Docker installed."
  echo "       On a PCA lab VM one of them is normally present."
  exit 1
fi
echo ">> Using Prometheus runtime: $RUNTIME"

# Start from a clean slate (idempotent re-runs).
if [ -f "$LAB_DIR/exporter.pid" ] || [ -f "$LAB_DIR/prometheus.pid" ] || [ -d "$LAB_DIR" ]; then
  echo ">> Cleaning a previous run ..."
  [ -f "$LAB_DIR/exporter.pid" ]   && kill "$(cat "$LAB_DIR/exporter.pid")"   2>/dev/null || true
  [ -f "$LAB_DIR/prometheus.pid" ] && kill "$(cat "$LAB_DIR/prometheus.pid")" 2>/dev/null || true
  command -v docker >/dev/null 2>&1 && docker rm -f "$DOCKER_NAME" >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
fi
mkdir -p "$LAB_DIR/data"

# --------------------------------------------------------------------------
# 1) The faulty exporter
#    It serves a single gauge on /metrics and stamps EVERY sample with an
#    explicit timestamp that trails real time by SKEW_SECONDS. This models a
#    skewed target clock or a proxy that forwards upstream timestamps.
# --------------------------------------------------------------------------
cat > "$LAB_DIR/exporter.py" <<'PYEOF'
import sys, time, math
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
SKEW_SECONDS = int(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        now = time.time()
        value = 20.0 + 5.0 * math.sin(now / 60.0)
        # >>> INJECTED FAULT <<<
        # The optional third field is an explicit timestamp in milliseconds.
        # We push it SKEW_SECONDS into the past on every scrape. Remove this
        # field (emit only "name value") to let Prometheus assign scrape time.
        ts_ms = int((now - SKEW_SECONDS) * 1000)
        body = (
            "# HELP lab_temperature_celsius Simulated sensor reading.\n"
            "# TYPE lab_temperature_celsius gauge\n"
            f"lab_temperature_celsius {value:.3f} {ts_ms}\n"
        )
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF

echo ">> Starting the faulty exporter on http://${EXPORTER_ADDR}/metrics ..."
nohup python3 "$LAB_DIR/exporter.py" "$EXPORTER_PORT" "$SKEW_SECONDS" \
  >"$LAB_DIR/exporter.log" 2>&1 &
echo $! > "$LAB_DIR/exporter.pid"

# Wait until the exporter answers.
for _ in $(seq 1 20); do
  if curl -sf "http://${EXPORTER_ADDR}/metrics" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

# --------------------------------------------------------------------------
# 2) Prometheus scrape config (honor_timestamps left at its default: true)
# --------------------------------------------------------------------------
cat > "$LAB_DIR/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  - job_name: lab-sensor
    # honor_timestamps defaults to true, so Prometheus TRUSTS the timestamp
    # exposed by the target. That default is exactly what makes this lab break.
    # The fix flips it to false (see the solution at the bottom of this file).
    honor_timestamps: true
    static_configs:
      - targets: ['${EXPORTER_ADDR}']
EOF

# --------------------------------------------------------------------------
# 3) Start Prometheus (with lifecycle reload enabled, so the fix can hot-reload)
# --------------------------------------------------------------------------
echo ">> Starting Prometheus on http://${PROM_ADDR} ..."
if [ "$RUNTIME" = "binary" ]; then
  nohup prometheus \
    --config.file="$LAB_DIR/prometheus.yml" \
    --storage.tsdb.path="$LAB_DIR/data" \
    --web.listen-address="${PROM_ADDR}" \
    --web.enable-lifecycle \
    >"$LAB_DIR/prometheus.log" 2>&1 &
  echo $! > "$LAB_DIR/prometheus.pid"
else
  docker run -d --name "$DOCKER_NAME" --network host \
    -v "$LAB_DIR/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    prom/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --web.listen-address="${PROM_ADDR}" \
    --web.enable-lifecycle >/dev/null
fi

# Wait until Prometheus is ready.
for _ in $(seq 1 40); do
  if curl -sf "http://${PROM_ADDR}/-/ready" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

# Give it a couple of scrape cycles so there is data (in the past) to look at.
sleep 12

# --------------------------------------------------------------------------
# Brief the student
# --------------------------------------------------------------------------
cat <<EOF

============================================================================
  PCA 1.7 — TIMESTAMP METRICS :: BREAK & FIX LAB IS RUNNING
============================================================================

The scenario
  A single gauge, lab_temperature_celsius, is scraped from a lab exporter.
  The target is healthy and being scraped every 5s.

THE SYMPTOM you will observe
  1. The target is UP:
       curl -s 'http://${PROM_ADDR}/api/v1/targets' | grep -o '"health":"[a-z]*"'
     ...yet the instant query at 'now' returns an EMPTY result:
       curl -s 'http://${PROM_ADDR}/api/v1/query?query=lab_temperature_celsius'
     -> {"status":"success","data":{"resultType":"vector","result":[]}}

  2. The raw scrape clearly HAS the metric (note the 3rd field, a timestamp
     in milliseconds):
       curl -s 'http://${EXPORTER_ADDR}/metrics' | grep lab_temperature_celsius

  3. The data is not gone — it is in the PAST. A range query over the last
     two hours DOES show it, shifted ~${SKEW_SECONDS}s behind real time:
       END=\$(date +%s); START=\$((END-7200))
       curl -s "http://${PROM_ADDR}/api/v1/query_range?query=lab_temperature_celsius&start=\${START}&end=\${END}&step=30" | head -c 400

  In the web UI (http://${PROM_ADDR}): open Graph, plot lab_temperature_celsius.
  The line stops abruptly ~${SKEW_SECONDS}s in the past; "Console"/instant is blank.

YOUR GOAL
  Make lab_temperature_celsius return a FRESH value at 'now', i.e. this must
  yield a non-empty vector whose timestamp is within the last few seconds:
     curl -s 'http://${PROM_ADDR}/api/v1/query?query=timestamp(lab_temperature_celsius)'
  Equivalently, this must be ~0 (not ~${SKEW_SECONDS}):
     curl -s 'http://${PROM_ADDR}/api/v1/query?query=time()-timestamp(lab_temperature_celsius)'

  Diagnose WHY a scraped, UP target produces no data at 'now'. The answer is
  about WHERE the sample's timestamp comes from. Fix it, then verify.

Lab directory : $LAB_DIR
Exporter      : http://${EXPORTER_ADDR}/metrics
Prometheus    : http://${PROM_ADDR}
Tear down     : bash "$0" --reset
============================================================================

EOF

# ###########################################################################
# ##  SOLUTION — read only after you have tried to fix it yourself.        ##
# ###########################################################################
#
# ROOT CAUSE
#   Each exposition line ends with an explicit timestamp:
#       lab_temperature_celsius 21.734 1699999999000
#                               ^value ^timestamp(ms) <- optional third field
#   Because honor_timestamps is true (the default), Prometheus stores the
#   sample AT THAT timestamp instead of at scrape time. The exporter's clock
#   trails real time by ${SKEW_SECONDS}s, so every sample lands in the past.
#   Instant queries only look back --query.lookback-delta (default 5m) from
#   the evaluation time, so at 'now' the series is stale => empty vector.
#   The target stays UP the whole time because scraping itself succeeds.
#
# STEP 1 — Confirm the fault: read the raw exposition and decode the stamp.
#     curl -s 'http://${EXPORTER_ADDR}/metrics' | grep lab_temperature_celsius
#     # take the 3rd field (ms), divide by 1000, and compare to 'now':
#     TS_MS=$(curl -s "http://${EXPORTER_ADDR}/metrics" | awk '/^lab_temperature_celsius/ {print $3}')
#     echo "sample time: $(date -d @$((TS_MS/1000)))   now: $(date)"
#     # -> the sample time is ~1 hour behind. That is the bug.
#
# STEP 2 — Fix it. Either of these resolves the topic; A is the correct
#          instrumentation, B is the server-side mitigation the exam expects
#          you to know.
#
#   OPTION A (fix the source — preferred):
#     Exporters must NOT emit explicit timestamps unless they are federating
#     or proxying another monitoring system. Remove the third field so the
#     line is just "name value", and let Prometheus assign the scrape time.
#       sed -i 's/ {ts_ms}\\n/\\n/' "$LAB_DIR/exporter.py"   # or edit by hand:
#       #   change:  f"lab_temperature_celsius {value:.3f} {ts_ms}\n"
#       #   to:      f"lab_temperature_celsius {value:.3f}\n"
#     Restart the exporter:
#       kill "$(cat "$LAB_DIR/exporter.pid")"
#       nohup python3 "$LAB_DIR/exporter.py" "$EXPORTER_PORT" "$SKEW_SECONDS" \
#         >"$LAB_DIR/exporter.log" 2>&1 & echo $! > "$LAB_DIR/exporter.pid"
#
#   OPTION B (mitigate at the server — no exporter change):
#     Tell Prometheus to ignore the exposed timestamps and use scrape time.
#       sed -i 's/honor_timestamps: true/honor_timestamps: false/' "$LAB_DIR/prometheus.yml"
#     Hot-reload without restarting (--web.enable-lifecycle is already on):
#       curl -X POST "http://${PROM_ADDR}/-/reload"
#     (SIGHUP to the process works too:  kill -HUP "$(cat "$LAB_DIR/prometheus.pid")")
#
# STEP 3 — Verify the fix (allow a couple of scrape cycles, ~10s):
#     curl -s 'http://${PROM_ADDR}/api/v1/query?query=lab_temperature_celsius'
#     # -> now returns a non-empty vector.
#     curl -s 'http://${PROM_ADDR}/api/v1/query?query=time()-timestamp(lab_temperature_celsius)'
#     # -> value ~0 (seconds), i.e. samples are landing at 'now'. Goal met.
#
# STEP 4 — Tear down:
#     bash "$0" --reset
#
# TAKEAWAYS FOR THE EXAM
#   * A sample is (timestamp, value); the exposition timestamp is optional
#     and in milliseconds since the Unix epoch.
#   * honor_timestamps (default true) decides whether Prometheus trusts the
#     target's timestamp or uses its own scrape time.
#   * Explicit timestamps are for federation/proxying only; normal exporters
#     omit them. A skewed target clock silently pushes data out of the
#     instant-query lookback window (default 5m) even while the target is UP.
#   * Use timestamp() and time() to measure sample freshness objectively.
# ###########################################################################