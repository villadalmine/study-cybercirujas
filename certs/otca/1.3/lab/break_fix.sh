#!/usr/bin/env bash
#
# ==============================================================================
# OTCA — OpenTelemetry Certified Associate
# Domain 1.3: Instrumentation  (exam weight: 4.5%)
# Reference syllabus: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
# OpenTelemetry SDK env spec: https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
# Python zero-code instrumentation: https://opentelemetry.io/docs/zero-code/python/
# ==============================================================================
#
# BREAK & FIX LAB — "The service is healthy but the traces vanished"
#
# This script builds a tiny auto-instrumented HTTP service on a DISPOSABLE lab
# VM, proves telemetry is flowing, then injects ONE controlled instrumentation
# misconfiguration. Your job is to diagnose why spans stopped and restore them.
#
# It is SAFE: everything lives under ~/otca-lab-1.3, the service binds to
# 127.0.0.1 only, no system packages or system config are touched, and a single
# `teardown` removes the whole thing. Do NOT run it on a machine you care about.
#
# Usage:
#   ./otca-1.3-break-fix.sh run        # setup + prove healthy + break + challenge (default)
#   ./otca-1.3-break-fix.sh check      # restart with CURRENT config and test if traces are back
#   ./otca-1.3-break-fix.sh hint       # progressive hints
#   ./otca-1.3-break-fix.sh solution   # print the full solution
#   ./otca-1.3-break-fix.sh teardown   # stop the service and delete the lab
# ------------------------------------------------------------------------------

set -euo pipefail

LAB_DIR="${HOME}/otca-lab-1.3"
ENV_FILE="${LAB_DIR}/otel.env"
APP_FILE="${LAB_DIR}/app.py"
LOG_FILE="${LAB_DIR}/app.log"
PID_FILE="${LAB_DIR}/app.pid"
VENV="${LAB_DIR}/.venv"
APP_HOST="127.0.0.1"
APP_PORT="8080"
APP_URL="http://${APP_HOST}:${APP_PORT}/checkout"

# --- pretty output -----------------------------------------------------------
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"
  YEL="$(printf '\033[33m')"; CYN="$(printf '\033[36m')"; RST="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$CYN" "$RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s[x] %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$BOLD" "------------------------------------------------------------------------------" "$RST"; }

# --- safety gate: this lab is destructive-by-design, refuse to be casual ------
acknowledge() {
  if [ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB:-}" = "yes" ]; then return 0; fi
  warn "This lab writes files, installs into a venv and starts a local service."
  warn "Run it ONLY on a throwaway VM. It never touches system config."
  printf '%sType exactly "lab" to continue:%s ' "$BOLD" "$RST"
  read -r reply
  [ "$reply" = "lab" ] || die "Aborted. Re-run on a disposable VM when ready."
}

# --- preflight ---------------------------------------------------------------
preflight() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required."
  python3 -c 'import venv' 2>/dev/null || die "python3 venv module is required (install python3-venv)."
  command -v curl >/dev/null 2>&1 || die "curl is required."
  ok "Preflight OK: python3, venv, curl present."
}

# --- lab materials -----------------------------------------------------------
write_files() {
  mkdir -p "$LAB_DIR"

  cat > "$APP_FILE" <<'PY'
# Minimal service under test. The route is auto-instrumented by the Flask
# instrumentation that opentelemetry-instrument injects at import time; the
# application code itself contains ZERO telemetry calls (that is the whole
# point of zero-code / auto instrumentation).
from flask import Flask, jsonify

app = Flask(__name__)


@app.route("/checkout")
def checkout():
    # A trivial "unit of work" — one server span per request is emitted by the
    # Flask instrumentation, not by anything written here.
    return jsonify(status="ok", service="checkout-api"), 200


if __name__ == "__main__":
    # threaded=False + no reloader => a single, predictable PID to manage.
    app.run(host="127.0.0.1", port=8080, threaded=False, use_reloader=False)
PY

  # The HEALTHY baseline configuration. Console exporter means: if the SDK is
  # producing spans, they are rendered as JSON straight into app.log, so the
  # student can literally see instrumentation output with no Collector required.
  cat > "$ENV_FILE" <<'ENV'
# ---- OpenTelemetry SDK configuration (healthy baseline) ----
OTEL_SERVICE_NAME=checkout-api
OTEL_TRACES_EXPORTER=console
OTEL_METRICS_EXPORTER=none
OTEL_LOGS_EXPORTER=none
# Flush the BatchSpanProcessor fast so spans show up within a second or two.
OTEL_BSP_SCHEDULE_DELAY=1000
ENV
  ok "Wrote app.py and otel.env under ${LAB_DIR}"
}

