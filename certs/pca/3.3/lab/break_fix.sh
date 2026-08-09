#!/usr/bin/env bash
#
# =============================================================================
#  PCA — Prometheus Certified Associate
#  Domain 3.3 — Tracing and Spans           (exam weight: 3)
#  Lab type: BREAK & FIX (controlled, reversible, self-contained)
# =============================================================================
#
#  WHAT THIS TEACHES
#  -----------------
#  A "span" is a single timed operation; a "trace" is the tree of spans that
#  share one trace_id. In the OpenTelemetry model, applications EMIT spans over
#  OTLP to a collector, the collector runs them through a PIPELINE
#  (receivers -> processors -> exporters), and only what survives the pipeline
#  reaches the tracing backend. A very common production incident is: "the app
#  swears it is sending traces, the collector is healthy, yet the backend shows
#  nothing." The usual culprit lives *inside* the pipeline — most often a
#  SAMPLING stage — not on the wire. This lab reproduces exactly that, using the
#  collector's own Prometheus metrics (accepted vs. sent spans) as the compass.
#
#  This is the direct bridge between tracing and Prometheus: the collector is
#  itself a Prometheus target on :8888, and its span counters are how you localize
#  a fault to a pipeline stage without a full tracing backend.
#
#  ARCHITECTURE OF THE LAB
#  -----------------------
#    curl (span generator)  --OTLP/HTTP JSON-->  otelcol-contrib
#         :4318/v1/traces                         receivers.otlp
#                                                 processors: [probabilistic_sampler, batch]
#                                                 exporters:  [debug]  --> stdout (docker logs)
#                                                 telemetry metrics --> :8888/metrics
#
#  SAFETY
#  ------
#  * Runs ONLY a single, named, disposable container (pca-tracing-lab-otelcol).
#  * Touches ONLY its own state dir ($HOME/pca-lab-3.3). No host services.
#  * Nothing is installed on the host; `... clean` removes everything.
#  * Run this on a THROWAWAY lab VM. It refuses to run without confirmation
#    (skip the prompt in automation with:  PCA_LAB_ASSUME_YES=1).
#
#  SOURCES (official)
#  ------------------
#  * PCA curriculum ............ https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#  * OTel Collector ............ https://opentelemetry.io/docs/collector/
#  * Collector internal metrics  https://opentelemetry.io/docs/collector/internal-telemetry/
#  * probabilistic_sampler ..... https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/probabilisticsamplerprocessor
#  * debug exporter ............ https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/debugexporter
#  * OTLP/HTTP spec ............ https://opentelemetry.io/docs/specs/otlp/
#
#  USAGE
#  -----
#    ./pca-lab-3.3.sh            # set up baseline, inject the fault, print the challenge
#    ./pca-lab-3.3.sh send       # emit one span over OTLP and print its trace_id + HTTP status
#    ./pca-lab-3.3.sh check      # show the collector's span counters (:8888) + recent logs
#    ./pca-lab-3.3.sh verify     # emit a probe span and assert it was exported -> PASS/FAIL
#    ./pca-lab-3.3.sh apply FILE # push a config into the collector and restart it
#    ./pca-lab-3.3.sh logs [N]   # tail collector logs
#    ./pca-lab-3.3.sh clean      # tear the whole lab down
# =============================================================================

set -euo pipefail

# ------------------------------- configuration -------------------------------
CONTAINER="pca-tracing-lab-otelcol"
IMAGE="otel/opentelemetry-collector-contrib:0.96.0"
CONTAINER_CONFIG="/etc/otelcol-contrib/config.yaml"
STATE="${PCA_LAB_HOME:-$HOME/pca-lab-3.3}"
OTLP_HTTP="http://localhost:4318/v1/traces"
METRICS="http://localhost:8888/metrics"
DOCKER=""   # resolved by detect_runtime()

