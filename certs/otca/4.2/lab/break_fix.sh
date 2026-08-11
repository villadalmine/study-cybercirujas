#!/usr/bin/env bash
#
# OTCA 4.2 — Debugging Observability Pipelines — "break & fix" lab
# =============================================================================
# Certification : OpenTelemetry Certified Associate (OTCA)
# Domain 4      : Maintaining and Debugging Observability Pipelines
# Topic 4.2     : Debugging Pipelines   (exam weight 2.5)
# Reference     : https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#                 https://opentelemetry.io/docs/collector/internal-telemetry/
#                 https://opentelemetry.io/docs/collector/troubleshooting/
#
# WHAT THIS SCRIPT DOES
#   Stands up a two-hop OpenTelemetry Collector pipeline on a DISPOSABLE lab VM
#   using Docker, proves it works end-to-end, then breaks ONE thing in a
#   controlled, fully reversible way. Your job is to diagnose the fault using
#   the Collector's own self-telemetry (:8888/metrics), its logs, and zpages,
#   then repair the pipeline. The step-by-step solution is at the BOTTOM of this
#   file, commented out — do not read it until you have tried.
#
# TOPOLOGY
#     [telemetrygen] --OTLP/gRPC--> [otca-edge collector] --OTLP/gRPC--> [otca-backend collector] --> debug/stdout
#     (load generator)              (the pipeline under test)            (simulated observability backend)
#
# SAFETY
#   Everything is namespaced under the docker network "otca-lab-net", the
#   containers "otca-edge/otca-backend/otca-loadgen", and the working dir
#   /tmp/otca-lab-4.2. It touches no host services and no repo files. Tear the
#   whole lab down at any time with:   ./break-fix-4.2.sh --clean
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------- config
LAB_DIR="/tmp/otca-lab-4.2"
NET="otca-lab-net"
COL_IMAGE="otel/opentelemetry-collector-contrib:0.102.0"
GEN_IMAGE="ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:0.102.0"
EDGE="otca-edge"
BACKEND="otca-backend"
LOADGEN="otca-loadgen"

# Ports published from the edge collector to the VM's localhost (diagnostics):
#   8888  -> internal self-telemetry (Prometheus metrics)
#   13133 -> health_check extension
#   55679 -> zpages extension
METRICS_PORT=8888
HEALTH_PORT=13133
ZPAGES_PORT=55679

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HDR=$'\033[1;36m'; C_OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s==== %s ====%s\n' "$C_HDR" "$*" "$C_OFF"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '%s[fail]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------- guards
require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is required and was not found in PATH."
  docker info >/dev/null 2>&1 || die "the docker daemon is not reachable (are you in the docker group / is it running?)."
  command -v curl >/dev/null 2>&1 || die "curl is required for the diagnostics steps."
}

confirm_disposable() {
  if [ "${OTCA_LAB_CONFIRM:-}" = "yes" ]; then return 0; fi
  if [ ! -t 0 ]; then
    die "Refusing to run non-interactively. Re-run with OTCA_LAB_CONFIRM=yes only on a DISPOSABLE lab VM."
  fi
  warn "This lab spawns docker containers named otca-* and writes to $LAB_DIR."
  warn "Run it ONLY on a throwaway lab VM you are happy to reset."
  read -r -p "Type 'yes' to continue: " reply
  [ "$reply" = "yes" ] || die "Aborted by user."
}

# ----------------------------------------------------------------------------- teardown
clean() {
  hdr "Tearing down the OTCA 4.2 lab"
  for c in "$LOADGEN" "$EDGE" "$BACKEND"; do
    docker rm -f "$c" >/dev/null 2>&1 && ok "removed container $c" || true
  done
  docker network rm "$NET" >/dev/null 2>&1 && ok "removed network $NET" || true
  rm -rf "$LAB_DIR" && ok "removed $LAB_DIR" || true
  ok "Lab is gone. Nothing else on the host was touched."
}

