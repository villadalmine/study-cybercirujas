#!/usr/bin/env bash
#
# =============================================================================
#  PCA — Prometheus Certified Associate  (CNCF)
#  Domain: PromQL   |   Topic 1.1 "Selecting Data"   |   Exam weight: 4
#  Reference: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#
#  BREAK & FIX LAB — "The 5xx panel that is always empty"
#
#  What this topic is about
#  ------------------------
#  "Selecting Data" is the foundation of PromQL. Before you can aggregate,
#  rate() or alert on anything, you must SELECT the right time series. That
#  means understanding:
#    * instant vector selectors        metric{label="value"}
#    * range vector selectors          metric{...}[5m]
#    * label matchers:
#         =    exact string equality
#         !=   exact string inequality
#         =~   regex match     (FULLY ANCHORED: implicit ^...$)
#         !~   regex non-match (FULLY ANCHORED)
#    * the __name__ meta-label, and the offset / @ modifiers.
#  The single most common production mistake in this area is reaching for `=`
#  when the value is a PATTERN (a class of status codes, a set of paths, an
#  environment prefix). `=` compares the literal string; it does NOT interpret
#  metacharacters. This lab reproduces exactly that failure — silently.
#
#  SAFETY / SCOPE  (read before running)
#  -------------------------------------
#  * Run this on a DISPOSABLE lab VM only. It is designed to be trivially
#    reversible and touches nothing outside its own working directory.
#  * It does NOT require root, does NOT edit system files, and only binds two
#    loopback ports on 127.0.0.1:  9090 (Prometheus)  and  8000 (demo target).
#  * It downloads a pinned static Prometheus release into the lab directory
#    ONLY if a system `prometheus`/`promtool` is not already on PATH.
#  * `down` kills the two processes it started (by recorded PID) and deletes
#    the working directory. Nothing else is affected.
#
#  Usage:
#     ./pca-1.1-selecting-data.sh up      # build + break the lab, print briefing
#     ./pca-1.1-selecting-data.sh status  # show process + query state
#     ./pca-1.1-selecting-data.sh down    # tear everything down
#
#  The full step-by-step SOLUTION is at the very bottom of this file, commented.
# =============================================================================

set -euo pipefail

# ---- configuration (all overridable via environment) ------------------------
WORKDIR="${PCA_LAB_DIR:-/tmp/pca-lab-1.1-selecting-data}"
PROM_PORT="${PCA_PROM_PORT:-9090}"
TARGET_PORT="${PCA_TARGET_PORT:-8000}"
PROM_VERSION="${PROM_VERSION:-2.53.0}"           # LTS line; override if desired
ASSUME_YES="${PCA_LAB_YES:-0}"

RULES_FILE="$WORKDIR/rules/selecting-data.rules.yml"
PROM_CFG="$WORKDIR/prometheus.yml"
EXPORTER="$WORKDIR/exporter.py"
RUNDIR="$WORKDIR/run"
LOGDIR="$WORKDIR/logs"

PROM_BIN=""
PROMTOOL_BIN=""
STARTED_PIDS=()

