#!/usr/bin/env bash
#
# ============================================================================
#  OTCA 2.6 — Context Propagation  ::  BREAK & FIX lab
# ============================================================================
#
#  Certification : OpenTelemetry Certified Associate (OTCA)
#  Topic         : 2.6 Context Propagation  (exam weight ~6.57%)
#  Source        : https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#  Concept refs  : https://opentelemetry.io/docs/concepts/context-propagation/
#                  https://www.w3.org/TR/trace-context/
#                  https://opentelemetry.io/docs/languages/python/instrumentation/#change-the-default-propagation-format
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It builds a minimal two-service distributed system on the loopback
#  interface:  a "frontend" that starts a span and makes an HTTP call, and a
#  "backend" that should CONTINUE that same trace. Distributed tracing only
#  works when the trace context (the W3C `traceparent` header, or a b3 header)
#  is INJECTED by the caller and EXTRACTED by the callee using the SAME
#  propagator format. This lab deliberately MISCONFIGURES the propagators so
#  the two services speak different wire formats, and the trace breaks apart.
#
#  SAFETY / DISPOSABILITY
#  ----------------------
#   * Runs entirely as your normal user. No root, no sudo, no package manager.
#   * Everything lives inside one throwaway directory (default:
#     $HOME/otca-2.6-context-propagation-lab). Delete it and the lab is gone.
#   * Listens ONLY on 127.0.0.1:8088. Nothing is exposed to the network.
#   * The only background process is a Python HTTP server this script starts
#     and kills by its own PID. Intended for a disposable lab VM.
#
#  REQUIREMENTS: python3 (>=3.8) with venv + pip, and outbound access to PyPI
#  for the one-time dependency install.
# ============================================================================

set -euo pipefail

LAB_DIR="${OTCA_LAB_DIR:-$HOME/otca-2.6-context-propagation-lab}"
PORT="${OTCA_LAB_PORT:-8088}"

echo "=============================================================="
echo " OTCA 2.6 Context Propagation — building lab in: $LAB_DIR"
echo "=============================================================="

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found."; exit 1; }

mkdir -p "$LAB_DIR"
cd "$LAB_DIR"

# ---------------------------------------------------------------------------
# 1) Isolated virtualenv with the OpenTelemetry API/SDK and the b3 propagator.
#    (Reused if it already exists — the setup is idempotent.)
# ---------------------------------------------------------------------------
if [ ! -x "./venv/bin/python" ]; then
  echo "[setup] creating virtualenv..."
  python3 -m venv ./venv
fi
echo "[setup] installing/upgrading OpenTelemetry packages (one time)..."
./venv/bin/python -m pip install --quiet --upgrade pip
./venv/bin/python -m pip install --quiet \
    "opentelemetry-api" \
    "opentelemetry-sdk" \
    "opentelemetry-propagator-b3"

# ---------------------------------------------------------------------------
# 2) The "backend" service. It EXTRACTS context from the inbound HTTP headers
#    using whatever propagator OTEL_PROPAGATORS names, then opens a server span
#    as a CHILD of the extracted remote context. If extraction finds nothing,
#    the SDK silently starts a brand-new ROOT trace — that is the failure mode.
# ---------------------------------------------------------------------------
cat > backend.py <<'PYEOF'
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from opentelemetry import trace
from opentelemetry.propagate import extract
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

PORT = int(os.environ.get("OTCA_LAB_PORT", "8088"))

provider = TracerProvider(resource=Resource.create({"service.name": "backend"}))
provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("backend")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # The inbound headers ARE the carrier. Extract using the configured
        # propagator (env OTEL_PROPAGATORS). Header names are lowercased so the
        # default getter finds 'traceparent' / 'b3' regardless of client casing.
        carrier = {k.lower(): v for k, v in self.headers.items()}
        parent_ctx = extract(carrier)

        with tracer.start_as_current_span("backend-handle", context=parent_ctx) as span:
            sc = span.get_span_context()
            has_parent = span.parent is not None and span.parent.is_valid
            print(
                "[backend]  propagator={:<18} saw_traceparent={} saw_b3={} "
                "trace_id={} span_id={} parent={}".format(
                    os.environ.get("OTEL_PROPAGATORS", "(default)"),
                    "traceparent" in carrier,
                    "b3" in carrier,
                    format(sc.trace_id, "032x"),
                    format(sc.span_id, "016x"),
                    "yes" if has_parent else "NONE (started a NEW root trace!)",
                ),
                flush=True,
            )
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):  # silence default access logging
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF

