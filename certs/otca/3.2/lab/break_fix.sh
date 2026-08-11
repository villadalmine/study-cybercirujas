#!/usr/bin/env bash
#
# otca-3.2-breakfix.sh — OTCA Domain 3 (The OpenTelemetry Collector), Topic 3.2: Deployment
#
# Break & Fix lab. Runs ONLY against a disposable lab VM. It deploys a real
# OpenTelemetry Collector in a container, injects ONE controlled, realistic
# deployment fault, and asks you to diagnose and repair it. Everything it
# creates is namespaced under the "otca-lab-" prefix and can be removed with
# the `cleanup` subcommand — it touches nothing else on the host.
#
# Scenario: the Collector is deployed as an "agent" that must receive OTLP
# telemetry over the container network from other workloads. A generator
# workload (telemetrygen) plays the role of an instrumented application.
#
# Sources (official):
#   - Collector configuration:  https://opentelemetry.io/docs/collector/configuration/
#   - Collector deployment:      https://opentelemetry.io/docs/collector/deployment/
#   - OTLP receiver README:      https://github.com/open-telemetry/opentelemetry-collector/blob/main/receiver/otlpreceiver/README.md
#   - Endpoint hardening (why localhost is now the default):
#                                https://opentelemetry.io/blog/2024/hardening-the-collector-one/
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration constants (all namespaced under otca-lab-)
# --------------------------------------------------------------------------- #
LAB_PREFIX="otca-lab"
NET="${LAB_PREFIX}-net"
COLLECTOR="${LAB_PREFIX}-collector"
LAB_DIR="${LAB_DIR:-/tmp/${LAB_PREFIX}}"
CONFIG="${LAB_DIR}/collector-config.yaml"
COLLECTOR_IMAGE="otel/opentelemetry-collector:latest"
GEN_IMAGE="ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest"

# --------------------------------------------------------------------------- #
# Pretty printing
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"; GRN="$(printf '\033[32m')"
  YEL="$(printf '\033[33m')"; CYN="$(printf '\033[36m')"; RST="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
head() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RST"; }
ok()   { printf '%s[ ok ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '%s[fail]%s %s\n' "$RED" "$RST" "$*" 1>&2; }

# --------------------------------------------------------------------------- #
# Container runtime detection (docker or podman)
# --------------------------------------------------------------------------- #
RUNTIME=""
detect_runtime() {
  if command -v docker >/dev/null 2>&1; then RUNTIME="docker"
  elif command -v podman >/dev/null 2>&1; then RUNTIME="podman"
  else
    err "Neither docker nor podman found. This lab needs a container runtime."
    exit 1
  fi
  ok "Using container runtime: ${RUNTIME}"
}

# --------------------------------------------------------------------------- #
# The BROKEN Collector configuration.
#
# The OTLP gRPC receiver is bound to 'localhost:4317'. Inside a container (or a
# Kubernetes Pod) that binds the loopback interface of the container's own
# network namespace ONLY. Any other workload dialing the Collector by its
# service name / Pod IP hits an interface where nothing is listening, and the
# kernel answers with a TCP RST -> "connection refused".
#
# This is not a made-up trap: recent Collector releases changed the default
# receiver endpoint from 0.0.0.0 to localhost precisely to reduce accidental
# exposure. Operators who containerize the Collector without revisiting the
# bind address hit exactly this symptom on first deploy.
# --------------------------------------------------------------------------- #
write_broken_config() {
  mkdir -p "$LAB_DIR"
  cat > "$CONFIG" <<'EOF'
# OpenTelemetry Collector — OTCA 3.2 Deployment lab (BROKEN state)
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: localhost:4317      # <-- fault lives here
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch: {}

exporters:
  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [batch]
      exporters:  [debug]
  telemetry:
    logs:
      level: info
EOF
  ok "Wrote Collector config: ${CONFIG}"
}

# --------------------------------------------------------------------------- #
# Lifecycle helpers
# --------------------------------------------------------------------------- #
ensure_net() {
  if ! $RUNTIME network inspect "$NET" >/dev/null 2>&1; then
    $RUNTIME network create "$NET" >/dev/null
    ok "Created network ${NET}"
  fi
}

run_collector() {
  $RUNTIME rm -f "$COLLECTOR" >/dev/null 2>&1 || true
  $RUNTIME run -d --name "$COLLECTOR" --network "$NET" \
    -v "${CONFIG}:/etc/otelcol/config.yaml:ro" \
    "$COLLECTOR_IMAGE" --config=/etc/otelcol/config.yaml >/dev/null
  sleep 2
  if [ "$($RUNTIME inspect -f '{{.State.Running}}' "$COLLECTOR" 2>/dev/null)" = "true" ]; then
    ok "Collector '${COLLECTOR}' is running"
  else
    err "Collector failed to start. Inspect: ${RUNTIME} logs ${COLLECTOR}"
    $RUNTIME logs "$COLLECTOR" 2>&1 | tail -n 20 || true
    exit 1
  fi
}

# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #
cmd_setup() {
  detect_runtime
  ensure_net
  $RUNTIME pull "$COLLECTOR_IMAGE" >/dev/null 2>&1 || true
  $RUNTIME pull "$GEN_IMAGE"       >/dev/null 2>&1 || true
  write_broken_config
  run_collector

  head "BREAK INJECTED — read carefully"
  cat <<EOF
${CYN}Deployment topology${RST}
  [telemetrygen]  --OTLP/gRPC-->  [${COLLECTOR}]  --debug exporter-->  stdout
  (plays an app)      :4317          (agent Collector)

${CYN}What you will observe (the SYMPTOM)${RST}
  Run:  ./$(basename "$0") test
  The generator fails to export. You will see gRPC errors such as:
    rpc error: code = Unavailable desc = connection error:
    ... dial tcp <ip>:4317: connect: connection refused
  The Collector process itself is UP and healthy — but NO spans ever reach
  it, so './$(basename "$0") logs' shows no exported traces.

${CYN}Your objective (what "fixed" means)${RST}
  1. telemetrygen exports successfully (exit code 0, "traces generated").
  2. './$(basename "$0") logs' shows the spans arriving through the
     debug exporter (look for 'ResourceSpans', span names, etc.).

${CYN}Rules of engagement${RST}
  - You may edit ONLY:  ${CONFIG}
  - Apply changes with: ./$(basename "$0") restart
  - Diagnose freely:    ./$(basename "$0") logs | status | test
  - Do NOT peek at the solution block at the bottom of this script until
    you have formed and tested a hypothesis.

The scenario is live. Start with:  ./$(basename "$0") test
EOF
}

cmd_test() {
  detect_runtime
  head "Sending 5 test traces from telemetrygen -> ${COLLECTOR}:4317"
  set +e
  $RUNTIME run --rm --network "$NET" "$GEN_IMAGE" \
    traces --otlp-endpoint "${COLLECTOR}:4317" --otlp-insecure --traces 5
  rc=$?
  set -e
  echo
  if [ "$rc" -eq 0 ]; then
    ok "Generator exited 0 — traces accepted. Now confirm they landed:"
    say "      ./$(basename "$0") logs   (look for exported spans)"
  else
    err "Generator failed (exit ${rc}). This is the symptom to diagnose."
    say "      Hint: is the receiver reachable on the container network,"
    say "      or only on the Collector's own loopback? Check 'status'."
  fi
}

cmd_logs() {
  detect_runtime
  head "Last 40 lines of Collector logs"
  $RUNTIME logs "$COLLECTOR" 2>&1 | tail -n 40 || true
}

cmd_status() {
  detect_runtime
  head "Lab status"
  $RUNTIME ps --filter "name=${LAB_PREFIX}" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
  echo
  say "OTLP gRPC bind address currently configured:"
  grep -nE 'endpoint:.*4317' "$CONFIG" 2>/dev/null | sed 's/^/    /' || warn "config not found"
  echo
  if grep -qE 'endpoint:[[:space:]]*localhost:4317' "$CONFIG" 2>/dev/null; then
    warn "gRPC receiver is bound to loopback — unreachable across the network (STILL BROKEN)."
  elif grep -qE 'endpoint:[[:space:]]*(0\.0\.0\.0|\[?::\]?):4317' "$CONFIG" 2>/dev/null; then
    ok "gRPC receiver is bound to a routable interface (looks FIXED). Verify with 'test'."
  fi
}

cmd_restart() {
  detect_runtime
  head "Restarting Collector to apply ${CONFIG}"
  run_collector
  say "Now re-run: ./$(basename "$0") test"
}

cmd_reset() {
  head "Re-injecting the original break"
  detect_runtime
  ensure_net
  write_broken_config
  run_collector
  ok "Lab restored to the broken baseline."
}

cmd_cleanup() {
  detect_runtime
  head "Removing all otca-lab-* resources"
  $RUNTIME rm -f "$COLLECTOR" >/dev/null 2>&1 || true
  $RUNTIME network rm "$NET"  >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR" 2>/dev/null || true
  ok "Cleaned up containers, network and ${LAB_DIR}."
}

cmd_solution() {
  sed -n '/^# ==== SOLUTION/,/^# ==== END SOLUTION/p' "$0"
}

usage() {
  cat <<EOF
OTCA 3.2 Deployment — Break & Fix

Usage: ./$(basename "$0") <command>

  setup      Deploy the Collector with the injected fault (default). START HERE.
  test       Send test traces and show the symptom / success.
  logs       Tail the Collector logs (where fixed traces appear).
  status     Show container state and the current bind address.
  restart    Recreate the Collector to apply your config edits.
  reset      Re-inject the original break (fresh start).
  cleanup    Remove every otca-lab-* container, network and temp file.
  solution   Print the step-by-step fix (try it yourself first!).
EOF
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
case "${1:-setup}" in
  setup)    cmd_setup ;;
  test)     cmd_test ;;
  logs)     cmd_logs ;;
  status)   cmd_status ;;
  restart)  cmd_restart ;;
  reset)    cmd_reset ;;
  cleanup)  cmd_cleanup ;;
  solution) cmd_solution ;;
  -h|--help|help) usage ;;
  *) err "Unknown command: $1"; usage; exit 2 ;;