log()  { printf '  %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

on_err() {
  printf '\n!! setup failed — rolling back the partially-started lab\n' >&2
  local p
  for p in "${STARTED_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
}

# ---- preflight --------------------------------------------------------------
require_tools() {
  command -v curl   >/dev/null 2>&1 || die "curl is required"
  command -v python3>/dev/null 2>&1 || die "python3 is required (demo target)"
  command -v tar    >/dev/null 2>&1 || die "tar is required"
}

confirm_lab() {
  [ "$ASSUME_YES" = "1" ] && return 0
  cat <<EOF

  This will start a Prometheus break/fix lab under:
      $WORKDIR
  binding 127.0.0.1:${PROM_PORT} and 127.0.0.1:${TARGET_PORT}.
  Run it ONLY on a disposable lab VM.

EOF
  read -r -p "  Type LAB to continue: " ans
  [ "$ans" = "LAB" ] || die "aborted by user"
}

port_busy() {
  # returns 0 if the port is already in use
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
  return 1
}

# ---- ensure a Prometheus + promtool we can drive ----------------------------
ensure_prometheus() {
  if command -v prometheus >/dev/null 2>&1 && command -v promtool >/dev/null 2>&1; then
    PROM_BIN="$(command -v prometheus)"
    PROMTOOL_BIN="$(command -v promtool)"
    log "using system Prometheus: $PROM_BIN"
    return
  fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported CPU arch '$(uname -m)' — install prometheus/promtool manually" ;;
  esac
  local dist="prometheus-${PROM_VERSION}.linux-${arch}"
  local url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${dist}.tar.gz"
  if [ ! -x "$WORKDIR/bin/prometheus" ]; then
    log "downloading pinned Prometheus ${PROM_VERSION} (${arch}) into the lab dir..."
    mkdir -p "$WORKDIR/bin"
    curl -fsSL "$url" -o "$WORKDIR/${dist}.tar.gz" || die "download failed: $url"
    tar -xzf "$WORKDIR/${dist}.tar.gz" -C "$WORKDIR"
    cp "$WORKDIR/$dist/prometheus" "$WORKDIR/$dist/promtool" "$WORKDIR/bin/"
    rm -rf "$WORKDIR/$dist" "$WORKDIR/${dist}.tar.gz"
  fi
  PROM_BIN="$WORKDIR/bin/prometheus"
  PROMTOOL_BIN="$WORKDIR/bin/promtool"
}

# ---- lab assets -------------------------------------------------------------
write_exporter() {
  # A tiny, correct Prometheus exporter. Counters increase monotonically with
  # wall-clock time so both instant selectors and rate() over a range behave
  # realistically. Emits several http_requests_total series across status codes.
  cat > "$EXPORTER" <<'PYEOF'
#!/usr/bin/env python3
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

T0 = time.time()

def _c(base, rate):
    return int(base + (time.time() - T0) * rate)

def render():
    rows = [
        ("GET",  "/",        "200", _c(24000, 12.0)),
        ("GET",  "/items",   "200", _c(18000,  9.0)),
        ("POST", "/items",   "201", _c( 3400,  1.5)),
        ("GET",  "/missing", "404", _c(  920,  0.7)),
        ("GET",  "/items",   "500", _c(  140,  0.20)),
        ("POST", "/items",   "503", _c(   55,  0.08)),
    ]
    out = [
        "# HELP http_requests_total Total number of HTTP requests handled.",
        "# TYPE http_requests_total counter",
    ]
    for method, path, status, val in rows:
        out.append(
            'http_requests_total{method="%s",path="%s",status="%s"} %d'
            % (method, path, status, val)
        )
    return ("\n".join(out) + "\n").encode()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] != "/metrics":
            self.send_response(404); self.end_headers(); return
        body = render()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):  # keep the lab console quiet
        pass

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8000), Handler).serve_forever()
PYEOF
  # bind port is fixed to 8000 inside the exporter; keep TARGET_PORT aligned
  sed -i "s/127.0.0.1\", 8000/127.0.0.1\", ${TARGET_PORT}/" "$EXPORTER" 2>/dev/null || true
}

write_prometheus_cfg() {
  cat > "$PROM_CFG" <<EOF
# Prometheus lab configuration — PCA topic 1.1 (Selecting Data)
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  - job_name: api
    static_configs:
      - targets: ["127.0.0.1:${TARGET_PORT}"]

rule_files:
  - ${RULES_FILE}
EOF
}

write_broken_rules() {
  # ---------------------- THE CONTROLLED BREAK ----------------------
  # This recording rule is SUPPOSED to select every 5xx response (500, 503)
  # and record their live total. It uses `=` (exact match) against the
  # PATTERN "5..". No series has the literal label value "5.." , so the
  # selector matches nothing, the sum() of an empty vector is itself empty,
  # and the recorded series `job:http_requests_5xx:current` never exists.
  # The rule is 100% valid YAML and valid PromQL — Prometheus starts cleanly
  # and reports NO error. That silence is exactly what makes this bug nasty.
  # ------------------------------------------------------------------
  mkdir -p "$(dirname "$RULES_FILE")"
  cat > "$RULES_FILE" <<'EOF'
groups:
  - name: pca_selecting_data
    interval: 5s
    rules:
      # BUG: `=` is an EXACT string match, not a pattern match.
      #      "5.." is being compared literally, so nothing is selected.
      - record: job:http_requests_5xx:current
        expr: sum by (job) (http_requests_total{status="5.."})
EOF
}

