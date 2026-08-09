#!/usr/bin/env bash
#
# ============================================================================
#  PCA — Prometheus Certified Associate
#  Domain 2: Prometheus Fundamentals  ·  Topic 2.5: Exposition Format (weight 4)
#
#  BREAK & FIX LAB — a broken /metrics endpoint that Prometheus refuses to scrape
#
#  What this does:
#    * Creates a disposable lab under $HOME/pca-lab-2.5 (nothing else is touched).
#    * Serves a MALFORMED Prometheus text exposition payload on 127.0.0.1:9101
#      via a tiny HTTP server that mimics a real exporter's /metrics endpoint.
#    * The server re-reads the file on EVERY scrape, so you fix the file and
#      re-verify with no restart — exactly like editing a node_exporter
#      textfile-collector .prom file in production.
#
#  Safe by design:
#    * Binds to 127.0.0.1 only (never exposed on the network).
#    * Writes only inside the lab directory; `down` removes it entirely.
#    * Runs unprivileged; no packages installed, no system files edited.
#
#  Reference (official):
#    Exposition formats  https://prometheus.io/docs/instrumenting/exposition_formats/
#    OpenMetrics spec    https://github.com/OpenObservability/OpenMetrics
#    PCA curriculum      https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#
#  Usage:
#    bash pca_2_5_break_fix.sh up        # break it + start the endpoint (default)
#    bash pca_2_5_break_fix.sh verify    # lint the live endpoint (your goal: exit 0)
#    bash pca_2_5_break_fix.sh solution  # print the fix (also commented at EOF)
#    bash pca_2_5_break_fix.sh down      # stop the server and remove the lab
# ============================================================================

set -uo pipefail

LAB_DIR="${LAB_DIR:-$HOME/pca-lab-2.5}"
PORT="${PORT:-9101}"
METRICS_FILE="$LAB_DIR/broken_metrics.prom"
SERVER_PY="$LAB_DIR/expo_server.py"
PID_FILE="$LAB_DIR/server.pid"
LOG_FILE="$LAB_DIR/server.log"
URL="http://127.0.0.1:${PORT}/metrics"

log()  { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "----------------------------------------------------------------------"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_python() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required for this lab."
}