esac

# ==== SOLUTION (step by step) ================================================
#
# WHY IT BREAKS
#   The OTLP gRPC receiver is configured with `endpoint: localhost:4317`. A
#   process binding `localhost` (127.0.0.1) only accepts connections arriving
#   on the loopback interface OF ITS OWN network namespace. In a container or
#   a Kubernetes Pod, every other workload reaches the Collector through the
#   container/Pod IP on the shared network — an interface where the receiver
#   is NOT listening. The kernel replies with a TCP RST, surfaced by gRPC as
#   "connection refused". The Collector is healthy; the door is simply on the
#   wrong wall. (Recent Collector releases default to `localhost` on purpose,
#   to avoid unintentionally exposing receivers — so this is a real first-deploy
#   trap, not a synthetic one.)
#
# STEP 1 — Reproduce and confirm the symptom
#   ./otca-3.2-breakfix.sh test
#     -> "dial tcp <ip>:4317: connect: connection refused", generator exits !=0
#   ./otca-3.2-breakfix.sh logs
#     -> Collector started fine; no ResourceSpans, because nothing arrives.
#
# STEP 2 — Localize the fault
#   ./otca-3.2-breakfix.sh status
#     -> reports the gRPC receiver bound to loopback.
#   Reason it through: process is UP + client gets "refused" == right port,
#   wrong bind interface. Deployment-level networking problem, not a pipeline
#   or exporter problem.
#
# STEP 3 — Apply the fix
#   Edit /tmp/otca-lab/collector-config.yaml and change:
#       grpc:
#         endpoint: localhost:4317
#   to:
#       grpc:
#         endpoint: 0.0.0.0:4317
#   (Equivalently, in Kubernetes you would bind the Pod interface, e.g. via the
#   POD_IP downward-API env var: `endpoint: ${env:POD_IP}:4317`, keeping the
#   surface as narrow as the deployment allows.)
#
# STEP 4 — Roll out the change and verify
#   ./otca-3.2-breakfix.sh restart
#   ./otca-3.2-breakfix.sh test      # generator now exits 0
#   ./otca-3.2-breakfix.sh logs      # debug exporter prints the 5 spans
#
# STEP 5 — Understand the trade-off (exam-relevant)
#   0.0.0.0 fixes reachability but binds ALL interfaces. In production do not
#   stop here: constrain exposure with NetworkPolicies, a dedicated Service,
#   TLS/mTLS on the receiver, and — where possible — bind the specific Pod IP
#   instead of a wildcard. Reachability and least-exposure are the two sides of
#   Collector deployment you must balance.
#   Ref: https://opentelemetry.io/blog/2024/hardening-the-collector-one/
#
# STEP 6 — Tear down the disposable lab
#   ./otca-3.2-breakfix.sh cleanup
#
# ==== END SOLUTION ===========================================================