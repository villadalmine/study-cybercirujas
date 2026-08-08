#!/usr/bin/env bash
#
# PCA — Prometheus Certified Associate
# Domain 1: PromQL  ·  Topic 1.2: Rates and Derivatives  (exam weight: 4)
#
# BREAK & FIX lab. Run ONLY on a disposable lab VM. It spins up a throwaway
# Prometheus that scrapes itself (no external target needed), then injects a
# controlled fault so you can experience — and repair — the single most common
# mistake with rate() / irate() / increase() / deriv(): a range window shorter
# than the data resolution.
#
# What this teaches (the exam-relevant mechanics):
#   * rate()/irate()/increase()/delta()/idelta()/deriv()/predict_linear() all
#     operate on a RANGE VECTOR: metric[<window>]. They need >= 2 samples inside
#     that window to produce any output; with < 2 they return an EMPTY vector,
#     not zero, not an error.
#   * Samples land one per scrape_interval. So the window is only meaningful
#     relative to scrape_interval. Official rule of thumb: window >= 4x interval.
#   * rate()/irate()/increase() expect a monotonic COUNTER (they auto-correct
#     counter resets). deriv()/delta()/predict_linear() expect a GAUGE.
#
# Sources (official):
#   PCA curriculum ..... https://github.com/cncf/curriculum (Prometheus Certified Associate)
#   rate() ............. https://prometheus.io/docs/prometheus/latest/querying/functions/#rate
#   irate() ............ https://prometheus.io/docs/prometheus/latest/querying/functions/#irate
#   deriv() ............ https://prometheus.io/docs/prometheus/latest/querying/functions/#deriv
#   predict_linear() ... https://prometheus.io/docs/prometheus/latest/querying/functions/#predict_linear
#   range selectors .... https://prometheus.io/docs/prometheus/latest/querying/basics/#range-vector-selectors
#   recording rules .... https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
#
# Usage:
#   ./rates_and_derivatives_breakfix.sh break     # set up lab + inject the fault (default)
#   ./rates_and_derivatives_breakfix.sh check      # grade your fix: PASS/FAIL
#   ./rates_and_derivatives_breakfix.sh status     # show current live queries
#   ./rates_and_derivatives_breakfix.sh reset      # restore a known-good state (reveals the answer)
#   ./rates_and_derivatives_breakfix.sh stop       # stop the lab Prometheus
#   ./rates_and_derivatives_breakfix.sh clean      # stop + delete the lab directory
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
LAB_DIR="${LAB_DIR:-$HOME/pca-lab-1.2-rates}"
PROM_VERSION="${PROM_VERSION:-2.53.2}"          # current LTS at time of writing
PROM_PORT="${PROM_PORT:-9099}"                  # NOT 9090, to avoid clobbering a real Prometheus
PROM_ADDR="127.0.0.1:${PROM_PORT}"
BROKEN_SCRAPE_INTERVAL="30s"                    # samples arrive every 30s ...
BROKEN_RULE_WINDOW="15s"                        # ... but the rule looks back only 15s  -> < 1 sample -> EMPTY
GOOD_RULE_WINDOW="2m"                           # the intended fix: 2m >= 4 x 30s -> 4 samples -> works
CFG="${LAB_DIR}/prometheus.yml"
RULES="${LAB_DIR}/rates.rules.yml"
PIDFILE="${LAB_DIR}/prometheus.pid"
LOGFILE="${LAB_DIR}/prometheus.log"
SELF="$(basename "$0")"

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #
msg()  { printf '\033[1;36m[lab]\033[0m %s\n'  "$*"; }
ok()   { printf '\033[1;32m[ ok]\033[0m %s\n'  "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n'  "$*" >&2; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

need() { command -v "$1" >/dev/null 2>&1 || { err "missing required tool: $1"; exit 1; }; }

# Run an instant query against the lab Prometheus HTTP API and print raw JSON.
prom_query() {
  curl -sG "http://${PROM_ADDR}/api/v1/query" --data-urlencode "query=$1"
}

# Number of series returned by an instant query (0 == empty vector).
count_results() {
  prom_query "$1" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("data",{}).get("result",[])))' 2>/dev/null || echo 0
}

