#!/usr/bin/env bash
#
# OTCA — Domain 1: Observability Concepts
# Topic 1.4: Analysis and Outcomes  (exam weight 4.5)
#
# BREAK & FIX LAB — "The outcome your analysis reports does not match reality."
#
# Big idea of this topic: telemetry only has value once it is turned into an
# *outcome* — a number on a dashboard, an SLI, an error rate, a trace count that
# answers a question ("is checkout healthy?"). Every stage the signal passes
# through in a pipeline can silently change that outcome. Sampling, filtering and
# routing are the usual suspects: the app emits correct data, every URL resolves,
# the Collector is "up" and green — yet the analysis you build on top reads zero,
# or worse, a plausible-but-wrong number. This lab reproduces that failure in a
# controlled, fully reversible way and asks you to make the OUTCOME match the
# INPUT again.
#
# WHAT THIS SCRIPT DOES (safely, on a DISPOSABLE lab VM only):
#   * Runs a single OpenTelemetry Collector (contrib) in one named container.
#   * Feeds it exactly N synthetic spans from a fake "checkout" service.
#   * Exports what survives the pipeline to a file the "analysis job" counts.
#   * Introduces ONE controlled misconfiguration in the traces pipeline.
#
# It touches nothing outside its own lab directory and its own container.
# No system packages, no host config, no privileged flags.
#
# ---------------------------------------------------------------------------
# USAGE
#   ./otca_1_4_break_fix.sh --yes            # set up the lab and BREAK it
#   ./otca_1_4_break_fix.sh check            # re-run the load and print the outcome
#   ./otca_1_4_break_fix.sh logs             # tail the Collector logs
#   ./otca_1_4_break_fix.sh solution         # apply the intended fix (spoiler)
#   ./otca_1_4_break_fix.sh cleanup          # remove the container and lab dir
#
# The Collector config the student edits lives at:  $LAB_DIR/collector.yaml
# ---------------------------------------------------------------------------

set -euo pipefail

# ------------------------------- configuration ------------------------------
LAB_DIR="${OTCA_LAB_DIR:-/tmp/otca-1.4-lab}"
CONTAINER="${OTCA_CONTAINER:-otca14-collector}"
IMAGE="${OTCA_IMAGE:-otel/opentelemetry-collector-contrib:0.111.0}"
OTLP_HTTP_PORT="${OTCA_OTLP_PORT:-4318}"
SPANS="${OTCA_SPANS:-1000}"
SERVICE_NAME="checkout"
SPAN_NAME="checkout.process"

OUTPUT_FILE="$LAB_DIR/output/traces.json"
CONFIG_FILE="$LAB_DIR/collector.yaml"
ENDPOINT="http://localhost:${OTLP_HTTP_PORT}/v1/traces"

# --------------------------------- helpers ----------------------------------
log()  { printf '\033[1;36m[otca-1.4]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[otca-1.4]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[otca-1.4] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

ENGINE=""
detect_engine() {
  if command -v docker >/dev/null 2>&1; then ENGINE="docker"
  elif command -v podman >/dev/null 2>&1; then ENGINE="podman"
  else die "Need 'docker' or 'podman' in PATH to run the Collector."; fi
}

confirm_disposable_vm() {
  # This lab is destructive-by-design (it starts containers, binds a port and
  # writes to /tmp). It must only ever run on a throwaway lab VM.
  if [ "${OTCA_LAB_CONFIRM:-}" = "yes" ] || [ "${1:-}" = "--yes" ]; then
    return 0
  fi
  cat >&2 <<EOF

  This script starts a container, binds TCP port ${OTLP_HTTP_PORT} and writes to
  ${LAB_DIR}. Run it ONLY on a disposable lab VM you can throw away.

  Re-run with:   $0 --yes
  or export:     OTCA_LAB_CONFIRM=yes

EOF
  exit 1
}

port_free_check() {
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${OTLP_HTTP_PORT} "; then
    warn "Port ${OTLP_HTTP_PORT} already has a listener; the Collector may fail to bind."
  fi
}

# ------------------------- Collector configurations -------------------------
# The HEALTHY pipeline: OTLP in -> batch -> (debug + file) out.
# The file exporter is the "analysis surface": our outcome job counts spans in it.
write_good_config() {
  cat > "$CONFIG_FILE" <<'YAML'
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch: {}

exporters:
  debug:
    verbosity: normal
  file:
    path: /lab/output/traces.json

service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, file]
YAML
}

