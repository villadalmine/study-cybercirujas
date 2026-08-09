#!/usr/bin/env bash
#
# PCA — Prometheus Certified Associate
# Domain 3: Instrumentation & Exposition — Topic 3.1: Metrics (exam weight: 3)
#
# BREAK & FIX LAB — "The poisoned textfile"
#
# WHAT THIS TEACHES
#   A Prometheus metric is only useful if the target can EXPOSE it. Exposition
#   happens over the text exposition format, and that format has strict rules:
#   metric names, HELP/TYPE metadata, label syntax, and — the star of this lab —
#   the sample VALUE, which must be a valid Go float64 (a plain machine number,
#   decimal point '.', never a locale-style comma). One malformed line does not
#   just drop that one sample: node_exporter's textfile collector rejects the
#   ENTIRE file and raises node_textfile_scrape_error. This is the single most
#   common self-inflicted "my metric disappeared" incident in production.
#
# SAFETY / SCOPE
#   * Everything lives in a throwaway container + a /tmp working directory.
#   * No host service, package, or system file is modified.
#   * The "break" is a single edited line in a .prom file — fully reversible.
#   * Run this ONLY on a disposable lab VM. Undo everything with: '--cleanup'.
#
# Reference sources (official):
#   * PCA curriculum:
#       https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#   * Exposition formats:
#       https://prometheus.io/docs/instrumenting/exposition_formats/
#   * Metric types (counter / gauge / histogram / summary):
#       https://prometheus.io/docs/concepts/metric_types/
#   * Data model (metric names & labels):
#       https://prometheus.io/docs/concepts/data_model/
#   * node_exporter textfile collector:
#       https://github.com/prometheus/node_exporter#textfile-collector
#
# Usage:
#   ./pca_3.1_metrics_breakfix.sh            # set up the lab and BREAK it
#   ./pca_3.1_metrics_breakfix.sh --verify   # check whether you fixed it
#   ./pca_3.1_metrics_breakfix.sh --fix      # apply the reference fix (spoiler)
#   ./pca_3.1_metrics_breakfix.sh --cleanup  # remove container + lab directory
#   ./pca_3.1_metrics_breakfix.sh --help
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
LAB_DIR="/tmp/pca-3.1-metrics-lab"
TEXTFILE_DIR="${LAB_DIR}/textfile"
PROM_FILE="app_metrics.prom"
CONTAINER_NAME="pca-node-exporter"
IMAGE="quay.io/prometheus/node-exporter:latest"
PORT="9100"
ENDPOINT="http://localhost:${PORT}/metrics"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

# Pick an available OCI runtime (podman is default on Fedora, docker elsewhere).
detect_runtime() {
  if command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
  elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
  else
    err "Neither 'docker' nor 'podman' is installed. Install one and retry."
    exit 1
  fi
  # Add an SELinux relabel flag to the bind mount when SELinux is active,
  # otherwise the container gets EACCES reading the mounted .prom files.
  MOUNT_OPTS=":ro"
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    MOUNT_OPTS=":ro,Z"
  fi
}

require_curl() {
  command -v curl >/dev/null 2>&1 || { err "'curl' is required."; exit 1; }
}

port_in_use() {
  # Best-effort check; not fatal, just informative.
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${PORT} " && return 0
  fi
  return 1
}

# --------------------------------------------------------------------------- #
# Content writers
# --------------------------------------------------------------------------- #

# The BROKEN exposition file. The bug is the sample value '21,7' on the last
# line: a comma is not a valid float64, so the parser aborts the whole file.
write_broken_file() {
  cat > "${TEXTFILE_DIR}/${PROM_FILE}" <<'EOF'
# HELP app_requests_total Total HTTP requests handled by the demo service.
# TYPE app_requests_total counter
app_requests_total{method="GET",status="200"} 1027
app_requests_total{method="POST",status="201"} 342
# HELP app_temperature_celsius Simulated sensor temperature reading.
# TYPE app_temperature_celsius gauge
app_temperature_celsius 21,7
EOF
  chmod 0644 "${TEXTFILE_DIR}/${PROM_FILE}"
}

