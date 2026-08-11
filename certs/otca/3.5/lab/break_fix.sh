#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 3: The OpenTelemetry Collector
#  Topic 3.5: Transforming Data  (exam weight ~5.2%)
#
#  LAB TYPE: break & fix  (safe, self-contained, disposable-VM only)
#
#  WHAT THIS TEACHES
#    The Collector transforms telemetry with the `transform` processor, which
#    runs statements written in OTTL (OpenTelemetry Transformation Language).
#    OTTL is strongly typed and *nil-aware*: reading an attribute that is not
#    present yields nil, and most converter functions (Substring, Int,
#    ConvertCase, ...) raise a runtime error when handed nil or the wrong type.
#    What happens to the telemetry batch when a statement errors is decided by
#    the processor's `error_mode`:
#       propagate  -> return the error up the pipeline; the WHOLE batch is
#                     rejected (data loss, visible to the sender).
#       ignore     -> log the error, skip that statement, keep the data.
#       silent     -> skip that statement, do not even log.
#    Understanding this triad — plus the `where` guard clause that lets a
#    statement opt out of spans it cannot handle — is the core of this topic.
#
#  SAFETY
#    Everything lives under /tmp. The Collector binds to 127.0.0.1 only.
#    No system files, no privileged ports, no persistent services are touched.
#    Still: run this ONLY on a throwaway lab VM you are happy to reset.
#
#  SOURCES (official)
#    OTCA curriculum ....... https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#    transform processor ... https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/transformprocessor/README.md
#    OTTL language ......... https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/README.md
#    OTTL functions ........ https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/ottlfuncs/README.md
#    Collector concepts .... https://opentelemetry.io/docs/collector/
# ============================================================================

set -euo pipefail

# --- Tunables (override via environment) ------------------------------------
WORKDIR="${WORKDIR:-/tmp/otca-3.5-transforming-data}"
OTELCOL_VERSION="${OTELCOL_VERSION:-0.119.0}"   # otelcol-contrib release to fetch if not installed
OTLP_HTTP_PORT="${OTLP_HTTP_PORT:-4318}"        # localhost OTLP/HTTP receiver port
CONFIG="${WORKDIR}/config.yaml"
LOGFILE="${WORKDIR}/collector.log"
PAYLOAD="${WORKDIR}/payload.json"
BIN_DIR="${WORKDIR}/bin"

COLLECTOR_PID=""

log()  { printf '\033[1;36m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[lab]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[lab]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup_demo() {
  if [[ -n "${COLLECTOR_PID}" ]] && kill -0 "${COLLECTOR_PID}" 2>/dev/null; then
    kill "${COLLECTOR_PID}" 2>/dev/null || true
    wait "${COLLECTOR_PID}" 2>/dev/null || true
  fi
}
trap cleanup_demo EXIT

# --- 0. Consent -------------------------------------------------------------
cat <<'BANNER'
============================================================================
 OTCA 3.5 — Transforming Data :: BREAK & FIX
 This will deploy an intentionally MISCONFIGURED OpenTelemetry Collector
 under /tmp and show you the failure it produces. Disposable lab VM only.
============================================================================
BANNER
if [[ -t 0 && -z "${ASSUME_YES:-}" ]]; then
  read -r -p "Proceed on this (throwaway) machine? [y/N] " ans
  [[ "${ans}" =~ ^[Yy]$ ]] || die "Aborted by user."
fi

# --- 1. Workspace -----------------------------------------------------------
mkdir -p "${WORKDIR}" "${BIN_DIR}"
: > "${LOGFILE}"

# --- 2. Ensure the otelcol-contrib binary (transform processor lives here) --
if command -v otelcol-contrib >/dev/null 2>&1; then
  OTELCOL="$(command -v otelcol-contrib)"
elif [[ -x "${BIN_DIR}/otelcol-contrib" ]]; then
  OTELCOL="${BIN_DIR}/otelcol-contrib"
else
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m). Install otelcol-contrib manually." ;;
  esac
  TARBALL="otelcol-contrib_${OTELCOL_VERSION}_linux_${ARCH}.tar.gz"
  URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/${TARBALL}"
  log "otelcol-contrib not found — downloading v${OTELCOL_VERSION} (${ARCH})..."
  curl -fsSL -o "${WORKDIR}/${TARBALL}" "${URL}" \
    || die "Download failed. Set OTELCOL_VERSION to a release that exists, or pre-install otelcol-contrib."
  tar -xzf "${WORKDIR}/${TARBALL}" -C "${BIN_DIR}" otelcol-contrib
  OTELCOL="${BIN_DIR}/otelcol-contrib"
fi
log "Using collector: ${OTELCOL}"

# --- 3. Write the BROKEN Collector config -----------------------------------
# The transform processor tries to derive a URL segment from `url.path`.
# One of the two incoming spans has NO `url.path`, so the attribute reads as
# nil, Substring(nil, ...) raises a runtime OTTL error, and because
# `error_mode: propagate` is set, the ENTIRE batch (both spans) is rejected.
cat > "${CONFIG}" <<YAML
receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:${OTLP_HTTP_PORT}