# The BROKEN pipeline: identical, except a filter processor is spliced in front
# of batch. Its OTTL condition 'name != ""' is true for every named span, and a
# span is DROPPED when a filter condition matches. Net effect: the pipeline is
# healthy, the Collector is green, and 100% of the telemetry evaporates before
# it reaches the exporters the analysis reads. Classic "green but empty" outcome.
write_broken_config() {
  cat > "$CONFIG_FILE" <<'YAML'
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch: {}
  # --- injected fault for OTCA 1.4 ---
  filter/outcomes:
    error_mode: ignore
    traces:
      span:
        - 'name != ""'

exporters:
  debug:
    verbosity: normal
  file:
    path: /lab/output/traces.json

service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [filter/outcomes, batch]
      exporters: [debug, file]
YAML
}

# ------------------------------ container mgmt ------------------------------
container_exists() { $ENGINE ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; }

ensure_container() {
  if container_exists; then
    log "Reusing existing container '$CONTAINER'."
    return 0
  fi
  log "Creating Collector container '$CONTAINER' from $IMAGE ..."
  $ENGINE create \
    --name "$CONTAINER" \
    -p "${OTLP_HTTP_PORT}:4318" \
    -v "$LAB_DIR:/lab" \
    "$IMAGE" \
    --config /lab/collector.yaml >/dev/null
}

wait_ready() {
  local i code
  for i in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
             -X POST "$ENDPOINT" \
             -H 'Content-Type: application/json' \
             --data-binary '{"resourceSpans":[]}' 2>/dev/null || true)
    if [ "$code" = "200" ]; then return 0; fi
    sleep 0.5
  done
  warn "Collector did not become ready on ${ENDPOINT}; check '$0 logs'."
  return 1
}

# ------------------------------ synthetic load ------------------------------
# Build one OTLP/HTTP JSON request carrying N spans from service 'checkout'.
# IDs are derived from a counter (valid non-zero hex, guaranteed unique) so the
# load generator needs no external RNG and is byte-for-byte reproducible.
build_payload() {
  local n="$1" out="$2" i now start end trace span
  now=$(date +%s%N); start="$now"; end="$((now + 2000000))"
  {
    printf '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"%s"}}]},"scopeSpans":[{"scope":{"name":"otca-lab"},"spans":[' "$SERVICE_NAME"
    for ((i=0; i<n; i++)); do
      trace=$(printf '%032x' "$((0x1000 + i))")
      span=$(printf '%016x' "$((0x2000 + i))")
      [ "$i" -gt 0 ] && printf ','
      printf '{"traceId":"%s","spanId":"%s","name":"%s","kind":2,"startTimeUnixNano":"%s","endTimeUnixNano":"%s","status":{"code":1}}' \
        "$trace" "$span" "$SPAN_NAME" "$start" "$end"
    done
    printf ']}]}]}'
  } > "$out"
}

send_load() {
  local payload code
  payload="$LAB_DIR/payload.json"
  build_payload "$SPANS" "$payload"
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
           -X POST "$ENDPOINT" \
           -H 'Content-Type: application/json' \
           --data-binary @"$payload" 2>/dev/null || true)
  log "Sent ${SPANS} spans to ${ENDPOINT} -> HTTP ${code} (expected 200)."
}

# --------------------------- the "analysis" outcome -------------------------
# The outcome the student cares about: how many spans actually reached the
# analysis surface (the file exporter). Counting the "spanId" field is format
# agnostic and does not collide with "parentSpanId".
measure_outcome() {
  local c=0
  if [ -f "$OUTPUT_FILE" ]; then
    c=$( { grep -o '"spanId"' "$OUTPUT_FILE" || true; } | wc -l | tr -d ' ' )
  fi
  echo "$c"
}

