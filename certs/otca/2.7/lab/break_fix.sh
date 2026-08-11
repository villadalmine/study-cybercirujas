#!/usr/bin/env bash
#
# ============================================================================
#  OTCA 2.7 — AGENTS  |  Break & Fix laboratory
# ============================================================================
#  Exam: OpenTelemetry Certified Associate (OTCA)  ·  Domain 2 (API & SDK)
#  Topic 2.7 "Agents"  ·  Exam weight: 6.57%
#
#  What "Agent" means in this topic
#  --------------------------------
#  In the OTCA API/SDK domain an *agent* is a ZERO-CODE (auto-instrumentation)
#  agent: a runtime attachment that instruments an application WITHOUT editing
#  its source. Examples: the Java agent (`-javaagent:opentelemetry-javaagent.jar`
#  or JAVA_TOOL_OPTIONS), and the Python launcher `opentelemetry-instrument`.
#  It discovers libraries, creates spans/metrics/logs, and ships them through an
#  exporter — all steered by OTEL_* environment variables. (Do not confuse it
#  with the Collector's "agent deployment mode", which is Domain 3.)
#
#  This lab uses the Python zero-code agent because it installs with pip alone.
#  The lesson is language-agnostic: the fault below has identical symptoms with
#  the Java agent, the .NET agent, or the Node.js agent.
#
#  Official sources (cite these to the student)
#  --------------------------------------------
#  - OTCA curriculum ....... https://github.com/cncf/curriculum (OTCA_Curriculum.pdf)
#  - Zero-code / agents .... https://opentelemetry.io/docs/zero-code/
#  - Python agent .......... https://opentelemetry.io/docs/zero-code/python/
#  - SDK env var config .... https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
#  - Exporter selection .... https://opentelemetry.io/docs/languages/sdk-configuration/general/
#
#  SAFETY: run this ONLY on a disposable lab VM. It creates a virtualenv, writes
#  files, and starts a local Flask server bound to 127.0.0.1. Everything lives
#  under $LAB_DIR and is fully reversible with `--clean`. No system state is
#  modified outside that directory.
# ============================================================================

set -euo pipefail

LAB_DIR="${OTCA_LAB_DIR:-$HOME/otca-lab-2.7-agents}"
VENV="$LAB_DIR/.venv"
APP_PORT="${OTCA_LAB_PORT:-8080}"
SERVICE_NAME="payments-api"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Teardown helpers
# ---------------------------------------------------------------------------
stop_app() {
  if [[ -f "$LAB_DIR/app.pid" ]]; then
    local pid; pid="$(cat "$LAB_DIR/app.pid" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$LAB_DIR/app.pid"
  fi
}

if [[ "${1:-}" == "--clean" ]]; then
  log "Tearing down the lab..."
  stop_app
  rm -rf "$LAB_DIR"
  ok "Lab removed: $LAB_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# Safety confirmation
# ---------------------------------------------------------------------------
if [[ "${1:-}" != "--yes" && "${FORCE:-0}" != "1" ]]; then
  warn "This will build a lab under: $LAB_DIR and start a server on 127.0.0.1:$APP_PORT"
  warn "Run it ONLY on a throwaway VM. Re-run with '--yes' (or FORCE=1) to proceed."
  read -r -p "Type 'yes' to continue: " reply
  [[ "$reply" == "yes" ]] || die "Aborted by user."
fi

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v curl    >/dev/null 2>&1 || die "curl is required."
python3 -c 'import venv' 2>/dev/null || die "The python3 'venv' module is required."

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$APP_PORT "; then
  # It may be a stale instance of THIS lab; try to clear it, otherwise abort.
  stop_app
  if ss -ltn 2>/dev/null | grep -q ":$APP_PORT "; then
    die "Port $APP_PORT is already in use. Set OTCA_LAB_PORT to a free port and retry."
  fi
fi

# ---------------------------------------------------------------------------
# Build the lab (idempotent)
# ---------------------------------------------------------------------------
mkdir -p "$LAB_DIR"
stop_app  # kill any previous run before rebuilding