# ---------------------------------------------------------------------------
# 3) The "frontend" service. It starts a client span and INJECTS the current
#    context into the outbound HTTP headers using its OWN OTEL_PROPAGATORS,
#    then calls the backend.
# ---------------------------------------------------------------------------
cat > frontend.py <<'PYEOF'
import http.client
import os
from opentelemetry import trace
from opentelemetry.propagate import inject
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

PORT = int(os.environ.get("OTCA_LAB_PORT", "8088"))

provider = TracerProvider(resource=Resource.create({"service.name": "frontend"}))
provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("frontend")

with tracer.start_as_current_span("frontend-call") as span:
    sc = span.get_span_context()
    print(
        "[frontend] propagator={:<18} trace_id={} span_id={}".format(
            os.environ.get("OTEL_PROPAGATORS", "(default)"),
            format(sc.trace_id, "032x"),
            format(sc.span_id, "016x"),
        ),
        flush=True,
    )

    headers = {}
    inject(headers)  # serialize the active context onto the wire
    print("[frontend] injected wire headers: {}".format(headers), flush=True)

    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    conn.request("GET", "/", headers=headers)
    conn.getresponse().read()
    conn.close()
PYEOF

# ---------------------------------------------------------------------------
# 4) The runner. Sources propagators.env, launches each service with ITS OWN
#    propagator, then compares the two trace_ids and prints a PASS/FAIL verdict.
#    This is the file the student re-runs after attempting the fix.
# ---------------------------------------------------------------------------
cat > run-trace.sh <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
PORT="${OTCA_LAB_PORT:-8088}"
export OTCA_LAB_PORT="$PORT"

# Load the two propagator settings the student controls.
# shellcheck disable=SC1091
source ./propagators.env

echo "== frontend propagator : $FRONTEND_PROPAGATORS"
echo "== backend  propagator : $BACKEND_PROPAGATORS"
echo

: > backend.out
OTEL_PROPAGATORS="$BACKEND_PROPAGATORS" ./venv/bin/python backend.py > backend.out 2>&1 &
BPID=$!
trap 'kill "$BPID" 2>/dev/null || true' EXIT

# Wait until the backend is actually listening on the loopback port.
for _ in $(seq 1 40); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.2
done

FRONT_OUT="$(OTEL_PROPAGATORS="$FRONTEND_PROPAGATORS" ./venv/bin/python frontend.py 2>&1)"
sleep 0.4
kill "$BPID" 2>/dev/null || true
wait "$BPID" 2>/dev/null || true
trap - EXIT

echo "$FRONT_OUT"
echo "---- backend span ----"
grep '^\[backend\]' backend.out || echo "(backend produced no span line)"
echo

FTID="$(printf '%s\n' "$FRONT_OUT" | sed -n 's/.*\[frontend\].*trace_id=\([0-9a-f]\{32\}\).*/\1/p' | head -1)"
BTID="$(sed -n 's/.*\[backend\].*trace_id=\([0-9a-f]\{32\}\).*/\1/p' backend.out | head -1)"

echo "frontend trace_id : ${FTID:-<none>}"
echo "backend  trace_id : ${BTID:-<none>}"
echo
if [ -n "$FTID" ] && [ "$FTID" = "$BTID" ]; then
  echo "VERDICT: PASS  ->  one continuous distributed trace; context propagated."
  exit 0
else
  echo "VERDICT: FAIL  ->  broken trace: the backend did NOT continue the frontend's trace."
  exit 1
fi
SHEOF
chmod +x run-trace.sh

# ---------------------------------------------------------------------------
# 5) THE BREAK.  We write mismatched propagators: the frontend speaks 'b3'
#    (single b3 header) while the backend only understands 'tracecontext'
#    (the W3C `traceparent` header). Each side is individually valid; together
#    they cannot exchange context.
# ---------------------------------------------------------------------------
cat > propagators.env <<'ENVEOF'
# Wire format each service uses to inject/extract trace context.
# Valid values include: tracecontext , baggage , b3 , b3multi (comma-separated).
#
# >>> THE BUG IS HERE: these two do not match. <<<
FRONTEND_PROPAGATORS="b3"
BACKEND_PROPAGATORS="tracecontext"
ENVEOF

echo
echo "[run] executing the BROKEN scenario once..."
echo "--------------------------------------------------------------"
./run-trace.sh || true
echo "--------------------------------------------------------------"

cat <<EOF

==============================================================================
 STUDENT BRIEFING — OTCA 2.6 Context Propagation
==============================================================================

