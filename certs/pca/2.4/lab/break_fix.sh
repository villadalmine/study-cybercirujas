#!/usr/bin/env bash
#
# ============================================================================
#  PCA — Exam Domain 2: Prometheus Fundamentals
#  Topic 2.4: Data Model and Labels        (exam weight: 4)
#
#  BREAK & FIX LAB — "The engineer who dropped a 'noisy' label"
#
#  What this teaches
#  -----------------
#  In Prometheus a *time series* is uniquely identified by its metric name
#  PLUS the full set of its label name/value pairs:
#
#        <metric_name>{<label>=<value>, ...}
#
#  Every label is part of the series' identity. Remove a label that
#  distinguishes two series and they collapse into ONE identity. When a
#  single scrape then produces two samples that share that identity (same
#  timestamp) but carry different values, Prometheus cannot store both:
#  it keeps one, drops the rest, and the data is silently lost.
#
#  This lab reproduces exactly that mistake using `metric_relabel_configs`
#  with an `action: labeldrop`, the single most common label footgun in
#  production ("this label is noisy, let's drop it").
#
#  Sources (official):
#    - Data model .... https://prometheus.io/docs/concepts/data_model/
#    - Jobs/instances  https://prometheus.io/docs/concepts/jobs_instances/
#    - metric_relabel_configs / labeldrop:
#        https://prometheus.io/docs/prometheus/latest/configuration/configuration/#metric_relabel_configs
#        https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
#
#  SAFETY
#  ------
#  This script does NOT touch any system Prometheus. It spins up an isolated,
#  disposable Prometheus instance on port 9099 with its own config and TSDB
#  under a lab directory. Run it on a throwaway lab VM. Tear it all down with:
#
#        ./break-fix-2.4.sh cleanup
#
#  The scenario is intentionally LEFT BROKEN when the script finishes: your
#  job is to diagnose it from the symptoms and repair it. The commented,
#  step-by-step solution is at the very bottom of this file.
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
PORT="${PORT:-9099}"
LAB_DIR="${LAB_DIR:-$HOME/pca-lab-2.4}"
CONFIG="${LAB_DIR}/prometheus.yml"
BACKUP="${LAB_DIR}/prometheus.yml.orig"      # safety copy of the healthy config
PIDFILE="${LAB_DIR}/prometheus.pid"
LOGFILE="${LAB_DIR}/prometheus.log"
TSDB="${LAB_DIR}/data"
BASEURL="http://localhost:${PORT}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
die()  { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------------------"; }

# Locate a prometheus binary or explain how to get one.
find_prometheus() {
  local c
  for c in prometheus /usr/local/bin/prometheus /opt/prometheus/prometheus ./prometheus; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
    if [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

# Instant-query helper (returns raw Prometheus API JSON).
promq() { curl -sG "${BASEURL}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null || true; }

# Extract .data.result[0].value[1] from an instant-query response (no jq needed).
jval() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.data.result[0].value[1] // "n/a"' 2>/dev/null || echo "n/a"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)["data"]["result"]
    print(d[0]["value"][1] if d else "n/a")
except Exception:
    print("n/a")'
  else
    grep -o '"value":\[[^]]*\]' | head -1 || echo "n/a"
  fi
}

wait_for_ready() {
  local i
  for i in $(seq 1 40); do
    if curl -sf "${BASEURL}/-/ready" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  return 1
}

# Hit several distinct web/API handlers so that prometheus_http_requests_total
# and prometheus_http_request_duration_seconds_* carry MANY handler values,
# each with different counts. This guarantees value collisions once the
# distinguishing `handler` label is dropped.
gen_traffic() {
  local n
  for n in 1 2 3; do
    curl -sf "${BASEURL}/-/healthy"                  >/dev/null 2>&1 || true
    curl -sf "${BASEURL}/-/ready"                    >/dev/null 2>&1 || true
    curl -sf "${BASEURL}/graph"                      >/dev/null 2>&1 || true
    curl -sf "${BASEURL}/api/v1/query?query=up"      >/dev/null 2>&1 || true
    curl -sf "${BASEURL}/api/v1/labels"              >/dev/null 2>&1 || true
    curl -sf "${BASEURL}/api/v1/status/config"       >/dev/null 2>&1 || true
    curl -sf "${BASEURL}/api/v1/status/flags"        >/dev/null 2>&1 || true
    curl -sf "${BASEURL}/api/v1/status/runtimeinfo"  >/dev/null 2>&1 || true
  done
}

stop_lab() {
  if [ -f "$PIDFILE" ]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$PIDFILE"
  fi
}

# ----------------------------------------------------------------------------
# Sub-command: cleanup
# ----------------------------------------------------------------------------
if [ "${1:-}" = "cleanup" ]; then
  echo "Tearing down the PCA 2.4 lab ..."
  stop_lab
  rm -rf "$LAB_DIR"
  echo "Done. Lab instance stopped and ${LAB_DIR} removed."
  exit 0
fi

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl is required."
PROM_BIN="$(find_prometheus)" || die \
"No 'prometheus' binary found. Install it on this lab VM, e.g.:
   VER=2.53.0
   curl -sSLO https://github.com/prometheus/prometheus/releases/download/v\${VER}/prometheus-\${VER}.linux-amd64.tar.gz
   tar xzf prometheus-\${VER}.linux-amd64.tar.gz
   sudo install prometheus-\${VER}.linux-amd64/prometheus /usr/local/bin/
Then re-run this script."

# Refuse to collide with something else already on the port.
stop_lab   # stop any previous run of THIS lab first
if curl -sf "${BASEURL}/-/ready" >/dev/null 2>&1; then
  die "Port ${PORT} is already serving a Prometheus that this lab did not start.
Pick a different port with:  PORT=9098 $0"
fi

# ----------------------------------------------------------------------------
# 1) Build a healthy, isolated lab instance
# ----------------------------------------------------------------------------
rule
echo "PCA Topic 2.4 — Data Model and Labels :: BREAK & FIX"
rule
mkdir -p "$TSDB"

cat > "$CONFIG" <<'YAML'
# ---- HEALTHY baseline configuration --------------------------------------
global:
  scrape_interval: 5s
  scrape_timeout: 4s
  evaluation_interval: 5s

scrape_configs:
  # Prometheus scrapes its own /metrics. Its instrumentation exposes richly
  # labelled series such as:
  #   prometheus_http_requests_total{handler="/api/v1/query", code="200"}
  #   prometheus_http_request_duration_seconds_bucket{handler=..., le=...}
  # The `handler` label is what makes those series distinct from one another.
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9099']
YAML

cp -f "$CONFIG" "$BACKUP"   # safety copy of the KNOWN-GOOD config

info "Starting isolated Prometheus on :${PORT} (config: ${CONFIG})"
nohup "$PROM_BIN" \
  --config.file="$CONFIG" \
  --storage.tsdb.path="$TSDB" \
  --storage.tsdb.retention.time=1h \
  --web.listen-address=":${PORT}" \
  --web.enable-lifecycle \
  >"$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"

wait_for_ready || die "Prometheus did not become ready. See ${LOGFILE}"
info "Prometheus is up and ready."

# Seed varied handler traffic, then let a couple of scrapes land.
gen_traffic
sleep 12
gen_traffic
sleep 8

# ----------------------------------------------------------------------------
# 2) Capture the HEALTHY baseline the student should later restore
# ----------------------------------------------------------------------------
BASE_SERIES="$(promq 'count(prometheus_http_requests_total)' | jval)"
BASE_HANDLERS="$(promq 'count(count by (handler) (prometheus_http_requests_total))' | jval)"
BASE_DUP="$(promq 'prometheus_target_scrapes_sample_duplicate_timestamp_total' | jval)"

rule
echo "HEALTHY BASELINE (memorise these — this is what 'fixed' looks like):"
info "distinct prometheus_http_requests_total series : ${BASE_SERIES}"
info "distinct 'handler' label values                : ${BASE_HANDLERS}"
info "duplicate-timestamp samples dropped so far      : ${BASE_DUP}   (expected ~0)"
rule

# ----------------------------------------------------------------------------
# 3) BREAK IT — drop the distinguishing `handler` label at ingestion time
# ----------------------------------------------------------------------------
echo "Injecting the fault (an 'innocent' labeldrop) and reloading ..."
cat > "$CONFIG" <<'YAML'
global:
  scrape_interval: 5s
  scrape_timeout: 4s
  evaluation_interval: 5s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9099']
    # ---- THE FAULT -------------------------------------------------------
    # "The handler label is too noisy, let's strip it." This looks harmless
    # and the config is 100% valid YAML that loads without complaint. But it
    # deletes the label that makes these series distinct, collapsing many
    # series into a single identity.
    metric_relabel_configs:
      - regex: handler
        action: labeldrop
    # ----------------------------------------------------------------------
YAML

# Reload via the lifecycle endpoint (no restart, no data loss of TSDB).
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASEURL}/-/reload" || true)"
[ "$code" = "200" ] || die "Reload failed (HTTP ${code}). See ${LOGFILE}"

# Let the broken config take effect over a few scrapes, with fresh traffic.
gen_traffic
sleep 12
gen_traffic
sleep 8

NOW_DUP="$(promq 'prometheus_target_scrapes_sample_duplicate_timestamp_total' | jval)"
NOW_HANDLERS="$(promq 'count(count by (handler) (prometheus_http_requests_total))' | jval)"

# ----------------------------------------------------------------------------
# 4) Brief the student
# ----------------------------------------------------------------------------
rule
echo "THE SYSTEM IS NOW BROKEN."
rule
cat <<EOF

WHAT YOU WILL OBSERVE (the symptoms)
------------------------------------
1. The target LOOKS HEALTHY. Open ${BASEURL}/targets — the 'prometheus'
   target is still UP and green. This is the trap: nothing is "down".

2. Data is being SILENTLY DROPPED. The dropped-duplicate counter is climbing:

     baseline : ${BASE_DUP}
     now      : ${NOW_DUP}        <-- and it keeps increasing every scrape

   Query it live:
     curl -sG '${BASEURL}/api/v1/query' \\
          --data-urlencode 'query=prometheus_target_scrapes_sample_duplicate_timestamp_total'

3. The logs are shouting about it (WARN level):
     grep -i 'duplicate\\|same timestamp' ${LOGFILE}
   You will see, once per scrape:
     "Error on ingesting samples with different value but same timestamp"
     num_dropped=<N>

4. Your dimensions are GONE. The 'handler' label has vanished and distinct
   series have collapsed into one:
     distinct 'handler' values  ->  baseline ${BASE_HANDLERS}   now ${NOW_HANDLERS}
   Try in the UI (${BASEURL}/graph):
     count by (handler) (prometheus_http_requests_total)
   PromQL that used to break down traffic per endpoint now returns nothing
   useful — you can no longer answer "which handler is slow / erroring?".

YOUR GOAL (what 'fixed' means)
------------------------------
 * ${BASEURL}/targets still UP  (it already is — that is not the fix).
 * prometheus_target_scrapes_sample_duplicate_timestamp_total STOPS rising.
 * The 'handler' label is present again and
       count(count by (handler) (prometheus_http_requests_total))
   returns roughly ${BASE_HANDLERS} again (its healthy baseline).
 * grep of ${LOGFILE} shows NO new "same timestamp" warnings after your fix.

RULES OF ENGAGEMENT
-------------------
 * Config file to inspect/edit : ${CONFIG}
 * Known-good copy (last resort): ${BACKUP}
 * Apply changes WITHOUT restart: curl -X POST ${BASEURL}/-/reload
 * Diagnose from the SYMPTOMS first. Ask yourself: what uniquely identifies
   a Prometheus time series, and what happens to two series when the label
   that told them apart is deleted?

When you are done experimenting, tear the lab down with:
   $0 cleanup

The full step-by-step solution is at the bottom of this script (commented).
Do not read it until you have tried.
EOF
rule
exit 0

# ============================================================================
#  SOLUTION — step by step   (read only after you have attempted the fix)
# ============================================================================
#
#  STEP 0 — Reproduce and confirm the failure mode
#  -----------------------------------------------
#  The target is UP, so "is it down?" is the wrong question. The right signal
#  is the duplicate-timestamp counter and the WARN log line. Confirm both:
#
#      # Counter is monotonically increasing => samples are being dropped:
#      watch -n1 "curl -sG http://localhost:9099/api/v1/query \
#         --data-urlencode 'query=prometheus_target_scrapes_sample_duplicate_timestamp_total' \
#         | grep -o '\"value\":\[[^]]*\]'"
#
#      # The engine tells you exactly what is wrong:
#      grep -i 'same timestamp' "$HOME/pca-lab-2.4/prometheus.log"
#      #   msg="Error on ingesting samples with different value but same timestamp" num_dropped=...
#
#
#  STEP 1 — Understand WHY (the data-model insight this topic tests)
#  ----------------------------------------------------------------
#  A Prometheus time series is uniquely keyed by:
#
#        metric_name + { every label name=value pair }
#
#  Two samples are "the same series" iff that whole key matches. Within one
#  scrape, Prometheus refuses to store two samples for the same series+
#  timestamp that carry DIFFERENT values (it cannot represent both), so it
#  keeps one and drops the rest, incrementing
#  prometheus_target_scrapes_sample_duplicate_timestamp_total and logging the
#  WARN above.
#
#  Here, prometheus_http_requests_total exists once per (handler, code):
#      {handler="/api/v1/query", code="200"}  value 42
#      {handler="/graph",        code="200"}  value 17
#      {handler="/-/healthy",    code="200"}  value 99
#  Our metric_relabel_configs deleted the `handler` label. All three collapse
#  to the SAME identity: prometheus_http_requests_total{code="200"} — three
#  samples, one timestamp, three different values => duplicate collision.
#
#
#  STEP 2 — Locate the fault in the config
#  ---------------------------------------
#      cat "$HOME/pca-lab-2.4/prometheus.yml"
#  Note the offending block under job 'prometheus':
#      metric_relabel_configs:
#        - regex: handler
#          action: labeldrop
#  labeldrop removes every label whose NAME matches the (auto-anchored) regex.
#  `handler` is exactly the label that distinguished those series. That is the
#  bug. (This is why you must never labeldrop/labelkeep an identifying label,
#  and why aggregation should be done in PromQL — e.g. sum without(handler)(..)
#  at query time — not by destroying the label at ingestion.)
#
#
#  STEP 3 — Fix it: stop deleting the identifying label
#  ---------------------------------------------------
#  Edit the config and remove the metric_relabel_configs block entirely so the
#  job reverts to:
#
#      scrape_configs:
#        - job_name: prometheus
#          static_configs:
#            - targets: ['localhost:9099']
#
#  If you genuinely wanted to drop only a truly redundant label, you would drop
#  one that is NOT part of any series' distinguishing identity — never one that
#  separates otherwise-identical series.
#
#      # Fast path if you get stuck — restore the known-good config:
#      cp "$HOME/pca-lab-2.4/prometheus.yml.orig" "$HOME/pca-lab-2.4/prometheus.yml"
#
#
#  STEP 4 — Apply without a restart, then validate
#  -----------------------------------------------
#      # Validate config syntax BEFORE reloading (promtool ships with Prometheus):
#      promtool check config "$HOME/pca-lab-2.4/prometheus.yml"
#
#      # Hot-reload (works because we started with --web.enable-lifecycle):
#      curl -X POST http://localhost:9099/-/reload
#
#      # Generate a little traffic and let 2-3 scrapes land:
#      for h in /-/healthy /graph /api/v1/labels '/api/v1/query?query=up'; do
#          curl -s "http://localhost:9099$h" >/dev/null; done
#      sleep 15
#
#
#  STEP 5 — Prove it is fixed
#  --------------------------
#      # 'handler' dimension is back to its healthy cardinality:
#      curl -sG http://localhost:9099/api/v1/query \
#        --data-urlencode 'query=count(count by (handler) (prometheus_http_requests_total))'
#
#      # The dropped-duplicate counter STOPS increasing (record it, wait, re-read):
#      curl -sG http://localhost:9099/api/v1/query \
#        --data-urlencode 'query=prometheus_target_scrapes_sample_duplicate_timestamp_total'
#      sleep 15
#      curl -sG http://localhost:9099/api/v1/query \
#        --data-urlencode 'query=prometheus_target_scrapes_sample_duplicate_timestamp_total'
#      #  -> same value on both reads == no more drops == fixed.
#
#      # No new WARN lines about "same timestamp" appear after the reload.
#      tail -f "$HOME/pca-lab-2.4/prometheus.log"
#
#
#  KEY TAKEAWAYS (PCA 2.4)
#  -----------------------
#   * Series identity = metric name + the COMPLETE label set. Every label counts.
#   * Deleting an identifying label collapses distinct series -> duplicate
#     samples at the same timestamp -> silent data loss (target still "UP").
#   * The diagnostic signal is NOT up==0; it is
#     prometheus_target_scrapes_sample_duplicate_timestamp_total climbing plus
#     the "Error on ingesting samples with different value but same timestamp"
#     WARN log — not the /targets health colour.
#   * Aggregate by dropping dimensions at QUERY time (sum without(handler)(...)),
#     never by labeldrop at ingestion, which is irreversible and lossy.
#   * relabel_configs (pre-scrape, on target labels) vs metric_relabel_configs
#     (post-scrape, on each sample's labels): both can corrupt series identity
#     the same way — respect the label set.
#
#  Refs: https://prometheus.io/docs/concepts/data_model/
#        https://prometheus.io/docs/prometheus/latest/configuration/configuration/#metric_relabel_configs
# ============================================================================