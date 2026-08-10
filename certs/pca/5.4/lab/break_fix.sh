#!/usr/bin/env bash
#
# ============================================================================
#  PCA 5.4 — Structuring and naming metrics  ·  BREAK & FIX LAB
# ============================================================================
#  Prometheus Certified Associate — Domain 5 (Instrumentation), objective 5.4.
#  Exam weight: 4.  Curriculum: https://github.com/cncf/curriculum (PCA).
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  Prometheus does not care how you name a series in order to STORE it — but
#  every rule, alert, dashboard and query that consumes it depends on the name
#  and unit following the official conventions. Break the convention and the
#  scrape still succeeds (target UP, data present) while every DOWNSTREAM
#  consumer silently goes dark. This lab reproduces exactly that failure mode
#  so you learn to recognise it and to apply the naming rules from:
#
#      https://prometheus.io/docs/practices/naming/
#      https://prometheus.io/docs/practices/instrumentation/#naming
#      https://prometheus.io/docs/concepts/data_model/
#      https://prometheus.io/docs/concepts/metric_types/
#      https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
#
#  SAFETY
#  ------
#  Everything lives under a single throwaway directory and binds ONLY to
#  127.0.0.1 on two high ports. It downloads a pinned Prometheus release, runs
#  it as your unprivileged user, and touches nothing else on the machine.
#  STILL: run it only on a DISPOSABLE lab VM you can reset. Teardown is one
#  command:  ./pca-5.4-break-fix.sh teardown
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-$HOME/pca-5.4-lab}"
EXPORTER_PORT="${EXPORTER_PORT:-9101}"
PROM_PORT="${PROM_PORT:-9090}"
PROM_VERSION="${PROM_VERSION:-2.53.2}"       # LTS line, pinned for reproducibility

EXPORTER_PID="$LAB_DIR/exporter.pid"
PROM_PID="$LAB_DIR/prometheus.pid"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
info(){ printf '%s[*]%s %s\n'  "$CYA" "$RST" "$*"; }
ok(){   printf '%s[+]%s %s\n'  "$GRN" "$RST" "$*"; }
warn(){ printf '%s[!]%s %s\n'  "$YEL" "$RST" "$*"; }
err(){  printf '%s[x]%s %s\n'  "$RED" "$RST" "$*" >&2; }

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
need(){ command -v "$1" >/dev/null 2>&1 || { err "missing dependency: $1"; exit 1; }; }
check_deps(){
  need python3
  need tar
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
    err "need curl or wget"; exit 1; }
}

fetch(){ # fetch <url> <outfile>
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -o "$2" "$1"
  else wget -q -O "$2" "$1"; fi
}

http_get(){ # http_get <url>   -> prints body, never aborts the script
  if command -v curl >/dev/null 2>&1; then curl -s "$1" || true
  else wget -q -O - "$1" || true; fi
}

# ---------------------------------------------------------------------------
# Install a pinned Prometheus into the lab dir (idempotent)
# ---------------------------------------------------------------------------
install_prometheus(){
  local arch tarball url dir
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l)        arch=armv7 ;;
    *) err "unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
  dir="prometheus-${PROM_VERSION}.linux-${arch}"
  if [ -x "$LAB_DIR/$dir/prometheus" ]; then
    ok "Prometheus $PROM_VERSION already present"
  else
    tarball="$dir.tar.gz"
    url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${tarball}"
    info "Downloading $tarball ..."
    fetch "$url" "$LAB_DIR/$tarball"
    tar -xzf "$LAB_DIR/$tarball" -C "$LAB_DIR"
    rm -f "$LAB_DIR/$tarball"
    [ -x "$LAB_DIR/$dir/prometheus" ] || { err "extraction failed"; exit 1; }
    ok "Installed Prometheus $PROM_VERSION"
  fi
  PROM_BIN="$LAB_DIR/$dir/prometheus"
  PROMTOOL_BIN="$LAB_DIR/$dir/promtool"
}

