#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 3: The OpenTelemetry Collector
#  Topic 3.4: Pipelines            (approx. exam weight: 5.2)
#
#  BREAK & FIX LAB — run ONLY inside a disposable lab VM you can throw away.
#  Everything lives under a single lab directory and a single background
#  process; it never touches systemd, /etc, or any real Collector install.
#
#  ---------------------------------------------------------------------------
#  MENTAL MODEL YOU ARE BEING TESTED ON
#  ---------------------------------------------------------------------------
#  A Collector config has two layers, and confusing them is the #1 pipeline bug:
#
#    1. DEFINITION — the top-level maps `receivers:`, `processors:`,
#       `exporters:`, `connectors:`, `extensions:`. Here you declare a
#       component instance and give it an id (e.g. `batch`, `resource/scrub`).
#       Declaring it does NOT make it run. It is inert until wired.
#
#    2. WIRING — `service.pipelines.<signal>`. A pipeline is a TYPED chain
#       (traces | metrics | logs). It lists component ids in three ordered
#       slots: `receivers: [...]`, `processors: [...]`, `exporters: [...]`.
#       Only ids referenced here are actually instantiated and executed.
#
#  Key production facts the Collector enforces at build time (before any data
#  flows), and that this lab makes you feel:
#    - Every id referenced by a pipeline MUST exist in the matching top-level
#      map, and its TYPE must match the pipeline signal. A dangling reference
#      is a FATAL error — the Collector refuses to start. It fails closed, not
#      open: no half-running pipeline, no silent drop.
#    - `processors:` order is significant — data flows left to right. Convention
#      is memory_limiter first, batch last-ish, so back-pressure is applied
#      before you spend CPU on batching.
#    - The same component id can be referenced by multiple pipelines
#      (fan-out on the config side), but a processor instance is NOT shared
#      across pipelines unless it is a stateless singleton — assume per-pipeline
#      instantiation. Receivers/exporters with the same id ARE shared.
#    - A pipeline must have >=1 receiver and >=1 exporter, else it is rejected.
#
#  This script:
#    1. Stands up a WORKING traces pipeline: otlp -> [memory_limiter, batch,
#       resource/scrub] -> debug.
#    2. Proves it by pushing one OTLP/HTTP span and seeing it hit the exporter.
#    3. Breaks the pipeline in a controlled, fully reversible way.
#    4. Hands you the mission. The worked solution is at the very bottom of
#       this file, commented out. Try it yourself first.
#
#  Reference sources (official):
#    OTCA curriculum:
#      https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#    Collector configuration & pipelines:
#      https://opentelemetry.io/docs/collector/configuration/#pipelines
#    Collector architecture (build-time pipeline graph):
#      https://opentelemetry.io/docs/collector/architecture/
#    resource processor:
#      https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/resourceprocessor
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment if you like)
# ---------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-$HOME/otca-lab-3.4}"
OTELCOL_VERSION="${OTELCOL_VERSION:-0.117.0}"   # best-effort default; override if needed
OTLP_HTTP_HOST="127.0.0.1"
OTLP_HTTP_PORT="4318"
OTLP_GRPC_PORT="4317"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# --cleanup: stop the collector and remove the lab directory, then exit.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--cleanup" ]]; then
  if [[ -f "$LAB_DIR/labctl.sh" ]]; then bash "$LAB_DIR/labctl.sh" stop || true; fi
  rm -rf "$LAB_DIR"
  log "lab torn down: $LAB_DIR removed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
have curl || die "curl is required (used to install the Collector and to push spans)."
have tar  || die "tar is required to unpack the Collector release."

warn "This lab breaks a local OpenTelemetry Collector. Run it only on a disposable VM."
warn "Lab directory: $LAB_DIR"

mkdir -p "$LAB_DIR/bin"

