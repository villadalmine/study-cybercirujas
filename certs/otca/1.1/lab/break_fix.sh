#!/usr/bin/env bash
#
# ==============================================================================
#  OTCA 1.1 — Telemetry Data  ·  BREAK & FIX LAB
#  OpenTelemetry Certified Associate (OTCA) · Domain 1 "OpenTelemetry Basics"
# ==============================================================================
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  Telemetry data in OpenTelemetry travels as three distinct SIGNALS — traces,
#  metrics and logs — encoded on the wire with OTLP (OpenTelemetry Protocol).
#  OTLP has two transports with two well-known, NON-interchangeable ports:
#        gRPC  -> 4317      HTTP/protobuf -> 4318
#  A producer (SDK, telemetrygen, a sidecar) pushes signals into a Collector
#  RECEIVER; the Collector runs them through a PIPELINE (receiver -> processor
#  -> exporter) and hands them to a backend. If the receiver does not listen
#  where the producer is dialing, the telemetry data never enters the pipeline
#  and is silently lost at the source. That plumbing failure is THE most common
#  first bug an operator hits, and it is exactly what you will diagnose here.
#
#  SAFETY
#  ------
#  Everything runs inside ONE throwaway Docker container on host networking and
#  ONE scratch directory under /tmp. It does not touch systemd, packages, users
#  or any file outside its lab dir. `cleanup` removes both. Run it on a
#  disposable lab VM anyway — that is the contract of a break & fix exercise.
#
#  USAGE
#  -----
#     ./break-fix-telemetry.sh break     # arm the fault + print your mission
#     ./break-fix-telemetry.sh test      # send test traces, observe the symptom
#     ./break-fix-telemetry.sh logs      # tail the Collector's own output
#     ./break-fix-telemetry.sh restart   # reload the Collector after you edit it
#     ./break-fix-telemetry.sh cleanup   # tear the whole lab down
#     ./break-fix-telemetry.sh solution  # print the step-by-step fix (spoiler)
#
#  Sources:
#   - OTLP spec & ports 4317/4318 ...... https://opentelemetry.io/docs/specs/otlp/
#   - Signals (traces/metrics/logs) .... https://opentelemetry.io/docs/concepts/signals/
#   - Collector pipelines .............. https://opentelemetry.io/docs/collector/configuration/
#   - debug exporter ................... https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/debugexporter
#   - telemetrygen ..................... https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
#   - OTCA curriculum .................. https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
# ==============================================================================

set -euo pipefail

# --- Tunables (override via env) ----------------------------------------------
COL_VERSION="${COL_VERSION:-0.119.0}"                 # collector-contrib release tag
COL_IMAGE="otel/opentelemetry-collector-contrib:${COL_VERSION}"
TGEN_IMAGE="ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:${COL_VERSION}"
CONTAINER="otca-lab-collector"
LAB_DIR="${LAB_DIR:-/tmp/otca-1.1-telemetry-data}"
CONFIG="${LAB_DIR}/collector.yaml"

GRPC_PORT_EXPECTED=4317        # where every OTLP gRPC producer dials by default
HTTP_PORT=4318                 # OTLP/HTTP (left correct on purpose)
BROKEN_GRPC_PORT=4319          # the injected fault: receiver told to listen here

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()   { printf '\033[33m%s\033[0m\n' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

require_docker() {
  command -v docker >/dev/null 2>&1 || {
    c_red "docker is required and was not found on PATH. Install Docker on the lab VM first."
    exit 1
  }
  docker info >/dev/null 2>&1 || {
    c_red "Cannot talk to the Docker daemon (is it running / are you in the docker group?)."
    exit 1
  }
}

confirm_lab() {
  if [[ "${OTCA_LAB_YES:-}" == "1" ]]; then return; fi
  c_ylw "This lab pulls images and runs a container on HOST networking (ports ${GRPC_PORT_EXPECTED}/${HTTP_PORT}/${BROKEN_GRPC_PORT})."
  c_ylw "Only run it on a disposable lab VM."
  read -r -p "Type 'lab' to continue: " ans
  [[ "$ans" == "lab" ]] || { echo "Aborted."; exit 1; }
}

# --- The broken Collector config ----------------------------------------------
# Note the ONE injected fault, flagged inline. The traces/metrics/logs pipelines
# are all correctly wired to the debug exporter — the telemetry never even
# reaches them, which is the whole lesson.
write_broken_config() {
  mkdir -p "$LAB_DIR"
  cat > "$CONFIG" <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        # >>> INJECTED FAULT <<<
        # The default OTLP/gRPC port is 4317. This receiver is told to listen on
        # ${BROKEN_GRPC_PORT} instead, so any producer dialing 4317 hits nothing.
        endpoint: 0.0.0.0:${BROKEN_GRPC_PORT}
      http:
        endpoint: 0.0.0.0:${HTTP_PORT}

processors:
  batch: {}

exporters:
  debug:
    verbosity: detailed        # print full resource/scope/span detail to stdout

service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [batch]
      exporters:  [debug]
    metrics:
      receivers:  [otlp]
      processors: [batch]
      exporters:  [debug]
    logs:
      receivers:  [otlp]
      processors: [batch]
      exporters:  [debug]
EOF
}

start_collector() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" --network host \
    -v "${CONFIG}:/etc/otelcol/config.yaml:ro" \
    "$COL_IMAGE" --config /etc/otelcol/config.yaml >/dev/null
  sleep 2
}