# ---- lifecycle --------------------------------------------------------------
wait_http() {  # wait_http <url> <label>
  local url="$1" label="$2" i=0
  until curl -sf -o /dev/null "$url"; do
    i=$((i+1)); [ "$i" -gt 60 ] && die "$label did not become ready: $url"
    sleep 0.5
  done
}

lab_up() {
  trap on_err ERR
  require_tools

  if [ -f "$RUNDIR/prometheus.pid" ] && kill -0 "$(cat "$RUNDIR/prometheus.pid")" 2>/dev/null; then
    log "lab already running (PID $(cat "$RUNDIR/prometheus.pid")). Use 'down' first to reset."
    trap - ERR; return 0
  fi

  confirm_lab
  port_busy "$PROM_PORT"   && die "port ${PROM_PORT} already in use — free it or set PCA_PROM_PORT"
  port_busy "$TARGET_PORT" && die "port ${TARGET_PORT} already in use — free it or set PCA_TARGET_PORT"

  mkdir -p "$WORKDIR" "$RUNDIR" "$LOGDIR" "$WORKDIR/data"
  log "provisioning lab in $WORKDIR"
  ensure_prometheus
  write_exporter
  write_prometheus_cfg
  write_broken_rules

  # start the demo target (exporter)
  nohup python3 "$EXPORTER" >"$LOGDIR/exporter.log" 2>&1 &
  echo $! > "$RUNDIR/exporter.pid"; STARTED_PIDS+=("$!")
  wait_http "http://127.0.0.1:${TARGET_PORT}/metrics" "exporter"
  log "demo target up on 127.0.0.1:${TARGET_PORT}/metrics"

  # start Prometheus with lifecycle API enabled (needed for hot reload)
  nohup "$PROM_BIN" \
    --config.file="$PROM_CFG" \
    --storage.tsdb.path="$WORKDIR/data" \
    --web.listen-address="127.0.0.1:${PROM_PORT}" \
    --web.enable-lifecycle \
    >"$LOGDIR/prometheus.log" 2>&1 &
  echo $! > "$RUNDIR/prometheus.pid"; STARTED_PIDS+=("$!")
  wait_http "http://127.0.0.1:${PROM_PORT}/-/ready" "prometheus"
  log "Prometheus up on http://127.0.0.1:${PROM_PORT}"

  trap - ERR
  print_briefing
}

lab_down() {
  local p
  for p in prometheus exporter; do
    if [ -f "$RUNDIR/$p.pid" ]; then
      kill "$(cat "$RUNDIR/$p.pid")" 2>/dev/null || true
    fi
  done
  # belt-and-suspenders: only our own exporter file, never a broad pkill
  pkill -f "python3 $EXPORTER" 2>/dev/null || true
  rm -rf "$WORKDIR"
  log "lab torn down; $WORKDIR removed."
}

q() {  # q <promql>  -> pretty-ish query against the lab
  curl -s --get "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
    --data-urlencode "query=$1"
}

lab_status() {
  local pp="down" ep="down"
  [ -f "$RUNDIR/prometheus.pid" ] && kill -0 "$(cat "$RUNDIR/prometheus.pid")" 2>/dev/null && pp="up"
  [ -f "$RUNDIR/exporter.pid"   ] && kill -0 "$(cat "$RUNDIR/exporter.pid")"   2>/dev/null && ep="up"
  echo "exporter : $ep    prometheus : $pp"
  [ "$pp" = "up" ] || { echo "(bring the lab up first: $0 up)"; return 0; }
  echo
  echo "Broken recording rule series (expected: empty result):"
  q 'job:http_requests_5xx:current' | sed 's/.*/  &/'
  echo
  echo "Raw 5xx selection with EXACT match  http_requests_total{status=\"5..\"} (expected: empty):"
  q 'http_requests_total{status="5.."}' | sed 's/.*/  &/'
  echo
  echo "Raw 5xx selection with REGEX match  http_requests_total{status=~\"5..\"} (expected: 500 & 503):"
  q 'http_requests_total{status=~"5.."}' | sed 's/.*/  &/'
}

