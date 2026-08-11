#!/usr/bin/env bash
#
# ==============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Topic 2.5: SDK Pipelines   (exam weight: 6.57)
#  Break & Fix lab — controlled, safe, disposable-VM only.
#
#  Reference syllabus:
#    https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#  Reference docs used to build this lab:
#    https://opentelemetry.io/docs/languages/python/instrumentation/
#    https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/
#    https://opentelemetry.io/docs/specs/otlp/           (4317 gRPC / 4318 HTTP)
#    https://opentelemetry.io/docs/collector/configuration/
#
#  WHAT THIS TEACHES
#    The OTel SDK trace pipeline has five wired stages:
#      Resource -> TracerProvider -> SpanProcessor -> SpanExporter -> OTLP endpoint
#    A single wrong value in the *exporter* stage silently disconnects telemetry
#    while the application's business logic keeps working perfectly. This lab
#    reproduces the single most common production failure of that pipeline:
#    the OTLP/HTTP exporter is pointed at the gRPC port (4317) instead of the
#    HTTP port (4318). You must repair the pipeline so spans reach the Collector.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Safety gate — this script starts a container and writes files. Run it ONLY
#    on a throwaway lab VM. Non-destructive, but we still refuse to run blind.
# ------------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-$HOME/otca-lab-2.5}"
CONTAINER_NAME="otca-collector-2-5"
IMAGE="${OTCA_COLLECTOR_IMAGE:-otel/opentelemetry-collector:latest}"

