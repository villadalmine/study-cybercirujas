#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate  (exam version: unknown)
#  Domain 2 · Topic 2.1 — Data Model            (exam weight: 6.58)
#  Lab type: BREAK & FIX  (safe, self-contained, disposable lab VM only)
# ----------------------------------------------------------------------------
#  What this lab teaches
#  ---------------------
#  In OpenTelemetry every signal you emit — a Span, a Metric data point, a Log
#  record — is NOT a free-floating object. In the OTLP data model each signal
#  is attached to a *Resource*: the immutable set of attributes that identify
#  the entity producing the telemetry (the process, container, host, service).
#  The single most important Resource attribute is `service.name`, a REQUIRED
#  attribute in the OpenTelemetry resource semantic conventions. It is the key
#  that lets a backend group spans into a service, correlate traces with the
#  metrics and logs of that same service, and render a service map.
#
#  Strip `service.name` out of the Resource and the *payload still validates* —
#  the spans are perfectly well-formed, the trace_id/span_id are valid, the
#  parent/child links are intact — yet the telemetry becomes orphaned: every
#  backend files it under `unknown_service` and cross-signal correlation dies.
#  This is a classic, silent, production-grade data-model failure, and that is
#  exactly what this lab injects.
#
#  Sources (official):
#    - OTCA curriculum ....... https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#    - Signals / traces ...... https://opentelemetry.io/docs/concepts/signals/traces/
#    - Resource & service.name https://opentelemetry.io/docs/specs/semconv/resource/#service
#    - OTLP data model ....... https://opentelemetry.io/docs/specs/otlp/
#    - Transform processor ... https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Safety guard — this script deliberately BREAKS a running pipeline.
#    It only ever touches files under a dedicated lab directory and binds the
#    Collector to 127.0.0.1, but refuse to proceed without an explicit opt-in.
# ---------------------------------------------------------------------------
if [ -t 0 ]; then
  echo "This lab starts an OpenTelemetry Collector with a DELIBERATELY BROKEN"
  echo "data-model pipeline. Run it ONLY on a throwaway lab VM."
  read -r -p "Type YES to continue: " _ans
  [ "${_ans:-}" = "YES" ] || { echo "Aborted."; exit 1; }
else
  [ "${OTCA_LAB_CONFIRM:-}" = "1" ] || {
    echo "Non-interactive shell: set OTCA_LAB_CONFIRM=1 to acknowledge this is a disposable lab VM." >&2
    exit 1
  }
fi

# ---------------------------------------------------------------------------
# 1. Parameters
# ---------------------------------------------------------------------------
OTELCOL_VERSION="${OTELCOL_VERSION:-0.116.0}"
LAB_DIR="${OTCA_LAB_DIR:-$HOME/otca-lab-2.1-datamodel}"
OTLP_HTTP="127.0.0.1:4318"

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v tar  >/dev/null || { echo "tar is required."  >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Lab directory + Collector binary (installed LOCALLY, never system-wide)
# ---------------------------------------------------------------------------
mkdir -p "$LAB_DIR/bin"
cd "$LAB_DIR"

if [ ! -x "$LAB_DIR/bin/otelcol-contrib" ]; then
  case "$(uname -m)" in
    x86_64|amd64)          ARCH=amd64 ;;
    aarch64|arm64)         ARCH=arm64 ;;
    *) echo "Unsupported arch $(uname -m); install otelcol-contrib into $LAB_DIR/bin manually." >&2; exit 1 ;;
  esac
  TARBALL="otelcol-contrib_${OTELCOL_VERSION}_linux_${ARCH}.tar.gz"
  URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/${TARBALL}"
  echo ">> Downloading otelcol-contrib ${OTELCOL_VERSION} (${ARCH}) ..."
  curl -fsSL -o "$LAB_DIR/$TARBALL" "$URL" || {
    echo "Download failed. Check network, or place an otelcol-contrib binary in $LAB_DIR/bin manually." >&2
    exit 1
  }
  tar -xzf "$LAB_DIR/$TARBALL" -C "$LAB_DIR/bin" otelcol-contrib
  rm -f "$LAB_DIR/$TARBALL"
fi
chmod +x "$LAB_DIR/bin/otelcol-contrib"

# ---------------------------------------------------------------------------
# 3. Write the BROKEN Collector config.
#    The `transform/otca_databreak` processor deletes service.name from the
#    Resource of every trace, then is wired into the traces pipeline.
#    A pristine copy is kept as collector.yaml.broken so you can reset.
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/collector.yaml" <<YAML
receivers:
  otlp:
    protocols:
      http:
        endpoint: ${OTLP_HTTP}

processors:
  # >>> THE INJECTED FAULT <<<
  # Deletes the required resource attribute service.name from every trace.
  transform/otca_databreak:
    error_mode: ignore
    trace_statements:
      - context: resource
        statements:
          - delete_key(attributes, "service.name")