if [[ ! -x "$VENV/bin/python" ]]; then
  log "Creating virtualenv..."
  python3 -m venv "$VENV"
fi

log "Installing the OpenTelemetry zero-code agent and a demo app (pip, quiet)..."
if ! "$VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 \
   || ! "$VENV/bin/pip" install --quiet \
        "flask" \
        "opentelemetry-distro" \
        "opentelemetry-instrumentation-flask" \
        "opentelemetry-exporter-otlp-proto-http" >/dev/null 2>&1; then
  die "pip install failed. This lab needs outbound access to PyPI on the VM."
fi

# --- the application under test (unaware it is being instrumented) ---------
cat > "$LAB_DIR/app.py" <<'PYEOF'
# A plain Flask service. There is NO OpenTelemetry code here on purpose:
# telemetry is added from the outside by the zero-code agent.
from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/work")
def work():
    # Trivial business logic. The agent auto-creates a SERVER span per request.
    return jsonify(status="ok", service="payments-api"), 200


@app.get("/health")
def health():
    return jsonify(status="up"), 200
PYEOF

# --- the AGENT CONFIGURATION (this file carries the injected fault) ---------
# NOTE: the single misconfigured line below is the whole exercise.
cat > "$LAB_DIR/agent.env" <<'ENVEOF'
# ---- OpenTelemetry zero-code agent configuration ----
# Identity of the service in your traces:
OTEL_SERVICE_NAME=payments-api
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=lab,service.version=1.0.0

# Sampling: keep everything (rule out sampling as a cause):
OTEL_TRACES_SAMPLER=parentbased_always_on

# Make the batch processor flush fast so the lab is responsive:
OTEL_BSP_SCHEDULE_DELAY=1000

# Keep metric/log noise out of this lab; we only study traces here:
OTEL_METRICS_EXPORTER=none
OTEL_LOGS_EXPORTER=none

# ---- Trace export ----
# In this offline lab, "console" is our stand-in backend: exported spans are
# printed to the agent log. In production this would be:
#   OTEL_TRACES_EXPORTER=otlp
#   OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_TRACES_EXPORTER=none
ENVEOF

# --- run wrapper: sources the agent config, then launches under the agent ---
cat > "$LAB_DIR/run.sh" <<RUNEOF
#!/usr/bin/env bash
set -euo pipefail
cd "$LAB_DIR"
export PATH="$VENV/bin:\$PATH"
# Export every variable defined in agent.env into the process environment:
set -a
# shellcheck disable=SC1091
. "$LAB_DIR/agent.env"
set +a
# 'opentelemetry-instrument' IS the agent: it wraps the target command,
# injects instrumentation, and honours the OTEL_* variables above.
exec opentelemetry-instrument flask --app app run --host 127.0.0.1 --port $APP_PORT
RUNEOF
chmod +x "$LAB_DIR/run.sh"

# --- restart helper the student uses after editing agent.env ---------------
cat > "$LAB_DIR/restart.sh" <<RSTEOF
#!/usr/bin/env bash
# Apply your fix (edit agent.env) then run this to relaunch the agent+app.
set -euo pipefail
LAB_DIR="$LAB_DIR"
if [[ -f "\$LAB_DIR/app.pid" ]]; then
  pid="\$(cat "\$LAB_DIR/app.pid" 2>/dev/null || true)"
  [[ -n "\${pid:-}" ]] && kill "\$pid" 2>/dev/null || true
  sleep 1; [[ -n "\${pid:-}" ]] && kill -9 "\$pid" 2>/dev/null || true
fi
: > "\$LAB_DIR/agent.log"
nohup "\$LAB_DIR/run.sh" >"\$LAB_DIR/agent.log" 2>&1 &
echo \$! > "\$LAB_DIR/app.pid"
echo "Restarted (pid \$(cat "\$LAB_DIR/app.pid")). Watch: tail -f \$LAB_DIR/agent.log"
RSTEOF
chmod +x "$LAB_DIR/restart.sh"