# The CORRECT exposition file (reference fix). Only the last value changed:
# '21,7' -> '21.7'. Note the mandatory trailing newline at end of file.
write_fixed_file() {
  cat > "${TEXTFILE_DIR}/${PROM_FILE}" <<'EOF'
# HELP app_requests_total Total HTTP requests handled by the demo service.
# TYPE app_requests_total counter
app_requests_total{method="GET",status="200"} 1027
app_requests_total{method="POST",status="201"} 342
# HELP app_temperature_celsius Simulated sensor temperature reading.
# TYPE app_temperature_celsius gauge
app_temperature_celsius 21.7
EOF
  chmod 0644 "${TEXTFILE_DIR}/${PROM_FILE}"
}

# --------------------------------------------------------------------------- #
# Container lifecycle
# --------------------------------------------------------------------------- #
start_exporter() {
  # Remove any stale container from a previous run (idempotent setup).
  "${RUNTIME}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

  log "Starting node_exporter (${IMAGE}) with the textfile collector enabled..."
  "${RUNTIME}" run -d --name "${CONTAINER_NAME}" \
    -p "${PORT}:9100" \
    -v "${TEXTFILE_DIR}:/textfile${MOUNT_OPTS}" \
    "${IMAGE}" \
    --collector.textfile.directory=/textfile >/dev/null

  # Wait for the /metrics endpoint to answer.
  local i
  for i in $(seq 1 30); do
    if curl -sf "${ENDPOINT}" >/dev/null 2>&1; then
      ok "node_exporter is serving metrics at ${ENDPOINT}"
      return 0
    fi
    sleep 1
  done
  err "node_exporter did not become ready. Inspect: ${RUNTIME} logs ${CONTAINER_NAME}"
  exit 1
}

# --------------------------------------------------------------------------- #
# Verification
# --------------------------------------------------------------------------- #
verify() {
  require_curl
  local metrics scrape_err app_count
  metrics="$(curl -s "${ENDPOINT}" || true)"

  if [ -z "${metrics}" ]; then
    err "Cannot reach ${ENDPOINT}. Is the lab running? Re-run without arguments."
    exit 1
  fi

  # node_textfile_scrape_error is a global gauge: 0 = all files parsed OK.
  scrape_err="$(printf '%s\n' "${metrics}" \
    | awk '/^node_textfile_scrape_error/ {print $2; exit}')"
  # Count how many of our custom counter series are actually exposed.
  app_count="$(printf '%s\n' "${metrics}" \
    | grep -c '^app_requests_total{' || true)"

  echo
  log "node_textfile_scrape_error = ${scrape_err:-<absent>}"
  log "app_requests_total series exposed = ${app_count}"
  echo

  if [ "${scrape_err:-1}" = "0" ] && [ "${app_count}" -ge 1 ]; then
    ok "FIXED. The file parses, the error gauge is 0, and your metrics are live."
    ok "Confirm the gauge value too:  curl -s ${ENDPOINT} | grep '^app_temperature_celsius'"
    return 0
  fi

  warn "STILL BROKEN. The textfile collector is rejecting the file."
  warn "Symptom recap: node_textfile_scrape_error=1 and 0 app_* samples exposed."
  warn "Inspect the collector's complaint in the exporter logs:"
  printf '        %s logs %s | grep -i textfile\n' "${RUNTIME}" "${CONTAINER_NAME}"
  return 1
}

# --------------------------------------------------------------------------- #
# Cleanup
# --------------------------------------------------------------------------- #
cleanup() {
  detect_runtime
  log "Removing container '${CONTAINER_NAME}'..."
  "${RUNTIME}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  log "Removing lab directory '${LAB_DIR}'..."
  rm -rf "${LAB_DIR}"
  ok "Lab environment removed. Nothing else was touched on this host."
}

