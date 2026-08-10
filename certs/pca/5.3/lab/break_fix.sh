#!/usr/bin/env bash
#
# ============================================================================
#  PCA - Prometheus Certified Associate
#  Domain 5: Instrumentation & Exporters  |  Topic 5.3: Exporters (weight 4)
#  Reference syllabus: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#
#  break-and-fix lab: "The exporter is up, but Prometheus says it is DOWN"
#
#  WHAT THIS SCRIPT DOES
#    1. Downloads pinned upstream binaries of node_exporter and Prometheus
#       into an isolated lab directory (nothing is installed system-wide).
#    2. Brings up a healthy stack: node_exporter on :9100/metrics scraped by a
#       local Prometheus on :9090. It proves `up{job="node"} == 1`.
#    3. Introduces ONE controlled, fully reversible misconfiguration on the
#       EXPORTER side and shows the student the resulting symptom.
#    4. Hands the console back to the student with a briefing.
#
#  SAFETY
#    - Runs ONLY inside "$LAB_DIR" and binds to loopback (127.0.0.1). It does
#      not touch systemd, /usr, package managers, firewalls or any real target.
#    - Everything is torn down with:  ./pca-5.3-exporters-breakfix.sh clean
#    - Intended for a DISPOSABLE lab VM. Do not run on anything you care about.
#
#  USAGE
#    ./pca-5.3-exporters-breakfix.sh            # setup healthy stack, then break it (default)
#    ./pca-5.3-exporters-breakfix.sh status     # show target health / diagnostics
#    ./pca-5.3-exporters-breakfix.sh solve      # instructor auto-fix (spoiler)
#    ./pca-5.3-exporters-breakfix.sh clean       # stop everything and remove the lab
# ============================================================================

set -euo pipefail

# ------------------------------ configuration -------------------------------
NE_VER="${NE_VER:-1.8.2}"          # node_exporter version (override with env)
PROM_VER="${PROM_VER:-2.53.2}"     # prometheus LTS version (override with env)
LAB_DIR="${LAB_DIR:-/opt/pca-lab-5.3}"
BIN_DIR="$LAB_DIR/bin"
DATA_DIR="$LAB_DIR/data"
NE_PORT=9100
PROM_PORT=9090
# The wrong telemetry path we will make node_exporter serve on. A realistic
# "someone tried to namespace the endpoint and forgot to update the scrape"
# mistake. /metrics will then answer 404.
BROKEN_PATH="/node/metrics"

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_HDR=$'\033[36m'; C_OFF=$'\033[0m'
log()  { printf '%s[lab]%s %s\n' "$C_HDR" "$C_OFF" "$*"; }
die()  { printf '%s[lab] ERROR:%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

# ------------------------------ prerequisites -------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l)        ARCH=armv7 ;;
    *) die "unsupported CPU arch: $(uname -m)" ;;
  esac
}

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else die "need curl or wget to download binaries"; fi
}

install_binaries() {
  detect_arch
  mkdir -p "$BIN_DIR" "$DATA_DIR"
  if [ ! -x "$BIN_DIR/node_exporter" ]; then
    log "downloading node_exporter v${NE_VER} (${ARCH}) ..."
    local t; t="$(mktemp -d)"
    fetch "https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/node_exporter-${NE_VER}.linux-${ARCH}.tar.gz" "$t/ne.tgz"
    tar -xzf "$t/ne.tgz" -C "$t"
    install -m 0755 "$t"/node_exporter-*/node_exporter "$BIN_DIR/node_exporter"
    rm -rf "$t"
  fi
  if [ ! -x "$BIN_DIR/prometheus" ]; then
    log "downloading prometheus v${PROM_VER} (${ARCH}) ..."
    local t; t="$(mktemp -d)"
    fetch "https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.linux-${ARCH}.tar.gz" "$t/prom.tgz"
    tar -xzf "$t/prom.tgz" -C "$t"
    install -m 0755 "$t"/prometheus-*/prometheus "$BIN_DIR/prometheus"
    rm -rf "$t"
  fi
}

write_prom_config() {
  cat > "$LAB_DIR/prometheus.yml" <<EOF
# Minimal scrape config for the PCA 5.3 exporters lab.
# NOTE: job "node" uses Prometheus' DEFAULT metrics_path (/metrics).
global:
  scrape_interval: 5s
  evaluation_interval: 5s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:${PROM_PORT}']
  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:${NE_PORT}']
EOF
}