# ---------------------------------------------------------------------------
# Locate or install the Collector (contrib distro, for the resource processor)
# ---------------------------------------------------------------------------
resolve_collector() {
  if have otelcol-contrib; then OTELCOL="$(command -v otelcol-contrib)"; return; fi
  if [[ -x "$LAB_DIR/bin/otelcol-contrib" ]]; then OTELCOL="$LAB_DIR/bin/otelcol-contrib"; return; fi
  if have otelcol; then
    warn "Only the core 'otelcol' distro was found; it lacks the 'resource' processor."
    warn "Installing the contrib distro locally so the lab config is valid."
  fi

  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported CPU arch $(uname -m); set OTELCOL by hand or install otelcol-contrib." ;;
  esac

  local base="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download"
  local tgz="otelcol-contrib_${OTELCOL_VERSION}_linux_${arch}.tar.gz"
  local url="${base}/v${OTELCOL_VERSION}/${tgz}"

  log "Downloading otelcol-contrib v${OTELCOL_VERSION} (${arch})..."
  if ! curl -fL "$url" -o "$LAB_DIR/$tgz"; then
    die "download failed: $url
     -> Set OTELCOL_VERSION to a release that exists, or install otelcol-contrib
        yourself and re-run. Releases: https://github.com/open-telemetry/opentelemetry-collector-releases/releases"
  fi
  tar -xzf "$LAB_DIR/$tgz" -C "$LAB_DIR/bin" otelcol-contrib
  chmod +x "$LAB_DIR/bin/otelcol-contrib"
  OTELCOL="$LAB_DIR/bin/otelcol-contrib"
}
resolve_collector
log "Using Collector binary: $OTELCOL"

# ---------------------------------------------------------------------------
# Write the lab environment file (sourced by labctl.sh)
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/lab.env" <<ENV
LAB_DIR="$LAB_DIR"
OTELCOL="$OTELCOL"
OTLP_HTTP_HOST="$OTLP_HTTP_HOST"
OTLP_HTTP_PORT="$OTLP_HTTP_PORT"
ENV

# ---------------------------------------------------------------------------
# Known-GOOD config: resource/scrub is BOTH defined and wired.
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/config.good.yaml" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
      http:
        endpoint: 127.0.0.1:4318

processors:
  # memory_limiter first: apply back-pressure before spending CPU downstream.
  memory_limiter:
    check_interval: 1s
    limit_mib: 128
    spike_limit_mib: 32
  batch:
    timeout: 200ms
  # Strips a sensitive attribute before export — a real production concern.
  resource/scrub:
    attributes:
      - key: user.password
        action: delete

exporters:
  debug:
    verbosity: detailed

service:
  telemetry:
    metrics:
      level: none      # don't try to bind the internal :8888 metrics endpoint
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch, resource/scrub]
      exporters: [debug]
YAML

# ---------------------------------------------------------------------------
# BROKEN config: identical, EXCEPT the resource/scrub DEFINITION is gone
# while the traces pipeline still REFERENCES it. Defined != wired, and here
# it is wired-but-not-defined: a dangling reference the Collector rejects.
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/config.broken.yaml" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
      http:
        endpoint: 127.0.0.1:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 128
    spike_limit_mib: 32
  batch:
    timeout: 200ms

exporters:
  debug:
    verbosity: detailed

service:
  telemetry:
    metrics:
      level: none
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch, resource/scrub]
      exporters: [debug]
YAML

# ---------------------------------------------------------------------------
# A minimal, valid OTLP/HTTP JSON trace payload (one span named for grep).
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/trace.json" <<'JSON'
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "otca-lab" } }
        ]
      },
      "scopeSpans": [
        {
          "scope": { "name": "otca.lab.manual" },
          "spans": [
            {
              "traceId": "5b8efff798038103d269b633813fc60c",
              "spanId": "eee19b7ec3c1b174",
              "name": "break-and-fix-demo",
              "kind": 2,
              "startTimeUnixNano": "1544712660000000000",
              "endTimeUnixNano": "1544712661000000000"
            }
          ]
        }
      ]
    }
  ]
}
JSON

# ---------------------------------------------------------------------------
# labctl.sh — the control plane you (the student) will use to fix the lab.
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/labctl.sh" <<'LABCTL'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/lab.env"
PIDFILE="$LAB_DIR/collector.pid"
LOG="$LAB_DIR/collector.log"

is_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
port_open()  { (exec 3<>"/dev/tcp/$OTLP_HTTP_HOST/$OTLP_HTTP_PORT") 2>/dev/null && { exec 3>&- 3<&-; return 0; }; return 1; }

