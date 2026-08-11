#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 2 · Topic 2.4: Signals (Tracing, Metric, Log)   [exam weight 6.57]
#  BREAK & FIX lab — run ONLY on a disposable, throwaway lab VM.
# ============================================================================
#
#  What this exercises
#  -------------------
#  In OpenTelemetry a "signal" is one category of telemetry: traces, metrics,
#  or logs. In the Collector each signal travels through its OWN independent
#  pipeline (receivers -> processors -> exporters) declared under
#  `service.pipelines`. A shared receiver (here: otlp) can feed all three, but
#  each signal is only wired end-to-end if a pipeline for THAT signal exists.
#  Delete a signal's pipeline and that signal is silently dropped even though
#  the other two keep flowing perfectly — the classic "why are my logs gone
#  but traces are fine?" incident.
#
#  This script:
#    1. Installs a local otelcol-contrib bound to loopback only.
#    2. Writes a healthy config with traces + metrics + logs pipelines.
#    3. Proves all three signals reach the debug exporter (baseline).
#    4. Performs a CONTROLLED, REVERSIBLE break: removes the logs pipeline.
#    5. Tells you the symptom and the acceptance criteria to fix it.
#
#  Safety: it touches nothing outside "$LAB_DIR", starts no system service,
#  binds only to 127.0.0.1, and destroys no data. The "break" is a single
#  edit to a lab config file plus a restart of a local background process.
#
#  Sources (official):
#    - Signals concept ......... https://opentelemetry.io/docs/concepts/signals/
#    - Collector configuration . https://opentelemetry.io/docs/collector/configuration/
#    - Collector pipelines ..... https://opentelemetry.io/docs/collector/architecture/
#    - OTLP/HTTP protocol ...... https://opentelemetry.io/docs/specs/otlp/
#    - OTCA curriculum ......... https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
# ============================================================================

set -euo pipefail

# ---- Lab parameters (override via env if you like) --------------------------
LAB_DIR="${LAB_DIR:-$HOME/otca-lab-2.4-signals}"
OTELCOL_VERSION="${OTELCOL_VERSION:-0.117.0}"
CONFIG="$LAB_DIR/otelcol.yaml"
BIN="$LAB_DIR/otelcol-contrib"
LOG="$LAB_DIR/collector.log"
PIDFILE="$LAB_DIR/collector.pid"
OTLP_HTTP="http://127.0.0.1:4318"
HEALTH="http://127.0.0.1:13133"

# ---- Safety gate ------------------------------------------------------------
require_lab() {
  if [[ "${OTCA_LAB_CONFIRM:-}" != "yes" ]]; then
    echo "This lab starts a collector and rewrites a config under $LAB_DIR."
    echo "Run it ONLY on a disposable VM, then re-run with:"
    echo "    OTCA_LAB_CONFIRM=yes $0"
    exit 1
  fi
  command -v curl >/dev/null || { echo "Missing dependency: curl"; exit 1; }
  command -v tar  >/dev/null || { echo "Missing dependency: tar";  exit 1; }
  mkdir -p "$LAB_DIR"
}

# ---- Collector binary -------------------------------------------------------
install_collector() {
  [[ -x "$BIN" ]] && return 0
  local arch tar_url tmp
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
  tar_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_${arch}.tar.gz"
  tmp="$LAB_DIR/otelcol.tgz"
  echo "==> Downloading otelcol-contrib v${OTELCOL_VERSION} (${arch})..."
  curl -fSL "$tar_url" -o "$tmp"
  tar -xzf "$tmp" -C "$LAB_DIR" otelcol-contrib
  chmod +x "$BIN"
  rm -f "$tmp"
}

# ---- Config: HEALTHY (all three signals wired) ------------------------------
write_good_config() {
  cat >"$CONFIG" <<'EOF'
# HEALTHY baseline — one shared OTLP receiver feeding THREE signal pipelines.
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
      http:
        endpoint: 127.0.0.1:4318

processors:
  batch: {}

exporters:
  debug:
    verbosity: detailed

extensions:
  health_check:
    endpoint: 127.0.0.1:13133

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
EOF
}

