#!/usr/bin/env bash
#
# ==============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 4: OpenTelemetry API & SDK  ·  Topic 4.3: Error Handling  (weight 2.5)
#
#  BREAK & FIX LAB  —  "The remote backend is down and nobody noticed"
#
#  What this teaches
#  -----------------
#  In OpenTelemetry the golden rule of error handling is: a telemetry pipeline
#  MUST NOT throw and MUST NOT lose data silently. The Collector implements this
#  in the *exporter helper*, which wraps every exporter with two independent
#  resilience layers:
#
#     sending_queue     -> an in-memory (optionally persistent) buffer that
#                          absorbs bursts and applies backpressure instead of
#                          dropping data when the consumer is slow or down.
#     retry_on_failure  -> exponential backoff around *transient* export errors
#                          (connection refused, 503, deadline exceeded, ...).
#
#  Disable both and any downstream hiccup becomes *permanent, silent data loss*:
#  the exporter tries once, fails, logs a line, increments a counter, and throws
#  the batch away. The application keeps sending ERROR spans (status code 2) that
#  document real incidents — and those are exactly the spans that vanish.
#
#  This lab stands up a Collector whose remote OTLP backend is unreachable and
#  whose error handling has been switched OFF. You will observe the data loss,
#  diagnose it, and restore correct error handling.
#
#  Sources (cite these when studying)
#  ----------------------------------
#    OTCA curriculum ......... https://github.com/cncf/curriculum
#    Error handling spec ..... https://opentelemetry.io/docs/specs/otel/error-handling/
#    Exporter queue & retry .. https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
#    Collector troubleshoot .. https://opentelemetry.io/docs/collector/troubleshooting/
#    Span Status (code=ERROR)  https://opentelemetry.io/docs/specs/otel/trace/api/#set-status
#
#  SAFETY: designed for a DISPOSABLE lab VM. It touches only loopback ports and
#  a scratch directory under /tmp. It never needs root, never edits system
#  services, and cleans up after itself with `clean`.
# ==============================================================================

set -euo pipefail

# ---- Lab parameters (override via environment if you must) -------------------
LAB_DIR="${LAB_DIR:-/tmp/otca-4.3-error-handling}"
OTELCOL_VERSION="${OTELCOL_VERSION:-0.116.0}"   # pinned: config schema is version-sensitive; keep it
OTLP_HTTP_PORT="${OTLP_HTTP_PORT:-4318}"        # Collector OTLP/HTTP receiver
METRICS_PORT="${METRICS_PORT:-8888}"            # Collector self-observability (Prometheus)
DEAD_BACKEND_PORT="${DEAD_BACKEND_PORT:-4999}"  # nothing listens here == remote backend is DOWN

CFG="${LAB_DIR}/collector.yaml"
LOG="${LAB_DIR}/collector.log"
PIDFILE="${LAB_DIR}/collector.pid"
BINPATH_STATE="${LAB_DIR}/.binpath"
LOCAL_SINK="${LAB_DIR}/local-sink.json"         # reliable local exporter (proves the pipeline flows)

# ---- Small helpers -----------------------------------------------------------
say()  { printf '\033[1;36m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&- && return 0 || return 1; }

confirm_disposable() {
  [ "${LAB_CONFIRM:-}" = "1" ] && return 0
  warn "This starts a local OpenTelemetry Collector and pushes test telemetry on loopback ports."
  warn "Run it ONLY on a disposable lab VM."
  read -r -p "Continue? [y/N] " ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) echo "Aborted."; exit 1 ;; esac
}

# ---- Collector binary resolution / download ----------------------------------
resolve_bin() {
  if [ -s "$BINPATH_STATE" ] && [ -x "$(cat "$BINPATH_STATE")" ]; then
    OTELCOL_BIN="$(cat "$BINPATH_STATE")"; return 0
  fi
  if [ -x "${LAB_DIR}/otelcol-contrib" ]; then
    OTELCOL_BIN="${LAB_DIR}/otelcol-contrib"; return 0
  fi
  if command -v otelcol-contrib >/dev/null 2>&1; then
    OTELCOL_BIN="$(command -v otelcol-contrib)"; return 0
  fi
  return 1
}

install_collector() {
  mkdir -p "$LAB_DIR"
  if resolve_bin; then
    say "Using Collector binary: $OTELCOL_BIN"
    echo "$OTELCOL_BIN" > "$BINPATH_STATE"; return 0
  fi
  local arch tarch url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) tarch="amd64" ;;
    aarch64|arm64) tarch="arm64" ;;
    *) bad "Unsupported architecture: $arch"; exit 1 ;;
  esac
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_${tarch}.tar.gz"
  say "Downloading otelcol-contrib v${OTELCOL_VERSION} (${tarch}) ..."
  curl -fsSL "$url" -o "${LAB_DIR}/otelcol.tgz"
  tar -xzf "${LAB_DIR}/otelcol.tgz" -C "$LAB_DIR" otelcol-contrib
  chmod +x "${LAB_DIR}/otelcol-contrib"
  OTELCOL_BIN="${LAB_DIR}/otelcol-contrib"
  echo "$OTELCOL_BIN" > "$BINPATH_STATE"
  ok "Collector installed at $OTELCOL_BIN"
}