# Pretty single-line value of the first series of a query (or "<empty vector>").
first_value() {
  prom_query "$1" | python3 -c '
import sys,json
r=json.load(sys.stdin).get("data",{}).get("result",[])
print("<empty vector>" if not r else r[0]["value"][1])
' 2>/dev/null || echo "<query failed>"
}

# --------------------------------------------------------------------------- #
# Safety guard: this must be a throwaway VM
# --------------------------------------------------------------------------- #
guard_lab() {
  if systemctl is-active --quiet prometheus 2>/dev/null; then
    err "A system 'prometheus.service' is ACTIVE on this host."
    err "Refusing to run: this script is for a disposable lab VM only."
    exit 1
  fi
  if [ "${PCA_LAB_YES:-0}" != "1" ] && [ -t 0 ]; then
    warn "This starts a throwaway Prometheus on ${PROM_ADDR} and writes under ${LAB_DIR}."
    read -r -p "Continue on this disposable lab VM? [y/N] " ans
    case "$ans" in y|Y|yes|YES) : ;; *) err "aborted."; exit 1;; esac
  fi
}

# --------------------------------------------------------------------------- #
# Install Prometheus into the lab dir if it is not already on PATH
# --------------------------------------------------------------------------- #
ensure_prometheus() {
  need curl; need python3; need tar; need sha256sum
  if command -v prometheus >/dev/null 2>&1 && command -v promtool >/dev/null 2>&1; then
    return
  fi
  local arch base tgz url
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) err "unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
  base="prometheus-${PROM_VERSION}.linux-${arch}"
  tgz="${base}.tar.gz"
  url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${tgz}"
  msg "Prometheus not found; downloading v${PROM_VERSION} (${arch}) into ${LAB_DIR}/bin ..."
  mkdir -p "${LAB_DIR}/bin"
  (
    cd "${LAB_DIR}"
    curl -fsSLO "${url}"
    curl -fsSLO "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/sha256sums.txt"
    grep " ${tgz}\$" sha256sums.txt | sha256sum -c -      # verify the official checksum
    tar -xzf "${tgz}"
    install -m0755 "${base}/prometheus" "${LAB_DIR}/bin/prometheus"
    install -m0755 "${base}/promtool"  "${LAB_DIR}/bin/promtool"
  )
  export PATH="${LAB_DIR}/bin:${PATH}"
  ok "Prometheus $(prometheus --version 2>&1 | head -n1)"
}

# --------------------------------------------------------------------------- #
# Config + rules rendering
# --------------------------------------------------------------------------- #
render_config() {   # $1 = scrape_interval
  cat >"${CFG}" <<EOF
# PCA lab 1.2 — Rates and Derivatives
global:
  scrape_interval: ${1}        # one sample per target every ${1}
  evaluation_interval: 15s     # how often recording rules run

rule_files:
  - ${RULES}

scrape_configs:
  - job_name: prometheus       # Prometheus scrapes itself; /metrics exposes real counters + gauges
    static_configs:
      - targets: ["${PROM_ADDR}"]
EOF
}

render_rules() {    # $1 = range window used inside the functions
  cat >"${RULES}" <<EOF
# PCA lab 1.2 — recording rules exercising rate() on a counter and deriv() on a gauge.
groups:
  - name: pca_rates_derivatives
    interval: 15s
    rules:
      # rate() on a COUNTER: per-second average increase over the window.
      - record: pca:http_requests:rate
        expr: sum(rate(prometheus_http_requests_total[${1}]))

      # deriv() on a GAUGE: per-second derivative via simple linear regression.
      - record: pca:head_series:deriv
        expr: deriv(prometheus_tsdb_head_series[${1}])
EOF
}

