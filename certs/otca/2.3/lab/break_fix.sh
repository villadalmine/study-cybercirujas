#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 2. The OpenTelemetry Collector
#  Topic 2.3 Configuration  (exam weight: 6.57%)
#
#  BREAK & FIX LAB — "The pipeline that references a component that does not
#  exist"
#
#  What this teaches
#  -----------------
#  An OpenTelemetry Collector config has TWO independent layers that a student
#  must learn to read separately:
#    1. The COMPONENT MAPS   -> receivers:, processors:, exporters:
#       Here you DEFINE and NAME instances (type, or type/name).
#    2. The SERVICE PIPELINES -> service.pipelines.<signal>
#       Here you WIRE named instances into an ordered flow.
#  A component that is defined but never wired does nothing; a pipeline that
#  wires a name that was never defined makes the Collector refuse to start.
#  This lab injects exactly that second, extremely common, mistake: the
#  processors map defines an instance called `batch/traces` (type/name form)
#  while the traces pipeline still references the bare name `batch`.
#
#  Safety
#  ------
#  * Everything lives under a throwaway directory in /tmp. Nothing is installed
#    system-wide, no systemd unit is touched, no root is required.
#  * The Collector runs as a plain background process bound to localhost only.
#  * `--clean` removes the whole lab directory and stops the process.
#  RUN THIS ONLY ON A DISPOSABLE LAB VM.
#
#  Sources (official)
#  ------------------
#  * OTCA curriculum:
#      https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#  * Collector configuration (components + pipelines):
#      https://opentelemetry.io/docs/collector/configuration/
#  * OTLP receiver:
#      https://github.com/open-telemetry/opentelemetry-collector/tree/main/receiver/otlpreceiver
#  * Batch processor:
#      https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/batchprocessor
#  * Debug exporter:
#      https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/debugexporter
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Tunables
# ----------------------------------------------------------------------------
WORKDIR="${WORKDIR:-/tmp/otca-2.3-config-lab}"
OTELCOL_VERSION="${OTELCOL_VERSION:-0.116.0}"   # only used if no binary is found
OTLP_GRPC_PORT="${OTLP_GRPC_PORT:-4317}"
OTLP_HTTP_PORT="${OTLP_HTTP_PORT:-4318}"

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
c_bold=$'\033[1m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
log()  { printf '%s[lab]%s %s\n' "$c_bold" "$c_off" "$*"; }
warn() { printf '%s[lab]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%s[lab] ERROR:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--force] [--clean]

  (no args)  Build the lab, inject the fault, show the symptom and the challenge.
  --force    Skip the "is this a disposable VM?" confirmation.
  --clean    Stop the Collector and delete the lab directory ($WORKDIR).
USAGE
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
FORCE=0
ACTION="build"
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --clean) ACTION="clean" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done