# ---------------------------------------------------------------------------
# Start the (broken) service in the background
# ---------------------------------------------------------------------------
: > "$LAB_DIR/agent.log"
log "Starting the instrumented service in the background..."
nohup "$LAB_DIR/run.sh" >"$LAB_DIR/agent.log" 2>&1 &
echo $! > "$LAB_DIR/app.pid"

# Wait for the HTTP server to accept connections
log "Waiting for the service to come up on 127.0.0.1:$APP_PORT ..."
up=0
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$APP_PORT/health" 2>/dev/null; then
    up=1; break
  fi
  sleep 1
done
[[ "$up" == "1" ]] || { warn "Service did not start; last log lines:"; tail -n 25 "$LAB_DIR/agent.log" || true; die "Startup failed."; }
ok "Service is UP (HTTP is healthy)."

# ---------------------------------------------------------------------------
# Demonstrate the symptom with real output
# ---------------------------------------------------------------------------
log "Sending one request to the business endpoint /work ..."
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APP_PORT/work" || true)"
log "Application response: HTTP $code   <-- the app itself is perfectly healthy"

log "Waiting a moment for the agent's batch span processor to flush..."
sleep 3
spans="$(grep -c '"span_id"' "$LAB_DIR/agent.log" 2>/dev/null || true)"
: "${spans:=0}"
log "Exported span records found in agent.log: $spans   <-- THIS is the problem"

# ---------------------------------------------------------------------------
# Student briefing
# ---------------------------------------------------------------------------
cat <<BRIEF

============================================================================
 OTCA 2.7 AGENTS — YOUR INCIDENT
============================================================================
Service '$SERVICE_NAME' has been instrumented with the OpenTelemetry zero-code
agent (opentelemetry-instrument). It was rolled out to this VM. On-call reports:

  "The service is green. Requests return HTTP 200. But our tracing backend
   shows ZERO spans for $SERVICE_NAME. Traces just aren't arriving."

WHAT YOU JUST SAW
  - GET /work returned:            HTTP $code   (application is fine)
  - Spans exported by the agent:   $spans          (nothing reaching the backend)
  This is SILENT telemetry loss: the worst kind, because nothing looks broken.

FILES (everything is under $LAB_DIR)
  - app.py        the service (contains NO otel code — instrumentation is external)
  - agent.env     the agent's OTEL_* configuration   <-- the fault lives here
  - run.sh        how the agent launches the app
  - restart.sh    relaunch after you edit agent.env
  - agent.log     stdout/stderr of the agent + app (your telemetry signal)

USEFUL COMMANDS
  Watch telemetry:   tail -f $LAB_DIR/agent.log
  Generate traffic:  curl -s 127.0.0.1:$APP_PORT/work ; echo
  Inspect config:    cat $LAB_DIR/agent.env
  Apply your fix:    edit $LAB_DIR/agent.env  then  $LAB_DIR/restart.sh
  Confirm the agent IS attached:  cat $LAB_DIR/run.sh   (note 'opentelemetry-instrument')

SUCCESS CRITERION (definition of done)
  After a request to /work, $LAB_DIR/agent.log must contain exported span
  records (JSON objects with "trace_id"/"span_id") whose resource carries
  service.name=$SERVICE_NAME. In short: make the span count go from 0 to > 0.

HINTS (peek only if stuck)
  1. The app is healthy and the agent IS loaded — so spans are being CREATED.
     The failure is at the EXPORT stage. Look at how traces leave the process.
  2. Rule out sampling first (it is already set to always_on). Then read every
     OTEL_*EXPORTER line in agent.env. One legal-looking value means "drop it".
  3. Three different switches can silence an agent while it "runs fine":
     the exporter, the SDK master switch, and the sampler. Which one is set here?

Reset anytime:  bash "$0" --clean
============================================================================
BRIEF

exit 0

