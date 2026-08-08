#!/usr/bin/env bash
#
# ==============================================================================
#  PCA — Prometheus Certified Associate
#  Domain 1: Observability Concepts  ·  Topic 1.6: Histograms  (exam weight: 4)
#  BREAK & FIX LAB — self-contained, disposable-VM only
# ==============================================================================
#
#  WHAT THIS TEACHES
#  -----------------
#  A Prometheus histogram is a single logical metric exposed as several time
#  series:
#      <name>_bucket{le="<upper_bound>"}   cumulative counters, one per bucket
#      <name>_sum                          running sum of all observed values
#      <name>_count   == _bucket{le="+Inf"} total number of observations
#  You never read a percentile off a histogram directly — you *estimate* it at
#  query time with histogram_quantile(), which does linear interpolation across
#  the buckets. For that interpolation to work, the input vector MUST still
#  carry the `le` label, because `le` IS the x-axis of the distribution.
#
#  The single most common production mistake with histograms — and a classic
#  PCA exam trap — is aggregating the buckets in a way that DROPS the `le`
#  label before feeding them to histogram_quantile(). This lab ships a p95
#  recording rule that does exactly that, so you can see, diagnose and fix it.
#
#  SAFETY
#  ------
#  Everything lives under a single throwaway directory and either one Docker
#  container or two background processes. It binds only to 127.0.0.1, writes
#  nothing outside ${LAB_DIR}, and is fully reversible with `teardown`.
#  Run it on a DISPOSABLE lab VM, never on a shared or production host.
#
#  USAGE
#  -----
#      ./lab_1.6_histograms.sh setup      # provision the BROKEN lab (default)
#      ./lab_1.6_histograms.sh check      # print the current symptom
#      ./lab_1.6_histograms.sh teardown   # stop everything
#      ./lab_1.6_histograms.sh teardown --purge   # stop and delete ${LAB_DIR}
#
#  Requirements: bash, curl, python3, and EITHER docker OR outbound internet
#  (to download a pinned Prometheus binary). tar is needed for the binary path.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-/tmp/pca-1.6-histograms-lab}"
EXPORTER_PORT="${EXPORTER_PORT:-9101}"
PROM_PORT="${PROM_PORT:-9090}"
PROM_VERSION="${PROM_VERSION:-2.53.2}"
CONTAINER_NAME="pca-1.6-prom"

msg()  { printf '\033[1;36m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ------------------------------------------------------------------------------
# File generators (exporter + Prometheus config + the BUGGED rule)
# ------------------------------------------------------------------------------
write_exporter() {
  # Pure-stdlib exporter: a background thread continuously "observes" simulated
  # request durations into a live cumulative histogram and serves /metrics.
  # No pip install, no client library — just Python 3.
  cat >"${LAB_DIR}/exporter.py" <<'PYEOF'
import os, random, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT   = int(os.environ.get("EXPORTER_PORT", "9101"))
LES    = [0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]     # finite bucket upper bounds
LABELS = ["0.1", "0.25", "0.5", "1", "2.5", "5", "10"]

lock = threading.Lock()
cum  = [0] * len(LES)   # cumulative counter per finite bucket: obs with d <= le
inf  = 0                # +Inf bucket == total observations == _count
ssum = 0.0              # _sum

def observe(d):
    global inf, ssum
    with lock:
        inf  += 1
        ssum += d
        for i, le in enumerate(LES):
            if d <= le:          # cumulative: increment this and every larger le
                cum[i] += 1

def generator():
    # Log-normal latency, median ~0.30s, p95 ~0.7s, with a rare slow tail.
    while True:
        for _ in range(40):
            d = random.lognormvariate(-1.2, 0.55)
            if random.random() < 0.02:
                d += random.uniform(1.0, 4.0)
            observe(d)
        time.sleep(0.1)

def render():
    with lock:
        out = [
            "# HELP http_request_duration_seconds Simulated HTTP request duration.",
            "# TYPE http_request_duration_seconds histogram",
        ]
        for i, lbl in enumerate(LABELS):
            out.append('http_request_duration_seconds_bucket{le="%s"} %d' % (lbl, cum[i]))
        out.append('http_request_duration_seconds_bucket{le="+Inf"} %d' % inf)
        out.append('http_request_duration_seconds_sum %r'   % ssum)
        out.append('http_request_duration_seconds_count %d' % inf)
        return "\n".join(out) + "\n"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/metrics"):
            body = render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"pca-1.6 histogram exporter — see /metrics\n")
    def log_message(self, *a):   # keep the lab quiet
        pass

if __name__ == "__main__":
    threading.Thread(target=generator, daemon=True).start()
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF
}