print_briefing() {
  cat <<EOF

============================================================================
  PCA 1.1 — Selecting Data :: BREAK & FIX  ::  "The 5xx panel that is empty"
============================================================================

  SCENARIO
  --------
  An "API errors" dashboard/alert is driven by a Prometheus recording rule
  that should track the live total of 5xx responses (HTTP 500 & 503). The
  service IS returning 5xx traffic, yet the panel reads "No data" and the
  alert never fires.

  Files you may inspect and edit:
    * Recording rule : $RULES_FILE
    * Prom config    : $PROM_CFG
    * Prometheus UI  : http://127.0.0.1:${PROM_PORT}/graph
    * promtool       : $PROMTOOL_BIN

  THE SYMPTOM YOU WILL SEE
  ------------------------
  1) The derived series returns NOTHING (Prometheus reports "Empty query
     result"), even after several evaluation cycles:

       curl -s --get "http://127.0.0.1:${PROM_PORT}/api/v1/query" \\
         --data-urlencode 'query=job:http_requests_5xx:current' | grep result

  2) Prometheus logs show NO error — the rule is valid and evaluates happily.
     Targets are UP:  http://127.0.0.1:${PROM_PORT}/targets

  3) The underlying 5xx series clearly EXIST when you select them correctly:

       # exact match  -> empty (this is the trap)
       curl -s --get "http://127.0.0.1:${PROM_PORT}/api/v1/query" \\
         --data-urlencode 'query=http_requests_total{status="5.."}'

       # regex match  -> returns the 500 and 503 series
       curl -s --get "http://127.0.0.1:${PROM_PORT}/api/v1/query" \\
         --data-urlencode 'query=http_requests_total{status=~"5.."}'

  YOUR GOAL
  ---------
  Make  job:http_requests_5xx:current  return a live, non-empty value equal to
  the sum of all 5xx requests, WITHOUT restarting Prometheus (hot reload only).
  Along the way, be able to explain WHY the original selector matched nothing.

  Quick state check any time:   $0 status
  Tear the lab down:            $0 down

  (The full step-by-step solution is at the bottom of this script, commented.)
============================================================================

EOF
}

# ---- dispatch ---------------------------------------------------------------
case "${1:-up}" in
  up)      lab_up ;;
  status)  lab_status ;;
  down)    lab_down ;;
  -h|--help|help) sed -n '1,60p' "$0" ;;
  *)       die "unknown command '${1}'  (use: up | status | down)" ;;
esac

exit 0