processors:
  transform:
    error_mode: propagate          # <-- any statement error kills the whole batch
    trace_statements:
      - context: span
        statements:
          # BUG: spans without url.path make this Substring receive nil and error.
          - set(attributes["url.first_segment"], Substring(attributes["url.path"], 1, 4))

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
      processors: [transform]
      exporters: [debug]
YAML

# --- 4. A fixed OTLP/HTTP trace batch: one span WITH url.path, one WITHOUT ---
cat > "${PAYLOAD}" <<'JSON'
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "checkout" } }
        ]
      },
      "scopeSpans": [
        {
          "scope": { "name": "otca.lab" },
          "spans": [
            {
              "traceId": "5b8efff798038103d269b633813fc60c",
              "spanId": "eee19b7ec3c1b174",
              "name": "GET /api/orders",
              "kind": 2,
              "startTimeUnixNano": "1700000000000000000",
              "endTimeUnixNano":   "1700000000100000000",
              "attributes": [
                { "key": "http.request.method", "value": { "stringValue": "GET" } },
                { "key": "url.path", "value": { "stringValue": "/api/orders" } }
              ]
            },
            {
              "traceId": "5b8efff798038103d269b633813fc60c",
              "spanId": "aaa19b7ec3c1b199",
              "name": "GET /health",
              "kind": 2,
              "startTimeUnixNano": "1700000000200000000",
              "endTimeUnixNano":   "1700000000250000000",
              "attributes": [
                { "key": "http.request.method", "value": { "stringValue": "GET" } }
              ]
            }
          ]
        }
      ]
    }
  ]
}
JSON

# --- 5. Helper scripts so you can iterate while fixing ----------------------
cat > "${WORKDIR}/run.sh" <<RUN
#!/usr/bin/env bash
# Run the Collector in the FOREGROUND so you can watch OTTL errors live.
# Edit config.yaml, then Ctrl-C here and re-run to reload.
exec "${OTELCOL}" --config "${CONFIG}"
RUN
chmod +x "${WORKDIR}/run.sh"

cat > "${WORKDIR}/send.sh" <<SEND
#!/usr/bin/env bash
# Send the test trace batch to the local OTLP/HTTP receiver and print the reply.
# HTTP 200 with no error => batch accepted. A non-200 / partial_success error
# => the transform processor rejected (dropped) your data.
curl -sS -w '\n--- HTTP %{http_code} ---\n' \
  -X POST "http://127.0.0.1:${OTLP_HTTP_PORT}/v1/traces" \
  -H 'Content-Type: application/json' \
  --data-binary @"${PAYLOAD}"
SEND
chmod +x "${WORKDIR}/send.sh"

# --- 6. Reproduce the failure once, automatically ---------------------------
# free the port from any stale run
if command -v fuser >/dev/null 2>&1; then fuser -k "${OTLP_HTTP_PORT}/tcp" 2>/dev/null || true; fi

log "Starting the (broken) Collector..."
"${OTELCOL}" --config "${CONFIG}" >"${LOGFILE}" 2>&1 &
COLLECTOR_PID=$!

# wait until the OTLP/HTTP port is accepting connections
for _ in $(seq 1 30); do
  if curl -s -o /dev/null -X POST "http://127.0.0.1:${OTLP_HTTP_PORT}/v1/traces" \
        -H 'Content-Type: application/json' --data '{}' 2>/dev/null; then
    break
  fi
  kill -0 "${COLLECTOR_PID}" 2>/dev/null || die "Collector exited early — see ${LOGFILE}"
  sleep 0.5
done

log "Sending 2 spans (1 with url.path, 1 without)..."
CURL_OUT="$(curl -sS -w $'\n--- HTTP %{http_code} ---' \
  -X POST "http://127.0.0.1:${OTLP_HTTP_PORT}/v1/traces" \
  -H 'Content-Type: application/json' \
  --data-binary @"${PAYLOAD}" 2>&1 || true)"

sleep 1

echo
echo "----- Sender (curl) saw --------------------------------------------------"
echo "${CURL_OUT}"
echo "----- Collector log (transform errors) -----------------------------------"
grep -iE "error|transform|ottl|substring|refused" "${LOGFILE}" | tail -n 15 || true
echo "----- Spans that reached the exporter ------------------------------------"
if grep -q "Span #" "${LOGFILE}"; then
  grep -c "Span #" "${LOGFILE}" | sed 's/^/spans exported: /'
else
  echo "spans exported: 0   (the batch was DROPPED by the transform processor)"
fi
echo "--------------------------------------------------------------------------"

# stop the demo instance; hand the lab over to the student
cleanup_demo
COLLECTOR_PID=""

# --- 7. Mission brief -------------------------------------------------------
cat <<BRIEF

============================================================================
 YOUR MISSION