# ----------------------------------------------------------------------------- config files
write_configs() {
  mkdir -p "$LAB_DIR"

  # --- backend collector: the simulated observability backend ----------------
  cat > "$LAB_DIR/backend.yaml" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

exporters:
  debug:
    verbosity: normal

service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
YAML

  # --- edge collector: THE PIPELINE UNDER TEST (starts fully healthy) ---------
  cat > "$LAB_DIR/edge.yaml" <<'YAML'
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679
  pprof:
    endpoint: 0.0.0.0:1777

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 256
    spike_limit_mib: 64
  batch:
    timeout: 5s
    send_batch_size: 512

exporters:
  debug:
    verbosity: normal
  otlp:
    endpoint: otca-backend:4317
    tls:
      insecure: true
    sending_queue:
      enabled: true
      queue_size: 1000
    retry_on_failure:
      enabled: true
      initial_interval: 2s
      max_interval: 10s
      max_elapsed_time: 60s

service:
  extensions: [health_check, zpages, pprof]
  telemetry:
    logs:
      level: info
    metrics:
      address: 0.0.0.0:8888
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp, debug]
YAML

  # --- student's pass/fail probe --------------------------------------------
  cat > "$LAB_DIR/check-pipeline.sh" <<'PROBE'
#!/usr/bin/env bash
# Samples the edge collector's self-telemetry twice, 6s apart, and reports
# whether spans are actually reaching the backend exporter.
set -euo pipefail
url="http://localhost:8888/metrics"
val() { curl -s "$url" | grep -E "$1" | grep 'exporter="otlp"' | awk '{print $2}' | head -n1; }
recv() { curl -s "$url" | grep -E '^otelcol_receiver_accepted_spans' | awk '{print $2}' | head -n1; }
s1=$(val 'otelcol_exporter_sent_spans'); f1=$(val 'otelcol_exporter_send_failed_spans'); r1=$(recv)
sleep 6
s2=$(val 'otelcol_exporter_sent_spans'); f2=$(val 'otelcol_exporter_send_failed_spans'); r2=$(recv)
: "${s1:=0}"; "${s2:=0}"; "${f1:=0}"; "${f2:=0}"; "${r1:=0}"; "${r2:=0}" 2>/dev/null || true
ds=$(awk -v a="${s1:-0}" -v b="${s2:-0}" 'BEGIN{print b-a}')
df=$(awk -v a="${f1:-0}" -v b="${f2:-0}" 'BEGIN{print b-a}')
dr=$(awk -v a="${r1:-0}" -v b="${r2:-0}" 'BEGIN{print b-a}')
echo "receiver_accepted_spans  +$dr   (data entering the edge)"
echo "exporter_sent_spans      +$ds   (data leaving toward the backend)"
echo "exporter_send_failed     +$df   (export attempts that failed)"
if awk -v s="$ds" -v f="$df" 'BEGIN{exit !(s>0 && f==0)}'; then
  echo "RESULT: PASS — traces are flowing to the backend and nothing is failing."
else
  echo "RESULT: FAIL — the pipeline is still broken (nothing leaving, or failures climbing)."
fi
PROBE
  chmod +x "$LAB_DIR/check-pipeline.sh"
}

# ----------------------------------------------------------------------------- lab lifecycle
start_lab() {
  hdr "Pulling images (pinned to 0.102.0 so the config schema is stable)"
  docker pull "$COL_IMAGE" >/dev/null && ok "collector image ready"
  docker pull "$GEN_IMAGE" >/dev/null && ok "telemetrygen image ready"

  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
  ok "network $NET ready"

  hdr "Starting the simulated backend collector"
  docker rm -f "$BACKEND" >/dev/null 2>&1 || true
  docker run -d --name "$BACKEND" --network "$NET" \
    -v "$LAB_DIR/backend.yaml:/etc/otelcol/config.yaml:ro" \
    "$COL_IMAGE" --config /etc/otelcol/config.yaml >/dev/null
  ok "$BACKEND up (OTLP/gRPC on :4317, exports to stdout debug)"

  hdr "Starting the edge collector (the pipeline you will debug)"
  docker rm -f "$EDGE" >/dev/null 2>&1 || true
  docker run -d --name "$EDGE" --network "$NET" \
    -p "${METRICS_PORT}:8888" -p "${HEALTH_PORT}:13133" -p "${ZPAGES_PORT}:55679" \
    -v "$LAB_DIR/edge.yaml:/etc/otelcol/config.yaml:ro" \
    "$COL_IMAGE" --config /etc/otelcol/config.yaml >/dev/null
  ok "$EDGE up (metrics :$METRICS_PORT, health :$HEALTH_PORT, zpages :$ZPAGES_PORT)"

  hdr "Starting the continuous trace load generator"
  docker rm -f "$LOADGEN" >/dev/null 2>&1 || true
  docker run -d --name "$LOADGEN" --network "$NET" "$GEN_IMAGE" \
    traces --otlp-endpoint "otca-edge:4317" --otlp-insecure \
    --duration 3600s --rate 5 --workers 1 --service otca-checkout >/dev/null
  ok "$LOADGEN emitting ~5 spans/s from service \"otca-checkout\""
}