# --------------------------------------------------------------------------- #
# Briefing shown to the student after the break
# --------------------------------------------------------------------------- #
briefing() {
  cat <<EOF

============================================================================
  PCA 3.1 — METRICS :: BREAK & FIX  ::  "The poisoned textfile"
============================================================================

WHAT WAS SET UP
  A node_exporter is running and reads custom application metrics from:
      ${TEXTFILE_DIR}/${PROM_FILE}
  Exposition endpoint:
      ${ENDPOINT}

WHAT IS BROKEN
  A developer wrote two metrics into that file — a counter
  (app_requests_total) and a gauge (app_temperature_celsius) — and shipped it.
  Since the deploy, ALL of the app_* metrics vanished from the endpoint, even
  the counter that "wasn't touched".

THE SYMPTOM YOU WILL SEE
  Run:
      curl -s ${ENDPOINT} | grep -E '^app_|^node_textfile_scrape_error'

  You will observe:
      * node_textfile_scrape_error 1      <-- the collector refused a file
      * NOT A SINGLE app_requests_total or app_temperature_celsius line
    The metrics are gone as a group, not one by one. That "all or nothing"
    behaviour is the diagnostic fingerprint of a textfile PARSE failure.

YOUR GOAL (definition of done)
  1. Make node_textfile_scrape_error report 0.
  2. Make app_requests_total (2 series) and app_temperature_celsius appear
     again on the endpoint.
  Achieve it by correcting the exposition file — do NOT delete metrics to
  silence the error. Then prove it:
      ./$(basename "$0") --verify

HINTS
  * The node_exporter re-reads the textfile directory on EVERY scrape, so after
    you edit the file you only need to curl again — no restart required.
  * Ask the exporter itself what it hated:
      ${RUNTIME} logs ${CONTAINER_NAME} | grep -i textfile
  * Recall the exposition-format contract for a sample line:
        <metric_name>[{label="value",...}] <value> [timestamp]
    and that <value> must be a valid float64 as Go's strconv.ParseFloat reads
    it (see prometheus.io/docs/instrumenting/exposition_formats).
  * A single bad line poisons the WHOLE file. Read every value literally.

  (The full step-by-step solution is at the very bottom of this script, as
   comments. Try it yourself before you scroll down there.)
============================================================================
EOF
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  case "${1:-}" in
    -h|--help)
      usage; exit 0 ;;
    --verify)
      detect_runtime; verify; exit $? ;;
    --cleanup)
      cleanup; exit 0 ;;
    --fix)
      detect_runtime
      warn "Applying the REFERENCE FIX (spoiler). Setting value to a valid float..."
      write_fixed_file
      verify; exit $? ;;
    "" )
      : ;; # default action: build + break
    * )
      err "Unknown argument: $1"; usage; exit 2 ;;
  esac

  require_curl
  detect_runtime

  if port_in_use; then
    warn "TCP port ${PORT} already appears to be in use; the container may fail"
    warn "to bind. If so, stop whatever holds it or run '--cleanup' first."
  fi

  log "Preparing lab directory: ${TEXTFILE_DIR}"
  mkdir -p "${TEXTFILE_DIR}"

  # Deliberately write the malformed file — this is the controlled "break".
  log "Writing the (intentionally malformed) exposition file..."
  write_broken_file

  start_exporter
  briefing

  # Show the live symptom immediately so the student sees the failure state.
  echo
  log "Current endpoint state (proof of the break):"
  echo "    \$ curl -s ${ENDPOINT} | grep -E '^app_|^node_textfile_scrape_error'"
  curl -s "${ENDPOINT}" | grep -E '^app_|^node_textfile_scrape_error' || \
    warn "(no app_* lines — exactly the symptom described above)"
  echo
}

main "$@"