# ---------------------------------------------------------------------------
# THE BREAK — deploy an exporter whose instrumentation violates the naming
# conventions. Nothing here is a "trick": this is the single most common
# real-world mistake, and Prometheus will happily scrape it.
#
#   BUG 1  counter has no `_total` suffix          -> rate() target name absent
#   BUG 2  latency uses a non-base unit in the name -> _ms instead of _seconds
#          (Prometheus base time unit is SECONDS, unit belongs as a suffix)
#   BUG 3  no `# HELP` / `# TYPE` metadata          -> series is untyped
# ---------------------------------------------------------------------------
write_broken_exporter(){
  cat > "$LAB_DIR/exporter.py" <<'PYEOF'
#!/usr/bin/env python3
"""Toy application exporter for the PCA 5.4 break & fix lab.

The metric NAMES below are wrong on purpose. Your job in the fix phase is to
correct them so that Prometheus produces the series that the recording rule
and the alert expect. Restart this process after editing (the harness does it
for you with the `restart-exporter` subcommand)."""
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# ====================  INSTRUMENTATION — EDIT THIS BLOCK  ====================
# BUG 1: a counter MUST end in `_total`.
COUNTER_NAME  = "api_http_requests"            # <-- convention: *_total
# BUG 2: the base unit of time in Prometheus is the SECOND. The unit is a
#        suffix, and the value must be expressed in that base unit.
LATENCY_NAME  = "api_request_duration_ms"      # <-- convention: *_seconds
LATENCY_VALUE = 42.0                           # currently milliseconds
# BUG 3: real instrumentation always exposes # HELP and # TYPE metadata.
EMIT_METADATA = False
# ===========================================================================

PORT  = int(os.environ.get("EXPORTER_PORT", "9101"))
START = time.time()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        # A monotonically increasing counter so rate() is non-zero once fixed.
        requests_total = int((time.time() - START) * 7)

        out = []
        if EMIT_METADATA:
            out.append(f"# HELP {COUNTER_NAME} Total HTTP requests handled by the API.")
            out.append(f"# TYPE {COUNTER_NAME} counter")
        out.append(f'{COUNTER_NAME}{{service="api",method="get"}} {requests_total}')

        if EMIT_METADATA:
            out.append(f"# HELP {LATENCY_NAME} Request handling latency.")
            out.append(f"# TYPE {LATENCY_NAME} gauge")
        out.append(f'{LATENCY_NAME}{{service="api"}} {LATENCY_VALUE}')

        body = ("\n".join(out) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):  # keep the lab quiet
        return


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF
  ok "Wrote broken exporter -> $LAB_DIR/exporter.py"
}

# ---------------------------------------------------------------------------
# Prometheus config + rules that consume the CONVENTIONAL names. These are
# correct; they will only produce data once the exporter is fixed.
# ---------------------------------------------------------------------------
write_prometheus_config(){
  cat > "$LAB_DIR/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s

rule_files:
  - rules.yml

scrape_configs:
  - job_name: api-exporter
    static_configs:
      - targets: ["127.0.0.1:${EXPORTER_PORT}"]
EOF

  cat > "$LAB_DIR/rules.yml" <<'EOF'
groups:
  - name: pca-5.4-consumers
    rules:
      # Recording rule: request rate per service. Depends on the counter being
      # named `api_http_requests_total`. If the name is wrong this is EMPTY.
      - record: service:api_http_requests:rate1m
        expr: sum by (service) (rate(api_http_requests_total[1m]))

      # Alert on a MISSING SLI. `absent()` fires while the correctly-named,
      # correctly-unit'd latency series does not exist. It resolves the moment
      # `api_request_duration_seconds` starts being scraped.
      - alert: ApiLatencySliAbsent
        expr: absent(api_request_duration_seconds{service="api"})
        for: 15s
        labels:
          severity: warning
        annotations:
          summary: "Latency SLI api_request_duration_seconds is not being reported"
          description: "The API latency series is absent. Likely a metric naming/unit violation in the exporter."
EOF
  ok "Wrote prometheus.yml + rules.yml"
}