start() {
  if is_running; then echo "already running (pid $(cat "$PIDFILE"))"; return 0; fi
  : > "$LOG"
  nohup "$OTELCOL" --config "$LAB_DIR/config.active.yaml" >>"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  if is_running; then
    echo "collector started (pid $(cat "$PIDFILE"))"
  else
    rm -f "$PIDFILE"
    echo "collector FAILED to start. Last log lines:" >&2
    tail -n 15 "$LOG" >&2
    return 1
  fi
}

stop() {
  if is_running; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 1; fi
  rm -f "$PIDFILE"
  echo "collector stopped"
}

status() {
  if is_running; then echo "process:   RUNNING (pid $(cat "$PIDFILE"))"
  else echo "process:   NOT running"; fi
  if port_open; then echo "otlp/http: $OTLP_HTTP_HOST:$OTLP_HTTP_PORT LISTENING"
  else echo "otlp/http: $OTLP_HTTP_HOST:$OTLP_HTTP_PORT CLOSED"; fi
}

logs() { tail -n "${1:-40}" "$LOG"; }

test_span() {
  if ! port_open; then
    echo "cannot send: OTLP/HTTP endpoint is closed (collector is not accepting data)." >&2
    return 1
  fi
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://$OTLP_HTTP_HOST:$OTLP_HTTP_PORT/v1/traces" \
    -H 'Content-Type: application/json' \
    --data @"$LAB_DIR/trace.json")
  echo "POST /v1/traces -> HTTP $code"
  sleep 1
  if grep -q 'break-and-fix-demo' "$LOG"; then
    echo "SUCCESS: the span traversed the pipeline and reached the debug exporter:"
    grep -n -A2 'break-and-fix-demo' "$LOG" | tail -n 20
  else
    echo "span accepted but not yet visible at the exporter; check: $0 logs"
  fi
}

reset()   { cp "$LAB_DIR/config.good.yaml" "$LAB_DIR/config.active.yaml"; echo "restored known-good config (escape hatch)"; }
diffcfg() { echo "--- config.good.yaml   +++ config.active.yaml"; diff -u "$LAB_DIR/config.good.yaml" "$LAB_DIR/config.active.yaml" || true; }

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
  logs)    shift; logs "${1:-40}" ;;
  test)    test_span ;;
  reset)   reset ;;
  diff)    diffcfg ;;
  *) echo "usage: $0 {start|stop|restart|status|logs [N]|test|reset|diff}"; exit 2 ;;
esac
LABCTL
chmod +x "$LAB_DIR/labctl.sh"

# ---------------------------------------------------------------------------
# Phase 1: prove the pipeline works, then break it.
# ---------------------------------------------------------------------------
log "Installing known-good config and starting the Collector..."
cp "$LAB_DIR/config.good.yaml" "$LAB_DIR/config.active.yaml"
bash "$LAB_DIR/labctl.sh" start

log "Sending one span to prove the healthy traces pipeline exports data..."
bash "$LAB_DIR/labctl.sh" test || warn "healthy test did not confirm; continuing anyway."

log "Now introducing the controlled fault (dangling processor reference)..."
cp "$LAB_DIR/config.broken.yaml" "$LAB_DIR/config.active.yaml"
bash "$LAB_DIR/labctl.sh" restart || true   # expected to fail: that IS the break

# ---------------------------------------------------------------------------
# Brief the student
# ---------------------------------------------------------------------------
cat <<BRIEF

============================================================================
  OTCA 3.4 — PIPELINES :: BREAK & FIX  ::  the pipeline is now BROKEN
============================================================================

SYMPTOM (what you will observe)
  - The Collector process is NOT running. It exited immediately on start.
  - The OTLP/HTTP port $OTLP_HTTP_PORT is CLOSED — nothing accepts telemetry.
  - Any producer pointed at this Collector gets "connection refused".
  - The log ($LAB_DIR/collector.log) contains a build-time error naming the
    'traces' pipeline and a processor "resource/scrub" that is "not configured".

    Confirm it yourself:
        cd $LAB_DIR
        bash labctl.sh status      # process NOT running, port CLOSED
        bash labctl.sh logs        # read the fatal error line
        bash labctl.sh diff        # good vs active — spot the difference

