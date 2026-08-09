#!/usr/bin/env bash
#
# ==============================================================================
#  PCA 2.3 — Understanding Prometheus Limitations
#  Break & Fix lab: the cardinality explosion
# ==============================================================================
#
#  WHAT THIS TEACHES
#  -----------------
#  Prometheus keeps the *head block* of its TSDB — every currently-active time
#  series — in RAM. A time series is uniquely identified by its metric name plus
#  the full set of label key/value pairs. So a single label whose value is
#  unbounded (a user id, a request id, an email, a full URL with query string,
#  a container id) multiplies your series count without limit. This is one of
#  the defining LIMITATIONS of Prometheus: it is a metrics system, not an event
#  or logging store, and it does not scale to high-cardinality data. One small,
#  misbehaving target can drive a single Prometheus node into memory pressure,
#  slow queries and eventual OOM. Horizontal scale / durable long-term storage
#  is explicitly out of scope for core Prometheus (that is what remote-write to
#  Thanos / Cortex / Mimir exists for).
#
#  This lab stands up an ISOLATED Prometheus (its own dir, its own ports — it
#  never touches a system install) scraping a deliberately broken exporter that
#  emits a per-user counter. You will see the head-series count and scrape
#  sample count explode. Your job is to bound the cardinality at ingestion and
#  hot-reload Prometheus WITHOUT taking the target down.
#
#  SAFE / DISPOSABLE: everything lives under $LAB_DIR and a couple of unprivileged
#  ports. `--cleanup` removes it all. Run it on a throwaway lab VM.
#
#  Official references (verify the claims yourself):
#    - Data model / what a series is:
#        https://prometheus.io/docs/concepts/data_model/
#    - Label CAUTION ("every unique combination ... is a new time series"):
#        https://prometheus.io/docs/practices/naming/#labels
#    - Instrumentation "do not overuse labels":
#        https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels
#    - metric_relabel_configs / sample_limit (scrape config):
#        https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
#        https://prometheus.io/docs/prometheus/latest/configuration/configuration/#metric_relabel_configs
#    - Local storage is NOT clustered / durable long-term storage:
#        https://prometheus.io/docs/prometheus/latest/storage/#operational-aspects
#    - PCA curriculum:
#        https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#
set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Configuration (override with env vars if you like)
# ------------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-$HOME/pca-lab-2.3}"
PROM_VERSION="${PROM_VERSION:-2.53.5}"      # used for download/container image
CARDINALITY="${CARDINALITY:-15000}"         # bounded on purpose so we do not OOM the VM
EXPORTER_PORT="${EXPORTER_PORT:-8000}"
PROM_PORT="${PROM_PORT:-9090}"
CONTAINER_PREFIX="pca-lab-2-3"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[lab]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[lab] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Pick a free TCP port starting from a base (never clobber an existing service)
# ------------------------------------------------------------------------------
port_free() {
  local p="$1"
  # /dev/tcp connect succeeds => something is listening => not free
  (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null && { exec 3>&- 3<&- ; return 1; }
  return 0
}
pick_port() {
  local p="$1" tries=0
  while ! port_free "$p"; do
    p=$((p + 1)); tries=$((tries + 1))
    [ "$tries" -gt 50 ] && die "could not find a free port near $1"
  done
  printf '%s' "$p"
}

# ------------------------------------------------------------------------------
# Teardown
# ------------------------------------------------------------------------------
cleanup_lab() {
  log "tearing down the lab..."
  local rt=""
  rt="$(command -v podman || command -v docker || true)"
  if [ -n "$rt" ]; then
    "$rt" rm -f "${CONTAINER_PREFIX}-prometheus" >/dev/null 2>&1 || true
  fi
  for pidf in "$LAB_DIR"/*.pid; do
    [ -e "$pidf" ] || continue
    kill "$(cat "$pidf")" >/dev/null 2>&1 || true
  done
  if [ -f "$LAB_DIR/prometheus.pid" ]; then
    kill "$(cat "$LAB_DIR/prometheus.pid")" >/dev/null 2>&1 || true
  fi
  rm -rf "$LAB_DIR"
  log "done. Lab directory $LAB_DIR removed."
}

# ------------------------------------------------------------------------------
# The broken exporter: a per-user request counter (unbounded label = the bug)
# ------------------------------------------------------------------------------
write_exporter() {
  cat > "$LAB_DIR/buggy_exporter.py" <<'PY'
#!/usr/bin/env python3
# A stand-in for a real application that made the classic instrumentation
# mistake: it puts a high-cardinality value (user_id) into a LABEL. Every
# distinct user becomes its own time series in Prometheus.
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CARD = int(os.environ.get("CARDINALITY", "15000"))
PORT = int(os.environ.get("EXPORTER_PORT", "8000"))

# Build the payload once (bounded + reproducible => safe, will not OOM the VM).
lines = []
lines.append("# HELP myapp_http_requests_total Requests, mislabelled per-user (THE BUG).")
lines.append("# TYPE myapp_http_requests_total counter")
for i in range(CARD):
    # user_id is unbounded in the real world -> one series per user, forever.
    lines.append(
        'myapp_http_requests_total{method="GET",path="/api",user_id="u%06d"} %d'
        % (i, (i % 7) + 1)
    )
# A correctly-instrumented, low-cardinality metric for contrast.
lines.append("# HELP myapp_up Whether the app is up (well-behaved metric).")
lines.append("# TYPE myapp_up gauge")
lines.append("myapp_up 1")
PAYLOAD = ("\n".join(lines) + "\n").encode()

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/metrics"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(PAYLOAD)
        else:
            self.send_response(200); self.end_headers()
            self.wfile.write(b"buggy exporter: GET /metrics\n")
    def log_message(self, *a):  # keep the terminal quiet
        pass

if __name__ == "__main__":
    print("buggy exporter serving %d series on 127.0.0.1:%d/metrics" % (CARD, PORT))
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
}

# ------------------------------------------------------------------------------
# Prometheus config: BROKEN state (scrapes the exporter with no guardrails)
# ------------------------------------------------------------------------------
write_broken_config() {
  cat > "$LAB_DIR/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  # Prometheus scraping itself (your baseline ~1.5-2k series).
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:${PROM_PORT}']

  # The buggy application. No sample_limit, no metric_relabel_configs:
  # Prometheus will happily ingest every per-user series. This is the break.
  - job_name: buggy-app
    static_configs:
      - targets: ['127.0.0.1:${EXPORTER_PORT}']
EOF
}

# ------------------------------------------------------------------------------
# Prometheus config: FIXED state (used only by `--solve`)
# ------------------------------------------------------------------------------
write_fixed_config() {
  cat > "$LAB_DIR/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:${PROM_PORT}']

  - job_name: buggy-app
    static_configs:
      - targets: ['127.0.0.1:${EXPORTER_PORT}']
    # Guardrail: fail the scrape LOUDLY (target DOWN) if a future cardinality
    # bomb slips through, instead of silently degrading the whole server.
    sample_limit: 5000
    # Bound cardinality at ingestion: metric_relabel_configs runs AFTER the
    # scrape and BEFORE storage, so dropping here means the series are never
    # written to the TSDB head at all.
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: myapp_http_requests_total
        action: drop
EOF
}

# ------------------------------------------------------------------------------
# Ensure a Prometheus runtime: prefer container -> native binary -> download
# Sets globals: PROM_MODE ("container"|"binary") and PROM_BIN / CONTAINER_RT
# ------------------------------------------------------------------------------
ensure_prometheus() {
  CONTAINER_RT="$(command -v podman || command -v docker || true)"
  if [ -n "$CONTAINER_RT" ]; then
    PROM_MODE="container"
    log "using container runtime: $CONTAINER_RT (image prom/prometheus:v${PROM_VERSION})"
    return
  fi
  if command -v prometheus >/dev/null 2>&1; then
    PROM_MODE="binary"; PROM_BIN="$(command -v prometheus)"
    log "using system prometheus binary: $PROM_BIN"
    return
  fi
  # Download the official static binary into the lab dir (trivial to clean up).
  local os arch
  os="linux"
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l)        arch="armv7" ;;
    *) die "unsupported arch $(uname -m); install prometheus or podman/docker" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "need curl to download prometheus"
  command -v tar  >/dev/null 2>&1 || die "need tar to unpack prometheus"
  local tarball="prometheus-${PROM_VERSION}.${os}-${arch}.tar.gz"
  local url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${tarball}"
  log "downloading $url"
  curl -fSL "$url" -o "$LAB_DIR/$tarball" || die "download failed (offline? set PROM_VERSION or install podman/docker)"
  tar -xzf "$LAB_DIR/$tarball" -C "$LAB_DIR"
  PROM_MODE="binary"
  PROM_BIN="$LAB_DIR/prometheus-${PROM_VERSION}.${os}-${arch}/prometheus"
  [ -x "$PROM_BIN" ] || die "prometheus binary not found after extract"
  log "using downloaded prometheus: $PROM_BIN"
}

start_prometheus() {
  mkdir -p "$LAB_DIR/data"
  if [ "$PROM_MODE" = "container" ]; then
    "$CONTAINER_RT" rm -f "${CONTAINER_PREFIX}-prometheus" >/dev/null 2>&1 || true
    "$CONTAINER_RT" run -d --name "${CONTAINER_PREFIX}-prometheus" \
      --network host \
      -v "$LAB_DIR":/lab:Z \
      "prom/prometheus:v${PROM_VERSION}" \
      --config.file=/lab/prometheus.yml \
      --storage.tsdb.path=/lab/data \
      --web.enable-lifecycle \
      --web.listen-address="127.0.0.1:${PROM_PORT}" >/dev/null \
      || die "failed to start prometheus container"
  else
    nohup "$PROM_BIN" \
      --config.file="$LAB_DIR/prometheus.yml" \
      --storage.tsdb.path="$LAB_DIR/data" \
      --web.enable-lifecycle \
      --web.listen-address="127.0.0.1:${PROM_PORT}" \
      >"$LAB_DIR/prometheus.log" 2>&1 &
    echo $! > "$LAB_DIR/prometheus.pid"
  fi
}

wait_ready() {
  local url="$1" name="$2" i
  for i in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then log "$name is up"; return 0; fi
    sleep 1
  done
  die "$name did not become ready ($url)"
}

# Convenience wrapper for instant-query the student will reuse.
promq() {
  curl -fsSG "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null
}

# ------------------------------------------------------------------------------
# Apply the reference fix (for `--solve`): rewrite config + hot reload.
# ------------------------------------------------------------------------------
solve_lab() {
  [ -d "$LAB_DIR" ] || die "no lab found — run the script with no args first"
  log "applying the reference fix (metric_relabel_configs drop + sample_limit)..."
  write_fixed_config
  curl -fsS -X POST "http://127.0.0.1:${PROM_PORT}/-/reload" \
    || die "reload failed (was prometheus started with --web.enable-lifecycle?)"
  sleep 7
  log "post-relabel sample count for buggy-app (target should be ~1, and STILL UP):"
  promq 'scrape_samples_post_metric_relabeling{job="buggy-app"}'; echo
  log "up{job=\"buggy-app\"} (must be 1 — we bounded cardinality, we did NOT drop the target):"
  promq 'up{job="buggy-app"}'; echo
  log "The 15k stale series age out of the TSDB head after ~5m; restart Prometheus to see head drop immediately."
}

# ==============================================================================
# main
# ==============================================================================
case "${1:-}" in
  --cleanup) [ -d "$LAB_DIR" ] && cleanup_lab || log "nothing to clean"; exit 0 ;;
  --solve)   solve_lab; exit 0 ;;
  -h|--help)
    cat <<H
PCA 2.3 break & fix lab.
  (no args)   set up the lab and BREAK it (cardinality explosion)
  --solve     apply the reference fix and verify
  --cleanup   stop everything and remove $LAB_DIR
Env: LAB_DIR CARDINALITY PROM_VERSION EXPORTER_PORT PROM_PORT
H
    exit 0 ;;
  "" ) : ;;
  * ) die "unknown option '$1' (see --help)" ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 is required for the exporter"
command -v curl    >/dev/null 2>&1 || die "curl is required"

log "PCA 2.3 — Understanding Prometheus Limitations :: cardinality explosion"
mkdir -p "$LAB_DIR"

# Never step on an already-listening port.
EXPORTER_PORT="$(pick_port "$EXPORTER_PORT")"
PROM_PORT="$(pick_port "$PROM_PORT")"
log "exporter port: ${EXPORTER_PORT}   prometheus port: ${PROM_PORT}"

trap 'warn "setup failed near line $LINENO — run: bash $0 --cleanup"' ERR

# 1) Start the buggy exporter.
write_exporter
CARDINALITY="$CARDINALITY" EXPORTER_PORT="$EXPORTER_PORT" \
  nohup python3 "$LAB_DIR/buggy_exporter.py" >"$LAB_DIR/exporter.log" 2>&1 &
echo $! > "$LAB_DIR/exporter.pid"
wait_ready "http://127.0.0.1:${EXPORTER_PORT}/metrics" "buggy exporter"

# 2) Start an isolated Prometheus with the BROKEN config.
write_broken_config
ensure_prometheus
start_prometheus
wait_ready "http://127.0.0.1:${PROM_PORT}/-/ready" "prometheus"

# 3) Let it scrape a couple of times, then show the damage.
log "waiting for two scrape cycles..."
sleep 12
trap - ERR

BUGGY_SAMPLES="$(promq 'scrape_samples_post_metric_relabeling{job="buggy-app"}' \
  | grep -o '"[0-9]\+"' | tail -1 | tr -d '"' || true)"
HEAD_SERIES="$(promq 'prometheus_tsdb_head_series' \
  | grep -o '"[0-9]\+"' | tail -1 | tr -d '"' || true)"

cat <<BANNER

================================================================================
  THE SYSTEM IS NOW BROKEN — this is the lab.
================================================================================
Open the Prometheus UI:   http://127.0.0.1:${PROM_PORT}
Config you may edit:      ${LAB_DIR}/prometheus.yml

WHAT YOU WILL SEE (the SYMPTOM):
  * Target 'buggy-app' is UP, yet it alone injected ~${BUGGY_SAMPLES:-15000} series.
  * prometheus_tsdb_head_series jumped to ~${HEAD_SERIES:-?} (baseline was ~1.5-2k).
  * A SINGLE tiny target destabilises the whole server. Let it run and watch
    process_resident_memory_bytes climb and queries slow down.

  Try these yourself:
    curl -sG http://127.0.0.1:${PROM_PORT}/api/v1/query \\
      --data-urlencode 'query=scrape_samples_post_metric_relabeling{job="buggy-app"}'
    curl -sG http://127.0.0.1:${PROM_PORT}/api/v1/query \\
      --data-urlencode 'query=prometheus_tsdb_head_series'
    curl -sG http://127.0.0.1:${PROM_PORT}/api/v1/query \\
      --data-urlencode 'query=topk(3, count by (__name__)({job="buggy-app"}))'

WHY THIS IS A PROMETHEUS *LIMITATION* (topic 2.3):
  Every unique label-value combination is a distinct time series, and the active
  set lives in RAM (the TSDB head). Prometheus is a metrics system, not an event
  store — it is NOT designed for per-entity (user_id / request_id / URL) labels,
  and a single node does not scale horizontally or store data durably long-term.

YOUR GOAL (the FIX):
  Bring scrape_samples_post_metric_relabeling{job="buggy-app"} down to a handful
  WITHOUT taking the target DOWN (up{job="buggy-app"} must stay 1), and stop the
  head-series growth. Do it by bounding cardinality at ingestion — then hot
  reload Prometheus:
    curl -X POST http://127.0.0.1:${PROM_PORT}/-/reload

  When you have tried it, compare against the reference fix:  bash $0 --solve
  Tear everything down when finished:                          bash $0 --cleanup
================================================================================

BANNER

log "lab is running. Nothing was installed system-wide; all state is under $LAB_DIR"
exit 0

# ==============================================================================
#  █  REFERENCE SOLUTION — step by step (do not peek until you have tried)  █
# ==============================================================================
#
#  ROOT CAUSE
#  ----------
#  The exporter emits `myapp_http_requests_total{...,user_id="uNNNNNN"}`. user_id
#  is unbounded, so every user is a new series. The real, permanent fix is at the
#  SOURCE: never put unbounded identifiers in labels
#  (https://prometheus.io/docs/practices/instrumentation/#do-not-overuse-labels).
#  Put the count in a low-cardinality metric (e.g. by method/path/status) and
#  keep per-user detail in logs/traces, not metrics. But you often cannot patch a
#  third-party target fast enough — so you defend Prometheus at ingestion.
#
#  STEP 1 — Confirm the culprit
#  ----------------------------
#    curl -sG http://127.0.0.1:${PROM_PORT}/api/v1/query \
#      --data-urlencode 'query=topk(3, count by (__name__)({job="buggy-app"}))'
#    # => myapp_http_requests_total ~= 15000. That one metric is the whole problem.
#
#  STEP 2 — Bound cardinality at ingestion (edit ${LAB_DIR}/prometheus.yml)
#  -----------------------------------------------------------------------
#  Under the `buggy-app` scrape config add BOTH a guardrail and a drop rule:
#
#      - job_name: buggy-app
#        static_configs:
#          - targets: ['127.0.0.1:${EXPORTER_PORT}']
#        sample_limit: 5000                 # fail LOUD if a future bomb slips in
#        metric_relabel_configs:            # runs after scrape, before storage
#          - source_labels: [__name__]
#            regex: myapp_http_requests_total
#            action: drop                   # never write these series to the TSDB
#
#  Notes on the choices:
#    * `action: drop` on __name__ removes the offending metric entirely. This is
#      the safe mitigation: it keeps the target UP and every other metric intact.
#    * Do NOT reach for `action: labeldrop` on `user_id` here: collapsing 15k
#      series onto one name produces duplicate samples at the same timestamp and
#      Prometheus rejects the scrape ("duplicate sample for timestamp"). Drop the
#      metric (or fix instrumentation) instead.
#    * `sample_limit` does NOT selectively trim — if a scrape exceeds it the whole
#      scrape fails and the target goes DOWN. That is a deliberate alarm, not the
#      fix; the relabel drop is what keeps us both bounded AND up.
#    Docs:
#      https://prometheus.io/docs/prometheus/latest/configuration/configuration/#metric_relabel_configs
#      https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
#
#  STEP 3 — Hot reload (no restart, no data loss)
#  ----------------------------------------------
#    curl -X POST http://127.0.0.1:${PROM_PORT}/-/reload
#    # (Prometheus was started with --web.enable-lifecycle so this endpoint works.)
#
#  STEP 4 — Verify the fix
#  -----------------------
#    curl -sG http://127.0.0.1:${PROM_PORT}/api/v1/query \
#      --data-urlencode 'query=scrape_samples_post_metric_relabeling{job="buggy-app"}'
#    # => ~1  (only myapp_up survives ingestion)
#    curl -sG http://127.0.0.1:${PROM_PORT}/api/v1/query \
#      --data-urlencode 'query=up{job="buggy-app"}'
#    # => 1   (target still UP — success is bounded ingestion, not a dead target)
#
#  The 15k series already in the head stop receiving samples and age out of the
#  TSDB head after ~5 minutes (staleness). To see head-series drop immediately,
#  restart Prometheus (or delete ${LAB_DIR}/data and restart) — a reminder that
#  the head block is an in-memory, per-node structure.
#
#  STEP 5 — Tie it back to "Prometheus limitations"
#  ------------------------------------------------
#  You mitigated cardinality, but the deeper limits remain by design:
#    * Single node, in-memory head: vertical scale only; guard cardinality always.
#    * Local storage is NOT durable long-term or clustered storage
#      (https://prometheus.io/docs/prometheus/latest/storage/#operational-aspects).
#      For long retention / global view / HA dedup, remote-write to Thanos,
#      Cortex or Mimir — that is the sanctioned way past these limits.
#    * Prometheus favours reliability over 100% accuracy: it is not a billing or
#      event-audit system. Pick the right tool; do not push events into metrics.
#
#  Shortcut to auto-apply this exact fix:   bash $0 --solve
#  Clean up the whole lab:                  bash $0 --cleanup
# ==============================================================================