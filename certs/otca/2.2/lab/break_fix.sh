#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 2 · The Collector — Topic 2.2: Composability and Extension  (weight 6.57)
#  BREAK & FIX lab — disposable VM only
# ============================================================================
#
#  WHAT THIS TEACHES
#  The Collector is not a monolith: it is a set of typed components (receivers,
#  processors, exporters, connectors, extensions) that do NOTHING until you
#  *compose* them into pipelines under `service:`. A component declared in the
#  top-level section is inert; it only runs once a pipeline names it. The name
#  after the slash ("debug/backend", "otlp/2") is an INSTANCE id — a distinct
#  component that must be declared before any pipeline can reference it. This
#  named-wiring model is exactly the "composability" the objective is about, and
#  `extensions:` is the "extension" half: cross-cutting components (health_check,
#  pprof, zpages) that attach to the service rather than to a data pipeline.
#
#  This script builds a known-good Collector, proves telemetry flows, then
#  introduces ONE controlled composition fault. You will see the symptom and
#  must restore correct composition. The full solution is commented at the end.
#
#  SAFETY
#  Runs entirely under a private lab directory, binds only to 127.0.0.1 on
#  unprivileged ports (4317/4318/13133), needs no root, touches no system
#  service, and installs the Collector binary locally (never system-wide).
#  Still: run it on a THROWAWAY VM you can delete.
#
#  OFFICIAL SOURCES
#   - Collector configuration ....... https://opentelemetry.io/docs/collector/configuration/
#   - Collector architecture ........ https://opentelemetry.io/docs/collector/architecture/
#   - Connectors (pipeline joins) ... https://opentelemetry.io/docs/collector/building/connectors/
#   - Extensions .................... https://opentelemetry.io/docs/collector/configuration/#extensions
#   - Releases (binaries) ........... https://github.com/open-telemetry/opentelemetry-collector-releases
#   - OTCA curriculum ............... https://github.com/cncf/curriculum
# ============================================================================

set -uo pipefail   # NOT -e: we deliberately trigger a failing run and inspect it.

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-$HOME/otca-lab-2.2-composability}"
CFG="$LAB_DIR/collector.yaml"
CFG_GOOD="$LAB_DIR/collector.good.yaml"     # instructor backup — do not peek while solving
LOG="$LAB_DIR/collector.log"
SPAN="$LAB_DIR/span.json"
DEFAULT_VERSION="0.128.0"                    # fallback only; latest is resolved at runtime
COL=""                                       # resolved Collector binary
COL_PID=""

OTLP_HTTP="127.0.0.1:4318"
OTLP_GRPC="127.0.0.1:4317"
HEALTH="127.0.0.1:13133"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  if [ -n "${COL_PID:-}" ] && kill -0 "$COL_PID" 2>/dev/null; then
    kill "$COL_PID" 2>/dev/null || true
    wait "$COL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------------
# Ensure a Collector (contrib) binary is available, installed locally.
# ----------------------------------------------------------------------------
ensure_collector() {
  for c in otelcol-contrib otelcol "$LAB_DIR/otelcol-contrib"; do
    if have "$c"; then COL="$(command -v "$c")"; ok "Using Collector: $COL"; return 0; fi
  done

  log "Collector not found — installing a local copy under $LAB_DIR"
  have curl || { err "curl is required to install the Collector."; exit 1; }
  have tar  || { err "tar is required to install the Collector.";  exit 1; }

  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) err "Unsupported arch $(uname -m). Install otelcol-contrib manually."; exit 1 ;;
  esac

  local tag ver
  tag="$(curl -fsSL https://api.github.com/repos/open-telemetry/opentelemetry-collector-releases/releases/latest \
         2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | grep -oE 'v[0-9.]+' || true)"
  ver="${tag#v}"
  [ -n "$ver" ] || { ver="$DEFAULT_VERSION"; warn "Could not resolve latest tag; falling back to $ver"; }

  local url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${ver}/otelcol-contrib_${ver}_linux_${arch}.tar.gz"
  log "Downloading $url"
  if ! curl -fsSL "$url" -o "$LAB_DIR/otelcol.tgz"; then
    err "Download failed (offline?). Install otelcol-contrib manually and re-run."
    exit 1
  fi
  tar -xzf "$LAB_DIR/otelcol.tgz" -C "$LAB_DIR" otelcol-contrib
  chmod +x "$LAB_DIR/otelcol-contrib"
  COL="$LAB_DIR/otelcol-contrib"
  ok "Installed Collector v${ver}: $COL"
}