============================================================================
 SYMPTOM
   * The sender (curl / any SDK) receives an OTLP error instead of 200 OK.
   * The Collector log shows an OTTL runtime error from the transform
     processor, e.g.:
         "failed to execute statement ... Substring ... expected string
          but got nil"
   * ZERO spans reach the debug exporter — including the perfectly valid
     "GET /api/orders" span. One malformed span poisoned the WHOLE batch.

 WHY
   * `attributes["url.path"]` is nil on the "GET /health" span.
   * Substring() cannot operate on nil, so the statement errors.
   * `error_mode: propagate` turns that per-span error into a batch-wide
     rejection — silent, upstream data loss you would only catch by watching
     the receiver's refused-spans metric.

 GOAL (definition of done)
   1. Both spans are exported (debug exporter prints 2 spans).
   2. "GET /api/orders" still gets url.first_segment = "api/".
   3. "GET /health" passes through untouched (no crash, no drop).
   4. You did NOT blindly silence errors: real future bugs must still surface.

 FILES
   config : ${CONFIG}
   run    : ${WORKDIR}/run.sh    (foreground collector — watch the logs)
   send   : ${WORKDIR}/send.sh   (fire the test batch from another terminal)

 WORKFLOW
   Terminal A:  ${WORKDIR}/run.sh
   Terminal B:  ${WORKDIR}/send.sh
   Edit config.yaml, Ctrl-C Terminal A, re-run, re-send, observe.

 HINT
   OTTL statements accept a trailing `where <condition>` guard. A statement
   only runs on spans whose condition is true. Think about which spans this
   Substring is *meant* for, and read the error_mode table at the top.
============================================================================
BRIEF

exit 0

# ============================================================================
#  SOLUTION  (do not peek until you have tried the mission)
# ============================================================================
#
#  ROOT CAUSE
#    OTTL is nil-aware and strongly typed. Reading a missing attribute returns
#    nil; Substring(nil, ...) is a type error. With `error_mode: propagate`,
#    that single error is returned all the way up the traces pipeline, so the
#    receiver rejects the entire ExportTraceServiceRequest — every span in the
#    batch is dropped, not just the offending one.
#
#  PRIMARY FIX (recommended, production-grade): guard the statement
#    Restrict the transform to spans that actually carry `url.path`. The valid
#    span is still transformed; the /health span is simply skipped. error_mode
#    stays `propagate`, so genuinely unexpected errors are NOT hidden.
#
#    processors:
#      transform:
#        error_mode: propagate
#        trace_statements:
#          - context: span
#            statements:
#              - set(attributes["url.first_segment"], Substring(attributes["url.path"], 1, 4))
#                  where attributes["url.path"] != nil
#
#    Alternative guard styles that read the same:
#      # group-level condition (applies to every statement in the block):
#      - context: span
#        conditions:
#          - attributes["url.path"] != nil
#        statements:
#          - set(attributes["url.first_segment"], Substring(attributes["url.path"], 1, 4))
#
#      # provide a default first, then always-safe transform:
#      - context: span
#        statements:
#          - set(attributes["url.path"], "/") where attributes["url.path"] == nil
#          - set(attributes["url.first_segment"], Substring(attributes["url.path"], 1, 4))
#
#  INFERIOR ALTERNATIVE (know it for the exam, avoid in production)
#    processors:
#      transform:
#        error_mode: ignore     # log + skip the failing statement, keep the batch
#    This stops the data loss, but it masks the type mismatch: if a real bug
#    later breaks a statement, you lose the transformation silently on every
#    span while the pipeline reports success. `silent` is worse still (no log).
#    Reach for ignore/silent only when a statement is *expected* to miss some
#    telemetry and you have accepted that trade-off deliberately.
#
#  STEP-BY-STEP
#    1) Edit the config:
#         nano ${WORKDIR}/config.yaml        # or ${CONFIG}
#       Append  `where attributes["url.path"] != nil`  to the Substring line.
#    2) (Optional) validate before running:
#         ${OTELCOL} validate --config ${CONFIG}
#    3) Terminal A — start the collector in the foreground:
#         ${WORKDIR}/run.sh
#    4) Terminal B — resend the batch:
#         ${WORKDIR}/send.sh
#
#  EXPECTED RESULT AFTER THE FIX
#    * curl returns:  --- HTTP 200 ---   (no error/partial_success body)
#    * Terminal A shows TWO spans at the debug exporter.
#    * The "GET /api/orders" span now carries:
#         -> url.first_segment: Str(api/)
#      (Substring("/api/orders", start=1, length=4) = "api/")
#    * The "GET /health" span is exported unchanged — no url.first_segment,
#      no error, no drop.
#
#  HOW TO PROVE DATA IS NO LONGER DROPPED
#    * Count exported spans in the log:  grep -c 'Span #' ${LOGFILE}   -> 2
#    * If you enable the Collector's own internal metrics, the counter
#      `otelcol_receiver_refused_spans` stops incrementing after the fix,
#      while `otelcol_exporter_sent_spans` advances by 2 per send.
#
#  TAKEAWAYS FOR THE EXAM
#    * transform/OTTL statements fail on nil and on wrong types.
#    * `where` (per-statement) and `conditions` (per-group) gate execution.
#    * error_mode {propagate | ignore | silent} decides batch fate on error;
#      the safe default is to GUARD the statement and keep error_mode: propagate
#      so unexpected failures stay loud.
#
#  CLEANUP
#    rm -rf ${WORKDIR}
# ============================================================================