# Restart the Collector clean, replay the load, flush, then measure. Because the
# config is bind-mounted, a start picks up whatever is currently in
# collector.yaml — so this is also how you verify a fix.
fresh_run() {
  $ENGINE stop "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$OUTPUT_FILE"
  $ENGINE start "$CONTAINER" >/dev/null
  wait_ready || true
  send_load
  sleep 2   # let the batch processor flush to the file exporter
}

# ---------------------------------- setup ----------------------------------
setup_break() {
  detect_engine
  port_free_check
  log "Preparing lab directory at ${LAB_DIR} ..."
  mkdir -p "$LAB_DIR/output"
  write_broken_config
  chmod -R a+rwX "$LAB_DIR"   # Collector image runs as UID 10001; needs r/w
  ensure_container
  fresh_run
  local outcome; outcome=$(measure_outcome)

  cat <<EOF

============================================================================
 OTCA 1.4 — ANALYSIS AND OUTCOMES  ::  BREAK & FIX
============================================================================

 SCENARIO
   A '${SERVICE_NAME}' service emits ${SPANS} spans named '${SPAN_NAME}'.
   Your analysis job answers one question — "how many checkout operations did
   we observe?" — by counting spans on the Collector's export surface
   (${OUTPUT_FILE}).

 THE OUTCOME YOU JUST MEASURED
   Spans emitted by the service ....... ${SPANS}
   Spans the analysis can see ......... ${outcome}     <-- the outcome is WRONG

 SYMPTOM YOU WILL SEE
   * The load generator reports HTTP 200 — the app side is fine.
   * '$0 logs' shows the Collector running, no errors, pipeline started.
   * Yet the analysis outcome reads ${outcome}, not ${SPANS}. Data is
     disappearing INSIDE a healthy-looking pipeline.

 YOUR GOAL
   Make the outcome match reality again: get the analysis to count ~${SPANS}
   spans. You may ONLY change the Collector configuration
   (${CONFIG_FILE}). Do NOT touch the service or the load generator — in a real
   incident the emitter is not yours to change.

 HOW TO WORK
   1. Inspect the pipeline:   cat ${CONFIG_FILE}
   2. Read the Collector logs: $0 logs
   3. Edit ${CONFIG_FILE} to correct the pipeline.
   4. Verify your fix:        $0 check
      (this restarts the Collector with your edited config and re-measures).

 A correct fix ends with:  "outcome: ${SPANS} / ${SPANS}  -> PASS"

 When finished:  $0 cleanup
============================================================================

EOF
}

do_check() {
  detect_engine
  container_exists || die "Lab not set up. Run: $0 --yes"
  fresh_run
  local outcome; outcome=$(measure_outcome)
  if [ "$outcome" = "$SPANS" ]; then
    log "outcome: ${outcome} / ${SPANS}  -> PASS  ✅  Analysis now matches reality."
  else
    warn "outcome: ${outcome} / ${SPANS}  -> FAIL  ❌  The pipeline is still altering the outcome."
  fi
}

do_logs() {
  detect_engine
  container_exists || die "No container '$CONTAINER'."
  $ENGINE logs --tail 40 "$CONTAINER"
}

do_solution() {
  detect_engine
  container_exists || die "Lab not set up. Run: $0 --yes"
  warn "Applying the intended fix (healthy config, no filter processor)..."
  write_good_config
  chmod -R a+rwX "$LAB_DIR"
  do_check
}

do_cleanup() {
  detect_engine
  $ENGINE rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  log "Removed container '$CONTAINER' and ${LAB_DIR}."
}

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------- main -----------------------------------
case "${1:-}" in
  ""|--yes|-y)   confirm_disposable_vm "${1:-}"; setup_break ;;
  check)         do_check ;;
  logs)          do_logs ;;
  solution)      do_solution ;;
  cleanup)       do_cleanup ;;
  help|-h|--help) usage ;;
  *)             die "Unknown command '$1'. Try: $0 help" ;;
esac

