#!/usr/bin/env bash
#
# ============================================================================
#  PCA — Prometheus Certified Associate
#  Domain: PromQL  |  Topic 1.3: Aggregating over time  (exam weight: 4)
#  Reference: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#  Docs:
#    - https://prometheus.io/docs/prometheus/latest/querying/functions/#rate
#    - https://prometheus.io/docs/prometheus/latest/querying/basics/#range-vector-selectors
#    - https://prometheus.io/docs/practices/rules/
#
#  BREAK & FIX lab — self-contained.
#  This script stands up an ISOLATED, throwaway Prometheus instance in its own
#  directory and on its own port, then plants ONE deliberate defect in a
#  recording rule that aggregates a counter over time. Nothing on the system
#  service manager, /etc, or any existing Prometheus is touched.
#
#  Run ONLY on a disposable lab VM.
#
#  Usage:
#     PCA_LAB=1 ./break-fix_pca_1.3_aggregating-over-time.sh          # plant the break
#     ./break-fix_pca_1.3_aggregating-over-time.sh clean              # tear the lab down
#
#  The full, step-by-step solution is at the very bottom of this file,
#  commented out. Try to solve it yourself before reading it.
# ============================================================================

set -euo pipefail

# ------------------------------- configuration ------------------------------
PROM_VERSION="${PROM_VERSION:-2.53.5}"     # LTS line; pinned for reproducibility
LAB_DIR="${LAB_DIR:-${HOME}/pca-lab-1.3}"
LAB_PORT="${LAB_PORT:-9099}"               # non-default port to avoid clashes
BIN_DIR="${LAB_DIR}/bin"
DATA_DIR="${LAB_DIR}/data"
CONFIG="${LAB_DIR}/prometheus.yml"
RULES="${LAB_DIR}/rules.yml"
LOGFILE="${LAB_DIR}/prometheus.log"
PIDFILE="${LAB_DIR}/prometheus.pid"
BASE_URL="http://localhost:${LAB_PORT}"

# --------------------------------- helpers ----------------------------------
say()  { printf '%s\n' "$*"; }
info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"; }