# ---- Config: BROKEN (logs signal pipeline removed) --------------------------
write_broken_config() {
  cat >"$CONFIG" <<'EOF'
# BROKEN — the `logs` pipeline is gone. The otlp receiver still exists, but
# because no pipeline consumes the logs signal, the receiver never registers
# the /v1/logs handler. Traces and metrics are untouched.
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
      http:
        endpoint: 127.0.0.1:4318

processors:
  batch: {}

exporters:
  debug:
    verbosity: detailed

extensions:
  health_check:
    endpoint: 127.0.0.1:13133

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
EOF
}

# ---- Collector process control ---------------------------------------------
stop_collector() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
    sleep 1
  fi
}

start_collector() {
  stop_collector
  "$BIN" --config "$CONFIG" >"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  wait_health
}

wait_health() {
  local i
  for i in $(seq 1 30); do
    if curl -sf "$HEALTH" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "!! Collector did not become healthy. Last log lines:"
  tail -n 20 "$LOG" || true
  return 1
}

# ---- OTLP/HTTP JSON payloads (minimal, spec-valid) --------------------------
TRACE_JSON='{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otca-lab"}}]},"scopeSpans":[{"scope":{"name":"otca.break-fix"},"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"lab-span","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000000000000"}]}]}]}'
METRIC_JSON='{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otca-lab"}}]},"scopeMetrics":[{"scope":{"name":"otca.break-fix"},"metrics":[{"name":"lab_requests_total","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asInt":"1","startTimeUnixNano":"1700000000000000000","timeUnixNano":"1700000000000000000"}]}}]}]}]}'
LOG_JSON='{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otca-lab"}}]},"scopeLogs":[{"scope":{"name":"otca.break-fix"},"logRecords":[{"timeUnixNano":"1700000000000000000","severityNumber":9,"severityText":"INFO","body":{"stringValue":"lab log line"}}]}]}]}'

# ---- Send one signal, print the HTTP status --------------------------------
send_signal() {
  local sig="$1" path="$2" data="$3" code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST "${OTLP_HTTP}${path}" --data "$data" 2>/dev/null || echo "000")
  printf '   %-8s POST %-12s -> HTTP %s\n' "$sig" "$path" "$code"
  echo "$code"
}

send_all() {
  send_signal "TRACE"  "/v1/traces"  "$TRACE_JSON"  >/dev/null
  send_signal "METRIC" "/v1/metrics" "$METRIC_JSON" >/dev/null
  send_signal "LOG"    "/v1/logs"    "$LOG_JSON"     >/dev/null
  # Reprint with visible codes:
  send_signal "TRACE"  "/v1/traces"  "$TRACE_JSON"
  send_signal "METRIC" "/v1/metrics" "$METRIC_JSON"
  send_signal "LOG"    "/v1/logs"    "$LOG_JSON"
  sleep 1
  echo "   Debug-exporter evidence (last matching lines in $LOG):"
  grep -E 'Span #|Metric #|LogRecord #' "$LOG" | tail -n 9 | sed 's/^/     /' || true
}

# ---- Verify: used AFTER the student edits the config ------------------------
verify_fix() {
  echo "==> Verifying the logs signal is restored..."
  start_collector
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST "${OTLP_HTTP}/v1/logs" --data "$LOG_JSON" 2>/dev/null || echo "000")
  sleep 1
  if [[ "$code" == "200" ]] && grep -q 'LogRecord #' "$LOG"; then
    echo "   PASS ✅  /v1/logs returned HTTP 200 and a LogRecord reached the exporter."
    echo "   All three signals — traces, metrics, logs — are flowing again."
  else
    echo "   FAIL ❌  /v1/logs returned HTTP ${code} and/or no LogRecord in the log."
    echo "   Re-check that a 'logs:' pipeline exists under service.pipelines."
  fi
}

# ============================================================================
#  Main
# ============================================================================
case "${1:-run}" in
  verify) require_lab; verify_fix; exit 0 ;;
  stop)   stop_collector; echo "Collector stopped."; exit 0 ;;
esac

require_lab
install_collector

echo "============================================================"
echo " STEP 1 — Baseline: healthy collector, all three signals"
echo "============================================================"
write_good_config
start_collector
send_all
echo
echo "You should have seen HTTP 200 for TRACE, METRIC and LOG,"
echo "and Span/Metric/LogRecord lines in the debug output. Baseline good."
echo

echo "============================================================"
echo " STEP 2 — Introducing the fault (controlled & reversible)"
echo "============================================================"
write_broken_config
start_collector
echo "Config rewritten and collector restarted. Health check still passes"
echo "(the config is syntactically valid), so nothing looks obviously wrong."
echo
send_all
echo