# ----------------------------------------------------------------------------
# Write a correctly-composed, syntactically valid Collector config.
#   traces pipeline: otlp -> [memory_limiter, batch] -> debug
#   service extensions: health_check   (the "extension" facet)
# ----------------------------------------------------------------------------
write_good_config() {
  cat >"$CFG" <<YAML
# OTCA 2.2 — correctly composed Collector.
# Every component below is DECLARED here and then WIRED under service:.
receivers:
  otlp:
    protocols:
      http:
        endpoint: ${OTLP_HTTP}
      grpc:
        endpoint: ${OTLP_GRPC}

processors:
  # memory_limiter must be the FIRST processor so back-pressure is applied
  # before batching — ordering inside a pipeline is significant.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  batch: {}

exporters:
  debug:
    verbosity: detailed

extensions:
  # Extensions attach to the SERVICE, not to a data pipeline. This is the
  # "extension" half of the objective: cross-cutting capabilities.
  health_check:
    endpoint: ${HEALTH}

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug]
YAML
  cp -f "$CFG" "$CFG_GOOD"
}

# Minimal OTLP/JSON span used to prove data flows end-to-end.
write_span() {
  cat >"$SPAN" <<'JSON'
{
  "resourceSpans": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "otca-lab"}}
    ]},
    "scopeSpans": [{
      "scope": {"name": "otca.break-and-fix"},
      "spans": [{
        "traceId": "5b8efff798038103d269b633813fc60c",
        "spanId": "eee19b7ec3c1b174",
        "name": "break-and-fix-span",
        "kind": 2,
        "startTimeUnixNano": "1544712660000000000",
        "endTimeUnixNano":   "1544712661000000000"
      }]
    }]
  }]
}
JSON
}

start_collector() {
  "$COL" --config "$CFG" >"$LOG" 2>&1 &
  COL_PID=$!
  sleep 3
  kill -0 "$COL_PID" 2>/dev/null
}

stop_collector() {
  [ -n "${COL_PID:-}" ] && kill "$COL_PID" 2>/dev/null || true
  wait "$COL_PID" 2>/dev/null || true
  COL_PID=""
}

# ----------------------------------------------------------------------------
# Prove the good state: config validates, collector runs, a span flows through
# and lands in the debug exporter output, health endpoint answers.
# ----------------------------------------------------------------------------
verify_good() {
  log "Validating the good config"
  if "$COL" validate --config "$CFG"; then ok "validate passed"; else err "validate failed unexpectedly"; exit 1; fi

  log "Starting Collector and pushing one span"
  if ! start_collector; then err "Collector did not stay up — check $LOG"; sed -n '1,40p' "$LOG"; exit 1; fi
  ok "Collector is up (pid $COL_PID)"

  if have curl; then
    curl -fsS -m 5 -o /dev/null \
      -H 'Content-Type: application/json' \
      -X POST "http://${OTLP_HTTP}/v1/traces" -d @"$SPAN" \
      && ok "Span accepted over OTLP/HTTP" || warn "Span POST failed (non-fatal)"
    sleep 2
    if grep -q "break-and-fix-span" "$LOG"; then
      ok "Span reached the debug exporter — composition works end-to-end"
    else
      warn "Span not seen in debug output yet (timing); continuing"
    fi
    curl -fsS -m 5 -o /dev/null "http://${HEALTH}/" \
      && ok "health_check extension answering on ${HEALTH}" \
      || warn "health endpoint not answering (non-fatal)"
  else
    warn "curl not present — skipped live traffic proof"
  fi
  stop_collector
}