exporters:
  debug:
    verbosity: detailed
  file:
    path: ${LAB_DIR}/export.json

service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [transform/otca_databreak]   # <-- fault is active here
      exporters: [debug, file]
YAML
cp "$LAB_DIR/collector.yaml" "$LAB_DIR/collector.yaml.broken"

# ---------------------------------------------------------------------------
# 4. Write a valid OTLP/HTTP trace payload (root span + child span, one trace)
#    Note the Resource DOES carry service.name=checkout at the source.
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/trace.json" <<'JSON'
{
  "resourceSpans": [{
    "resource": { "attributes": [
      {"key":"service.name","value":{"stringValue":"checkout"}},
      {"key":"service.version","value":{"stringValue":"1.4.2"}},
      {"key":"deployment.environment","value":{"stringValue":"lab"}}
    ]},
    "scopeSpans": [{
      "scope": {"name":"otca.lab.manual","version":"1.0.0"},
      "spans": [
        {
          "traceId":"5b8efff798038103d269b633813fc60c",
          "spanId":"eee19b7ec3c1b174",
          "name":"GET /checkout",
          "kind":2,
          "startTimeUnixNano":"1700000000000000000",
          "endTimeUnixNano":"1700000000500000000",
          "status":{"code":1}
        },
        {
          "traceId":"5b8efff798038103d269b633813fc60c",
          "spanId":"aaaa1111bbbb2222",
          "parentSpanId":"eee19b7ec3c1b174",
          "name":"SELECT cart",
          "kind":3,
          "startTimeUnixNano":"1700000000100000000",
          "endTimeUnixNano":"1700000000400000000",
          "status":{"code":1}
        }
      ]
    }]
  }]
}
JSON

# ---------------------------------------------------------------------------
# 5. Helper scripts the student will use to investigate, iterate and verify
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/send.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
curl -s -o /dev/null -w "OTLP/HTTP status: %{http_code}\n" \
  -X POST http://127.0.0.1:4318/v1/traces \
  -H "Content-Type: application/json" \
  --data @trace.json
HELPER

cat > "$LAB_DIR/restart.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -f collector.pid ] && kill -0 "$(cat collector.pid)" 2>/dev/null; then
  kill "$(cat collector.pid)" 2>/dev/null || true
  sleep 1
fi
./bin/otelcol-contrib --config collector.yaml >collector.log 2>&1 &
echo $! > collector.pid
for _ in $(seq 1 40); do
  if (echo > /dev/tcp/127.0.0.1/4318) 2>/dev/null; then
    echo "Collector up (pid $(cat collector.pid)) — OTLP/HTTP on 127.0.0.1:4318."
    exit 0
  fi
  sleep 0.5
done
echo "Collector did not open 127.0.0.1:4318 in time — inspect collector.log" >&2
exit 1
HELPER

cat > "$LAB_DIR/stop.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -f collector.pid ] && kill -0 "$(cat collector.pid)" 2>/dev/null; then
  kill "$(cat collector.pid)" && echo "Collector stopped."
else
  echo "Collector not running."
fi
HELPER

cat > "$LAB_DIR/reset-break.sh" <<'HELPER'
#!/usr/bin/env bash
# Re-inject the fault if you want to start over.
set -euo pipefail
cd "$(dirname "$0")"
cp collector.yaml.broken collector.yaml
echo "Broken config restored. Run ./restart.sh to apply."
HELPER

cat > "$LAB_DIR/check.sh" <<'HELPER'
#!/usr/bin/env bash
# Success criterion: after the pipeline, the Resource must still carry
# service.name=checkout. This is your objective.
set -euo pipefail
cd "$(dirname "$0")"
: > export.json
./send.sh >/dev/null
sleep 2   # file exporter flush_interval; raise this if PASS/FAIL is flaky
spans=$(grep -o '"GET /checkout"' export.json 2>/dev/null | wc -l | tr -d ' ')
echo "Spans exported: ${spans}  (0 means the Collector isn't receiving — check ./restart.sh / collector.log)"
if grep -q '"checkout"' export.json 2>/dev/null; then
  echo "RESULT: PASS — service.name=checkout survived the pipeline."
  echo "The Resource identity in the OTLP data model is intact. Objective met."
  exit 0
else
  echo "RESULT: FAIL — service.name is absent from the exported telemetry."
  echo "Spans arrive with an anonymous Resource; a backend would file them under 'unknown_service'."
  exit 1
fi
HELPER

chmod +x "$LAB_DIR"/send.sh "$LAB_DIR"/restart.sh "$LAB_DIR"/stop.sh "$LAB_DIR"/reset-break.sh "$LAB_DIR"/check.sh