write_prometheus_config() {
  local rules_path="$1"
  cat >"${LAB_DIR}/prometheus.yml" <<YAMLEOF
global:
  scrape_interval: 2s
  evaluation_interval: 5s

rule_files:
  - "${rules_path}"

scrape_configs:
  - job_name: histograms-demo
    static_configs:
      - targets: ["127.0.0.1:${EXPORTER_PORT}"]
YAMLEOF
}

write_broken_rule() {
  # >>> THE INTENTIONAL BUG IS ON THE expr LINE BELOW <<<
  # sum(rate(..._bucket[1m])) collapses every bucket into ONE series and, in
  # doing so, discards the `le` label. histogram_quantile() then has no x-axis
  # to interpolate over and returns NaN for every evaluation.
  cat >"${LAB_DIR}/rules.yml" <<'YAMLEOF'
groups:
  - name: pca-1.6-histograms
    interval: 5s
    rules:
      - record: job:http_request_duration_seconds:p95
        expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])))
YAMLEOF
}

# ------------------------------------------------------------------------------
# Runtime backends: Docker (preferred) or downloaded binary (fallback)
# ------------------------------------------------------------------------------
have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

start_exporter() {
  EXPORTER_PORT="${EXPORTER_PORT}" nohup python3 "${LAB_DIR}/exporter.py" \
    >"${LAB_DIR}/exporter.log" 2>&1 &
  echo $! >"${LAB_DIR}/exporter.pid"
  msg "exporter running on http://127.0.0.1:${EXPORTER_PORT}/metrics (pid $(cat "${LAB_DIR}/exporter.pid"))"
}

start_prometheus_docker() {
  write_prometheus_config "/etc/prometheus/rules.yml"
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${CONTAINER_NAME}" --network host \
    -v "${LAB_DIR}/prometheus.yml":/etc/prometheus/prometheus.yml \
    -v "${LAB_DIR}/rules.yml":/etc/prometheus/rules.yml \
    "prom/prometheus:v${PROM_VERSION}" \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --web.console.libraries=/usr/share/prometheus/console_libraries \
    --web.console.templates=/usr/share/prometheus/consoles \
    --web.listen-address=127.0.0.1:${PROM_PORT} \
    --web.enable-lifecycle >/dev/null
  echo "docker" >"${LAB_DIR}/mode"
  msg "Prometheus (docker: ${CONTAINER_NAME}) on http://127.0.0.1:${PROM_PORT}"
}

start_prometheus_binary() {
  need tar
  local os="linux" arch
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
  local dist="prometheus-${PROM_VERSION}.${os}-${arch}"
  if [ ! -x "${LAB_DIR}/${dist}/prometheus" ]; then
    msg "downloading ${dist} ..."
    curl -fsSL -o "${LAB_DIR}/prom.tar.gz" \
      "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${dist}.tar.gz"
    tar -xzf "${LAB_DIR}/prom.tar.gz" -C "${LAB_DIR}"
  fi
  write_prometheus_config "${LAB_DIR}/rules.yml"
  nohup "${LAB_DIR}/${dist}/prometheus" \
    --config.file="${LAB_DIR}/prometheus.yml" \
    --storage.tsdb.path="${LAB_DIR}/data" \
    --web.listen-address=127.0.0.1:${PROM_PORT} \
    --web.enable-lifecycle \
    >"${LAB_DIR}/prometheus.log" 2>&1 &
  echo $! >"${LAB_DIR}/prometheus.pid"
  echo "binary" >"${LAB_DIR}/mode"
  msg "Prometheus (binary, pid $(cat "${LAB_DIR}/prometheus.pid")) on http://127.0.0.1:${PROM_PORT}"
}