# --------------------------- process management -----------------------------
pidfile() { echo "$LAB_DIR/$1.pid"; }
is_running() { local p; p="$(pidfile "$1")"; [ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; }
stop_proc() {
  local name="$1" p; p="$(pidfile "$name")"
  if [ -f "$p" ]; then kill "$(cat "$p")" 2>/dev/null || true; rm -f "$p"; fi
}

start_node_exporter() { # start_node_exporter <telemetry-path>
  stop_proc node_exporter
  local path="$1"
  log "starting node_exporter on :${NE_PORT} with --web.telemetry-path=${path}"
  nohup "$BIN_DIR/node_exporter" \
      --web.listen-address="127.0.0.1:${NE_PORT}" \
      --web.telemetry-path="${path}" \
      > "$LAB_DIR/node_exporter.log" 2>&1 &
  echo $! > "$(pidfile node_exporter)"
}

start_prometheus() {
  is_running prometheus && return 0
  log "starting prometheus on :${PROM_PORT}"
  nohup "$BIN_DIR/prometheus" \
      --config.file="$LAB_DIR/prometheus.yml" \
      --storage.tsdb.path="$DATA_DIR" \
      --web.listen-address="127.0.0.1:${PROM_PORT}" \
      --web.enable-lifecycle \
      > "$LAB_DIR/prometheus.log" 2>&1 &
  echo $! > "$(pidfile prometheus)"
}

# ------------------------------ diagnostics ---------------------------------
wait_prom_ready() {
  for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "prometheus did not become ready; see $LAB_DIR/prometheus.log"
}

metrics_http_code() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${NE_PORT}/metrics" || echo 000; }

node_up_value() { # -> "1", "0" or "" (unknown)
  curl -sG "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
       --data-urlencode 'query=up{job="node"}' 2>/dev/null \
    | sed -n 's/.*"value":\[[0-9.eE+-]*,"\([01]\)"\].*/\1/p'
}

status() {
  local code up
  code="$(metrics_http_code)"
  up="$(node_up_value)"
  echo   "-------------------------------------------------------------"
  printf ' node_exporter GET /metrics  -> HTTP %s\n' "$code"
  printf ' prometheus  up{job=node}    -> %s\n' "${up:-<no series>}"
  echo   "-------------------------------------------------------------"
  echo   " active node_exporter cmdline:"
  sed -n 's/^/   /p' <<<"$(tr '\0' ' ' < /proc/"$(cat "$(pidfile node_exporter)" 2>/dev/null || echo 0)"/cmdline 2>/dev/null || echo '   (not running)')"
}

# ------------------------------ orchestration -------------------------------
confirm_disposable() {
  [ "${PCA_LAB_CONFIRM:-}" = "yes" ] && return 0
  printf '%s' "This lab modifies a running Prometheus stack. Type YES to confirm this is a disposable lab VM: "
  read -r ans; [ "$ans" = "YES" ] || die "aborted by user"
}

setup_healthy() {
  need tar
  install_binaries
  write_prom_config
  start_node_exporter "/metrics"     # correct path -> healthy
  start_prometheus
  wait_prom_ready
  log "waiting for the scrape to register the target as UP ..."
  for _ in $(seq 1 20); do [ "$(node_up_value)" = "1" ] && break; sleep 1; done
  [ "$(node_up_value)" = "1" ] || die "baseline never became healthy; see logs in $LAB_DIR"
  log "${C_OK}baseline healthy: up{job=\"node\"} == 1${C_OFF}"
}

break_it() {
  # THE CONTROLLED BREAK: restart the exporter serving its metrics on a
  # non-default telemetry path. Prometheus still scrapes /metrics, so it now
  # gets a 404 and marks the target DOWN. Nothing else is changed.
  start_node_exporter "$BROKEN_PATH"
  log "waiting for the target to flip to DOWN ..."
  for _ in $(seq 1 20); do [ "$(node_up_value)" = "0" ] && break; sleep 1; done
}

briefing() {
  cat <<EOF

$C_HDR================================ STUDENT BRIEFING ================================$C_OFF
 PCA Topic 5.3 - Exporters

 The node_exporter process is running and healthy from the OS point of view.
 Prometheus, however, reports its target as DOWN.

 SYMPTOM you will observe:
   * Prometheus UI  -> Status > Targets : job "node" is red / DOWN with the
     error message:  "server returned HTTP status 404 Not Found"
   * PromQL         :  up{job="node"}   evaluates to  0
   * Direct check   :  curl -s -o /dev/null -w '%{http_code}' \\
                         http://127.0.0.1:${NE_PORT}/metrics   ->  404
   * Yet the process IS alive (systemctl/ps show it running) and it DOES
     serve metrics -- just not where Prometheus is looking.

 YOUR GOAL:
   Make  up{job="node"} == 1  again, WITHOUT killing or reinstalling anything.
   Diagnose WHY a live exporter can still read as DOWN, and reconcile the two
   sides of the contract: the exporter's telemetry endpoint and the scrape
   job's metrics_path.

 USEFUL STARTING POINTS:
   Prometheus UI ..... http://127.0.0.1:${PROM_PORT}/targets
   Scrape config ..... $LAB_DIR/prometheus.yml
   Exporter cmdline .. cat /proc/\$(cat $LAB_DIR/node_exporter.pid)/cmdline | tr '\\0' ' '
   Exporter log ...... $LAB_DIR/node_exporter.log
   Probe the exporter: curl -s http://127.0.0.1:${NE_PORT}/         (read the landing page!)

 Check your progress at any time with:  $0 status
$C_HDR=================================================================================$C_OFF
EOF
}

solve() {
  # Instructor spoiler: the direct fix is to restore the exporter's default path.
  log "auto-fix: restarting node_exporter on the default /metrics path"
  start_node_exporter "/metrics"
  for _ in $(seq 1 20); do [ "$(node_up_value)" = "1" ] && break; sleep 1; done
  [ "$(node_up_value)" = "1" ] && log "${C_OK}fixed: up{job=\"node\"} == 1${C_OFF}" || log "${C_BAD}still down; check logs${C_OFF}"
}

clean() {
  stop_proc node_exporter; stop_proc prometheus
  rm -rf "$LAB_DIR"
  log "lab torn down and $LAB_DIR removed."
}

main() {
  case "${1:-run}" in
    run)
      confirm_disposable
      setup_healthy
      break_it
      status
      briefing
      ;;
    status) status ;;
    solve)  solve; status ;;
    clean)  clean ;;
    *) die "unknown command: $1 (use: run | status | solve | clean)" ;;
  esac
}
main "$@"