server_alive() {
  [ -f "$PID_FILE" ] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Write the tiny exporter-like HTTP server. It intentionally does NOT validate
# the payload — a real exporter happily serves whatever bytes you give it; the
# scraper is the one that rejects malformed exposition format.
# ---------------------------------------------------------------------------
write_server() {
  cat > "$SERVER_PY" <<'PY'
import sys, http.server, socketserver

PORT = int(sys.argv[1])
FILE = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip('/') not in ('/metrics', ''):
            self.send_response(404); self.end_headers(); return
        try:
            with open(FILE, 'rb') as fh:
                body = fh.read()
        except OSError as exc:
            body = ("# reading metrics file failed: %s\n" % exc).encode()
        self.send_response(200)
        # Classic Prometheus text exposition content type.
        self.send_header('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # keep the lab quiet

class Server(socketserver.TCPServer):
    allow_reuse_address = True

with Server(('127.0.0.1', PORT), Handler) as httpd:
    httpd.serve_forever()
PY
}

# ---------------------------------------------------------------------------
# THE BREAK: a payload with four independent exposition-format violations.
# Every byte here is valid ASCII and harmless — only the *format* is wrong.
# ---------------------------------------------------------------------------
write_broken_metrics() {
  cat > "$METRICS_FILE" <<'PROM'
# HELP http_requests_total Total number of HTTP requests handled.
# TYPE http_requests_total counter
# TYPE http_requests_total counter
http_requests_total{method=GET,code="200"} 1027
http_requests_total{method="POST",code="200"} 3
# HELP http_requests_total Duplicate description sneaked in.
# HELP app_temperature_celsius Current probe temperature in Celsius.
# TYPE app_temperature_celsius gauge
app_temperature_celsius 0.provided
PROM
}

start_server() {
  if server_alive; then
    log "Endpoint already running (pid $(cat "$PID_FILE")) at ${URL}"
    return 0
  fi
  nohup python3 "$SERVER_PY" "$PORT" "$METRICS_FILE" >"$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"
  sleep 1
  if ! server_alive; then
    log "Server failed to start. Last log lines:"
    tail -n 20 "$LOG_FILE" 2>/dev/null || true
    die "Could not bind 127.0.0.1:${PORT} (port busy?). Set PORT=<n> and retry."
  fi
  log "Endpoint up (pid $(cat "$PID_FILE")) at ${URL}"
}

cmd_up() {
  need_python
  mkdir -p "$LAB_DIR"
  write_server
  write_broken_metrics
  start_server

  hr
  log "PCA 2.5 — EXPOSITION FORMAT — BREAK & FIX"
  hr
  log "SCENARIO"
  log "  An exporter is serving metrics at ${URL}. The bytes arrive fine, but"
  log "  the Prometheus text parser rejects them, so the target is unscrapeable."
  log ""
  log "SYMPTOMS you will observe"
  log "  * curl returns a 200 with a body, so the network/exporter 'looks' healthy:"
  log "      curl -s ${URL}"
  log "  * In a real Prometheus, the target shows up=0 and a scrape error like:"
  log "      \"text format parsing error in line N: ...\""
  log "  * The official linter fails (this is your scoreboard):"
  log "      curl -s ${URL} | promtool check metrics        # -> non-zero exit"
  log ""
  log "YOUR OBJECTIVE"
  log "  Edit the served file so the SAME two metric families still exist and"
  log "  the linter passes with exit code 0. Do NOT delete the metrics — repair"
  log "  the format. The file is:"
  log "      ${METRICS_FILE}"
  log "  The server re-reads it on every scrape, so just edit and re-verify:"
  log "      bash $0 verify"
  log ""
  log "HINTS (exposition format rules being violated)"
  log "  - Each metric family declares '# TYPE' and '# HELP' AT MOST ONCE."
  log "  - Every label value MUST be enclosed in double quotes."
  log "  - Sample values are Go float64 literals (e.g. 1027, 21.4, 1.6e9, +Inf, NaN)."
  hr
  log "Reveal the answer any time with:  bash $0 solution"
}

# ---------------------------------------------------------------------------
# VERIFY: lint the LIVE endpoint. Prefer promtool (canonical); fall back to the
# reference Python parser from prometheus_client if promtool is not installed.
# ---------------------------------------------------------------------------
cmd_verify() {
  need_python
  server_alive || die "Endpoint is not running. Start it with: bash $0 up"

  local payload
  payload="$(curl -fsS "$URL" 2>/dev/null)" || die "Could not GET ${URL}."

  log "Current payload served at ${URL}:"
  hr
  printf '%s\n' "$payload"
  hr

  if command -v promtool >/dev/null 2>&1; then
    log "Linting with: promtool check metrics"
    if printf '%s\n' "$payload" | promtool check metrics; then
      log ""
      log "RESULT: VALID exposition format. Objective achieved. ✔"
      return 0
    else
      log ""
      log "RESULT: STILL INVALID — read the line number above and fix that rule."
      return 1
    fi
  fi

  # Fallback: the official client parser (same one Prometheus uses conceptually).
  log "promtool not found — validating with prometheus_client.parser instead."
  if python3 - "$METRICS_FILE" <<'PY'
import sys
try:
    from prometheus_client.parser import text_string_to_metric_families
except Exception:
    print("Neither promtool nor prometheus_client is available.")
    print("Install one:  go install .../promtool   |   pip install prometheus_client")
    sys.exit(2)
data = open(sys.argv[1], encoding="utf-8").read()
try:
    fams = list(text_string_to_metric_families(data))
    print("VALID: parsed %d metric family/families." % len(fams))
except Exception as exc:
    print("INVALID: %s" % exc)
    sys.exit(1)
PY
  then
    log ""
    log "RESULT: VALID exposition format. Objective achieved. ✔"
    return 0
  else
    local rc=$?
    log ""
    [ "$rc" -eq 2 ] || log "RESULT: STILL INVALID — fix the reported error and re-run verify."
    return "$rc"
  fi
}

cmd_solution() {
  sed -n '/^# ==== SOLUTION/,/^# ==== END SOLUTION/p' "$0"
}

cmd_down() {
  if server_alive; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    sleep 1
  fi
  rm -rf "$LAB_DIR"
  log "Lab stopped and ${LAB_DIR} removed. Clean."
}

main() {
  case "${1:-up}" in
    up|break|start) cmd_up ;;
    verify|check)   cmd_verify ;;
    solution|hint)  cmd_solution ;;
    down|clean|cleanup) cmd_down ;;
    *) die "Unknown command '$1'. Use: up | verify | solution | down" ;;
  esac
}

main "$@"