SYMPTOM YOU JUST SAW
  * The frontend printed a span with one trace_id.
  * The backend printed a span with a DIFFERENT trace_id and
    parent = "NONE (started a NEW root trace!)".
  * Notice the backend line: "saw_traceparent=False saw_b3=True".
  * The verdict was: FAIL.

  In a real backend (Jaeger, Tempo, an OTLP Collector) this shows up as TWO
  disconnected traces instead of one end-to-end trace. The waterfall is
  chopped: the frontend call and the backend work never join up, and you lose
  all cross-service latency attribution. This is the single most common
  "why is my distributed trace broken?" incident in production.

ROOT CAUSE (diagnose it yourself)
  The frontend INJECTS a 'b3' header. The backend is configured to EXTRACT
  only 'tracecontext' (the W3C 'traceparent' header), which it never finds, so
  it falls back to starting a fresh root trace. Injection format != extraction
  format => context is dropped at the service boundary.

YOUR GOAL (definition of done)
  Make both services agree on ONE propagation format so that:
    - frontend trace_id  ==  backend trace_id
    - the backend span reports  parent = yes
    - ./run-trace.sh prints  VERDICT: PASS

  Files you may edit live in:  $LAB_DIR
  The only file you need to change is:  propagators.env
  Re-run your fix at any time with:     $LAB_DIR/run-trace.sh

  (Do NOT peek below until you have tried it.)
==============================================================================
EOF

# ##########################################################################
# ##                                                                      ##
# ##   SOLUTION — step by step  (read only after attempting the fix)      ##
# ##                                                                      ##
# ##########################################################################
#
# WHY IT BROKE
#   Context propagation has two halves that MUST use the same wire format:
#     - inject()  on the caller  -> writes trace context into outbound headers
#     - extract() on the callee  -> reads trace context from inbound headers
#   OTEL_PROPAGATORS selects that format per process. The frontend used "b3"
#   (header:  b3: <traceid>-<spanid>-<sampled>) while the backend used
#   "tracecontext" (header:  traceparent: 00-<traceid>-<spanid>-<flags>).
#   The backend searched for `traceparent`, found none, and per spec began a
#   NEW root trace with a NEW trace_id. Nothing errored — that is what makes it
#   insidious: both services "work", the trace just silently splits in two.
#
# THE FIX — make both ends speak the same format.
#
#   Step 1. Open the propagator config:
#             $ cd "$HOME/otca-2.6-context-propagation-lab"
#             $ nano propagators.env
#
#   Step 2. Set BOTH services to the same value. The recommended, standards-
#           based choice is the W3C Trace Context format plus Baggage:
#
#             FRONTEND_PROPAGATORS="tracecontext,baggage"
#             BACKEND_PROPAGATORS="tracecontext,baggage"
#
#           (Any single shared value works — e.g. both "b3", or both "b3multi".
#            What matters is that caller and callee MATCH. When integrating with
#            an existing b3-based system, standardize on b3 on both ends
#            instead. Include "baggage" so user-defined baggage also crosses the
#            boundary along with the span context.)
#
#   Step 3. Re-run the lab:
#             $ ./run-trace.sh
#
#   Step 4. Confirm success. You should now see:
#             [frontend] ... trace_id=<X> ...
#             [frontend] injected wire headers: {'traceparent': '00-<X>-...-01'}
#             [backend]  ... saw_traceparent=True ... trace_id=<X> ... parent=yes
#             frontend trace_id : <X>
#             backend  trace_id : <X>          <-- identical
#             VERDICT: PASS
#
#   The trace_ids now match and the backend span is a child of the frontend
#   span: a single, continuous distributed trace. Context propagated correctly.
#
# ONE-LINER (non-interactive) equivalent of the fix:
#   cd "$HOME/otca-2.6-context-propagation-lab" \
#     && printf '%s\n' \
#          'FRONTEND_PROPAGATORS="tracecontext,baggage"' \
#          'BACKEND_PROPAGATORS="tracecontext,baggage"'  > propagators.env \
#     && ./run-trace.sh
#
# PRODUCTION TAKEAWAYS
#   * Standardize ONE propagator format org-wide. Mixed b3/tracecontext fleets
#     are the classic cause of split traces; pin OTEL_PROPAGATORS everywhere.
#   * The OTel default is already "tracecontext,baggage" — most breakages come
#     from someone OVERRIDING it on one service (or a legacy b3-only service /
#     proxy) and forgetting the other side.
#   * A "new root trace" with no parent, appearing exactly at a service hop, is
#     the fingerprint of a propagation mismatch — check inject vs extract format
#     first, before suspecting sampling or the exporter.
#   * Gateways/proxies/message brokers must forward the trace headers verbatim;
#     stripping `traceparent`/`tracestate`/`baggage` breaks propagation just as
#     surely as a format mismatch.
#
# CLEANUP (disposable lab):
#   rm -rf "$HOME/otca-2.6-context-propagation-lab"
# ##########################################################################