# ------------------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------------------
cmd_setup() {
  need curl; need python3
  mkdir -p "${LAB_DIR}"
  warn "Disposable-VM lab. It writes only under ${LAB_DIR} and binds to 127.0.0.1."

  write_exporter
  write_broken_rule
  start_exporter

  if have_docker; then
    start_prometheus_docker
  else
    warn "docker not usable — falling back to a downloaded Prometheus binary."
    start_prometheus_binary
  fi

  msg "waiting for Prometheus to come up and scrape a few times ..."
  for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null 2>&1 && break
    sleep 1
  done
  sleep 8   # let rate(...[1m]) and the recording rule accumulate real samples

  cat <<EOF

================================================================================
  THE BREAK — what has been staged for you
================================================================================
A working histogram is being scraped, and a recording rule is meant to publish
its 95th-percentile latency as:

      job:http_request_duration_seconds:p95

That rule is broken on purpose.

--------------------------------------------------------------------------------
  SYMPTOM you will observe
--------------------------------------------------------------------------------
  * Open http://127.0.0.1:${PROM_PORT} and graph  job:http_request_duration_seconds:p95
    -> the panel shows "No datapoints" / a flat gap, or a value of NaN.
  * Yet the raw histogram is perfectly healthy and its buckets ARE increasing:
        http_request_duration_seconds_bucket        (has many series, one per le)
        rate(http_request_duration_seconds_count[1m]) > 0
  * And this query DOES return a sane number (~0.5–1s):
        histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[1m]))
  So the data is fine — the p95 rule specifically produces NaN.

--------------------------------------------------------------------------------
  YOUR GOAL
--------------------------------------------------------------------------------
  Make  job:http_request_duration_seconds:p95  evaluate to a finite value
  (roughly 0.5–1.0 seconds) WITHOUT changing the exporter, the buckets, or the
  0.95 quantile. Edit only the rule expression, reload Prometheus, and confirm.

  Reload after editing:  curl -X POST http://127.0.0.1:${PROM_PORT}/-/reload
  Re-check the symptom:  $0 check

  Rule file to edit:     ${LAB_DIR}/rules.yml
  (Ask yourself: what label does histogram_quantile() need on its input, and
   which part of the current expression throws that label away?)
================================================================================
EOF
}

cmd_check() {
  need curl
  echo "--- Is the raw histogram healthy? (expect a count of bucket series > 0) ---"
  curl -s -G "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
    --data-urlencode 'query=count(http_request_duration_seconds_bucket)'
  echo
  echo "--- Does a CORRECT ad-hoc p95 work? (expect a finite value ~0.5-1) ---"
  curl -s -G "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
    --data-urlencode 'query=histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[1m])))'
  echo
  echo "--- The recording rule under test (BROKEN -> value \"NaN\" or empty) ---"
  curl -s -G "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
    --data-urlencode 'query=job:http_request_duration_seconds:p95'
  echo
  echo
  echo "Interpretation: buckets present + ad-hoc p95 finite, but the rule NaN"
  echo "=> the bug is in HOW the rule aggregates the buckets, not in the data."
}

cmd_teardown() {
  if [ -f "${LAB_DIR}/mode" ] && [ "$(cat "${LAB_DIR}/mode")" = "docker" ]; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
  for p in prometheus exporter; do
    if [ -f "${LAB_DIR}/${p}.pid" ]; then
      kill "$(cat "${LAB_DIR}/${p}.pid")" >/dev/null 2>&1 || true
      rm -f "${LAB_DIR}/${p}.pid"
    fi
  done
  msg "lab stopped."
  if [ "${1:-}" = "--purge" ]; then
    rm -rf "${LAB_DIR}"
    msg "purged ${LAB_DIR}."
  else
    msg "files kept under ${LAB_DIR} (use 'teardown --purge' to delete them)."
  fi
}

case "${1:-setup}" in
  setup)    cmd_setup ;;
  check)    cmd_check ;;
  teardown) cmd_teardown "${2:-}" ;;
  *) die "unknown command '${1}'. Use: setup | check | teardown [--purge]" ;;
esac