# ------------------------------- pretty output -------------------------------
c()    { if [ -t 1 ]; then printf '\033[%sm' "$1"; fi; }
log()  { printf '%s[lab]%s  %s\n'  "$(c '1;36')" "$(c 0)" "$*"; }
warn() { printf '%s[warn]%s %s\n'  "$(c '1;33')" "$(c 0)" "$*" >&2; }
err()  { printf '%s[err]%s  %s\n'  "$(c '1;31')" "$(c 0)" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"; }

# --------------------------- runtime / preconditions -------------------------
detect_runtime() {
  need_cmd curl
  local candidate
  for candidate in "docker" "sudo docker" "podman"; do
    if $candidate info >/dev/null 2>&1; then DOCKER="$candidate"; break; fi
  done
  [ -n "$DOCKER" ] || err "No usable container runtime. Install docker or podman."
}

guard_disposable() {
  [ "${PCA_LAB_ASSUME_YES:-0}" = "1" ] && return 0
  cat <<'EOF'

  ┌──────────────────────────────────────────────────────────────────────┐
  │  This lab starts a container and INTENTIONALLY breaks its config.      │
  │  Run it ONLY on a disposable lab VM you do not care about.             │
  └──────────────────────────────────────────────────────────────────────┘
EOF
  local ans
  read -r -p "  Type 'yes' to confirm this is a throwaway lab VM: " ans
  [ "$ans" = "yes" ] || err "Aborted by user."
}

require_running() {
  $DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1 \
    || err "Lab collector not found. Run '$0' (no args) first."
}

# ------------------------------ collector configs ----------------------------
# HEALTHY pipeline: the sampler keeps 100% of spans, so every span is exported.
write_good_config() {
  cat > "$1" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 1s
  probabilistic_sampler:
    sampling_percentage: 100

exporters:
  debug:
    verbosity: detailed

service:
  telemetry:
    metrics:
      address: 0.0.0.0:8888
  pipelines:
    traces:
      receivers: [otlp]
      processors: [probabilistic_sampler, batch]
      exporters: [debug]
YAML
}

# FAULTY pipeline: identical EXCEPT the sampler keeps 0% of spans.
# The receiver still accepts every span (HTTP 200) and the collector is healthy,
# but the probabilistic_sampler drops 100% of them before the exporter.
write_broken_config() {
  cat > "$1" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 1s
  probabilistic_sampler:
    sampling_percentage: 0

exporters:
  debug:
    verbosity: detailed

service:
  telemetry:
    metrics:
      address: 0.0.0.0:8888
  pipelines:
    traces:
      receivers: [otlp]
      processors: [probabilistic_sampler, batch]
      exporters: [debug]
YAML
}

# ------------------------------ container lifecycle --------------------------
wait_ready() {
  local i
  for i in $(seq 1 30); do
    if curl -sf "$METRICS" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  err "Collector did not become ready. Inspect with: $DOCKER logs $CONTAINER"
}

recreate_collector() {  # $1 = config file on host
  $DOCKER rm -f "$CONTAINER" >/dev/null 2>&1 || true
  $DOCKER create --name "$CONTAINER" \
    -p 4317:4317 -p 4318:4318 -p 8888:8888 "$IMAGE" >/dev/null
  $DOCKER cp "$1" "$CONTAINER:$CONTAINER_CONFIG"
  $DOCKER start "$CONTAINER" >/dev/null
  wait_ready
}

do_apply() {  # $1 = config file on host
  local cfg="${1:?usage: $0 apply <config.yaml>}"
  [ -f "$cfg" ] || err "No such file: $cfg"
  require_running
  $DOCKER cp "$cfg" "$CONTAINER:$CONTAINER_CONFIG"
  $DOCKER restart "$CONTAINER" >/dev/null
  wait_ready
  log "Applied '$cfg' and restarted the collector."
}

# ------------------------------- span generator ------------------------------
rand_hex() {  # $1 = number of bytes
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Emits ONE span over OTLP/HTTP-JSON. Echoes "<trace_id>|<http_status>".
_emit_span() {
  local trace_id span_id now start payload code
  trace_id="$(rand_hex 16)"      # 16 bytes = 32 hex chars
  span_id="$(rand_hex 8)"        #  8 bytes = 16 hex chars
  now="$(date +%s%N)"
  start="$(( now - 1000000000 ))"   # 1s duration
  payload="$(cat <<JSON
{
  "resourceSpans": [{
    "resource": { "attributes": [
      { "key": "service.name",          "value": { "stringValue": "pca-lab-checkout" } },
      { "key": "deployment.environment","value": { "stringValue": "lab" } }
    ]},
    "scopeSpans": [{
      "scope": { "name": "pca.lab.tracer", "version": "1.0.0" },
      "spans": [{
        "traceId": "$trace_id",
        "spanId":  "$span_id",
        "name":    "GET /checkout",
        "kind":    2,
        "startTimeUnixNano": "$start",
        "endTimeUnixNano":   "$now",
        "attributes": [
          { "key": "http.request.method", "value": { "stringValue": "GET" } },
          { "key": "http.route",          "value": { "stringValue": "/checkout" } }
        ],
        "status": { "code": 1 }
      }]
    }]
  }]
}
JSON
)"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST -H 'Content-Type: application/json' \
      --data "$payload" "$OTLP_HTTP" 2>/dev/null || echo 000)"
  printf '%s|%s' "$trace_id" "$code"
}

exported_p() {  # $1 = trace_id  -> returns 0 if the exporter logged it
  $DOCKER logs "$CONTAINER" 2>&1 | grep -q "$1"
}

# ------------------------------- subcommands ---------------------------------
do_send() {
  require_running
  local out tid code
  out="$(_emit_span)"; tid="${out%%|*}"; code="${out##*|}"
  printf '%s\n' "$tid" > "$STATE/last_trace" 2>/dev/null || true
  log "Emitted span  trace_id=$tid  http_status=$code"
  if [ "$code" = "200" ]; then
    log "The OTLP receiver ACCEPTED the span (HTTP 200). Whether it is EXPORTED is a separate question."
  else
    warn "Unexpected HTTP status ($code) — the receiver/network is the problem, not the pipeline."
  fi
}

do_check() {
  require_running
  log "Collector internal telemetry ($METRICS) — the span pipeline as counters:"
  curl -s "$METRICS" \
    | grep -E '^otelcol_(receiver_accepted_spans|receiver_refused_spans|exporter_sent_spans|exporter_send_failed_spans)' \
    || warn "No span counters yet — send some spans first ('$0 send')."
  echo
  log "Reading: accepted_spans climbing while sent_spans stays flat => spans are dropped INSIDE the pipeline."
  echo
  log "Last 15 collector log lines:"
  $DOCKER logs --tail 15 "$CONTAINER" 2>&1 || true
}

do_verify() {
  require_running
  local out tid code
  out="$(_emit_span)"; tid="${out%%|*}"; code="${out##*|}"
  log "Probe span trace_id=$tid (http=$code); waiting up to 2s for it to reach the exporter..."
  sleep 2
  if exported_p "$tid"; then
    printf '\n  %s✅ PASS%s — the span reached the exporter. Spans flow end-to-end again.\n\n' "$(c '1;32')" "$(c 0)"
    return 0
  else
    printf '\n  %s❌ FAIL%s — the span was accepted (HTTP %s) but never exported. Keep digging.\n\n' "$(c '1;31')" "$(c 0)" "$code"
    return 1
  fi
}

do_clean() {
  detect_runtime
  $DOCKER rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$STATE"
  log "Lab torn down (container + $STATE removed)."
}

print_challenge() {  # $1 = broken-phase trace_id  $2 = http status
  local tid="$1" code="$2" accepted sent
  accepted="$(curl -s "$METRICS" | awk '/^otelcol_receiver_accepted_spans/{s+=$2} END{printf "%d", s+0}')"
  sent="$(curl -s "$METRICS" | awk '/^otelcol_exporter_sent_spans/{s+=$2} END{printf "%d", s+0}')"
  cat <<EOF

  ============================================================================
   PCA 3.3 — BREAK & FIX CHALLENGE:  "the spans vanish"
  ============================================================================

  SYMPTOM (what you will observe)
  -------------------------------
   * The collector container is Up and healthy — no crash, no restart loop.
   * Your application emits spans and the OTLP endpoint answers HTTP 200:
         probe span trace_id .......... $tid
         OTLP ingest HTTP status ...... $code   (accepted at the edge)
   * Yet NOTHING is exported. The debug exporter never prints your span, and a
     downstream tracing backend (Jaeger/Tempo) would stay empty.
   * The collector's own counters give it away:
         otelcol_receiver_accepted_spans = $accepted   (spans came in)
         otelcol_exporter_sent_spans     = $sent   (spans went out)
     The gap between "accepted" and "sent" means the spans are being dropped
     SOMEWHERE INSIDE THE PIPELINE — not on the wire, not at the backend.

  YOUR GOAL
  ---------
   Make spans flow end-to-end again, i.e. make this print PASS:
         $0 verify
   and make otelcol_exporter_sent_spans start climbing at:
         $METRICS

  CONSTRAINTS
  -----------
   * Do NOT change the receiver, the exporter, or the ports. Ingress works
     (HTTP 200) and egress works (the debug exporter is fine). The fault is a
     PROCESSING decision in the traces pipeline.
   * The live, editable config is on disk at:
         $STATE/config.yaml
     (it is also inside the container at $CONTAINER_CONFIG)

  TOOLBOX
  -------
     $0 send             # emit one span, see the HTTP status
     $0 check            # accepted vs. sent counters + recent logs  <-- your compass
     $0 apply $STATE/config.yaml   # push your edited config + restart
     $0 verify           # PASS/FAIL win condition
     $0 logs 40          # tail collector logs
     $0 clean            # give up / reset the lab

  Think in terms of the span lifecycle: received -> sampled -> batched -> exported.
  Which of those stages can silently discard a span while everything else stays
  green? (Scroll to the very bottom of this script only if you are truly stuck.)
  ============================================================================

EOF
}

do_start() {
  guard_disposable
  detect_runtime
  mkdir -p "$STATE"

  log "Pulling collector image ($IMAGE) ..."
  $DOCKER pull "$IMAGE" >/dev/null 2>&1 || err "Failed to pull $IMAGE (check network)."

  # ---- Phase 1: prove the healthy baseline ----------------------------------
  log "Phase 1/2 — starting a HEALTHY tracing pipeline (baseline) ..."
  write_good_config "$STATE/good.yaml"
  recreate_collector "$STATE/good.yaml"
  local out tid
  out="$(_emit_span)"; tid="${out%%|*}"
  sleep 2
  if exported_p "$tid"; then
    log "Baseline OK: span $tid was received AND exported (visible in the collector logs)."
  else
    warn "Baseline span not seen yet; the lab will still proceed."
  fi
  rm -f "$STATE/good.yaml"   # remove the answer from disk on purpose

  # ---- Phase 2: inject the fault --------------------------------------------
  log "Phase 2/2 — injecting the fault and restarting the collector ..."
  write_broken_config "$STATE/config.yaml"
  do_apply "$STATE/config.yaml"
  local bout btid bcode
  bout="$(_emit_span)"; btid="${bout%%|*}"; bcode="${bout##*|}"
  printf '%s\n' "$btid" > "$STATE/last_trace" 2>/dev/null || true
  sleep 2

  print_challenge "$btid" "$bcode"
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
}

main() {
  case "${1:-start}" in
    start|"")        do_start ;;
    send)            detect_runtime; do_send ;;
    verify)          detect_runtime; do_verify ;;
    check|status)    detect_runtime; do_check ;;
    apply)           detect_runtime; do_apply "${2:-}" ;;
    logs)            detect_runtime; require_running; $DOCKER logs --tail "${2:-40}" "$CONTAINER" ;;
    clean|reset|down) do_clean ;;
    help|-h|--help)  usage ;;
    *) warn "Unknown command: $1"; usage; exit 1 ;;
  esac
}