# ###########################################################################
# #                         SOLUTION  (do not peek early)                   #
# ###########################################################################
#
# ROOT CAUSE
#   The traces pipeline contains an extra stage:
#
#       processors: [filter/outcomes, batch]
#                     ^^^^^^^^^^^^^^^
#
#   whose definition is:
#
#       filter/outcomes:
#         error_mode: ignore
#         traces:
#           span:
#             - 'name != ""'
#
#   The filter processor DROPS any span for which a listed OTTL condition is
#   true. The condition 'name != ""' is true for every span that has a name —
#   i.e. all of them. So 100% of the checkout spans are discarded before they
#   ever reach the debug/file exporters, and the analysis surface stays empty.
#   The Collector is perfectly healthy; the *outcome* is destroyed by an
#   over-broad filter. This is exactly how a well-meant "drop health-check
#   noise" rule silently deletes production traffic.
#
# DIAGNOSIS PATH (what a student should actually do)
#   1. Prove the emitter is innocent:
#          ./otca_1_4_break_fix.sh logs
#      The Collector shows it started and is listening; the load generator got
#      HTTP 200. So the loss is INSIDE the Collector, not before it.
#
#   2. Read the pipeline top-to-bottom:
#          cat /tmp/otca-1.4-lab/collector.yaml
#      Walk every processor in service.pipelines.traces.processors IN ORDER.
#      Anything that can drop/sample/route data is a suspect: filter,
#      probabilistic_sampler, tail_sampling, routing, transform (with a drop).
#
#   3. Turn the Collector's own telemetry into evidence. Raise verbosity or add
#      the count connector to see per-processor throughput. Quick check: bump
#      the debug exporter and watch that 0 spans are exported while spans are
#      received — the gap sits at the filter stage.
#
#   4. Read the offending stage's intent vs. effect: 'name != ""' matches
#      everything. That is the bug — an inverted / too-broad predicate.
#
# THE FIX  (edit /tmp/otca-1.4-lab/collector.yaml)
#   Option A — remove the fault entirely (correct here, since nothing needs
#   dropping in this lab). Delete the filter/outcomes processor block AND remove
#   it from the pipeline list:
#
#       processors:
#         batch: {}
#       ...
#       service:
#         pipelines:
#           traces:
#             receivers: [otlp]
#             processors: [batch]          # <- filter/outcomes removed
#             exporters: [debug, file]
#
#   Option B — keep a filter but fix the predicate so it only drops what you
#   actually intend (e.g. real health-check spans), never real traffic:
#
#       filter/outcomes:
#         error_mode: ignore
#         traces:
#           span:
#             - 'name == "/healthz"'       # narrow, intentional
#
# VERIFY
#       ./otca_1_4_break_fix.sh check
#   Expected:
#       [otca-1.4] Sent 1000 spans to http://localhost:4318/v1/traces -> HTTP 200 (expected 200).
#       [otca-1.4] outcome: 1000 / 1000  -> PASS  ✅  Analysis now matches reality.
#   (Or run ./otca_1_4_break_fix.sh solution to apply Option A automatically.)
#
# THE OUTCOMES LESSON (why 1.4 cares)
#   * "Green pipeline" is not "correct outcome." Liveness of the Collector says
#     nothing about whether your analysis surface received the data.
#   * Every drop/sample/route stage is part of your analysis, not a detail
#     beneath it. A 10% probabilistic_sampler would have shown ~100/1000 here —
#     a *plausible* number that is silently wrong, which is more dangerous than
#     a zero. Under sampling you must interpret counts via adjusted_count, or
#     your rates and SLIs are off by the sampling ratio.
#   * Always validate outcomes end-to-end (emit N, expect N on the surface the
#     analysis reads) — the counts-must-reconcile check this lab automates.
#
# SOURCES (official)
#   - OpenTelemetry Collector — Filter processor (drop semantics, OTTL):
#     https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/filterprocessor/README.md
#   - OpenTelemetry Collector — configuration, pipelines & processor ordering:
#     https://opentelemetry.io/docs/collector/configuration/
#   - OpenTelemetry — Sampling (head/tail, adjusted_count and its effect on outcomes):
#     https://opentelemetry.io/docs/concepts/sampling/
#   - OpenTelemetry — Debug exporter (pipeline observability):
#     https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md
#   - OTLP/HTTP protocol (traces endpoint, JSON encoding):
#     https://opentelemetry.io/docs/specs/otlp/
#   - CNCF — OTCA curriculum:
#     https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
# ###########################################################################