# ============================================================================
#  ┌──────────────────────────────────────────────────────────────────────┐
#  │  INSTRUCTOR SOLUTION — step by step (do not reveal to the student yet) │
#  └──────────────────────────────────────────────────────────────────────┘
#
#  ROOT CAUSE
#  ----------
#  In agent.env the trace exporter is disabled:
#
#        OTEL_TRACES_EXPORTER=none
#
#  `none` is a fully valid value defined by the OpenTelemetry SDK environment
#  variable spec. It installs NO span exporter, so the agent still starts, still
#  auto-instruments Flask, and still CREATES spans on every request — but there
#  is no SpanProcessor/exporter pipeline to ship them, so they are dropped
#  in-process. The application is 100% healthy (HTTP 200) while the backend
#  receives nothing. Classic silent data loss.
#  Ref: https://opentelemetry.io/docs/languages/sdk-configuration/general/
#       https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
#
#  STEP 1 — Reproduce and scope
#    curl -s 127.0.0.1:$APP_PORT/work ; echo        # -> HTTP 200, app is fine
#    sleep 2
#    grep -c '"span_id"' "$LAB_DIR/agent.log"        # -> 0  (no spans exported)
#    tail -n 40 "$LAB_DIR/agent.log"                 # no exporter errors either -> silent
#
#  STEP 2 — Prove the agent is actually attached (rule out "agent not loaded")
#    grep opentelemetry-instrument "$LAB_DIR/run.sh"        # the agent IS in the launch line
#    "$VENV/bin/pip" show opentelemetry-distro | head       # agent packages installed
#    ps -o cmd= -p "$(cat "$LAB_DIR/app.pid")"              # cmdline shows the agent wrapper
#    # Since the agent is loaded but nothing is exported, the fault is in export/sampling,
#    # NOT in instrumentation.
#
#  STEP 3 — Rule out sampling
#    grep OTEL_TRACES_SAMPLER "$LAB_DIR/agent.env"          # parentbased_always_on -> not sampling
#
#  STEP 4 — Read the exporter configuration (find the fault)
#    grep -E 'OTEL_.*EXPORTER|OTEL_SDK_DISABLED' "$LAB_DIR/agent.env"
#    # -> OTEL_TRACES_EXPORTER=none      <-- the culprit
#
#  STEP 5 — Fix it
#    # Lab (offline) fix — export to the console stand-in backend:
#    sed -i 's/^OTEL_TRACES_EXPORTER=none/OTEL_TRACES_EXPORTER=console/' "$LAB_DIR/agent.env"
#
#    # Production-correct fix would instead be:
#    #   OTEL_TRACES_EXPORTER=otlp
#    #   OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318   # http/protobuf
#    #   OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
#
#  STEP 6 — Restart the agent so the new env takes effect (env is read at launch)
#    "$LAB_DIR/restart.sh"
#
#  STEP 7 — Verify success criterion
#    sleep 2
#    curl -s 127.0.0.1:$APP_PORT/work ; echo
#    sleep 2
#    grep -c '"span_id"' "$LAB_DIR/agent.log"                 # -> > 0
#    grep -o '"name": "GET /work"' "$LAB_DIR/agent.log" | head  # the server span appears
#    grep -o '"service.name": "payments-api"' "$LAB_DIR/agent.log" | head  # correct resource
#    # Span count moved from 0 -> N. Incident resolved.
#
#  WHY THIS MATTERS / PREVENTION
#  -----------------------------
#  Three independent "kill switches" produce this exact healthy-app/no-telemetry
#  symptom; know all three, because they look identical from the outside:
#    - OTEL_TRACES_EXPORTER=none        exporter removed; spans created then dropped
#    - OTEL_SDK_DISABLED=true           whole SDK becomes a no-op; nothing created
#    - OTEL_TRACES_SAMPLER=always_off   spans created but never recorded/sampled
#  Guardrails:
#    * Manage OTEL_* config in one reviewed source (ConfigMap / Operator
#      Instrumentation CR / systemd drop-in), not ad-hoc shell edits.
#    * Add a synthetic check that asserts spans for the service arrive at the
#      backend after a probe request — alert on "0 spans" like any other SLO.
#    * Treat `none`, `OTEL_SDK_DISABLED`, and `always_off` as production-config
#      red flags in code review.
#
#  Clean up the lab when done:   bash "$0" --clean
# ============================================================================