WHY (the concept under test)
  The 'traces' pipeline REFERENCES the processor id "resource/scrub", but that
  id is no longer DEFINED under the top-level 'processors:' map. Wiring an id
  that was never defined is a fatal, build-time error: the Collector validates
  the full pipeline graph before it serves a single byte, and fails closed.

YOUR MISSION
  Make the Collector start AND stay up, with the traces pipeline exporting the
  test span again — WITHOUT gutting the pipeline's intent (it is meant to run
  otlp -> [memory_limiter, batch, resource/scrub] -> debug). You may either:
    (a) restore a valid DEFINITION for the referenced processor, or
    (b) remove the dangling REFERENCE from the pipeline.
  Then verify:
        cd $LAB_DIR
        bash labctl.sh restart
        bash labctl.sh status      # RUNNING + LISTENING
        bash labctl.sh test        # span reaches the debug exporter

  Edit only:  $LAB_DIR/config.active.yaml
  Escape hatch (don't peek first): bash labctl.sh reset   # restores good config
  Tear the lab down when finished:  bash $0 --cleanup

  The step-by-step solution is at the very bottom of this script, commented.
============================================================================

BRIEF

exit 0

# ============================================================================
#  SOLUTION — try the mission before reading. (Everything below is a comment.)
# ============================================================================
#
#  STEP 0 — Enter the lab:
#      cd "$LAB_DIR"
#
#  STEP 1 — Read the symptom precisely:
#      bash labctl.sh status
#        process:   NOT running
#        otlp/http: 127.0.0.1:4318 CLOSED
#      bash labctl.sh logs
#        Error: invalid configuration: service::pipelines::traces:
#          references processor "resource/scrub" which is not configured
#      (Wording varies slightly by Collector version, but it always names the
#       pipeline 'traces' and the processor id it cannot resolve.)
#
#  STEP 2 — Localize with a diff against the known-good baseline:
#      bash labctl.sh diff
#      The 'processors:' map in config.active.yaml is MISSING the
#      'resource/scrub' block, yet the traces pipeline still lists it under
#      'processors: [memory_limiter, batch, resource/scrub]'. Defined != wired,
#      and here it is wired but not defined.
#
#  STEP 3 — Fix. Pick ONE:
#
#    OPTION A (production-correct — restore the definition):
#      Edit config.active.yaml and re-add the definition under 'processors:',
#      keeping memory_limiter first and batch before it in the chain:
#
#        processors:
#          memory_limiter:
#            check_interval: 1s
#            limit_mib: 128
#            spike_limit_mib: 32
#          batch:
#            timeout: 200ms
#          resource/scrub:
#            attributes:
#              - key: user.password
#                action: delete
#
#    OPTION B (minimal — drop the dangling reference):
#      Edit the traces pipeline so it no longer references the undefined id:
#
#        pipelines:
#          traces:
#            receivers: [otlp]
#            processors: [memory_limiter, batch]
#            exporters: [debug]
#
#      (Valid, but you lose the attribute-scrubbing step — acceptable only if
#       that redaction is genuinely not required. In production, prefer A.)
#
#  STEP 4 — Restart and verify the pipeline is live end-to-end:
#      bash labctl.sh restart
#      bash labctl.sh status
#        process:   RUNNING (pid ...)
#        otlp/http: 127.0.0.1:4318 LISTENING
#      bash labctl.sh test
#        POST /v1/traces -> HTTP 200
#        SUCCESS: the span traversed the pipeline and reached the debug exporter
#
#  STEP 5 — Tear down when finished:
#      bash "$0" --cleanup   # stops the collector and removes "$LAB_DIR"
#
#  TAKEAWAY
#    In a Collector, DEFINING a component and WIRING it into a pipeline are two
#    separate acts. A pipeline may reference only ids that are (1) defined in
#    the matching top-level map and (2) of a type valid for that signal. The
#    Collector builds and validates the entire pipeline graph at startup and
#    fails closed on any dangling or mistyped reference — you never get a
#    half-running pipeline, so a startup crashloop with a "not configured"
#    error is almost always a wiring/definition mismatch, not a data problem.
# ============================================================================