# ----------------------------------------------------------------------------
# --clean teardown
# ----------------------------------------------------------------------------
if [ "$ACTION" = "clean" ]; then
  if [ -f "$WORKDIR/collector.pid" ]; then
    pid="$(cat "$WORKDIR/collector.pid" 2>/dev/null || true)"
    [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
  log "Lab removed: $WORKDIR"
  exit 0
fi

# ----------------------------------------------------------------------------
# Disposability guard
# ----------------------------------------------------------------------------
if [ "$FORCE" -ne 1 ]; then
  warn "This lab starts a background OpenTelemetry Collector and writes to $WORKDIR."
  warn "Run it ONLY on a disposable lab VM."
  read -r -p "Type 'yes' to continue: " ans
  [ "$ans" = "yes" ] || die "aborted by user."
fi

# ----------------------------------------------------------------------------
# Ensure an otelcol binary exists (prefer an already-installed contrib/core one)
# ----------------------------------------------------------------------------
mkdir -p "$WORKDIR"
cd "$WORKDIR"

find_binary() {
  for cand in otelcol-contrib otelcol; do
    if command -v "$cand" >/dev/null 2>&1; then command -v "$cand"; return 0; fi
  done
  for p in /usr/bin/otelcol-contrib /usr/local/bin/otelcol-contrib \
           /usr/bin/otelcol /usr/local/bin/otelcol "$WORKDIR/otelcol-contrib"; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

if ! BIN="$(find_binary)"; then
  log "No otelcol binary found; downloading otelcol-contrib v${OTELCOL_VERSION}..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture: $arch (install otelcol-contrib manually and re-run)." ;;
  esac
  base="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download"
  tarball="otelcol-contrib_${OTELCOL_VERSION}_linux_${arch}.tar.gz"
  url="${base}/v${OTELCOL_VERSION}/${tarball}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tarball" || die "download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$tarball" || die "download failed: $url"
  else
    die "neither curl nor wget available; install otelcol-contrib manually."
  fi
  tar -xzf "$tarball" otelcol-contrib
  chmod +x otelcol-contrib
  BIN="$WORKDIR/otelcol-contrib"
fi
log "Using Collector binary: $BIN"
"$BIN" --version 2>/dev/null | head -n1 || true

# ----------------------------------------------------------------------------
# Write the environment file consumed by the helper scripts
# ----------------------------------------------------------------------------
cat > env.sh <<EOF
# Auto-generated by the OTCA 2.3 lab. Do not edit.
BIN="$BIN"
OTLP_HTTP="http://localhost:${OTLP_HTTP_PORT}/v1/traces"
OTLP_GRPC="localhost:${OTLP_GRPC_PORT}"
EOF

# ----------------------------------------------------------------------------
# Write the BROKEN Collector configuration
#
# The fault is intentional and lives on the line marked  # <-- FAULT.
# processors: defines the instance `batch/traces`, but the traces pipeline
# wires the bare name `batch`, which is not configured anywhere.
# ----------------------------------------------------------------------------
cat > config.yaml <<EOF
# OTCA 2.3 Configuration lab — fix me so the Collector starts and exports spans.
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: localhost:${OTLP_GRPC_PORT}
      http:
        endpoint: localhost:${OTLP_HTTP_PORT}

processors:
  # This instance uses the type/name form and is named "batch/traces".
  batch/traces:
    send_batch_size: 512
    timeout: 5s

exporters:
  debug:
    verbosity: detailed

service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]        # <-- FAULT: no processor named "batch" exists
      exporters: [debug]
EOF

# ----------------------------------------------------------------------------
# Helper: start-collector.sh
# ----------------------------------------------------------------------------
cat > start-collector.sh <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh
if [ -f collector.pid ] && kill -0 "$(cat collector.pid)" 2>/dev/null; then
  echo "Collector already running (pid $(cat collector.pid)). Logs: collector.log"
  exit 0
fi
: > collector.log
nohup "$BIN" --config ./config.yaml >> collector.log 2>&1 &
echo $! > collector.pid
sleep 2
if kill -0 "$(cat collector.pid)" 2>/dev/null; then
  echo "Collector started (pid $(cat collector.pid)). Logs: collector.log"
else
  echo "Collector FAILED to start. Last log lines:"
  echo "------------------------------------------------------------"
  tail -n 20 collector.log
  echo "------------------------------------------------------------"
  rm -f collector.pid
  exit 1
fi
HELPER_EOF

# ----------------------------------------------------------------------------
# Helper: stop-collector.sh
# ----------------------------------------------------------------------------
cat > stop-collector.sh <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -f collector.pid ]; then
  pid="$(cat collector.pid)"
  kill "$pid" 2>/dev/null || true
  rm -f collector.pid
  echo "Stopped collector (pid $pid)."
else
  echo "No collector.pid found; nothing to stop."
fi
HELPER_EOF

# ----------------------------------------------------------------------------
# Helper: send-trace.sh  (deterministic span so verify.sh can grep for it)
# Alternative, if you have it installed:
#   telemetrygen traces --otlp-insecure --otlp-endpoint "$OTLP_GRPC" --traces 1
# ----------------------------------------------------------------------------
cat > send-trace.sh <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh
curl -sS -o /dev/null -w "OTLP/HTTP POST -> HTTP %{http_code}\n" \
  -X POST "$OTLP_HTTP" -H 'Content-Type: application/json' --data @- <<'JSON'
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "otca-2-3-lab" } }
        ]
      },
      "scopeSpans": [
        {
          "scope": { "name": "manual-lab-client" },
          "spans": [
            {
              "traceId": "5b8efff798038103d269b633813fc60c",
              "spanId": "eee19b7ec3c1b174",
              "name": "lab-check-span",
              "kind": 1,
              "startTimeUnixNano": "1700000000000000000",
              "endTimeUnixNano":   "1700000000500000000"
            }
          ]
        }
      ]
    }
  ]
}
JSON
HELPER_EOF

# ----------------------------------------------------------------------------
# Helper: verify.sh
# ----------------------------------------------------------------------------
cat > verify.sh <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh
if [ ! -f collector.pid ] || ! kill -0 "$(cat collector.pid)" 2>/dev/null; then
  echo "FAIL: the Collector is not running."
  echo "      Fix config.yaml, then: ./start-collector.sh"
  exit 1
fi
if grep -q "lab-check-span" collector.log; then
  echo "PASS: the debug exporter printed the test span 'lab-check-span'."
  echo "      The traces pipeline is wired correctly. Challenge solved."
else
  echo "PENDING: the Collector is up, but no exported span seen yet."
  echo "         Run: ./send-trace.sh   then re-run: ./verify.sh"
  exit 1
fi
HELPER_EOF

chmod +x start-collector.sh stop-collector.sh send-trace.sh verify.sh

# ----------------------------------------------------------------------------
# Trigger the fault so the student sees the real symptom immediately
# ----------------------------------------------------------------------------
log "Injecting the fault and attempting to start the Collector..."
start_rc=0
./start-collector.sh || start_rc=$?