confirm_disposable() {
  if [[ "${OTCA_ASSUME_DISPOSABLE:-}" == "yes" || "${1:-}" == "--force" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "REFUSING: no TTY and OTCA_ASSUME_DISPOSABLE!=yes." >&2
    echo "Run on a DISPOSABLE VM with: OTCA_ASSUME_DISPOSABLE=yes bash $0" >&2
    exit 1
  fi
  echo "This lab writes to $LAB_DIR and runs the container '$CONTAINER_NAME'."
  read -r -p "Confirm this is a disposable lab VM [type yes]: " ans
  [[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
}

# ------------------------------------------------------------------------------
# Container runtime detection (docker or podman).
# ------------------------------------------------------------------------------
detect_runtime() {
  if command -v docker >/dev/null 2>&1; then RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then RUNTIME=podman
  else
    echo "ERROR: need 'docker' or 'podman' installed." >&2
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Cleanup mode:  bash otca-2.5.sh cleanup
# ------------------------------------------------------------------------------
cleanup() {
  detect_runtime
  echo "==> Removing container '$CONTAINER_NAME' ..."
  $RUNTIME rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "==> Lab files left in $LAB_DIR (delete with: rm -rf '$LAB_DIR')"
  echo "==> Done."
}

if [[ "${1:-setup}" == "cleanup" ]]; then
  cleanup
  exit 0
fi

# ------------------------------------------------------------------------------
# 1. Preconditions
# ------------------------------------------------------------------------------
confirm_disposable "${1:-}"
detect_runtime

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required." >&2; exit 1; }
python3 -c 'import venv' 2>/dev/null || { echo "ERROR: python3 venv module required (dnf install python3-venv or python3)." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required." >&2; exit 1; }

for p in 4317 4318 13133; do
  if curl -sf "http://localhost:$p/" >/dev/null 2>&1; then
    echo "WARNING: something already answers on port $p — a stale lab? Run: bash $0 cleanup" >&2
  fi
done

echo "==> Provisioning lab in: $LAB_DIR"
mkdir -p "$LAB_DIR"
cd "$LAB_DIR"

# ------------------------------------------------------------------------------
# 2. The telemetry SINK: a real OpenTelemetry Collector with a 'debug' exporter.
#    Received spans are printed to the Collector log. Empty log = broken pipeline.
# ------------------------------------------------------------------------------
cat > collector-config.yaml <<'YAMLEOF'
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317      # gRPC — NOT where OTLP/HTTP clients POST
      http:
        endpoint: 0.0.0.0:4318      # HTTP/protobuf — path /v1/traces

exporters:
  debug:
    verbosity: detailed             # prints every received span to the log

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
  telemetry:
    logs:
      level: info
YAMLEOF

# ------------------------------------------------------------------------------
# 3. The APPLICATION: a correct, textbook SDK trace pipeline. We create it in the
#    GOOD state first, then deliberately break exactly one value (step 5) so the
#    fix is a clean, reversible one-liner.
# ------------------------------------------------------------------------------
cat > app.py <<'PYEOF'
import logging
import time

# The SDK trace pipeline — five stages, each depends on the previous one.
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

# Surface exporter failures on stderr instead of swallowing them silently.
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

# Stage 1 — Resource: identity stamped on every span (service.name is mandatory
#           in practice; without it the Collector groups your telemetry as
#           "unknown_service").
resource = Resource.create({"service.name": "otca-lab-2.5", "lab.topic": "2.5-sdk-pipelines"})

# Stage 2 — TracerProvider: the SDK object that mints tracers and spans.
provider = TracerProvider(resource=resource)

# Stage 3 — SpanExporter: serializes finished spans to OTLP/HTTP and ships them.
#           OTLP/HTTP MUST target the Collector's HTTP receiver (4318) at the
#           /v1/traces path. This exact line is the break target.
exporter = OTLPSpanExporter(
    endpoint="http://localhost:4318/v1/traces",
    timeout=5,  # fail fast so the symptom is visible quickly
)

# Stage 4 — SpanProcessor: buffers ended spans and hands batches to the exporter.
processor = BatchSpanProcessor(exporter)

# Stage 5 — Wire the processor into the provider, then register the provider
#           globally so instrumentation resolves to a REAL tracer (not the no-op).
provider.add_span_processor(processor)
trace.set_tracer_provider(provider)

tracer = trace.get_tracer("otca.lab.2.5")

print("app: business loop running — this keeps working even if telemetry is broken")
for i in range(30):
    with tracer.start_as_current_span("handle-request") as span:
        span.set_attribute("iteration", i)
        span.add_event("processing")
        time.sleep(0.5)
        print(f"app: processed request {i}")

# Flush the pipeline on shutdown so no batched span is dropped on exit.
provider.shutdown()
print("app: done, pipeline flushed")
PYEOF

# ------------------------------------------------------------------------------
# 4. Python environment (isolated venv — no system pollution).
# ------------------------------------------------------------------------------
if [[ ! -d .venv ]]; then
  echo "==> Creating virtualenv ..."
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
./.venv/bin/python -m pip install --quiet --upgrade pip
echo "==> Installing OpenTelemetry SDK + OTLP/HTTP exporter (this may take a minute) ..."
./.venv/bin/python -m pip install --quiet \
  opentelemetry-sdk \
  opentelemetry-exporter-otlp-proto-http

# Convenience launcher for the student.
cat > run-app.sh <<'RUNEOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
exec ./.venv/bin/python app.py
RUNEOF
chmod +x run-app.sh

# ------------------------------------------------------------------------------
# 5. Start the Collector and wait until it is healthy.
#    ':Z' relabels the bind mount for SELinux (this VM is Fedora).
# ------------------------------------------------------------------------------
echo "==> Starting Collector container '$CONTAINER_NAME' ..."
$RUNTIME rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
$RUNTIME run -d --name "$CONTAINER_NAME" \
  -p 4317:4317 -p 4318:4318 -p 13133:13133 \
  -v "$LAB_DIR/collector-config.yaml:/etc/otelcol/config.yaml:ro,Z" \
  "$IMAGE" --config /etc/otelcol/config.yaml >/dev/null

echo -n "==> Waiting for Collector health "
for _ in $(seq 1 30); do
  if curl -sf "http://localhost:13133/" >/dev/null 2>&1; then ok=1; break; fi
  echo -n "."; sleep 1
done
echo
if [[ "${ok:-}" != "1" ]]; then
  echo "ERROR: Collector did not become healthy. Inspect: $RUNTIME logs $CONTAINER_NAME" >&2
  exit 1
fi
echo "==> Collector is UP (gRPC 4317, HTTP 4318, health 13133)."

# ------------------------------------------------------------------------------
# 6. >>> INTRODUCE THE BREAK <<<
#    Point the OTLP/HTTP exporter at the gRPC port (4317) instead of HTTP (4318).
#    One character of a port number — the classic OTLP protocol/port confusion.
# ------------------------------------------------------------------------------
sed -i 's#http://localhost:4318/v1/traces#http://localhost:4317/v1/traces#' app.py
echo "==> BREAK APPLIED: exporter endpoint now targets the gRPC port 4317."

# ------------------------------------------------------------------------------
# 7. Demonstrate the symptom (short run), then hand control to the student.
# ------------------------------------------------------------------------------
before=$($RUNTIME logs "$CONTAINER_NAME" 2>&1 | grep -c "Span #" || true)
echo "==> Demonstration run (12s) — watch for export failures on stderr ..."
timeout 12 ./.venv/bin/python app.py 2>&1 | sed 's/^/    app> /' || true
after=$($RUNTIME logs "$CONTAINER_NAME" 2>&1 | grep -c "Span #" || true)

cat <<BRIEF

================================================================================
 OTCA 2.5 — SDK PIPELINES :: BREAK & FIX BRIEFING
================================================================================
 STATE: the telemetry pipeline is BROKEN. The app is healthy.

 WHAT YOU JUST SAW (the SYMPTOM):
   * The business loop printed "processed request N" for every iteration —
     the application itself is completely fine.
   * The SDK logged repeated 'Failed to export ... spans' / connection errors
     from the BatchSpanProcessor's exporter.
   * Spans received by the Collector during the run: $((after - before)) (expected: 30).

 OBSERVE IT YOURSELF:
   Terminal A (Collector sink):   $RUNTIME logs -f $CONTAINER_NAME
   Terminal B (the app):          $LAB_DIR/run-app.sh
   The Collector log shows NO "Span #..." blocks while the app runs.

 YOUR GOAL:
   Repair ONLY the SDK pipeline so that a full run of run-app.sh causes
   30 spans (service.name=otca-lab-2.5) to appear in the Collector log.
   Do NOT touch the Collector config — the receiver is correct. The defect is
   in the application's exporter stage.

 HINTS:
   * OTLP has two wire transports on two ports. Which one does OTLP/HTTP use?
   * Which pipeline stage owns the destination address?
   * grep for the port number in app.py.

 WHEN FIXED, VERIFY:
   $LAB_DIR/run-app.sh
   $RUNTIME logs $CONTAINER_NAME | grep -c "Span #"     # -> should climb to 30

 RESET / TEARDOWN:
   bash $0 cleanup
================================================================================
BRIEF

exit 0

# ==============================================================================
# ============================  SOLUTION (SPOILER)  ============================
# ==============================================================================
#
# ROOT CAUSE
#   The OTLP/HTTP SpanExporter was configured to send to the Collector's gRPC
#   listener (port 4317). OTLP defines two distinct, non-interchangeable
#   transports:
#       * OTLP/gRPC  -> port 4317, HTTP/2 (h2c) framing, no URL path
#       * OTLP/HTTP  -> port 4318, HTTP/1.1 POST to /v1/{traces,metrics,logs}
#   Posting an HTTP/1.1 request to the gRPC listener never yields a valid OTLP
#   response, so the exporter's export() fails, the BatchSpanProcessor retries
#   and eventually drops the batch, and zero spans reach the traces pipeline.
#   The application logic is untouched, which is exactly why a broken telemetry
#   pipeline is dangerous: it is silent to the app and only visible in the
#   exporter's own logs and in the (empty) backend.
#
# STEP-BY-STEP FIX
#   1. Confirm the app is healthy but telemetry is dark:
#        ./run-app.sh            # prints "processed request N", logs export errors
#        docker logs otca-collector-2-5 | grep -c "Span #"   # -> 0
#
#   2. Confirm the Collector is genuinely listening on the HTTP port:
#        ss -ltnp | grep -E '4317|4318'         # both should be LISTEN
#        curl -sS -o /dev/null -w '%{http_code}\n' \
#             -X POST http://localhost:4318/v1/traces \
#             -H 'Content-Type: application/x-protobuf' --data-binary ''
#        # 4318 answers with an HTTP status; 4317 (gRPC) will not behave as HTTP.
#
#   3. Locate the defective pipeline stage — the exporter endpoint:
#        grep -n '4317' app.py
#        # -> endpoint="http://localhost:4317/v1/traces"   (WRONG: gRPC port)
#
#   4. Repair the exporter stage to target the OTLP/HTTP receiver:
#        sed -i 's#http://localhost:4317/v1/traces#http://localhost:4318/v1/traces#' app.py
#      Equivalent idiomatic fixes (any ONE of these):
#        a) In code:      OTLPSpanExporter(endpoint="http://localhost:4318/v1/traces")
#        b) Via env var (drop the explicit endpoint arg; SDK appends /v1/traces):
#             export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
#             export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
#        c) Keep 4317 but switch to the gRPC exporter instead (the OTHER valid
#           pairing): use opentelemetry-exporter-otlp-proto-grpc's OTLPSpanExporter
#           with endpoint="http://localhost:4317" (no /v1/traces path for gRPC).
#
#   5. Re-run and verify the full pipeline end to end:
#        ./run-app.sh
#        # app stderr now shows NO "Failed to export" lines.
#        docker logs otca-collector-2-5 | grep -c "Span #"   # -> 30
#        docker logs otca-collector-2-5 | grep -m1 service.name
#        # -> service.name: Str(otca-lab-2.5)
#
# WHY THE FULL PIPELINE MATTERS (exam framing)
#   Resource -> TracerProvider -> SpanProcessor -> SpanExporter -> OTLP endpoint.
#   A break at ANY stage produces the same outward symptom (no data in the
#   backend) but a different diagnosis:
#     * Provider not set globally      -> get_tracer() returns a no-op; spans are
#                                         never even created.
#     * Processor never add_span_processor'd -> spans created but never exported.
#     * Wrong exporter/endpoint/port   -> spans exported but never delivered
#                                         (THIS lab).
#     * Sampler = ALWAYS_OFF / ParentBased dropping -> spans sampled out at source.
#   Diagnose top-down: is the tracer real? is a processor wired? does the
#   exporter log delivery errors? does the Collector receive on that transport?
#
# REFERENCES
#   OTLP transports & ports:  https://opentelemetry.io/docs/specs/otlp/
#   Python SDK pipeline:      https://opentelemetry.io/docs/languages/python/instrumentation/
#   OTLP exporter config:     https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/
#   Collector debug exporter: https://opentelemetry.io/docs/collector/configuration/
# ==============================================================================