# ---------------------------------------------------------------------------
# Process control
# ---------------------------------------------------------------------------
is_running(){ [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

start_exporter(){
  is_running "$EXPORTER_PID" && return 0
  EXPORTER_PORT="$EXPORTER_PORT" nohup python3 "$LAB_DIR/exporter.py" \
      >"$LAB_DIR/exporter.log" 2>&1 &
  echo $! > "$EXPORTER_PID"
  disown || true
  # readiness
  for _ in $(seq 1 20); do
    if http_get "http://127.0.0.1:${EXPORTER_PORT}/metrics" | grep -q .; then
      ok "Exporter listening on 127.0.0.1:${EXPORTER_PORT}/metrics"; return 0
    fi
    sleep 0.3
  done
  err "exporter failed to start (see $LAB_DIR/exporter.log)"; return 1
}

start_prometheus(){
  is_running "$PROM_PID" && return 0
  install_prometheus
  "$PROMTOOL_BIN" check config "$LAB_DIR/prometheus.yml" >/dev/null
  nohup "$PROM_BIN" \
      --config.file="$LAB_DIR/prometheus.yml" \
      --storage.tsdb.path="$LAB_DIR/data" \
      --web.listen-address="127.0.0.1:${PROM_PORT}" \
      --web.enable-lifecycle \
      >"$LAB_DIR/prometheus.log" 2>&1 &
  echo $! > "$PROM_PID"
  disown || true
  for _ in $(seq 1 40); do
    if http_get "http://127.0.0.1:${PROM_PORT}/-/ready" | grep -qi 'ready'; then
      ok "Prometheus ready on http://127.0.0.1:${PROM_PORT}"; return 0
    fi
    sleep 0.5
  done
  err "prometheus failed to become ready (see $LAB_DIR/prometheus.log)"; return 1
}

stop_pid(){ is_running "$1" && kill "$(cat "$1")" 2>/dev/null || true; rm -f "$1"; }

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
pq(){ # pq <promql> -> number of result series
  local q="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -sG "http://127.0.0.1:${PROM_PORT}/api/v1/query" --data-urlencode "query=${q}"
  else
    wget -q -O - "http://127.0.0.1:${PROM_PORT}/api/v1/query?query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$q")"
  fi | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",{}).get("result",[])))' 2>/dev/null || echo 0
}

alert_state(){
  http_get "http://127.0.0.1:${PROM_PORT}/api/v1/alerts" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print("unknown"); sys.exit()
a=[x for x in d.get("data",{}).get("alerts",[]) if x.get("labels",{}).get("alertname")=="ApiLatencySliAbsent"]
print(a[0]["state"] if a else "inactive")'
}

status(){
  info "Sampling Prometheus (allow ~15s after any change for scrape + rule eval)"
  local up wrong right rate astate
  up=$(pq 'up{job="api-exporter"} == 1')
  wrong=$(pq 'api_http_requests')                 # the mis-named series
  right=$(pq 'api_http_requests_total')           # what consumers expect
  rate=$(pq 'service:api_http_requests:rate1m')   # the recording rule output
  astate=$(alert_state)

  echo
  printf '  %-52s %s\n' "target up (scrape works at all):"        "$([ "$up"    -ge 1 ] && echo "${GRN}yes${RST}" || echo "${RED}NO${RST}")"
  printf '  %-52s %s\n' "mis-named series api_http_requests:"     "$([ "$wrong" -ge 1 ] && echo "${YEL}present (wrong name)${RST}" || echo "absent")"
  printf '  %-52s %s\n' "conventional api_http_requests_total:"   "$([ "$right" -ge 1 ] && echo "${GRN}present${RST}" || echo "${RED}ABSENT${RST}")"
  printf '  %-52s %s\n' "recording rule service:...:rate1m:"      "$([ "$rate"  -ge 1 ] && echo "${GRN}populated${RST}" || echo "${RED}EMPTY${RST}")"
  printf '  %-52s %s\n' "alert ApiLatencySliAbsent:"              "$([ "$astate" = firing ] && echo "${RED}FIRING${RST}" || echo "${GRN}$astate${RST}")"
  echo
  if [ "$right" -ge 1 ] && [ "$rate" -ge 1 ] && [ "$astate" != firing ]; then
    ok "LAB SOLVED — metrics follow the naming conventions and consumers are live."
  else
    warn "Still broken. Fix the metric names/units in $LAB_DIR/exporter.py, then run: $0 restart-exporter"
  fi
}

brief(){
  cat <<EOF

${BLD}================ PCA 5.4 — BREAK & FIX: THE SYMPTOM ================${RST}

The exporter is UP and Prometheus is scraping it successfully. Prove it:

    ${CYA}curl -s http://127.0.0.1:${EXPORTER_PORT}/metrics${RST}
    ${CYA}open http://127.0.0.1:${PROM_PORT}/targets        ${RST}# state = UP

And yet every CONSUMER is dark:

  * PromQL  ${CYA}api_http_requests_total${RST}                 -> "No data"
  * Recording rule ${CYA}service:api_http_requests:rate1m${RST} -> empty
  * Alert   ${CYA}ApiLatencySliAbsent${RST}                     -> ${RED}FIRING${RST}
            (open http://127.0.0.1:${PROM_PORT}/alerts)

This is NOT a connectivity, scrape, or TSDB problem. The raw data is being
ingested — under the WRONG names. Notice that this query DOES return data:

    ${CYA}api_http_requests${RST}          (a counter with no _total suffix)
    ${CYA}api_request_duration_ms${RST}    (a latency with a non-base unit)

${BLD}YOUR GOAL${RST}
  Make the exporter emit series that satisfy the Prometheus naming
  conventions so the recording rule populates and the alert resolves:

    1. The counter must carry the ${BLD}_total${RST} suffix.
    2. The latency must use the base unit ${BLD}seconds${RST}, as a name suffix
       (…_seconds), with the VALUE expressed in seconds — not milliseconds.
    3. Expose ${BLD}# HELP${RST} and ${BLD}# TYPE${RST} metadata so the series is typed.

  Edit:   ${CYA}$LAB_DIR/exporter.py${RST}   (see the EDIT THIS BLOCK section)
  Apply:  ${CYA}$0 restart-exporter${RST}
  Check:  ${CYA}$0 status${RST}     (wait ~15s for scrape + rule evaluation)

  Reference: https://prometheus.io/docs/practices/naming/

${BLD}===================================================================${RST}
EOF
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_setup(){
  mkdir -p "$LAB_DIR"
  check_deps
  warn "Lab dir: $LAB_DIR  (disposable-VM only). Teardown: $0 teardown"
  write_broken_exporter
  write_prometheus_config
  start_exporter
  start_prometheus
  brief
}

cmd_restart_exporter(){
  info "Restarting exporter to apply your edits ..."
  stop_pid "$EXPORTER_PID"
  start_exporter
  ok "Exporter restarted. Give Prometheus ~15s, then: $0 status"
}

cmd_teardown(){
  stop_pid "$PROM_PID"
  stop_pid "$EXPORTER_PID"
  ok "Processes stopped."
  read -r -p "Also delete $LAB_DIR ? [y/N] " a || true
  case "${a:-}" in
    y|Y) rm -rf "$LAB_DIR"; ok "Removed $LAB_DIR" ;;
    *)   info "Kept $LAB_DIR (logs, config, your edits)";;
  esac
}

usage(){
  cat <<EOF
PCA 5.4 — Structuring and naming metrics — break & fix lab

  $0 setup             Install Prometheus, deploy the broken exporter, start both
  $0 status            Run the diagnostic checks (broken vs solved)
  $0 restart-exporter  Reload the exporter after you edit exporter.py
  $0 teardown          Stop processes and optionally remove the lab dir

Ports: exporter 127.0.0.1:${EXPORTER_PORT}  ·  prometheus 127.0.0.1:${PROM_PORT}
EOF
}

case "${1:-setup}" in
  setup)            cmd_setup ;;
  status)           status ;;
  restart-exporter) cmd_restart_exporter ;;
  teardown)         cmd_teardown ;;
  -h|--help|help)   usage ;;
  *) err "unknown subcommand: $1"; usage; exit 2 ;;