cat <<'BRIEF'
============================================================
 STUDENT BRIEFING
============================================================
SYMPTOM
  - TRACE  POST /v1/traces  -> HTTP 200   (works)
  - METRIC POST /v1/metrics -> HTTP 200   (works)
  - LOG    POST /v1/logs    -> HTTP 404   (BROKEN)
  The collector is "healthy", the OTLP receiver is up, and two of three
  signals flow. Only the logs signal is dead. The debug output shows Spans
  and Metrics but no LogRecord. This is the fingerprint of a MISSING SIGNAL
  PIPELINE, not a receiver, network, or exporter outage — one shared otlp
  receiver only serves a signal when a pipeline for that signal exists.

YOUR TASK
  Edit the config and restore the logs signal end-to-end. Acceptance:
    1. POST http://127.0.0.1:4318/v1/logs returns HTTP 200.
    2. A "LogRecord #0" line appears in the debug exporter output.
    3. Traces and metrics must keep working (do not break what works).

WHERE
    Config file : ~/otca-lab-2.4-signals/otelcol.yaml   (edit this)
    Collector log: ~/otca-lab-2.4-signals/collector.log
    Restart after editing:
        OTCA_LAB_CONFIRM=yes ./<this-script> stop
        (or) kill $(cat ~/otca-lab-2.4-signals/collector.pid); ./<binary> ...
    Then grade yourself:
        OTCA_LAB_CONFIRM=yes ./<this-script> verify

HINTS (escalating)
  1. Which section decides what a signal does end-to-end? service.pipelines.
  2. Compare the pipelines block against receivers/exporters — count the signals.
  3. Traces and metrics each have a pipeline. Logs does not. Add one.
============================================================
BRIEF

# ============================================================================
#  SOLUTION — step by step (do not read until you have tried).
# ============================================================================
#
#  ROOT CAUSE
#  ----------
#  The `logs:` pipeline was deleted from `service.pipelines`. The otlp receiver
#  and the debug exporter both still support logs, but with no pipeline to
#  connect receiver -> processor -> exporter for the logs signal, the OTLP/HTTP
#  receiver never mounts the /v1/logs route. Result: HTTP 404 on logs while
#  traces and metrics (which still have pipelines) return 200.
#
#  FIX — Step 1: open the config
#      $ vi ~/otca-lab-2.4-signals/otelcol.yaml
#
#  FIX — Step 2: under service.pipelines, re-add the logs pipeline so it reads:
#
#      service:
#        extensions: [health_check]
#        pipelines:
#          traces:
#            receivers: [otlp]
#            processors: [batch]
#            exporters: [debug]
#          metrics:
#            receivers: [otlp]
#            processors: [batch]
#            exporters: [debug]
#          logs:                    # <-- the restored signal
#            receivers: [otlp]
#            processors: [batch]
#            exporters: [debug]
#
#    (Equivalent one-liner append, mind YAML indentation with two spaces:)
#      $ cat >> ~/otca-lab-2.4-signals/otelcol.yaml <<'YAML'
#          logs:
#            receivers: [otlp]
#            processors: [batch]
#            exporters: [debug]
#      YAML
#
#  FIX — Step 3: validate the config before restarting (fast feedback loop):
#      $ ~/otca-lab-2.4-signals/otelcol-contrib validate \
#            --config ~/otca-lab-2.4-signals/otelcol.yaml
#      Expected: exit code 0, no error.
#
#  FIX — Step 4: restart the collector and confirm:
#      $ OTCA_LAB_CONFIRM=yes ./<this-script> verify
#      Expected:
#          PASS ✅  /v1/logs returned HTTP 200 and a LogRecord reached the exporter.
#
#  WHAT TO REMEMBER FOR THE EXAM
#  -----------------------------
#    * Each signal (traces / metrics / logs) is wired independently in the
#      Collector; a component being "present" is not the same as being "used".
#    * A signal only flows when a pipeline of that TYPE lists it. The pipeline
#      key name (traces/metrics/logs) IS the signal selector.
#    * Health check / process-up says nothing about a specific signal — verify
#      signals individually (send one of each), which is exactly how you triage
#      "traces work but logs vanished" in production.
#
#  Refs: https://opentelemetry.io/docs/collector/configuration/#pipelines
#        https://opentelemetry.io/docs/concepts/signals/
# ============================================================================