confirm_lab() {
  # Refuse to run unless the operator has flagged this as a throwaway VM.
  if [[ "${PCA_LAB:-0}" != "1" && "${1:-}" != "--yes" ]]; then
    cat >&2 <<EOF
This script intentionally breaks a Prometheus recording rule for training.
It is meant for a DISPOSABLE lab VM only.

Re-run with:   PCA_LAB=1 $0
        or:    $0 --yes
EOF
    exit 2
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

stop_lab() {
  if [[ -f "${PIDFILE}" ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    info "Stopping previous lab Prometheus (pid $(cat "${PIDFILE}"))"
    kill "$(cat "${PIDFILE}")" 2>/dev/null || true
    sleep 1
  fi
  rm -f "${PIDFILE}"
}

# ---------------------------- prometheus binary -----------------------------
ensure_prometheus() {
  # Prefer an already-installed binary; otherwise fetch a pinned release and
  # verify its published SHA256 checksum before trusting it.
  if command -v prometheus >/dev/null 2>&1 && command -v promtool >/dev/null 2>&1; then
    ok "Using system prometheus/promtool from PATH"
    PROM_BIN="$(command -v prometheus)"
    PROMTOOL_BIN="$(command -v promtool)"
    return
  fi

  PROM_BIN="${BIN_DIR}/prometheus"
  PROMTOOL_BIN="${BIN_DIR}/promtool"
  if [[ -x "${PROM_BIN}" && -x "${PROMTOOL_BIN}" ]]; then
    ok "Using previously downloaded prometheus in ${BIN_DIR}"
    return
  fi

  need curl; need tar; need sha256sum
  local arch os tarball url base sums
  arch="$(detect_arch)"; os="linux"
  base="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}"
  tarball="prometheus-${PROM_VERSION}.${os}-${arch}.tar.gz"
  url="${base}/${tarball}"
  sums="${base}/sha256sums.txt"

  info "Downloading Prometheus ${PROM_VERSION} (${os}-${arch})"
  mkdir -p "${BIN_DIR}"
  ( cd "${BIN_DIR}"
    curl -fsSL -o "${tarball}" "${url}"
    curl -fsSL -o sha256sums.txt "${sums}"
    grep " ${tarball}\$" sha256sums.txt | sha256sum -c - \
      || die "Checksum verification failed for ${tarball}"
    tar -xzf "${tarball}"
    cp "prometheus-${PROM_VERSION}.${os}-${arch}/prometheus" prometheus
    cp "prometheus-${PROM_VERSION}.${os}-${arch}/promtool"   promtool
    chmod +x prometheus promtool
  )
  ok "Prometheus binary verified and installed in ${BIN_DIR}"
}

# ------------------------------ lab artifacts -------------------------------
write_config() {
  # Prometheus scrapes ITSELF. The scrape_interval (30s) is the load-bearing
  # number for this lab: the planted defect only makes sense relative to it.
  cat > "${CONFIG}" <<EOF
global:
  scrape_interval: 30s        # a sample of every series lands every 30 seconds
  evaluation_interval: 15s

rule_files:
  - ${RULES}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:${LAB_PORT}']
EOF
}

write_broken_rules() {
  # =====================  THE DELIBERATE DEFECT  ==========================
  # prometheus_http_requests_total is a COUNTER. To turn it into a per-second
  # request rate you feed a RANGE VECTOR to rate(). rate() needs at least TWO
  # samples inside that range window to compute a slope.
  #
  # Here the range is [15s] while the scrape_interval is 30s. Samples are 30s
  # apart, so a 15-second-wide window can never contain two of them. rate()
  # therefore has nothing to differentiate and yields an EMPTY result — and so
  # the recording rule below never produces a single data point.
  # ========================================================================
  cat > "${RULES}" <<'EOF'
groups:
  - name: pca_lab_aggregation_over_time
    interval: 15s
    rules:
      - record: job:prometheus_http_requests:rate2m
        expr: rate(prometheus_http_requests_total[15s])
EOF
}

start_prometheus() {
  mkdir -p "${DATA_DIR}"
  info "Starting isolated Prometheus on ${BASE_URL}"
  # --web.enable-lifecycle lets the student hot-reload after fixing the rule.
  nohup "${PROM_BIN}" \
    --config.file="${CONFIG}" \
    --storage.tsdb.path="${DATA_DIR}" \
    --web.listen-address="0.0.0.0:${LAB_PORT}" \
    --web.enable-lifecycle \
    >"${LOGFILE}" 2>&1 &
  echo $! > "${PIDFILE}"
  sleep 3
  kill -0 "$(cat "${PIDFILE}")" 2>/dev/null \
    || die "Prometheus failed to start — see ${LOGFILE}"
  ok "Prometheus is up (pid $(cat "${PIDFILE}"))"
}

demonstrate_symptom() {
  # Give the counter a little traffic so the FIXED query later has something to
  # show, then prove the broken query is empty right now.
  info "Generating a few HTTP requests against the API..."
  for _ in 1 2 3 4 5; do curl -fsS "${BASE_URL}/-/ready" >/dev/null 2>&1 || true; done

  info "Querying the broken recording rule output..."
  local q result
  q="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' \
        "job:prometheus_http_requests:rate2m" 2>/dev/null || echo "job:prometheus_http_requests:rate2m")"
  result="$(curl -fsS "${BASE_URL}/api/v1/query?query=${q}" 2>/dev/null || true)"
  say "  GET /api/v1/query?query=job:prometheus_http_requests:rate2m"
  say "  -> ${result:-<no response>}"
  say "  (expect \"result\":[] — an empty vector: the rule produced nothing)"
}

briefing() {
  cat <<EOF

============================================================================
 PCA 1.3 — AGGREGATING OVER TIME  ::  BREAK & FIX
============================================================================

WHAT WAS BROKEN
  A recording rule that is supposed to expose the per-second HTTP request rate
  of Prometheus has been planted with a subtle defect. The rule loads without
  error and Prometheus is perfectly healthy — but the rule's output series is
  permanently empty.

WHERE THINGS LIVE
  Config file .......... ${CONFIG}
  Rules file ........... ${RULES}
  Prometheus UI ........ ${BASE_URL}
  Logs ................. ${LOGFILE}

THE SYMPTOM YOU WILL SEE
  Open ${BASE_URL}/graph and run each of these:

    1)  job:prometheus_http_requests:rate2m
          -> "Empty query result"      (the recording rule never fires values)

    2)  rate(prometheus_http_requests_total[15s])
          -> "Empty query result"      (the raw expression is empty too)

    3)  prometheus_http_requests_total
          -> returns data normally      (the counter itself is FINE)

  So the metric exists and increases, yet aggregating it over time gives you
  nothing. That contrast is the whole clue.

YOUR GOAL
  Make the recording rule "job:prometheus_http_requests:rate2m" return a
  non-empty result — a real per-second rate — WITHOUT changing the scrape
  interval and WITHOUT touching the counter itself. Fix it where the mistake
  actually is: the time aggregation.

HINTS
  * rate(), like every _over_time / range function, operates on a RANGE VECTOR
    selected with [<duration>]. Ask: how many samples of this series fall
    inside that window?
  * rate() and increase() need at least TWO samples in the range to compute a
    slope. What is the scrape_interval? What is the range in the rule?
  * Prometheus best practice: make the range at least 4x the scrape_interval
    so a rate survives one missed scrape.
  * Validate before reloading:   ${PROMTOOL_BIN} check rules ${RULES}
  * Hot-reload without restart:   curl -X POST ${BASE_URL}/-/reload
  * After a fix, wait ~2-3 scrape intervals so enough samples accumulate.

WHEN YOU ARE STUCK
  The complete step-by-step solution is at the bottom of this script file,
  commented out. Read the script, not just the terminal.

TEAR DOWN
  $0 clean
============================================================================
EOF
}