# --------------------------------------------------------------------------- #
# Lifecycle
# --------------------------------------------------------------------------- #
prom_running() { [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; }

stop_prom() {
  if prom_running; then
    msg "Stopping lab Prometheus (pid $(cat "${PIDFILE}")) ..."
    kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    for _ in $(seq 1 20); do prom_running || break; sleep 0.3; done
  fi
  rm -f "${PIDFILE}"
}

start_prom() {
  stop_prom
  msg "Validating configuration with promtool ..."
  ( cd "${LAB_DIR}" && promtool check config "${CFG}" )
  msg "Starting lab Prometheus on http://${PROM_ADDR} ..."
  (
    cd "${LAB_DIR}"
    nohup prometheus \
      --config.file="${CFG}" \
      --storage.tsdb.path="${LAB_DIR}/data" \
      --web.listen-address="${PROM_ADDR}" \
      --web.enable-lifecycle \
      >"${LOGFILE}" 2>&1 &
    echo $! >"${PIDFILE}"
  )
  for _ in $(seq 1 60); do
    curl -sf "http://${PROM_ADDR}/-/ready" >/dev/null 2>&1 && { ok "Prometheus ready."; return; }
    sleep 1
  done
  err "Prometheus did not become ready; last log lines:"; tail -n 20 "${LOGFILE}" || true; exit 1
}

wait_for_samples() {
  msg "Waiting for >= 2 scrapes so a WIDE window has data to prove the metric is healthy ..."
  for _ in $(seq 1 48); do
    [ "$(count_results 'rate(prometheus_http_requests_total[5m])')" -gt 0 ] && { ok "Samples are flowing."; return; }
    sleep 5
  done
  err "timed out waiting for samples; check ${LOGFILE}"; exit 1
}

# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #
do_break() {
  guard_lab
  mkdir -p "${LAB_DIR}"
  ensure_prometheus
  msg "Rendering FAULTY config: scrape_interval=${BROKEN_SCRAPE_INTERVAL}, function window=${BROKEN_RULE_WINDOW}"
  render_config "${BROKEN_SCRAPE_INTERVAL}"
  render_rules  "${BROKEN_RULE_WINDOW}"
  start_prom
  wait_for_samples

  rule
  warn "FAULT INJECTED — here is the symptom you must diagnose:"
  rule
  printf '  %-58s -> %s\n' "rate(prometheus_http_requests_total[5m])   (wide)" "$(first_value 'sum(rate(prometheus_http_requests_total[5m]))')"
  printf '  %-58s -> %s\n' "rate(prometheus_http_requests_total[${BROKEN_RULE_WINDOW}])   (rule)" "$(first_value 'sum(rate(prometheus_http_requests_total['"${BROKEN_RULE_WINDOW}"']))')"
  printf '  %-58s -> %s\n' "pca:http_requests:rate   (recording rule output)"     "$(first_value 'pca:http_requests:rate')"
  printf '  %-58s -> %s\n' "pca:head_series:deriv    (recording rule output)"     "$(first_value 'pca:head_series:deriv')"
  rule
  cat <<EOF

WHAT YOU SEE
  The metric is perfectly healthy — the WIDE [5m] window returns a value — yet
  both recording rules ('pca:http_requests:rate', 'pca:head_series:deriv') and
  the [${BROKEN_RULE_WINDOW}] query return an EMPTY vector. In Grafana this shows up as
  the dreaded "No data". No error is logged; the query simply resolves to nothing.

WHY (the trap this topic tests)
  rate()/irate()/increase()/deriv() need at least TWO samples inside the range
  window. Samples arrive once per scrape_interval (${BROKEN_SCRAPE_INTERVAL} here), so a [${BROKEN_RULE_WINDOW}]
  window can hold at most ONE sample -> nothing to compute a slope from -> empty.

YOUR OBJECTIVE
  Make BOTH recording rules emit a value again.
  Constraints: do NOT change the metric names and do NOT change the functions
  (rate/deriv stay). Fix only the time relationship between the range window and
  the scrape_interval. Edit files under:
      ${CFG}
      ${RULES}
  then reload without a restart:
      curl -X POST http://${PROM_ADDR}/-/reload
  and grade yourself:
      ./${SELF} check

  Hint: prometheus.io's rule of thumb is  window >= 4 x scrape_interval.

EOF
}

do_check() {
  command -v prometheus >/dev/null 2>&1 || export PATH="${LAB_DIR}/bin:${PATH}"
  prom_running || { err "Lab Prometheus is not running. Run: ./${SELF} break"; exit 1; }
  msg "Grading ... (recording rules may need one 15s evaluation cycle after a reload)"
  local rate_n deriv_n
  for _ in $(seq 1 6); do
    rate_n="$(count_results 'pca:http_requests:rate')"
    deriv_n="$(count_results 'pca:head_series:deriv')"
    { [ "${rate_n}" -gt 0 ] && [ "${deriv_n}" -gt 0 ]; } && break
    sleep 5
  done
  rule
  printf '  %-32s : %s\n' "pca:http_requests:rate" "$([ "${rate_n}" -gt 0 ] && echo "present ($(first_value 'pca:http_requests:rate'))" || echo 'EMPTY')"
  printf '  %-32s : %s\n' "pca:head_series:deriv"  "$([ "${deriv_n}" -gt 0 ] && echo "present ($(first_value 'pca:head_series:deriv'))" || echo 'EMPTY')"
  rule
  if [ "${rate_n}" -gt 0 ] && [ "${deriv_n}" -gt 0 ]; then
    ok "PASS — both rate() and deriv() now return data. You repaired the window/interval relationship."
  else
    err "FAIL — still empty. Widen the range window (>= 4 x scrape_interval) or shorten scrape_interval, then reload and re-check."
    exit 1
  fi
}

do_status() {
  prom_running || { err "Lab Prometheus is not running."; exit 1; }
  rule
  printf '  scrape_interval  : %s\n' "$(grep -E 'scrape_interval:' "${CFG}" | head -n1 | awk '{print $2}')"
  printf '  rule window      : %s\n' "$(grep -Eo '\[[0-9]+[smhd]\]' "${RULES}" | head -n1)"
  rule
  for q in \
    'sum(rate(prometheus_http_requests_total[5m]))' \
    'sum(irate(prometheus_http_requests_total[5m]))' \
    'sum(increase(prometheus_http_requests_total[5m]))' \
    'deriv(prometheus_tsdb_head_series[5m])' \
    'predict_linear(prometheus_tsdb_head_series[10m], 3600)' \
    'pca:http_requests:rate' \
    'pca:head_series:deriv'
  do
    printf '  %-56s = %s\n' "${q}" "$(first_value "${q}")"
  done
  rule
}

do_reset() {
  command -v prometheus >/dev/null 2>&1 || export PATH="${LAB_DIR}/bin:${PATH}"
  msg "Restoring a known-good state (this reveals the answer): window ${BROKEN_RULE_WINDOW} -> ${GOOD_RULE_WINDOW}"
  render_config "${BROKEN_SCRAPE_INTERVAL}"     # scrape stays 30s ...
  render_rules  "${GOOD_RULE_WINDOW}"           # ... window widened to 2m (>= 4 x 30s)
  if prom_running; then
    curl -sf -X POST "http://${PROM_ADDR}/-/reload" >/dev/null && ok "Reloaded." || { start_prom; }
  else
    start_prom; wait_for_samples
  fi
  ok "Known-good config applied. Run: ./${SELF} check"
}

do_clean() { stop_prom; msg "Removing ${LAB_DIR}"; rm -rf "${LAB_DIR}"; ok "Lab removed."; }

usage() {
  sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
case "${1:-break}" in
  break)  do_break  ;;
  check)  do_check  ;;
  status) do_status ;;
  reset)  do_reset  ;;
  stop)   stop_prom; ok "Stopped." ;;
  clean)  do_clean  ;;
  -h|--help|help) usage ;;
  *) err "unknown subcommand: $1"; usage; exit 2 ;;