do_break() {
  require_docker
  confirm_lab
  c_bold "Pulling images (first run only)…"
  docker pull "$COL_IMAGE"  >/dev/null 2>&1 || true
  docker pull "$TGEN_IMAGE" >/dev/null 2>&1 || true
  write_broken_config
  start_collector

  cat <<EOF

$(c_red '================  FAULT ARMED  ================')

A Collector is running (container: ${CONTAINER}). Its config lives at:
    ${CONFIG}

$(c_bold 'THE SYMPTOM YOU WILL SEE')
Run:   $0 test
telemetrygen will try to push 5 spans over OTLP/gRPC to the default port
(localhost:${GRPC_PORT_EXPECTED}) and FAIL with something like:

    traces export: context deadline exceeded
    rpc error: code = Unavailable desc = connection error:
        desc = "transport: Error while dialing: dial tcp 127.0.0.1:${GRPC_PORT_EXPECTED}: connect: connection refused"

Meanwhile   $0 logs   shows the Collector alive and healthy but NEVER printing
a single "ResourceSpans" line — because no telemetry data ever reached it.

$(c_bold 'YOUR MISSION')
Make the telemetry data flow. Success = after '$0 test' the Collector logs
print your spans in full detail (a block containing 'ResourceSpans' and the
span name 'okey-dokey' / 'lets-go' emitted by telemetrygen), and telemetrygen
exits 0.

$(c_bold 'HINTS')
  * OTLP has fixed ports. Which one does a gRPC producer use by default?
  * You are NOT allowed to change how telemetrygen dials — fix the receiver.
  * Edit ${CONFIG}, then reload with:   $0 restart
  * Inspect what's actually listening:  ss -ltnp | grep -E '431[789]'

When you are ready to compare, or if you get stuck:  $0 solution

EOF
}

do_test() {
  require_docker
  c_bold "Sending 5 test traces over OTLP/gRPC to localhost:${GRPC_PORT_EXPECTED} …"
  echo
  if docker run --rm --network host "$TGEN_IMAGE" \
        traces --otlp-insecure --otlp-endpoint "localhost:${GRPC_PORT_EXPECTED}" --traces 5
  then
    echo
    c_grn "telemetrygen exited 0 — now check '$0 logs' for the exported spans."
  else
    echo
    c_red "telemetrygen FAILED — the telemetry data did not reach the Collector (this is the symptom)."
  fi
}

do_logs()    { require_docker; docker logs --tail 60 -f "$CONTAINER"; }
do_restart() { require_docker; c_bold "Reloading Collector with the current config…"; start_collector; c_grn "Restarted. Re-run: $0 test"; }
do_cleanup() {
  require_docker
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  c_grn "Lab removed (container + ${LAB_DIR})."
}

case "${1:-break}" in
  break)    do_break   ;;
  test)     do_test    ;;
  logs)     do_logs    ;;
  restart)  do_restart ;;
  cleanup)  do_cleanup ;;
  solution) do_solution ;;
  *) echo "usage: $0 {break|test|logs|restart|cleanup|solution}"; exit 1 ;;
esac

# ==============================================================================
#  SOLUTION — printed by:  ./break-fix-telemetry.sh solution
# ==============================================================================
do_solution() {
cat <<'SOLUTION'
=========================  STEP-BY-STEP SOLUTION  =========================

ROOT CAUSE
  The OTLP receiver was told to listen on gRPC port 4319, but every OTLP/gRPC
  producer — telemetrygen, the language SDKs, most sidecars — dials 4317 by
  default. The Collector process was perfectly healthy; the telemetry data was
  lost BEFORE the pipeline, at the transport layer. This is a "signal never
  ingested" failure, not a "signal dropped in a processor" failure — the two
  look similar (no data at the backend) but are diagnosed in opposite places.

1) CONFIRM WHAT IS ACTUALLY LISTENING (evidence before edits)
     $ ss -ltnp | grep -E '431[789]'
     LISTEN 0 4096 *:4318  users:(("otelcol-contrib",...))   # OTLP/HTTP  (fine)
     LISTEN 0 4096 *:4319  users:(("otelcol-contrib",...))   # OTLP/gRPC  (WRONG)
     # Nothing on 4317 -> that is exactly why telemetrygen got "connection refused".

2) FIX THE RECEIVER ENDPOINT
     $ sed -i 's/0.0.0.0:4319/0.0.0.0:4317/' /tmp/otca-1.1-telemetry-data/collector.yaml
   or edit by hand so the block reads:
       receivers:
         otlp:
           protocols:
             grpc:
               endpoint: 0.0.0.0:4317     # <- corrected
             http:
               endpoint: 0.0.0.0:4318

3) RELOAD THE COLLECTOR (it does not hot-reload the config file)
     $ ./break-fix-telemetry.sh restart

4) RE-SEND AND VERIFY THE DATA FLOWS
     $ ./break-fix-telemetry.sh test        # telemetrygen now exits 0
     $ ./break-fix-telemetry.sh logs        # look for the exported spans:

       ResourceSpans #0
       Resource attributes:
            -> service.name: Str(telemetrygen)
       ScopeSpans #0
       Span #0
           Trace ID       : ...
           Name           : lets-go
           Kind           : Client
       ...
   Seeing full ResourceSpans in the debug exporter output confirms the whole
   path — producer -> OTLP/gRPC:4317 -> otlp receiver -> batch -> debug — is up.

WHY THE OTHER PORT MATTERED (the exam-relevant takeaway)
  * OTLP/HTTP on 4318 was fine the entire time. If you had instead pointed a
    producer at the HTTP port, or sent JSON to the gRPC port, you'd get a
    DIFFERENT failure (protocol/415 mismatch) — because OTLP transport AND
    encoding must both match. Port + transport + signal type are three
    independent things a producer and a receiver must agree on.
  * The debug exporter (formerly the "logging" exporter) with verbosity:detailed
    is your first-line tool for proving telemetry data reached the Collector at
    all, before you blame a downstream backend.

CLEAN UP
     $ ./break-fix-telemetry.sh cleanup
===========================================================================
SOLUTION
}