# ---------------------------------------------------------------------------
# 6. Start the broken pipeline and demonstrate the symptom once
# ---------------------------------------------------------------------------
echo ">> Starting the (broken) Collector ..."
"$LAB_DIR/restart.sh"

echo
echo ">> Sending a well-formed trace and checking the Resource on the way out:"
"$LAB_DIR/check.sh" || true

# ---------------------------------------------------------------------------
# 7. Brief the student
# ---------------------------------------------------------------------------
cat <<BRIEF

============================================================================
 OTCA 2.1 — DATA MODEL · BREAK & FIX
============================================================================
 A local OpenTelemetry Collector is running with a broken traces pipeline.

 THE SYMPTOM YOU WILL SEE
   - You POST a perfectly valid OTLP trace whose Resource declares
       service.name = "checkout"
   - The spans arrive (payload is 100% valid: good trace_id, span_id,
     parent/child links) — but on the exporter side the Resource has
     NO service.name at all. ./check.sh reports RESULT: FAIL.
   - In a real backend this telemetry would be dumped into "unknown_service"
     and could never be correlated with that service's metrics or logs.
     The traces are not lost — they are ORPHANED from their identity.

 WHY IT MATTERS (the data model point)
   Every signal in OTLP is (Resource + Scope + signal payload). The Resource
   is not decoration — service.name is a REQUIRED resource attribute and the
   primary correlation key across traces/metrics/logs. Losing it silently is
   a data-model failure that every free structural check would pass.

 YOUR OBJECTIVE
   Make ./check.sh print RESULT: PASS — i.e. service.name=checkout must
   survive end to end — WITHOUT editing trace.json (the source data is fine;
   the pipeline is what's wrong).

 YOUR TOOLBOX (in $LAB_DIR)
   cat collector.yaml     # inspect the pipeline — the fault lives here
   tail -f collector.log  # watch the Collector's debug exporter live
   ./restart.sh           # apply config changes (no hot reload)
   ./send.sh              # push one sample trace
   ./check.sh             # PASS/FAIL against the objective
   ./reset-break.sh       # re-inject the fault and start over
   ./stop.sh              # stop the Collector when you're done

 Hint: read the 'processors:' section and the traces pipeline. Ask yourself
 which processor is allowed to mutate the Resource, and what it is doing to it.

 The full step-by-step solution is at the bottom of this script, commented out.
 Clean up when finished:  ./stop.sh && rm -rf "$LAB_DIR"
============================================================================
BRIEF

exit 0

# ===========================================================================
#  SOLUTION — step by step  (do not read until you have tried)
# ---------------------------------------------------------------------------
#
#  1. Reproduce and confirm the symptom:
#         cd "$LAB_DIR"
#         ./check.sh
#     -> RESULT: FAIL, and "Spans exported: 2" (data arrives, identity gone).
#
#  2. Inspect the pipeline:
#         cat collector.yaml
#     Notice the processor `transform/otca_databreak`. It runs an OTTL
#     statement in the `resource` context:
#         delete_key(attributes, "service.name")
#     and it is wired into the traces pipeline's `processors:` list. That is
#     the fault: it removes the required Resource attribute from every trace.
#
#  3. Confirm from the exported data that ONLY service.name is missing while
#     the spans themselves are intact:
#         python3 -m json.tool export.json | grep -E 'service\.|GET /checkout'
#     -> you see service.version and deployment.environment, plus the spans,
#        but no service.name — proof it was stripped in the pipeline, not
#        missing at the source.
#
#  4. Fix it. Any ONE of these is correct; the cleanest is to detach the
#     processor from the pipeline (keep the source data untouched):
#
#       Option A — remove the processor from the traces pipeline:
#         sed -i 's#processors: \[transform/otca_databreak\].*#processors: []#' collector.yaml
#
#       Option B — delete only the offending OTTL statement, leaving the
#         processor in place (edit collector.yaml and remove the line):
#           - delete_key(attributes, "service.name")
#
#       Option C — delete the whole `transform/otca_databreak:` processor
#         block AND its reference in the pipeline.
#
#     (In real life you would instead FIX the transform to preserve or set
#      service.name — e.g. `set(attributes["service.name"], "checkout")
#      where attributes["service.name"] == nil` — never silently drop it.)
#
#  5. Apply the change (the Collector does not hot-reload) and re-verify:
#         ./restart.sh
#         ./check.sh
#     -> RESULT: PASS — service.name=checkout survived the pipeline.
#
#  6. Clean up:
#         ./stop.sh
#         rm -rf "$LAB_DIR"
#
#  Takeaway: a signal can be structurally flawless and still be broken at the
#  data-model level if its Resource identity is damaged. service.name is the
#  hinge of that identity — guard the Resource as carefully as the payload.
# ===========================================================================