# ----------------------------------------------------------------------------
# THE CONTROLLED BREAK
# Repoint the traces pipeline at an exporter instance that was never declared.
# This is a pure COMPOSITION fault: 'debug/backend' is a different instance id
# than the declared 'debug', so the graph cannot be built.
# ----------------------------------------------------------------------------
apply_break() {
  sed -i 's/^\(\s*exporters:\s*\)\[debug\]\s*$/\1[debug\/backend]/' "$CFG"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
mkdir -p "$LAB_DIR"
log "Lab directory: $LAB_DIR"

ensure_collector
write_good_config
write_span
verify_good
apply_break

log "Reproducing the failure with the broken config"
VALIDATE_OUT="$("$COL" validate --config "$CFG" 2>&1)"; VALIDATE_RC=$?
echo "$VALIDATE_OUT"

log "Attempting to start the broken Collector (expected to exit immediately)"
"$COL" --config "$CFG" >"$LOG" 2>&1 &
BROKEN_PID=$!
sleep 3
if kill -0 "$BROKEN_PID" 2>/dev/null; then
  kill "$BROKEN_PID" 2>/dev/null || true
  warn "Collector unexpectedly stayed up — inspect $LOG"
else
  ok "Collector refused to start (as designed)"
fi

cat <<EOF

============================================================================
 SYMPTOM YOU WILL SEE
   * '$COL validate --config $CFG' exits non-zero (rc=$VALIDATE_RC).
   * The Collector process starts and dies within seconds; nothing listens
     on ${OTLP_HTTP} / ${OTLP_GRPC}; the health endpoint ${HEALTH} is dead.
   * The error names an exporter the service cannot resolve, e.g.:
         service::pipelines::traces: references exporter "debug/backend"
         which is not configured
     (older builds phrase it as: unknown exporters config for "debug/backend").

 YOUR OBJECTIVE
   Restore CORRECT COMPOSITION so that:
     1. '$COL validate --config $CFG'  returns 0, and
     2. the Collector starts, stays up, and a fresh span again reaches the
        debug exporter (grep 'break-and-fix-span' in $LOG).
   Reason about the wiring model — do NOT simply copy back the backup.

 FILES
   Broken config to fix ... $CFG
   Collector binary ....... $COL
   Test span .............. $SPAN
   Instructor backup ...... $CFG_GOOD   (avoid until you have solved it)

 QUICK CHECK ONE-LINERS
   $COL validate --config $CFG
   "$COL" --config "$CFG" & sleep 3 ; \\
     curl -sS -H 'Content-Type: application/json' \\
       -X POST http://${OTLP_HTTP}/v1/traces -d @"$SPAN"
============================================================================
EOF

exit 0

# ============================================================================
#  SOLUTION — step by step (do not read until you have tried)
# ============================================================================
#
#  1) READ THE ERROR, DON'T GUESS.
#        $COL validate --config $CFG
#     The message points at service::pipelines::traces and an exporter named
#     "debug/backend" that "is not configured". `validate` builds the component
#     graph without opening any port, so it is your fastest feedback loop.
#
#  2) UNDERSTAND THE MODEL (this IS topic 2.2).
#     A Collector pipeline is composed by NAME. Under service:, a pipeline may
#     only list component instances that are DECLARED in the matching top-level
#     section. The text after the slash is an instance id: "debug" and
#     "debug/backend" are two different exporters. We declared "debug" but the
#     traces pipeline asks for "debug/backend", which exists nowhere — so the
#     graph is unbuildable and the service will not start. Declaring a component
#     is necessary but not sufficient; it only runs once a pipeline composes it.
#     (Ref: https://opentelemetry.io/docs/collector/configuration/#pipelines)
#
#  3) FIX — choose ONE:
#
#     Option A — re-wire the pipeline to the exporter that already exists:
#        sed -i 's/^\(\s*exporters:\s*\)\[debug\/backend\]\s*$/\1[debug]/' "$CFG"
#
#     Option B — declare the referenced instance, then keep the reference.
#        Add under `exporters:` a real "debug/backend" instance, e.g.:
#            exporters:
#              debug:
#                verbosity: detailed
#              debug/backend:
#                verbosity: normal
#        Both instances are now valid targets and the pipeline composes.
#
#     (In production the realistic Option B is an OTLP exporter to a backend:
#            exporters:
#              otlp/backend:
#                endpoint: otel-gateway.example.com:4317
#                tls:
#                  insecure: false
#      and the traces pipeline lists [otlp/backend]. Same rule: declare, then
#      compose. Ref: https://opentelemetry.io/docs/collector/configuration/#exporters)
#
#  4) RE-VALIDATE, then RUN and PROVE data flows again:
#        $COL validate --config $CFG            # expect rc=0
#        "$COL" --config "$CFG" >"$LOG" 2>&1 &  # start
#        sleep 3
#        curl -sS -H 'Content-Type: application/json' \
#             -X POST http://${OTLP_HTTP}/v1/traces -d @"$SPAN"
#        sleep 2
#        grep break-and-fix-span "$LOG"         # span landed in the exporter
#        curl -sS http://${HEALTH}/             # health_check extension is up
#        kill %1                                # stop the Collector
#
#  5) WIDER LESSON — composability & extension beyond this fault.
#     Same declare-then-compose rule governs every component kind:
#       * processors  — order in the list is execution order (memory_limiter
#                        first, batch last); a processor not listed never runs.
#       * connectors  — a connector is an EXPORTER in one pipeline and a
#                        RECEIVER in another; it is how you compose pipelines
#                        together (e.g. spanmetrics: traces -> metrics).
#                        Ref: https://opentelemetry.io/docs/collector/building/connectors/
#       * extensions  — declared under `extensions:` AND listed in
#                        service.extensions; omitting the service list is the
#                        "extension" analogue of this very bug — the component
#                        is inert. Ref:
#                        https://opentelemetry.io/docs/collector/configuration/#extensions
#     If you later need a component your distro lacks, you EXTEND the Collector
#     by rebuilding it with the OpenTelemetry Collector Builder (ocb) and a
#     builder manifest listing the modules to include:
#         https://opentelemetry.io/docs/collector/custom-collector/
#
#  6) CONFIRM against the backup only after solving:
#        diff -u "$CFG_GOOD" "$CFG"
#     Option A yields an identical traces pipeline; Option B is a valid variant.
# ============================================================================