# ---- The BROKEN configuration (this is what the student must repair) ----------
write_broken_config() {
  cat > "$CFG" <<YAML
# OTCA 4.3 — Error Handling lab.  Collector config with error handling DISABLED.
#
# Two exporters fan out from the traces pipeline:
#   * file/local-sink   -> always works; proves data reaches the pipeline.
#   * otlphttp/backend  -> points at a DOWN backend (127.0.0.1:${DEAD_BACKEND_PORT}).
#
# Because the backend exporter has NO error handling, every batch destined for
# the remote backend is dropped on the first failure. The ERROR spans your app
# emits are lost with only a log line to show for it.

receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:${OTLP_HTTP_PORT}

processors:
  batch:
    timeout: 1s

exporters:
  # Reliable local sink — NOT the thing under test. It just proves the pipeline
  # is healthy and that data really did arrive at the Collector.
  file/local-sink:
    path: ${LOCAL_SINK}

  # Remote backend. It is DOWN (nothing listens on ${DEAD_BACKEND_PORT}).
  otlphttp/backend:
    endpoint: http://127.0.0.1:${DEAD_BACKEND_PORT}
    retry_on_failure:
      enabled: false      # <-- BROKEN: transient export errors are NOT retried
    sending_queue:
      enabled: false      # <-- BROKEN: no buffer, no backpressure, no persistence

service:
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      address: 127.0.0.1:${METRICS_PORT}
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [file/local-sink, otlphttp/backend]
YAML
}

# ---- Collector lifecycle -----------------------------------------------------
start_collector() {
  resolve_bin || { bad "No Collector binary. Run: $0 setup"; exit 1; }
  stop_collector
  say "Starting Collector ..."
  : > "$LOG"
  nohup "$OTELCOL_BIN" --config "$CFG" >>"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  local i
  for i in $(seq 1 25); do
    if port_open "$OTLP_HTTP_PORT"; then ok "Collector up (pid $(cat "$PIDFILE"))"; return 0; fi
    if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      bad "Collector exited during startup. Last log lines:"; tail -n 20 "$LOG"; exit 1
    fi
    sleep 0.4
  done
  bad "Collector did not open port ${OTLP_HTTP_PORT} in time. Log tail:"; tail -n 20 "$LOG"; exit 1
}

stop_collector() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    sleep 0.5
    kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}

# ---- Workload: emit ERROR spans (status code 2) via OTLP/HTTP JSON -----------
gen_traces() {
  local n="${1:-20}"
  port_open "$OTLP_HTTP_PORT" || { bad "Collector not listening on ${OTLP_HTTP_PORT}. Run: $0 setup"; return 1; }
  say "Pushing ${n} ERROR spans to http://127.0.0.1:${OTLP_HTTP_PORT}/v1/traces"
  local i end start tid sid
  for ((i=0; i<n; i++)); do
    end="$(date +%s%N)"
    start="$(( end - 5000000 ))"   # 5 ms span
    tid="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sid="$(head -c8  /dev/urandom | od -An -tx1 | tr -d ' \n')"
    curl -s -o /dev/null -X POST "http://127.0.0.1:${OTLP_HTTP_PORT}/v1/traces" \
      -H 'Content-Type: application/json' --data-binary @- <<JSON || true
{
  "resourceSpans": [{
    "resource": { "attributes": [
      { "key": "service.name", "value": { "stringValue": "otca-checkout" } }
    ]},
    "scopeSpans": [{
      "scope": { "name": "otca.lab" },
      "spans": [{
        "traceId": "${tid}",
        "spanId": "${sid}",
        "name": "POST /checkout",
        "kind": 2,
        "startTimeUnixNano": "${start}",
        "endTimeUnixNano": "${end}",
        "status": { "code": 2, "message": "payment gateway timeout" },
        "attributes": [
          { "key": "http.response.status_code", "value": { "intValue": "503" } }
        ]
      }]
    }]
  }]
}
JSON
  done
  sleep 2   # let the batch processor flush
  ok "Workload sent."
}