esac

# =========================================================================== #
# ============================  SOLUTION (spoiler)  ========================== #
# =========================================================================== #
#
# SYMPTOM RECAP
#   * Grafana panel / the recording rules 'pca:http_requests:rate' and
#     'pca:head_series:deriv' show "No data".
#   * rate(prometheus_http_requests_total[15s]) -> empty vector
#     BUT rate(prometheus_http_requests_total[5m]) -> a real number.
#   * No error anywhere. An empty range vector is silent.
#
# ROOT CAUSE
#   rate(), irate(), increase(), delta(), idelta(), deriv() and predict_linear()
#   all consume a RANGE VECTOR (metric[window]) and need >= 2 samples inside that
#   window to compute anything. Samples land once per scrape_interval. The lab
#   scrape_interval is 30s, so a [15s] window holds at most ONE sample -> no pair
#   of points -> the function yields nothing (empty), which downstream reads as
#   "No data". The wide [5m] window works precisely because it spans several
#   scrapes. The metric was never the problem; the window was.
#
# STEP-BY-STEP FIX  (recommended: widen the window per query — scrape_interval is
#                    a fleet-wide cost decision, not something to shrink per graph)
#
#   1. Confirm the resolution you are working against:
#        grep scrape_interval ${LAB_DIR:-$HOME/pca-lab-1.2-rates}/prometheus.yml
#        # -> scrape_interval: 30s
#
#   2. Edit the rules file and widen BOTH windows to >= 4 x scrape_interval.
#      30s * 4 = 120s, so use [2m]:
#        # in rates.rules.yml
#        - record: pca:http_requests:rate
#          expr: sum(rate(prometheus_http_requests_total[2m]))
#        - record: pca:head_series:deriv
#          expr: deriv(prometheus_tsdb_head_series[2m])
#
#   3. Validate before loading it (never reload an unparsed rules file):
#        promtool check rules ${LAB_DIR:-$HOME/pca-lab-1.2-rates}/rates.rules.yml
#        # -> SUCCESS: 2 rules found
#
#   4. Hot-reload without restarting (needs --web.enable-lifecycle, already set):
#        curl -X POST http://127.0.0.1:9099/-/reload
#
#   5. Wait one 15s evaluation cycle, then grade:
#        ./rates_and_derivatives_breakfix.sh check
#        # -> PASS — both rate() and deriv() now return data.
#
# ALTERNATIVE FIX (shrink the resolution instead of widening the window)
#   Edit prometheus.yml:  scrape_interval: 30s  ->  5s   (a [15s] window now holds
#   3 samples), then reload and re-check. This also passes, but in production you
#   normally keep scrape_interval stable and tune the window per query, because
#   scrape frequency multiplies storage and target load across the whole fleet.
#
# GOING DEEPER (what the exam wants you to distinguish)
#   * rate()  = per-second AVERAGE over the window; smooths spikes; use in alerts
#               and dashboards. Handles counter resets automatically.
#   * irate() = per-second INSTANT rate from only the last two samples; twitchy;
#               use for fast-moving graphs, never for slow-moving alert thresholds.
#   * increase(metric[w]) == rate(metric[w]) * w ; the raw growth over the window.
#   * rate/irate/increase are for COUNTERS only. Applying them to a gauge is
#     meaningless (they assume monotonic-up-with-resets).
#   * deriv()  = per-second slope of a GAUGE via least-squares linear regression.
#   * predict_linear(gauge[w], t) extrapolates that regression t seconds ahead —
#     the classic "disk full in 4h" alert:
#        predict_linear(node_filesystem_avail_bytes[6h], 4*3600) < 0
#   * delta()/idelta() are the gauge analogues of increase()/irate difference.
#   In every one of these, the same trap applies: window < 2 x scrape_interval
#   => empty vector. Aim for window >= 4 x scrape_interval for resilience to a
#   missed scrape.
#
# CLEAN UP
#   ./rates_and_derivatives_breakfix.sh stop     # leave data, stop the process
#   ./rates_and_derivatives_breakfix.sh clean    # remove ${LAB_DIR} entirely
# =========================================================================== #