# ===========================================================================
# ===========================  SOLUTION (SPOILER)  ==========================
# ===========================================================================
# Do not read this until you have attempted the fix. Everything below is a
# comment; nothing here executes.
#
# ---------------------------------------------------------------------------
# STEP 1 — Confirm the symptom precisely.
#
#     curl -s http://localhost:9100/metrics \
#       | grep -E '^app_|^node_textfile_scrape_error'
#
#   Expected while broken:
#     node_textfile_scrape_error 1
#   ...and zero app_* lines. The "1" tells you a textfile failed to parse; the
#   total absence of app_* tells you the failure took the whole file with it.
#
# ---------------------------------------------------------------------------
# STEP 2 — Ask the exporter what it rejected (read the actual error, don't
#          guess).
#
#     docker logs pca-node-exporter  | grep -i textfile     # or 'podman logs'
#
#   You will see a message similar to:
#     level=error ... collector=textfile ... msg="failed to collect textfile
#       data" file=app_metrics.prom err="text format parsing error in line 8:
#       expected float as value, got \"21,7\""
#
#   That line/column pinpoints the offending sample value.
#
# ---------------------------------------------------------------------------
# STEP 3 — Understand WHY it failed (the exam-relevant concept).
#
#   The Prometheus text exposition format defines each sample line as:
#       metric_name[{label="value",...}]  VALUE  [timestamp]
#   VALUE must be a float64 as parsed by Go's strconv.ParseFloat: an optional
#   sign, decimal digits with a '.' separator, optional exponent, or the
#   special tokens +Inf, -Inf, NaN. A locale decimal comma ("21,7") is NOT a
#   valid float, so the parser aborts.
#
#   Crucially, the textfile collector parses each *file* as one unit. A single
#   malformed line invalidates the ENTIRE file, so the healthy counter series
#   (app_requests_total) disappear as collateral damage. That is why the
#   symptom was "all metrics from this file gone", not "one metric wrong".
#
#   Ref: https://prometheus.io/docs/instrumenting/exposition_formats/
#        https://prometheus.io/docs/concepts/data_model/
#
# ---------------------------------------------------------------------------
# STEP 4 — Fix the file. Edit /tmp/pca-3.1-metrics-lab/textfile/app_metrics.prom
#          and change the comma to a decimal point:
#
#          -   app_temperature_celsius 21,7
#          +   app_temperature_celsius 21.7
#
#   One-liner:
#     sed -i 's/^app_temperature_celsius 21,7$/app_temperature_celsius 21.7/' \
#       /tmp/pca-3.1-metrics-lab/textfile/app_metrics.prom
#
#   Also make sure the file still ends with a trailing newline — the textfile
#   collector requires files to end in '\n' or it will report a parse error on
#   the final line. ('cat -A file' should show the last line ending in '$'.)
#
# ---------------------------------------------------------------------------
# STEP 5 — Verify (no restart needed; node_exporter re-reads on every scrape).
#
#     curl -s http://localhost:9100/metrics \
#       | grep -E '^app_|^node_textfile_scrape_error'
#
#   Expected once fixed:
#     node_textfile_scrape_error 0
#     app_requests_total{method="GET",status="200"} 1027
#     app_requests_total{method="POST",status="201"} 342
#     app_temperature_celsius 21.7
#
#   Or simply:  ./pca_3.1_metrics_breakfix.sh --verify   (prints PASS/FAIL)
#
# ---------------------------------------------------------------------------
# STEP 6 — Tear the lab down when finished:
#
#     ./pca_3.1_metrics_breakfix.sh --cleanup
#
# ---------------------------------------------------------------------------
# TAKEAWAYS FOR THE EXAM
#   * The exposition format is strict: metric_name, optional {labels}, a single
#     float64 value, optional timestamp. Values use '.', never ',' — and
#     special values are +Inf / -Inf / NaN only.
#   * node_textfile_scrape_error is your first-line signal that a target is
#     serving a malformed textfile; when it is 1, expect whole files (not
#     single samples) to be missing.
#   * Instrumentation correctness is upstream of everything: PromQL, alerting
#     and dashboards cannot query a series the exporter refused to expose.
# ===========================================================================