# ---- Diagnostics the student runs while investigating ------------------------
inspect() {
  echo "==================== COLLECTOR STATE ===================="
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    ok "Collector running (pid $(cat "$PIDFILE"))"
  else
    bad "Collector NOT running"
  fi

  echo
  echo "---- Local sink (file exporter): did data reach the pipeline? ----"
  if [ -s "$LOCAL_SINK" ]; then
    ok "local-sink has $(wc -l < "$LOCAL_SINK") batch line(s) -> the pipeline IS flowing."
  else
    warn "local-sink is empty -> generate a workload first: $0 gen"
  fi

  echo
  echo "---- Collector logs: what happened to the REMOTE backend export? ----"
  grep -Ei 'error|fail|drop|retry|queue|refused' "$LOG" | tail -n 15 || true

  echo
  echo "---- Self-observability metrics (best-effort, port ${METRICS_PORT}) ----"
  if port_open "$METRICS_PORT"; then
    curl -s "http://127.0.0.1:${METRICS_PORT}/metrics" \
      | grep -E 'otelcol_exporter_(send_failed_spans|sent_spans|queue_size|queue_capacity|enqueue_failed_spans)' \
      | grep -Ev '^#' || warn "metrics not populated yet — send a workload and retry"
  else
    warn "metrics endpoint not reachable in this Collector build"
  fi
  echo "========================================================="
  echo "Read: 'send_failed_spans' for exporter=\"otlphttp/backend\" climbing with"
  echo "      NO queue_size means data is being dropped on first failure."
}

# ---- Automated grading -------------------------------------------------------
verify() {
  local fails=0
  echo "==================== VERIFY ===================="

  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    ok "Collector is running with your edited config."
  else
    bad "Collector is not running (edit ${CFG}, then: $0 restart)"; fails=$((fails+1))
  fi

  local leftover
  leftover="$(grep -c 'enabled: false' "$CFG" 2>/dev/null || true)"
  if [ "${leftover:-0}" -eq 0 ] && grep -q 'retry_on_failure' "$CFG" && grep -q 'sending_queue' "$CFG"; then
    ok "Error handling is enabled on the backend exporter (retry + queue)."
  else
    bad "Backend exporter still has error handling disabled ('enabled: false' present)."; fails=$((fails+1))
  fi

  # Fresh workload; with a queue enabled the Collector buffers/retries instead of
  # emitting an immediate permanent-drop for the batch we just sent.
  gen_traces 10 >/dev/null 2>&1 || true
  if grep -Eiq 'dropping data|permanent error' <(tail -n 25 "$LOG"); then
    warn "Still seeing drop/permanent-error log lines — inspect further: $0 inspect"
  else
    ok "No immediate permanent-drop after the last workload — data is being buffered/retried."
  fi

  echo "-----------------------------------------------"
  if [ "$fails" -eq 0 ]; then
    ok "PASS — error handling restored. Transient backend outages no longer lose data."
  else
    bad "NOT YET — ${fails} check(s) failing. See the mission below."
  fi
  echo "==============================================="
  [ "$fails" -eq 0 ]
}

mission() {
  cat <<TXT

============================================================================
 SYMPTOM YOU WILL SEE
============================================================================
 * The local file sink (${LOCAL_SINK}) fills up: the pipeline works and the
   Collector really receives your spans.
 * The remote backend export FAILS. Collector logs repeat something like:
       Exporting failed. ... connection refused
       Dropping data because sending_queue is disabled ... (or 'Permanent error')
   and the metric otelcol_exporter_send_failed_spans{exporter="otlphttp/backend"}
   keeps climbing while there is NO otelcol_exporter_queue_size at all.
 * Net effect: every ERROR span headed for the backend is LOST on first failure,
   with no retry and no buffering. That is broken error handling.

============================================================================
 YOUR GOAL
============================================================================
 Make the backend exporter survive a transient/temporary backend outage WITHOUT
 losing telemetry. When the backend is down the Collector must queue and retry
 (with backoff), not drop on the first error.

 Investigate ...... $0 inspect
 Edit the config .. ${CFG}   (fix exporters.otlphttp/backend)
 Reload ........... $0 restart
 Re-test .......... $0 gen ; $0 inspect
 Grade ............ $0 verify
 Tear down ........ $0 clean
============================================================================
TXT
}

setup() {
  confirm_disposable
  mkdir -p "$LAB_DIR"
  install_collector
  write_broken_config
  start_collector
  gen_traces 20
  inspect
  mission
}

usage() {
  cat <<TXT
OTCA 4.3 Error Handling — break & fix lab
Usage: $0 [setup|inspect|gen [N]|restart|verify|clean]
  setup    install Collector, deploy the BROKEN config, start it, send workload (default)
  inspect  show pipeline/log/metric symptoms
  gen [N]  push N ERROR spans (default 20)
  restart  reload the Collector after you edit ${CFG}
  verify   grade your fix
  clean    stop the Collector and remove ${LAB_DIR}
TXT
}