clean_lab() {
  stop_lab
  info "Removing lab directory ${LAB_DIR}"
  rm -rf "${LAB_DIR}"
  ok "Lab removed."
}

# ---------------------------------- main ------------------------------------
main() {
  case "${1:-}" in
    clean) clean_lab; exit 0 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
  esac

  confirm_lab "${1:-}"
  need curl
  mkdir -p "${LAB_DIR}"
  stop_lab
  ensure_prometheus
  write_config
  write_broken_rules
  info "Validating the (intentionally flawed but syntactically valid) rule..."
  "${PROMTOOL_BIN}" check rules "${RULES}" || warn "promtool reported an issue"
  start_prometheus
  demonstrate_symptom
  briefing
}

main "$@"

# ============================================================================
#  SOLUTION  —  step by step  (do not peek until you have tried)
# ============================================================================
#
#  ROOT CAUSE
#  ----------
#  The recording rule computed:
#
#        rate(prometheus_http_requests_total[15s])
#
#  with a global scrape_interval of 30s. rate() differentiates a counter across
#  the samples that fall inside its range window. A 15-second window over a
#  series sampled every 30 seconds contains at most ONE sample, and rate()
#  needs at least TWO to draw a line between them. With fewer than two points it
#  returns nothing, so the recorded series job:prometheus_http_requests:rate2m
#  is empty forever. The counter is healthy; the *time aggregation window* was
#  simply too small for the data's resolution.
#
#  This is the single most common PromQL mistake around "aggregating over time":
#  the range in [ ] must be sized relative to how often the series is scraped,
#  not chosen arbitrarily.
#
#  THE FIX
#  -------
#  Widen the range to at least 4x the scrape_interval. With a 30s scrape, use
#  [2m] (four samples) — the value that makes the rule name "rate2m" honest.
#
#  1) Edit the rules file:
#
#         $EDITOR "${LAB_DIR}/rules.yml"
#
#     Change the expr line from:
#
#         expr: rate(prometheus_http_requests_total[15s])
#
#     to:
#
#         expr: rate(prometheus_http_requests_total[2m])
#
#     The corrected file:
#
#         groups:
#           - name: pca_lab_aggregation_over_time
#             interval: 15s
#             rules:
#               - record: job:prometheus_http_requests:rate2m
#                 expr: rate(prometheus_http_requests_total[2m])
#
#  2) Validate the rule syntax/semantics before applying it:
#
#         "${LAB_DIR}/bin/promtool" check rules "${LAB_DIR}/rules.yml"
#         # (or system promtool)  ->  SUCCESS: 1 rule found
#
#  3) Hot-reload Prometheus (no restart, no data loss):
#
#         curl -X POST "${BASE_URL}/-/reload"
#
#     Confirm the reload was accepted (HTTP 200) and check the log tail:
#
#         tail -n 20 "${LAB_DIR}/prometheus.log"
#
#  4) Wait ~2-3 scrape intervals (about 60-90s) so at least two samples land
#     inside the new 2m window, then verify:
#
#         # raw expression now has data
#         curl -s "${BASE_URL}/api/v1/query?query=rate(prometheus_http_requests_total%5B2m%5D)"
#
#         # the recording rule output is now populated
#         curl -s "${BASE_URL}/api/v1/query?query=job:prometheus_http_requests:rate2m"
#
#     Both should return "status":"success" with a non-empty "result" array.
#     In the UI, ${BASE_URL}/graph, the series now plots a real per-second rate.
#
#  WHY 4x, AND THE BROADER TOPIC
#  -----------------------------
#  Prometheus recommends a range of at least 4x the scrape_interval so that a
#  rate/increase still has two usable samples even if one scrape is missed.
#  This same "how many samples fall in the window" reasoning governs the entire
#  aggregating-over-time family you are tested on:
#
#    * Counter-rate functions (need >=2 samples in range):
#        rate()      per-second average rate, extrapolated, counter-reset aware
#        irate()     per-second rate from the LAST two samples (spiky, alerting)
#        increase()  total increase over the range (= rate() * range seconds)
#        delta(), idelta(), deriv()   for GAUGES, not counters
#
#    * The <aggregation>_over_time() functions collapse a range vector of a
#      SINGLE series into one value per series over time (these work with a
#      single sample too):
#        avg_over_time, min_over_time, max_over_time, sum_over_time,
#        count_over_time, last_over_time, present_over_time,
#        quantile_over_time, stddev_over_time, stdvar_over_time
#
#  Do not confuse the two axes:
#    - _over_time() aggregates ONE series ACROSS TIME (the range in [ ]).
#    - sum()/avg()/max() by (...) aggregate ACROSS SERIES at one instant.
#  And never invert the order for counters: always rate() FIRST, then sum() —
#  i.e. sum(rate(x[5m])), never rate(sum(x)[5m]) — because summing counters
#  hides individual resets.
#
#  Sources:
#    https://prometheus.io/docs/prometheus/latest/querying/functions/
#    https://prometheus.io/docs/practices/rules/
#    https://prometheus.io/docs/prometheus/latest/querying/basics/#range-vector-selectors
# ============================================================================