# =============================================================================
#  SOLUTION — step by step
# =============================================================================
#
#  ROOT CAUSE
#  ----------
#  In PromQL, the label matcher `=` performs EXACT STRING EQUALITY. The value
#  "5.." is treated as the literal three characters  5 . .  — not as a pattern.
#  No time series carries the label value status="5..", so the selector
#  `http_requests_total{status="5.."}` returns an empty instant vector, and
#  `sum by (job)(<empty>)` is itself empty. The recording rule therefore never
#  produces the series `job:http_requests_5xx:current`. Nothing errors; the
#  data is simply never selected.
#
#  To match a CLASS of values you need a regex matcher `=~`. Remember that
#  PromQL regexes are FULLY ANCHORED — `status=~"5.."` is implicitly `^5..$`,
#  i.e. exactly three characters, first is '5', so it matches "500" and "503"
#  but NOT "50" or "5000". That is precisely the 5xx class we want.
#
#  STEP 1 — Confirm the diagnosis (prove it is a selector problem, not missing data)
#  ---------------------------------------------------------------------------------
#     # exact match: empty  (the bug)
#     curl -s --get "http://127.0.0.1:9090/api/v1/query" \
#       --data-urlencode 'query=http_requests_total{status="5.."}'
#
#     # regex match: two series (status 500 and 503) -> data exists
#     curl -s --get "http://127.0.0.1:9090/api/v1/query" \
#       --data-urlencode 'query=http_requests_total{status=~"5.."}'
#
#     # the recorded series is absent
#     curl -s --get "http://127.0.0.1:9090/api/v1/query" \
#       --data-urlencode 'query=job:http_requests_5xx:current'
#
#  STEP 2 — Fix the matcher in the recording rule
#  ----------------------------------------------
#     Edit  $RULES_FILE  and change the expression from `=` to `=~`:
#
#       - record: job:http_requests_5xx:current
#         expr: sum by (job) (http_requests_total{status=~"5.."})
#
#     One-liner (idempotent) equivalent:
#       sed -i 's/status="5\.\."/status=~"5.."/' \
#         /tmp/pca-lab-1.1-selecting-data/rules/selecting-data.rules.yml
#
#  STEP 3 — Validate the rules file BEFORE reloading
#  -------------------------------------------------
#       PROMTOOL=/tmp/pca-lab-1.1-selecting-data/bin/promtool   # or system promtool
#       "$PROMTOOL" check rules \
#         /tmp/pca-lab-1.1-selecting-data/rules/selecting-data.rules.yml
#     Expect: "SUCCESS: 1 rules found".
#
#  STEP 4 — Hot-reload Prometheus (no restart, no data loss)
#  ---------------------------------------------------------
#     Prometheus was started with --web.enable-lifecycle, so:
#       curl -X POST http://127.0.0.1:9090/-/reload
#     Confirm the reload succeeded (check config reload metric = 1):
#       curl -s --get "http://127.0.0.1:9090/api/v1/query" \
#         --data-urlencode 'query=prometheus_config_last_reload_successful'
#
#  STEP 5 — Verify the fix
#  -----------------------
#     Wait one evaluation interval (~5s), then:
#       curl -s --get "http://127.0.0.1:9090/api/v1/query" \
#         --data-urlencode 'query=job:http_requests_5xx:current'
#     You should now see one series {job="api"} with a live, non-empty value
#     that keeps increasing (it is the sum of the 500 and 503 counters).
#     Equivalently:   ./pca-1.1-selecting-data.sh status
#
#  WHY IT WORKS / WHAT TO REMEMBER (exam-grade takeaways)
#  ------------------------------------------------------
#   * `=`  exact equality      * `!=` exact inequality
#   * `=~` regex match         * `!~` regex non-match     (both FULLY anchored)
#   * Use a regex matcher whenever the value is a PATTERN or a SET, e.g.
#       status=~"5.."          all 5xx
#       method=~"GET|POST"     alternation
#       path!~"/health.*"      exclude health-check noise
#   * A metric name is just sugar for the __name__ label:
#       http_requests_total{status="500"}  ==  {__name__="http_requests_total",status="500"}
#       {__name__=~"http_.*_total"}  selects by name via regex.
#   * At least one matcher must not match the empty string — you cannot select
#     with `{}` or with only `label=~".*"`; anchor on a real metric/label.
#   * Instant vs range vectors: `metric{...}` is an instant vector (one sample
#     per series). `metric{...}[5m]` is a RANGE vector (many samples) and can be
#     fed to rate()/increase() but NOT graphed directly — mixing them up is the
#     sibling failure to this one ("expected type instant vector ... got range").
#   * Time-shift modifiers select from the past:
#       http_requests_total offset 5m
#       http_requests_total @ 1609746000            (absolute, evaluate @ instant)
#
#  Sources:
#   * PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#   * PromQL basics (selectors, matchers, vectors):
#       https://prometheus.io/docs/prometheus/latest/querying/basics/
#   * Recording rules:
#       https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
#   * Management API / hot reload (--web.enable-lifecycle):
#       https://prometheus.io/docs/prometheus/latest/management_api/
# =============================================================================