main "$@"

# =============================================================================
#  SOLUTION — step by step  (read only after you have tried)
# =============================================================================
#
#  1) CONFIRM THE SHAPE OF THE FAILURE.
#     $ ./pca-lab-3.3.sh send        # -> http_status = 200   (span is ACCEPTED)
#     $ ./pca-lab-3.3.sh verify      # -> FAIL                (span is NOT exported)
#     The container is Up and answers 200, so this is NOT a network/receiver
#     problem and NOT a crashed collector. The span dies after ingress.
#
#  2) LOCALIZE WITH THE COLLECTOR'S OWN METRICS (the tracing<->Prometheus bridge).
#     $ ./pca-lab-3.3.sh check
#       otelcol_receiver_accepted_spans   ... > 0 and climbing   (spans enter)
#       otelcol_receiver_refused_spans    ... 0                  (nothing rejected at ingress)
#       otelcol_exporter_sent_spans       ... 0                  (nothing leaves)
#       otelcol_exporter_send_failed_spans... 0                  (exporter/backend is fine)
#     accepted > 0 while sent = 0, with no refusals and no send failures, proves
#     the spans are discarded BETWEEN the receiver and the exporter — i.e. by a
#     PROCESSOR in the traces pipeline.
#
#  3) INSPECT THE PIPELINE PROCESSORS.
#     traces.processors: [probabilistic_sampler, batch]
#     'batch' only groups spans; it does not drop them. 'probabilistic_sampler'
#     is a head-based sampler whose whole job is to KEEP a percentage of spans
#     and drop the rest. That is the only span-dropping stage here.
#
#  4) FIND THE ROOT CAUSE IN THE CONFIG.
#     $ grep -n sampling_percentage "$HOME/pca-lab-3.3/config.yaml"
#         probabilistic_sampler:
#           sampling_percentage: 0        # <-- keeps 0% of spans = drops 100%
#     sampling_percentage is "percent of spans to KEEP", not "to drop". 0 means
#     every span is discarded before it can be batched or exported.
#
#  5) FIX IT. Edit $HOME/pca-lab-3.3/config.yaml and set the sampler to keep
#     spans. For a debug/lab pipeline you want everything, so:
#
#         processors:
#           batch:
#             timeout: 1s
#           probabilistic_sampler:
#             sampling_percentage: 100
#
#     (Removing the probabilistic_sampler from the processors list entirely and
#      from the pipeline would also work; setting it to 100 is the minimal fix.)
#
#  6) APPLY AND VERIFY.
#     $ ./pca-lab-3.3.sh apply "$HOME/pca-lab-3.3/config.yaml"
#     $ ./pca-lab-3.3.sh verify        # -> PASS
#     $ ./pca-lab-3.3.sh check         # otelcol_exporter_sent_spans now climbs
#
#  WHY THIS MATTERS IN PRODUCTION (spans & sampling concepts)
#  ----------------------------------------------------------
#  * Sampling is a first-class tracing concept: you rarely keep 100% of spans in
#    production because traces are voluminous. probabilistic_sampler is HEAD-based
#    (the keep/drop decision is made per-trace at ingestion, using a hash of the
#    trace_id so all spans of a trace share one decision — consistency).
#  * A fat-fingered 0 (or "0.10" meant as 10%) is a classic outage: telemetry
#    silently disappears while every health check stays green. Always alert on
#    otelcol_exporter_sent_spans == 0 while otelcol_receiver_accepted_spans > 0.
#  * When you need "keep all ERROR traces but 1% of the rest", head-based
#    probabilistic sampling is not enough — you move the decision to the END of
#    the trace with the tail_sampling processor, which can see span status/latency
#    before deciding. See:
#    https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
#
#  CLEAN UP:  ./pca-lab-3.3.sh clean
# =============================================================================