setup_venv() {
  if [ ! -x "${VENV}/bin/opentelemetry-instrument" ]; then
    info "Creating virtualenv and installing OpenTelemetry (first run only)..."
    python3 -m venv "$VENV"
    "${VENV}/bin/pip" install --upgrade pip >/dev/null
    # Install the app framework FIRST so opentelemetry-bootstrap can detect it
    # and pull the matching instrumentation library.
    "${VENV}/bin/pip" install "flask<4" opentelemetry-distro opentelemetry-exporter-otlp >/dev/null
    "${VENV}/bin/opentelemetry-bootstrap" -a install >/dev/null
    ok "OpenTelemetry Python distro + auto-instrumentation installed."
  else
    ok "Virtualenv already provisioned."
  fi
  "${VENV}/bin/pip" show opentelemetry-instrumentation-flask >/dev/null 2>&1 \
    || die "Flask instrumentation missing — re-run after 'teardown'."
}

# --- service lifecycle -------------------------------------------------------
stop_app() {
  if [ -f "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}

start_app() {
  stop_app
  : > "$LOG_FILE"
  # Load the CURRENT env file into the environment, exactly as an operator would
  # via an EnvironmentFile= in a systemd unit or an envFrom in a Pod spec.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  nohup "${VENV}/bin/opentelemetry-instrument" "${VENV}/bin/python" "$APP_FILE" \
    >"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"

  # Wait for the port to accept connections.
  for _ in $(seq 1 30); do
    if curl -fsS "$APP_URL" >/dev/null 2>&1; then return 0; fi
    if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      warn "Service exited early. Last log lines:"; tail -n 20 "$LOG_FILE" >&2
      die "The instrumented service failed to start."
    fi
    sleep 0.5
  done
  die "Service did not become ready on ${APP_URL}."
}

# Generate traffic, then report whether any span reached the exporter.
# Returns 0 if telemetry is flowing, 1 if it is silent.
telemetry_present() {
  curl -fsS "$APP_URL" >/dev/null 2>&1 || true
  curl -fsS "$APP_URL" >/dev/null 2>&1 || true
  sleep 3   # let the BatchSpanProcessor flush (OTEL_BSP_SCHEDULE_DELAY=1000ms)
  grep -q '"trace_id"' "$LOG_FILE" 2>/dev/null
}

# --- the break ---------------------------------------------------------------
break_it() {
  # Controlled fault injection: a single-line change to the SDK configuration.
  # We turn the traces exporter OFF. The application is untouched and still
  # returns HTTP 200; only the observability signal disappears. This mirrors the
  # single most common real-world instrumentation incident: the code is emitting
  # spans, but the pipeline that carries them out of the process is disabled.
  sed -i 's/^OTEL_TRACES_EXPORTER=.*/OTEL_TRACES_EXPORTER=none/' "$ENV_FILE"
  start_app
}

# --- narrative sections ------------------------------------------------------
challenge_banner() {
  rule
  say "${BOLD}OTCA 1.3 — INSTRUMENTATION :: BREAK & FIX${RST}"
  rule
  say ""
  say "${BOLD}SCENARIO${RST}"
  say "  'checkout-api' is a zero-code (auto) instrumented Flask service running"
  say "  under ${VENV}/bin/opentelemetry-instrument. It exports spans with the"
  say "  console exporter, so working telemetry appears as JSON in:"
  say "      ${CYN}${LOG_FILE}${RST}"
  say ""
  say "  A change was pushed to its SDK configuration (${ENV_FILE})."
  say "  The service was restarted. Then the on-call alert fired."
  say ""
  say "${BOLD}${RED}SYMPTOM YOU WILL SEE${RST}"
  say "  * The service is perfectly healthy:"
  say "        curl ${APP_URL}   ->   HTTP 200  {\"status\":\"ok\"}"
  say "  * There are NO exporter errors, NO stack traces, NO crash in the log."
  say "  * But ${RED}not a single span${RST} is written to the log anymore. The trace"
  say "    for /checkout has simply gone dark. Grafana/Jaeger shows the service"
  say "    flat-lined even though it is serving traffic."
  say ""
  say "${BOLD}${GRN}YOUR GOAL${RST}"
  say "  Restore trace emission WITHOUT editing app.py. Only the SDK"
  say "  configuration is allowed to change. Success = a span with a"
  say "  \"trace_id\" for /checkout is emitted again."
  say ""
  say "${BOLD}INVESTIGATE${RST}"
  say "  cat  ${ENV_FILE}"
  say "  cat  ${LOG_FILE}"
  say "  ${VENV}/bin/opentelemetry-instrument --help   # what wraps the process?"
  say "  # Reference: https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/"
  say ""
  say "${BOLD}WHEN YOU THINK YOU FIXED IT${RST}, re-run:"
  say "  ${CYN}$0 check${RST}      (restarts the service with your config and grades it)"
  say ""
  say "Stuck? ${CYN}$0 hint${RST}     Give up? ${CYN}$0 solution${RST}"
  rule
}

grade() {
  info "Restarting checkout-api with the current configuration..."
  start_app
  if telemetry_present; then
    ok "${GRN}SOLVED.${RST} A span with a trace_id is being exported again:"
    grep '"trace_id"' "$LOG_FILE" | head -n 1 | sed 's/^/    /'
    say ""
    ok "Telemetry pipeline restored. Run '$0 teardown' to clean up the lab."
  else
    warn "${RED}Still dark.${RST} The service answers on ${APP_URL} but no span"
    warn "reached the exporter. Re-check OTEL_TRACES_EXPORTER and whether the"
    warn "SDK is globally disabled. Then run '$0 check' again."
    return 1
  fi
}

hint() {
  say "${BOLD}Hint 1${RST}  The app returns 200, so the network/app layer is fine."
  say "         The failure is in the SIGNAL, not the service. Diff the config"
  say "         against a healthy baseline mentally: what carries spans OUT?"
  say ""
  say "${BOLD}Hint 2${RST}  Auto-instrumentation has three switches that can each"
  say "         silence traces independently:"
  say "           1) the process must be wrapped by opentelemetry-instrument,"
  say "           2) the whole SDK must not be disabled (OTEL_SDK_DISABLED),"
  say "           3) an exporter must be selected (OTEL_TRACES_EXPORTER)."
  say ""
  say "${BOLD}Hint 3${RST}  grep for OTEL_TRACES_EXPORTER in ${ENV_FILE}."
  say "         A value of 'none' means: instrument everything, produce spans,"
  say "         then throw them away. That is a valid, silent, error-free config."
}

teardown() {
  stop_app
  rm -rf "$LAB_DIR"
  ok "Lab torn down: ${LAB_DIR} removed, service stopped."
}

# --- entrypoint --------------------------------------------------------------
main() {
  local cmd="${1:-run}"
  case "$cmd" in
    run)
      acknowledge; preflight; write_files; setup_venv
      info "Bringing up the HEALTHY baseline to prove instrumentation works..."
      start_app
      if telemetry_present; then
        ok "Baseline verified — spans are being exported to the console:"
        grep '"trace_id"' "$LOG_FILE" | head -n 1 | sed 's/^/    /'
      else
        die "Baseline failed to emit spans; environment is not ready to break."
      fi
      info "Injecting the controlled fault..."
      break_it
      ok "Fault injected. The service is up; the traces are not."
      say ""
      challenge_banner
      ;;
    check|verify|grade) grade ;;
    hint)               hint ;;
    solution)           print_solution ;;
    teardown|clean)     teardown ;;
    *) die "Unknown command '$cmd'. Use: run | check | hint | solution | teardown" ;;
  esac
}