esac

# ============================================================================
#  SOLUTION — step by step (do not read until you have tried it)
# ============================================================================
#
#  0. Confirm the diagnosis first. This is the whole lesson: the scrape is
#     healthy, the DATA is present, only the NAMES are wrong.
#
#         ./pca-5.4-break-fix.sh status
#         curl -s http://127.0.0.1:9101/metrics
#         # -> api_http_requests{...}        (counter, no _total)
#         # -> api_request_duration_ms{...}  (time not in base unit seconds)
#
#     In the Prometheus UI (http://127.0.0.1:9090/graph) query both
#     `api_http_requests` (data) and `api_http_requests_total` (No data). That
#     contrast is the fingerprint of a naming/unit violation, never a scrape
#     failure.
#
#  1. Edit the instrumentation block in  $LAB_DIR/exporter.py :
#
#         COUNTER_NAME  = "api_http_requests_total"     # BUG 1 fixed: counters end in _total
#         LATENCY_NAME  = "api_request_duration_seconds" # BUG 2 fixed: base unit = seconds, as suffix
#         LATENCY_VALUE = 0.042                          #             value converted 42 ms -> 0.042 s
#         EMIT_METADATA = True                           # BUG 3 fixed: expose # HELP and # TYPE
#
#     Why each change matters (https://prometheus.io/docs/practices/naming/):
#       * `_total` is the mandatory suffix for a counter. Client libraries and
#         OpenMetrics rely on it; `rate()`/`increase()` are written against it.
#         Without it the counter is indistinguishable from a gauge to a reader.
#       * Prometheus SHOULD use base units: seconds (not ms/us), bytes (not
#         KB/MB), ratios 0-1 (not percent). The unit is a plural suffix on the
#         name (`_seconds`, `_bytes`). A value of 42 under `_seconds` would mean
#         42 seconds, so the numeric value is converted as well as the name.
#       * `# HELP`/`# TYPE` make the series self-describing and correctly typed
#         (counter vs gauge), which drives UI behaviour, `promtool`, and the
#         OpenMetrics contract. Untyped series work but hide intent.
#       * Names stay snake_case, lowercase, single-word application prefix
#         (`api_`), and labels stay lowercase snake_case. Never encode a label
#         value into the metric name (`api_get_requests_total`); use the
#         `method="get"` label instead — which this exporter already does.
#
#  2. Apply the change and let Prometheus re-scrape + re-evaluate:
#
#         ./pca-5.4-break-fix.sh restart-exporter
#         sleep 15
#         ./pca-5.4-break-fix.sh status
#
#  3. Confirm every consumer recovered:
#
#         # counter now exists under its conventional name (present):
#         curl -sG http://127.0.0.1:9090/api/v1/query \
#              --data-urlencode 'query=api_http_requests_total' | python3 -m json.tool
#
#         # recording rule populated (non-empty, and rate > 0 since the counter climbs):
#         curl -sG http://127.0.0.1:9090/api/v1/query \
#              --data-urlencode 'query=service:api_http_requests:rate1m'
#
#         # latency now in base-unit seconds (0.042, not 42):
#         curl -sG http://127.0.0.1:9090/api/v1/query \
#              --data-urlencode 'query=api_request_duration_seconds'
#
#         # alert resolves once the SLI is present:
#         #   http://127.0.0.1:9090/alerts  -> ApiLatencySliAbsent = inactive
#
#     `status` prints "LAB SOLVED" when api_http_requests_total is present, the
#     recording rule is populated, and the alert is no longer firing.
#
#  4. Clean up:
#
#         ./pca-5.4-break-fix.sh teardown
#
#  KEY TAKEAWAY
#  ------------
#  A metric name is a public API contract, not a label. Prometheus stores
#  anything, so a naming/unit mistake never fails the scrape — it fails every
#  rule, alert and dashboard downstream, silently. The conventions
#  (`_total` for counters, base units as suffixes, snake_case, no values baked
#  into names, HELP/TYPE metadata) exist precisely so that authors and
#  consumers of a series agree on its name and meaning without coordination.
#
#  Sources:
#    https://prometheus.io/docs/practices/naming/
#    https://prometheus.io/docs/practices/instrumentation/#naming
#    https://prometheus.io/docs/concepts/metric_types/
#    https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
# ============================================================================