prove_healthy() {
  hdr "Proving the pipeline works BEFORE we break it"
  say "Waiting for the first batch to reach the backend (up to 40s)..."
  local i
  for i in $(seq 1 40); do
    if docker logs "$BACKEND" 2>&1 | grep -q 'TracesExporter'; then
      ok "backend received traces end-to-end — baseline is healthy."
      docker logs "$BACKEND" 2>&1 | grep 'TracesExporter' | tail -n1 | sed 's/^/    backend: /'
      return 0
    fi
    sleep 1
  done
  warn "Backend has not logged traces yet; check 'docker logs $BACKEND'. Continuing anyway."
}

break_it() {
  hdr "Injecting the fault (controlled, reversible: a single config line)"
  # Point the edge collector's OTLP exporter at a PORT WHERE NOTHING LISTENS.
  # The host resolves, the port is closed -> every export attempt is refused.
  sed -i 's/endpoint: otca-backend:4317/endpoint: otca-backend:4999/' "$LAB_DIR/edge.yaml"
  docker restart "$EDGE" >/dev/null
  ok "fault injected and edge collector reloaded."
}

briefing() {
  cat <<BRIEF

$(printf '%s' "$C_HDR")=============================================================================
 OTCA 4.2  —  YOUR MISSION
=============================================================================$(printf '%s' "$C_OFF")

SCENARIO
  The "otca-checkout" service is still emitting spans and the edge Collector is
  running with a VALID config (it started cleanly, no crash). Yet your backend
  has gone dark: no new traces are arriving. This is the classic pipeline
  incident — the process is UP but the data is not FLOWING.

SYMPTOM YOU WILL OBSERVE
  * The backend receives nothing new:
      docker logs --tail 5 $BACKEND         # no fresh "TracesExporter" lines
  * The edge still ingests fine, but export is failing and backing up:
      curl -s localhost:$METRICS_PORT/metrics | grep -E \\
        'otelcol_(receiver_accepted_spans|exporter_sent_spans|exporter_send_failed_spans|exporter_queue_size)'
      -> receiver_accepted_spans          keeps climbing   (ingest healthy)
      -> exporter_sent_spans{otlp}        flat at 0        (nothing leaves)
      -> exporter_send_failed_spans{otlp} keeps climbing   (export failing)
      -> exporter_queue_size{otlp}        rising to 1000   (backpressure / queue filling)
  * The edge logs are shouting the reason:
      docker logs --tail 20 $EDGE          # "Exporting failed ... connection refused"

TOOLS AT YOUR DISPOSAL
  * Self-telemetry (Prometheus):   http://localhost:$METRICS_PORT/metrics
  * Health check extension:        curl -s localhost:$HEALTH_PORT/     (or /health/status)
  * zpages pipeline view:          http://localhost:$ZPAGES_PORT/debug/pipelinez
  * zpages live traces:            http://localhost:$ZPAGES_PORT/debug/tracez
  * Edge / backend logs:           docker logs -f $EDGE   |   docker logs -f $BACKEND
  * The edge config file:          $LAB_DIR/edge.yaml

WHAT SUCCESS LOOKS LIKE
  Traces reach the backend again with NO failures. Verify with the probe:
      $LAB_DIR/check-pipeline.sh
  You are done when it prints:  RESULT: PASS

  (Tear the lab down afterwards with:  $0 --clean)

BRIEF
}

# ----------------------------------------------------------------------------- main
main() {
  case "${1:-}" in
    --clean|clean) require_docker; clean; exit 0 ;;
    -h|--help)
      say "Usage: $0 [--clean]"
      say "  (no args)  set up the lab, prove it healthy, inject the fault, and brief you"
      say "  --clean    remove all otca-* containers, the network and $LAB_DIR"
      exit 0 ;;
  esac

  require_docker
  confirm_disposable
  write_configs
  start_lab
  prove_healthy
  break_it
  briefing
}