# ==== SOLUTION (step by step) ==============================================
#
# The endpoint serves bytes fine (HTTP 200), which is why "curl works" fools
# people. Prometheus does not scrape bytes — it scrapes a strict line-based
# TEXT EXPOSITION FORMAT, and this payload breaks four of its rules. Fix them
# in ${METRICS_FILE}; the server re-reads on each scrape, so no restart.
# Re-run `bash pca_2_5_break_fix.sh verify` after each edit — promtool reports
# ONE error at a time (by line), so you will peel them off one by one.
#
# The broken payload:
#     1  # HELP http_requests_total Total number of HTTP requests handled.
#     2  # TYPE http_requests_total counter
#     3  # TYPE http_requests_total counter          <-- (1) duplicate TYPE
#     4  http_requests_total{method=GET,code="200"} 1027   <-- (2) unquoted value
#     5  http_requests_total{method="POST",code="200"} 3
#     6  # HELP http_requests_total Duplicate description sneaked in.  <-- (3) dup HELP
#     7  # HELP app_temperature_celsius Current probe temperature in Celsius.
#     8  # TYPE app_temperature_celsius gauge
#     9  app_temperature_celsius 0.provided          <-- (4) non-numeric value
#
# FIX 1 — Duplicate metadata line.
#   A metric family may carry exactly one '# TYPE' (and one '# HELP') line.
#   Symptom: "second TYPE line for metric name http_requests_total".
#   Action:  delete line 3.
#
# FIX 2 — Unquoted label value.
#   Every label value is a double-quoted string; bare words are a syntax error.
#   Symptom: parse error, expected '"' at the '=' after method.
#     -  http_requests_total{method=GET,code="200"} 1027
#     +  http_requests_total{method="GET",code="200"} 1027
#
# FIX 3 — Duplicate HELP line.
#   Same one-per-family rule as TYPE.
#   Symptom: "second HELP line for metric name http_requests_total".
#   Action:  delete line 6.
#
# FIX 4 — Non-numeric sample value.
#   A sample value must be a Go float64 literal: 1027, 21.4, 1.6e9, +Inf, -Inf,
#   NaN — never a word. '0.provided' is not a number.
#   Symptom: "expected float as value, got \"0.provided\"".
#     -  app_temperature_celsius 0.provided
#     +  app_temperature_celsius 21.4
#
# CORRECTED /metrics payload (what verify must lint to exit 0):
#     # HELP http_requests_total Total number of HTTP requests handled.
#     # TYPE http_requests_total counter
#     http_requests_total{method="GET",code="200"} 1027
#     http_requests_total{method="POST",code="200"} 3
#     # HELP app_temperature_celsius Current probe temperature in Celsius.
#     # TYPE app_temperature_celsius gauge
#     app_temperature_celsius 21.4
#
# One-shot repair an SRE would actually run (overwrite with the good payload):
#     cat > "$HOME/pca-lab-2.5/broken_metrics.prom" <<'FIXED'
#     # HELP http_requests_total Total number of HTTP requests handled.
#     # TYPE http_requests_total counter
#     http_requests_total{method="GET",code="200"} 1027
#     http_requests_total{method="POST",code="200"} 3
#     # HELP app_temperature_celsius Current probe temperature in Celsius.
#     # TYPE app_temperature_celsius gauge
#     app_temperature_celsius 21.4
#     FIXED
#
# Or surgically, preserving the rest of the file:
#     f="$HOME/pca-lab-2.5/broken_metrics.prom"
#     sed -i '3d' "$f"                                   # drop duplicate TYPE
#     sed -i 's/method=GET,/method="GET",/' "$f"         # quote the label value
#     sed -i '/^# HELP http_requests_total Duplicate/d' "$f"   # drop duplicate HELP
#     sed -i 's/^app_temperature_celsius .*/app_temperature_celsius 21.4/' "$f"
#   (Note: delete the duplicate TYPE first, because that shifts line numbers.)
#
# CONFIRM:
#     bash pca_2_5_break_fix.sh verify     # -> "VALID ... Objective achieved. ✔", exit 0
# TEAR DOWN:
#     bash pca_2_5_break_fix.sh down
#
# WHY THIS MATTERS (production takeaway)
#   A target can be network-reachable, return HTTP 200, and STILL be up=0 in
#   Prometheus because a single malformed line rejects the whole scrape. When a
#   target flaps to "down" with no obvious network cause, pipe the raw endpoint
#   through the parser — `curl -s <target>/metrics | promtool check metrics` —
#   before you touch firewalls or scrape_configs.
#
# Sources:
#   https://prometheus.io/docs/instrumenting/exposition_formats/
#   https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
#   https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
# ==== END SOLUTION =========================================================