# ============================================================================
#  SOLUTION - step by step (read only after you have tried it yourself)
# ============================================================================
#
#  ROOT CAUSE
#  ----------
#  An exporter exposes its metrics at a configurable HTTP endpoint. For
#  node_exporter that endpoint is controlled by  --web.telemetry-path  and
#  defaults to  /metrics . In this lab the exporter was started with
#  --web.telemetry-path=/node/metrics , so:
#     * GET /node/metrics  -> 200  (the metrics really are there)
#     * GET /metrics       -> 404
#  Prometheus scrapes each target at its job's  metrics_path , which defaults
#  to  /metrics . Because the scrape config was never updated to match the new
#  endpoint, every scrape hits 404 and Prometheus sets  up == 0 . A DOWN target
#  therefore does NOT necessarily mean the exporter is dead -- here it is alive
#  and healthy; the two sides simply disagree on the URL path.
#
#  STEP 1 - Confirm the exporter is actually alive and find its real endpoint.
#     ps aux | grep node_exporter
#     cat /proc/$(cat /opt/pca-lab-5.3/node_exporter.pid)/cmdline | tr '\0' ' '; echo
#       -> note  --web.telemetry-path=/node/metrics
#     # node_exporter's landing page tells you the path directly:
#     curl -s http://127.0.0.1:9100/ | grep -i href
#       -> <a href="/node/metrics">Metrics</a>
#     curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9100/metrics        # 404
#     curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9100/node/metrics   # 200
#
#  STEP 2 - Read the exact scrape error in Prometheus (do not guess).
#     Open http://127.0.0.1:9090/targets  (or query the API):
#     curl -sG http://127.0.0.1:9090/api/v1/targets | tr ',' '\n' | grep -i lastError
#       -> "server returned HTTP status 404 Not Found"
#     A 404 (as opposed to "connection refused") is the tell-tale sign that the
#     exporter is up but the PATH is wrong.
#
#  STEP 3 - Reconcile the contract. Choose ONE of the two valid fixes:
#
#     FIX A (fix the exporter -- restore the conventional endpoint; preferred,
#            because /metrics is the ecosystem convention):
#       kill "$(cat /opt/pca-lab-5.3/node_exporter.pid)"
#       nohup /opt/pca-lab-5.3/bin/node_exporter \
#             --web.listen-address=127.0.0.1:9100 \
#             --web.telemetry-path=/metrics \
#             > /opt/pca-lab-5.3/node_exporter.log 2>&1 &
#       echo $! > /opt/pca-lab-5.3/node_exporter.pid
#
#     FIX B (fix the scrape job -- teach Prometheus the exporter's real path;
#            correct when a non-default path is intentional):
#       # Edit /opt/pca-lab-5.3/prometheus.yml, add metrics_path under job "node":
#       #   - job_name: node
#       #     metrics_path: /node/metrics
#       #     static_configs:
#       #       - targets: ['127.0.0.1:9100']
#       # Then hot-reload Prometheus (works because we started it with
#       # --web.enable-lifecycle):
#       curl -X POST http://127.0.0.1:9090/-/reload
#
#  STEP 4 - Verify recovery (allow one scrape_interval, 5s).
#     curl -sG http://127.0.0.1:9090/api/v1/query \
#          --data-urlencode 'query=up{job="node"}'
#       -> ... "value":[<ts>,"1"]      # target is UP again
#     # or simply:  ./pca-5.3-exporters-breakfix.sh status
#
#  TAKEAWAYS
#     * up == 0 means "the scrape failed", not "the process is dead". Always
#       read the target's lastError to tell apart: connection refused (down /
#       wrong host:port), 404 (wrong metrics_path), 401/403 (auth), context
#       deadline exceeded (timeout / slow exporter).
#     * An exporter's endpoint = listen address + telemetry path. Both must
#       match the scrape job's target and metrics_path exactly.
#     * Prefer the conventional /metrics path; only override metrics_path when
#       the exporter genuinely serves elsewhere (e.g. blackbox/snmp probe jobs).
#
#  Sources (official):
#     PCA curriculum ....... https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#     node_exporter ........ https://github.com/prometheus/node_exporter
#     Scrape config ........ https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
#     Exporters overview ... https://prometheus.io/docs/instrumenting/exporters/
# ============================================================================