main "$@"


# =============================================================================
# SOLUTION — INSTRUCTOR / STUDENT REFERENCE (do not peek until you've tried)
# =============================================================================
# Mental model for debugging ANY Collector pipeline: walk the data path
# receiver -> processors -> exporter and ask at each hop "did the count go up?"
# The self-telemetry on :8888 is the source of truth; logs give the root cause.
#
# STEP 1 — Confirm ingest is healthy (rule out the app and the receiver):
#     curl -s localhost:8888/metrics | grep '^otelcol_receiver_accepted_spans'
#   The value increases on every poll. Conclusion: spans ARE entering the edge,
#   so the problem is downstream of the receiver — not the app, not the network
#   into the collector.
#
# STEP 2 — Localize the break to the exporter:
#     curl -s localhost:8888/metrics | grep -E \
#       'otelcol_exporter_(sent|send_failed)_spans'
#   You see  otelcol_exporter_sent_spans{exporter="otlp"} 0  (flat) while
#            otelcol_exporter_send_failed_spans{exporter="otlp"}  climbs.
#     curl -s localhost:8888/metrics | grep 'otelcol_exporter_queue_size'
#   queue_size rises toward queue_capacity (1000): the sending queue is filling
#   because retries never drain. Conclusion: the OTLP exporter cannot deliver.
#   (Note exporter="debug" keeps working — that is why the edge's own debug logs
#    still show spans; presence at the edge, absence at the backend, pins the
#    fault to the hop BETWEEN them.)
#
# STEP 3 — Get the root cause from the logs:
#     docker logs --tail 30 otca-edge
#   You'll see repeating lines like:
#     "Exporting failed. Will retry the request after interval."
#     ... "rpc error: code = Unavailable ... connection refused" ... "otca-backend:4999"
#   The exporter is dialing port 4999, where nothing listens.
#
# STEP 4 — Confirm the backend truly received nothing (closes the loop):
#     docker logs --tail 10 otca-backend     # no new TracesExporter lines
#
# STEP 5 — Cross-check the wiring visually (optional, great habit):
#     curl -s localhost:55679/debug/pipelinez     # shows the traces pipeline
#     curl -s localhost:13133/                     # health_check extension
#
# STEP 6 — Fix the config (the endpoint port is wrong: 4999 -> 4317):
#     sed -i 's/endpoint: otca-backend:4999/endpoint: otca-backend:4317/' \
#         /tmp/otca-lab-4.2/edge.yaml
#   (or edit exporters.otlp.endpoint back to otca-backend:4317 by hand)
#
# STEP 7 — Reload the Collector so it re-reads the config:
#     docker restart otca-edge
#   (The Collector does not hot-reload this config by default; a restart applies it.)
#
# STEP 8 — Verify the repair:
#     watch -n2 "curl -s localhost:8888/metrics | grep -E \
#       'otelcol_exporter_(sent|send_failed)_spans'"
#   -> sent_spans{otlp} now climbs, send_failed goes flat, queue_size drains to 0.
#     docker logs --tail 10 otca-backend      # TracesExporter lines resume.
#     /tmp/otca-lab-4.2/check-pipeline.sh      # prints: RESULT: PASS
#
# WHY THIS IS THE RIGHT METHOD (exam takeaway)
#   * Metrics tell you WHERE in the pipeline data stops (receiver up, exporter
#     failing) before you ever read a log line — receiver_accepted vs
#     exporter_sent vs exporter_send_failed is the canonical triage triad.
#   * queue_size / queue_capacity reveals backpressure and pending data loss
#     once max_elapsed_time is exceeded and the queue overflows.
#   * Logs supply the concrete cause (connection refused, bad endpoint).
#   * A collector that STARTS is not a collector that WORKS: config validity and
#     data delivery are independent facts, and 4.2 is about proving the second.
#
# Sources:
#   https://opentelemetry.io/docs/collector/internal-telemetry/
#   https://opentelemetry.io/docs/collector/troubleshooting/
#   https://opentelemetry.io/docs/collector/configuration/#service
# =============================================================================