# ----------------------------------------------------------------------------
# Present the challenge
# ----------------------------------------------------------------------------
cat <<CHALLENGE

============================================================================
${c_bold}OTCA 2.3 — CONFIGURATION :: BREAK & FIX CHALLENGE${c_off}
============================================================================

${c_bold}Lab directory:${c_off} $WORKDIR
${c_bold}Config file to fix:${c_off} $WORKDIR/config.yaml
${c_bold}Collector log:${c_off} $WORKDIR/collector.log

${c_bold}${c_red}SYMPTOM${c_off}
The Collector process exits within a second of starting; it never begins
listening on the OTLP ports. In collector.log you will see a startup
validation error of roughly this shape:

    Error: invalid configuration: service::pipelines::traces:
    references processor "batch" which is not configured
    ... collector server run finished with error

Because the process dies on load, there is NO partial mode: no receiver,
no exporter, nothing accepts data. Ports ${OTLP_GRPC_PORT}/${OTLP_HTTP_PORT} are closed.

${c_bold}WHY IT MATTERS${c_off}
A Collector config is validated as a graph before any telemetry flows. Every
name listed inside a pipeline (receivers/processors/exporters) must resolve to
an instance DEFINED in the matching top-level component map. The names must
match exactly, including the optional "/name" suffix. "batch" and
"batch/traces" are two different identities.

${c_bold}${c_grn}YOUR GOAL${c_off}
Edit ONLY $WORKDIR/config.yaml so that:
  1. ./start-collector.sh reports the Collector started and stays up, AND
  2. after ./send-trace.sh, ./verify.sh prints PASS
     (the debug exporter must print the span 'lab-check-span').

${c_bold}TOOLS PROVIDED (run from $WORKDIR)${c_off}
  ./start-collector.sh   start it in the background (fails fast if config is bad)
  ./stop-collector.sh    stop it
  ./send-trace.sh        push one OTLP/HTTP trace into the Collector
  ./verify.sh            check the fix
  $BIN validate --config ./config.yaml   # dry-run: validate without starting

${c_bold}HINTS${c_off}
  * Read the two layers separately. First list every processor NAME that is
    actually defined. Then read what the traces pipeline ASKS for.
  * There are two valid fixes; either one is correct. Pick the one that keeps
    the batching tuning you were given.
  * `validate` gives you the same error without leaving a process behind — use
    it to iterate quickly.

(start-collector.sh exit code above was: ${start_rc} — non-zero is expected now.)
============================================================================
CHALLENGE

# ============================================================================
#  SOLUTION  (instructor reference — do not reveal to the student up front)
# ============================================================================
#
#  Step 1 — Reproduce and read the exact error.
#    cd "$WORKDIR"
#    "$BIN" validate --config ./config.yaml
#    # -> service::pipelines::traces: references processor "batch"
#    #    which is not configured
#
#  Step 2 — Diagnose the mismatch. List what is defined vs. what is referenced.
#    grep -nA3 '^processors:' config.yaml     # defined name: batch/traces
#    grep -n  'processors:' config.yaml       # pipeline asks for: [batch]
#    The processors map defines the instance "batch/traces" (type/name form),
#    but the traces pipeline wires the bare name "batch". No instance called
#    "batch" exists, so graph validation fails and the process never starts.
#
#  Step 3 — Apply ONE of the two valid fixes.
#
#    FIX A (recommended: keep the tuned instance, correct the wiring)
#      Change the pipeline reference to the real instance name:
#          processors: [batch]         ->   processors: [batch/traces]
#      e.g.:
#          sed -i 's/processors: \[batch\]/processors: [batch\/traces]/' config.yaml
#
#    FIX B (rename the instance to the bare type used by the pipeline)
#      Rename the map key from "batch/traces" to "batch":
#          batch/traces:               ->   batch:
#      e.g.:
#          sed -i 's/^  batch\/traces:/  batch:/' config.yaml
#
#    Either way the resulting traces pipeline is a valid graph:
#      receivers: [otlp] -> processors: [<matching batch instance>] -> exporters: [debug]
#
#  Step 4 — Validate, restart, exercise, verify.
#    "$BIN" validate --config ./config.yaml   # must print no error
#    ./start-collector.sh                     # must report "Collector started"
#    ./send-trace.sh                          # OTLP/HTTP -> HTTP 200
#    ./verify.sh                              # must print PASS
#
#  Step 5 — Confirm the corrected mental model.
#    * Two layers: component MAPS define/name instances; service PIPELINES wire
#      names. A name used in a pipeline must resolve to a defined instance.
#    * Instance identity includes the "/name" suffix: "batch" != "batch/traces".
#    * `otelcol validate` catches this class of error before any data flows —
#      make it part of CI for every Collector config change.
#
#  Teardown:
#    ./stop-collector.sh
#    "$0" --clean
# ============================================================================