# ==============================================================================
#  SOLUTION — step by step   (try the fix yourself before reading this)
# ==============================================================================
#
#  ROOT CAUSE
#  ----------
#  The broken rule is:
#
#      histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])))
#                                ^^^^ aggregates WITHOUT `by (le)`
#
#  histogram_quantile(φ, v) reconstructs a percentile by interpolating across
#  the cumulative buckets of `v`. It identifies the buckets purely by their
#  `le` label — `le` is the x-axis of the distribution. A plain sum() has no
#  `by (le)` clause, so Prometheus sums every bucket series into ONE result
#  series and drops all labels, including `le`. The function is then handed a
#  single labelless value with no bucket structure to interpolate over, so it
#  returns NaN for every evaluation. The raw data was never the problem: the
#  buckets exist and increase, but the AGGREGATION destroyed the one dimension
#  the function depends on.
#
#  (Two related failures worth knowing for the exam, same family of bug:
#     - Any aggregation before histogram_quantile — sum, avg, max — must keep
#       `le`: always `sum by (le) (...)`, `sum without (instance,pod) (...)`, etc.
#     - The classic pattern is  histogram_quantile(φ, sum by (le) (rate(x_bucket[5m]))).
#       You need rate() because _bucket are counters; you need `by (le)` because
#       the quantile is computed per bucket; and never sum()/avg() two already
#       computed quantiles — average of p95s is not a p95.)
#
#  THE FIX
#  -------
#  Preserve the `le` label through the aggregation:
#
#      # ${LAB_DIR}/rules.yml
#      groups:
#        - name: pca-1.6-histograms
#          interval: 5s
#          rules:
#            - record: job:http_request_duration_seconds:p95
#              expr: histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[1m])))
#              #                                    ^^^^^^ the fix: keep the le dimension
#
#  STEPS
#  -----
#    1. Reproduce the symptom first, so you know the baseline:
#         ./lab_1.6_histograms.sh check
#       -> raw buckets present, ad-hoc `sum by (le)` p95 finite, RULE = NaN.
#
#    2. Edit the rule file and add `by (le)` to the inner aggregation:
#         sed -i 's/sum(rate(/sum by (le) (rate(/' "${LAB_DIR}/rules.yml"
#       (or edit ${LAB_DIR}/rules.yml by hand).
#
#    3. Hot-reload Prometheus (no restart, no data loss):
#         curl -X POST "http://127.0.0.1:${PROM_PORT}/-/reload"
#       Confirm the rule loaded and is healthy at:
#         http://127.0.0.1:${PROM_PORT}/rules      (State should be "ok")
#
#    4. Wait one evaluation_interval (~5s) so the rule fires, then verify:
#         ./lab_1.6_histograms.sh check
#       job:http_request_duration_seconds:p95 now returns a finite value
#       (~0.5–1.0s), matching the ad-hoc query. Symptom resolved.
#
#    5. Clean up when finished:
#         ./lab_1.6_histograms.sh teardown --purge
#
#  WHY THE FIX IS CORRECT (and not just "it stopped being NaN")
#  ------------------------------------------------------------
#  `sum by (le)` sums the per-target/per-series rates within each bucket while
#  KEEPING one output series per `le` value. histogram_quantile() again sees a
#  full set of cumulative buckets (le="0.1" ... le="+Inf"), finds the bucket
#  where the 95th percentile falls, and linearly interpolates within it. The
#  result equals the ad-hoc query in step 3 because both feed the function the
#  same le-labelled bucket vector — we changed only the aggregation, never the
#  data, the buckets, or the quantile.
#
#  SOURCES (official)
#  ------------------
#    - histogram_quantile() reference and the `le`-label requirement:
#      https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile
#    - Histograms & summaries best practices (aggregation, bucket choice, rate):
#      https://prometheus.io/docs/practices/histograms/
#    - Metric types (histogram exposition: _bucket/_sum/_count, +Inf):
#      https://prometheus.io/docs/concepts/metric_types/#histogram
#    - Recording rules and hot reload (/-/reload, --web.enable-lifecycle):
#      https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
#      https://prometheus.io/docs/prometheus/latest/management_api/
#    - PCA curriculum (Domain 1 — Observability Concepts, Histograms):
#      https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
# ==============================================================================