case "${1:-setup}" in
  setup)   setup ;;
  inspect) inspect ;;
  gen)     resolve_bin >/dev/null 2>&1 || true; gen_traces "${2:-20}" ;;
  restart) start_collector; ok "Reloaded with current config. Now: $0 gen && $0 inspect" ;;
  verify)  verify ;;
  clean)   stop_collector; rm -rf "$LAB_DIR"; ok "Lab removed." ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac

# =============================================================================
# ============================  SOLUTION (spoiler)  ===========================
# =============================================================================
#
# STEP 1 — Reproduce and read the evidence
# ----------------------------------------
#   $ ./this_script.sh inspect
#
#   You will see, side by side:
#     - local-sink.json growing              -> the pipeline itself is healthy;
#                                               the problem is ONE exporter, not
#                                               the receiver or processors.
#     - Collector log lines such as:
#         "Exporting failed. Rejecting data. ... connect: connection refused"
#         "Dropping data because sending_queue is disabled"  (or "Permanent error")
#     - otelcol_exporter_send_failed_spans{exporter="otlphttp/backend"} rising,
#       and NO otelcol_exporter_queue_size series at all.
#
#   Diagnosis: the backend is unreachable (transient outage), but the exporter
#   has retry_on_failure.enabled=false and sending_queue.enabled=false, so the
#   first failure is treated as terminal and the batch is discarded. This is the
#   classic OpenTelemetry error-handling failure: silent, permanent data loss on
#   a recoverable error.
#
# STEP 2 — Fix the error handling in the exporter
# -----------------------------------------------
#   Edit ${LAB_DIR}/collector.yaml and replace the otlphttp/backend block with:
#
#     otlphttp/backend:
#       endpoint: http://127.0.0.1:4999
#       retry_on_failure:
#         enabled: true          # retry transient errors ...
#         initial_interval: 1s    # ... starting at 1s ...
#         max_interval: 10s       # ... capped at 10s per attempt ...
#         max_elapsed_time: 120s  # ... giving up only after 2 minutes.
#       sending_queue:
#         enabled: true          # buffer instead of drop; apply backpressure
#         num_consumers: 4
#         queue_size: 1000       # bound the buffer so memory stays predictable
#         # For crash-safe delivery, back the queue with disk:
#         #   storage: file_storage       (add the file_storage extension)
#
#   Notes on the mechanics (why this is the *correct* answer, not just "turn it on"):
#     * retry_on_failure only retries errors the exporter classifies as RETRYABLE
#       (connection refused, 503, DEADLINE_EXCEEDED). A PERMANENT error (e.g. 400
#       bad request) is NOT retried by design — retrying it would loop forever.
#     * sending_queue decouples the pipeline from the exporter. Without it, retry
#       backoff blocks the consumer and creates backpressure to the receiver.
#     * queue_size bounds memory: when the queue is FULL the Collector still drops
#       (and increments otelcol_exporter_enqueue_failed_spans) — but now that is a
#       deliberate, observable capacity limit, not an accident on the first error.
#     * For guaranteed delivery across Collector restarts, persist the queue with
#       the file_storage extension (storage: file_storage).
#
# STEP 3 — Reload and confirm
# ---------------------------
#   $ ./this_script.sh restart
#   $ ./this_script.sh gen
#   $ ./this_script.sh inspect
#
#   Now the logs show retry/backoff ("... will retry ...") instead of immediate
#   drops, and otelcol_exporter_queue_size is > 0 (data is buffered). Optionally,
#   bring the backend UP (any listener on port 4999) and watch the queue flush —
#   the previously "lost" ERROR spans are delivered once the backend recovers.
#
#   $ ./this_script.sh verify     # -> PASS
#
# STEP 4 — Relate it back to the exam
# -----------------------------------
#   OpenTelemetry error handling is layered, and 4.3 expects you to know all of it:
#     API/SDK layer .... never throw into user code; route problems to a global
#                        error handler; ERROR is expressed as Span Status code=2
#                        plus RecordException, NOT as a crash.
#     Collector layer .. the exporter helper (sending_queue + retry_on_failure) is
#                        the resilience boundary; failures are LOGGED and COUNTED
#                        (send_failed_spans / enqueue_failed_spans), never hidden.
#   The bug in this lab was a Collector-layer error-handling misconfiguration that
#   converted a recoverable, transient failure into silent permanent data loss.
#
#   References:
#     https://opentelemetry.io/docs/specs/otel/error-handling/
#     https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
#     https://opentelemetry.io/docs/collector/troubleshooting/
#     https://opentelemetry.io/docs/specs/otel/trace/api/#set-status
# =============================================================================