# print_solution just cats the commented block below so 'solution' works too.
print_solution() {
  sed -n '/^# ==== SOLUTION/,/^# ==== END SOLUTION/p' "$0" | sed 's/^# \{0,1\}//'
}

main "$@"
exit 0

# ==============================================================================
# ==== SOLUTION (step by step) — do not peek until you have tried =============
# ==============================================================================
#
# ROOT CAUSE
#   The injected fault set   OTEL_TRACES_EXPORTER=none   in otel.env.
#   With this value the SDK is fully active and DOES create spans for every
#   /checkout request, but it attaches a no-op exporter, so every span is
#   silently discarded. Because it is a legal configuration, there is no error,
#   no warning and no crash — the classic "service healthy, traces missing"
#   incident. This is why 1.3 stresses that instrumentation has several
#   independent kill-switches and you must check each one.
#
# DIAGNOSTIC LADDER (rule out top-down; the answer is at rung 4)
#   1. Is the service even producing traffic to instrument?
#          curl -i http://127.0.0.1:8080/checkout        # -> 200, so yes.
#   2. Is the process actually wrapped by auto-instrumentation?
#          ps -ef | grep opentelemetry-instrument        # -> yes, it is wrapped.
#      (If it were started as plain `python app.py`, NO instrumentation loads —
#       that is a different, equally common break. Fix: prepend
#       `opentelemetry-instrument` to the start command.)
#   3. Is the SDK globally disabled?
#          grep OTEL_SDK_DISABLED otca-lab-1.3/otel.env  # -> absent/false, good.
#      (OTEL_SDK_DISABLED=true would turn the SDK into a no-op entirely.)
#   4. Is a traces exporter selected?
#          grep OTEL_TRACES_EXPORTER otca-lab-1.3/otel.env
#          # -> OTEL_TRACES_EXPORTER=none      <-- THE BUG.
#
# FIX
#   Edit ~/otca-lab-1.3/otel.env and set a real exporter. For this lab restore
#   the console exporter so spans are visible again:
#
#       OTEL_TRACES_EXPORTER=console
#
#   One-liner:
#       sed -i 's/^OTEL_TRACES_EXPORTER=.*/OTEL_TRACES_EXPORTER=console/' \
#           ~/otca-lab-1.3/otel.env
#
#   Then let the grader restart and verify:
#       ./otca-1.3-break-fix.sh check
#
#   Expected: a span JSON containing "name": "/checkout" and a "trace_id"
#   is printed to app.log, confirming the pipeline is live again.
#
# PRODUCTION VARIANT (what you would really set)
#   In production you rarely export to the console. You point the SDK at a
#   Collector over OTLP. The equivalent healthy config is:
#
#       OTEL_TRACES_EXPORTER=otlp
#       OTEL_EXPORTER_OTLP_PROTOCOL=grpc            # or http/protobuf
#       OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
#
#   Watch the two pitfalls the exam probes here:
#     * PORT/PROTOCOL mismatch — gRPC listens on 4317, HTTP on 4318. Setting
#       protocol=grpc against :4318 (or http/protobuf against :4317) fails to
#       export, usually with connection-refused/UNAVAILABLE in the app log.
#     * ENDPOINT semantics — OTEL_EXPORTER_OTLP_ENDPOINT is the BASE; the HTTP
#       exporter appends the signal path (/v1/traces). The signal-specific
#       OTEL_EXPORTER_OTLP_TRACES_ENDPOINT must be the FULL path and no suffix
#       is appended. Mixing these up sends traces to a 404.
#
# TAKEAWAYS FOR OTCA 1.3 (Instrumentation)
#   * Zero-code instrumentation = the SDK + instrumentation libraries are
#     injected at startup (here by opentelemetry-instrument); application code
#     stays clean of telemetry calls.
#   * "No spans" has a fixed short list of causes: process not wrapped,
#     OTEL_SDK_DISABLED=true, OTEL_TRACES_EXPORTER=none/misset, or a broken
#     exporter endpoint/protocol. Walk them in that order.
#   * A silent, error-free pipeline can still be dropping 100% of telemetry.
#     Prove emission with the console exporter before blaming the backend.
#
# Sources:
#   https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
#   https://opentelemetry.io/docs/zero-code/python/
#   https://opentelemetry.io/docs/specs/otlp/           (ports 4317 gRPC / 4318 HTTP)
# ==== END SOLUTION ============================================================