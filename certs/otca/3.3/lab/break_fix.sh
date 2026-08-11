#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 3: The OpenTelemetry Collector  |  Topic 3.3: Scaling  (weight 5.2)
#  Break & Fix lab — Collector horizontal/vertical scaling under load
# ----------------------------------------------------------------------------
#  Reference syllabus:
#    https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#  Primary sources used to build this lab:
#    https://opentelemetry.io/docs/collector/scaling/
#    https://opentelemetry.io/docs/collector/deployment/gateway/
#    https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
# ----------------------------------------------------------------------------
#  WHAT THIS SCRIPT DOES
#    It stands up a miniature two-tier Collector topology with Docker:
#        telemetrygen  --OTLP-->  GATEWAY (otca-gateway)  --OTLP-->  BACKEND (otca-backend)
#    The GATEWAY is deployed with a DELIBERATELY undersized export pipeline
#    (no batch processor, sending_queue of depth 1, a single consumer). Under a
#    realistic ingest burst the gateway cannot drain fast enough, its in-memory
#    export queue overflows, and telemetry is SILENTLY DROPPED at enqueue time.
#    This is the canonical "the single Collector instance does not scale" symptom.
#
#  SAFETY
#    * Runs ONLY containers on a dedicated Docker network + localhost ports.
#    * Touches NO host config, NO host services, writes only under the LAB_DIR.
#    * Container memory/CPU are capped. Intended for a DISPOSABLE lab VM.
#    * Tear everything down with:   ./this_script.sh clean
#
#  >>> DO NOT RUN ON A PRODUCTION OR SHARED HOST. Use a throwaway VM. <<<
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment before running if you wish)
# ---------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-${HOME}/otca-3.3-scaling-lab}"
NET="${NET:-otca-lab-net}"
COL_IMAGE="${COL_IMAGE:-otel/opentelemetry-collector-contrib:0.104.0}"
GEN_IMAGE="${GEN_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest}"
GATEWAY="otca-gateway"
BACKEND="otca-backend"
GW_METRICS_PORT="${GW_METRICS_PORT:-8888}"   # host port -> gateway :8888
BE_METRICS_PORT="${BE_METRICS_PORT:-8889}"   # host port -> backend :8888
GEN_TRACES="${GEN_TRACES:-200000}"           # number of traces to fire
GEN_WORKERS="${GEN_WORKERS:-20}"             # concurrent generators

# ---------------------------------------------------------------------------
# Pretty printing helpers
# ---------------------------------------------------------------------------
c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
section() { printf '\n%s==== %s ====%s\n' "$c_b" "$1" "$c_0"; }
info()    { printf '%s[*]%s %s\n' "$c_b" "$c_0" "$1"; }
ok()      { printf '%s[+]%s %s\n' "$c_g" "$c_0" "$1"; }
warn()    { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$1"; }
die()     { printf '%s[x]%s %s\n' "$c_r" "$c_0" "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Teardown / cleanup
# ---------------------------------------------------------------------------
cleanup() {
  info "Removing lab containers and network (safe to run repeatedly)..."
  docker rm -f "$GATEWAY" "$BACKEND" >/dev/null 2>&1 || true
  docker network rm "$NET"           >/dev/null 2>&1 || true
  ok "Lab resources removed. LAB_DIR left in place: ${LAB_DIR}"
}

if [[ "${1:-}" == "clean" ]]; then
  cleanup
  exit 0
fi

# ---------------------------------------------------------------------------
# Prometheus metric scraper:  get_metric <host_port> <metric_name>
# Sums every series whose line begins with the metric name.
# ---------------------------------------------------------------------------
get_metric() {
  local port="$1" name="$2"
  awk -v m="$name" 'index($0,m)==1 {s+=$NF} END{printf "%d", s+0}' \
    < <(curl -s "http://localhost:${port}/metrics" 2>/dev/null) 2>/dev/null || echo 0
}

wait_ready() {
  local port="$1" name="$2" tries=30
  info "Waiting for ${name} internal telemetry on :${port} ..."
  while (( tries-- > 0 )); do
    if curl -s "http://localhost:${port}/metrics" 2>/dev/null | grep -q 'otelcol_'; then
      ok "${name} is up."
      return 0
    fi
    sleep 1
  done
  die "${name} did not become ready. Check: docker logs ${name}"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
section "Preflight"
command -v docker >/dev/null 2>&1 || die "docker is required but not found."
command -v curl   >/dev/null 2>&1 || die "curl is required but not found."
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon (permissions? daemon down?)."
ok "docker and curl available."

mkdir -p "$LAB_DIR"
info "Lab working directory: ${LAB_DIR}"

# Idempotent reset of any previous run
docker rm -f "$GATEWAY" "$BACKEND" >/dev/null 2>&1 || true
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
ok "Docker network ready: ${NET}"

# ---------------------------------------------------------------------------
# Write the collector configurations
# ---------------------------------------------------------------------------
section "Rendering Collector configurations"

# BACKEND: a healthy sink representing your observability backend.
cat > "${LAB_DIR}/backend.yaml" <<'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

exporters:
  debug:
    verbosity: basic

service:
  telemetry:
    metrics:
      address: 0.0.0.0:8888
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
EOF

# GATEWAY (BROKEN): the tier under test. The export path is intentionally
# undersized for the incoming rate. Note what is *missing* and what is *tiny*:
#   - NO batch processor      -> every received request is exported one by one
#   - queue_size: 1           -> the in-memory export buffer holds a single item
#   - num_consumers: 1        -> a single goroutine drains that buffer
#   - retry_on_failure: off   -> overflow is dropped immediately, not retried
cat > "${LAB_DIR}/gateway-broken.yaml" <<'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

processors: {}

exporters:
  otlp:
    endpoint: otca-backend:4317
    tls:
      insecure: true
    sending_queue:
      enabled: true
      queue_size: 1
      num_consumers: 1
    retry_on_failure:
      enabled: false

service:
  telemetry:
    metrics:
      address: 0.0.0.0:8888
  pipelines:
    traces:
      receivers: [otlp]
      processors: []
      exporters: [otlp]
EOF
ok "Wrote backend.yaml and gateway-broken.yaml"

# ---------------------------------------------------------------------------
# Start the topology
# ---------------------------------------------------------------------------
section "Starting the two-tier Collector topology"

docker run -d --name "$BACKEND" --network "$NET" \
  --memory=256m --cpus=1 \
  -p "${BE_METRICS_PORT}:8888" \
  -v "${LAB_DIR}/backend.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  "$COL_IMAGE" >/dev/null
ok "Started BACKEND sink (${BACKEND})."

docker run -d --name "$GATEWAY" --network "$NET" \
  --memory=256m --cpus=1 \
  -p "${GW_METRICS_PORT}:8888" -p "4317:4317" \
  -v "${LAB_DIR}/gateway-broken.yaml:/etc/otelcol-contrib/config.yaml:ro" \
  "$COL_IMAGE" >/dev/null
ok "Started GATEWAY under test (${GATEWAY}) with the BROKEN scaling config."

wait_ready "$BE_METRICS_PORT" "$BACKEND"
wait_ready "$GW_METRICS_PORT" "$GATEWAY"

# Show that the queue really is depth 1
QCAP="$(get_metric "$GW_METRICS_PORT" otelcol_exporter_queue_capacity)"
info "Gateway export queue capacity reported by the Collector: ${QCAP:-unknown}"

# ---------------------------------------------------------------------------
# Apply the load — this is the "break"
# ---------------------------------------------------------------------------
section "Generating an ingest burst with telemetrygen"
info "Firing ${GEN_TRACES} traces with ${GEN_WORKERS} workers at maximum rate..."
docker run --rm --network "$NET" "$GEN_IMAGE" traces \
  --otlp-endpoint "${GATEWAY}:4317" \
  --otlp-insecure \
  --traces "$GEN_TRACES" \
  --workers "$GEN_WORKERS" >/dev/null 2>&1 || warn "telemetrygen exited non-zero (expected under overload)."

sleep 3  # let the internal counters settle

SENT="$(get_metric "$GW_METRICS_PORT"    otelcol_exporter_sent_spans)"
FAILED="$(get_metric "$GW_METRICS_PORT"  otelcol_exporter_enqueue_failed_spans)"
SENDFAIL="$(get_metric "$GW_METRICS_PORT" otelcol_exporter_send_failed_spans)"

# ---------------------------------------------------------------------------
# Report the symptom + the student's objective
# ---------------------------------------------------------------------------
section "OBSERVED SYMPTOM"
cat <<EOF
The gateway's own telemetry (curl http://localhost:${GW_METRICS_PORT}/metrics) reports:

    otelcol_exporter_sent_spans           = ${SENT}
    otelcol_exporter_enqueue_failed_spans = ${c_r}${FAILED}${c_0}   <-- SILENTLY DROPPED
    otelcol_exporter_send_failed_spans    = ${SENDFAIL}

Even though the BACKEND is perfectly healthy, a large number of spans never
reached it. They were discarded at the gateway's export queue: the buffer is one
item deep, a single consumer drains it, and there is no batching, so at burst
rate the queue is full almost continuously and new items are refused at enqueue.
In production this is invisible to producers (OTLP still returns success for the
accepted requests) — you only find it in the Collector's own metrics, exactly
where a student is expected to look on the exam.

Inspect it yourself:
    docker logs ${GATEWAY} | tail -n 30
    curl -s http://localhost:${GW_METRICS_PORT}/metrics | grep -E 'enqueue_failed|queue_(size|capacity)|sent_spans'
    curl -s http://localhost:${BE_METRICS_PORT}/metrics | grep -E 'receiver_accepted_spans'   # backend under-received

$(printf '%sYOUR OBJECTIVE%s' "$c_y" "$c_0")
--------------
Re-engineer the GATEWAY so the SAME burst is delivered with ZERO loss.
Edit ${LAB_DIR}/gateway-broken.yaml (or write a new file), then:

    docker rm -f ${GATEWAY}
    docker run -d --name ${GATEWAY} --network ${NET} --memory=256m --cpus=1 \\
      -p ${GW_METRICS_PORT}:8888 -p 4317:4317 \\
      -v ${LAB_DIR}/<your-fixed-config>.yaml:/etc/otelcol-contrib/config.yaml:ro \\
      ${COL_IMAGE}

Then replay the load and re-check the counters:

    docker run --rm --network ${NET} ${GEN_IMAGE} traces \\
      --otlp-endpoint ${GATEWAY}:4317 --otlp-insecure --traces ${GEN_TRACES} --workers ${GEN_WORKERS}

$(printf '%sSUCCESS CRITERIA%s' "$c_g" "$c_0")
----------------
    otelcol_exporter_enqueue_failed_spans == 0
    otelcol_exporter_sent_spans           == total spans produced (traces x spans-per-trace)

Think about BOTH axes the syllabus calls out:
  * VERTICAL  — batching + a right-sized, multi-consumer sending_queue on one instance.
  * HORIZONTAL— multiple gateway replicas; and WHY, once tail-sampling or
                spanmetrics enter the picture, you cannot round-robin — every span
                of a trace must land on the SAME replica.

Tear down when finished:
    $0 clean
EOF

echo
ok "Lab is running and left in the BROKEN state for you to fix. Good luck."

# ###########################################################################
# #                                                                         #
# #                    S O L U T I O N   (step by step)                     #
# #                                                                         #
# #   Everything below is COMMENTED OUT. Read it only after attempting the  #
# #   fix yourself. Nothing here executes.                                  #
# #                                                                         #
# ###########################################################################
#
# ---------------------------------------------------------------------------
# ROOT CAUSE
# ---------------------------------------------------------------------------
# The gateway pipeline was throughput-starved on the export side:
#   1. No `batch` processor  -> the exporter issued one gRPC export per received
#      request. Per-request overhead (serialization + a network round trip)
#      dominated, so effective throughput was a tiny fraction of ingest.
#   2. sending_queue.queue_size: 1 -> the async export buffer could hold a single
#      item. While the one consumer was blocked on an in-flight export, every
#      newly received request found the queue full.
#   3. num_consumers: 1 -> only one goroutine drained the queue, so there was no
#      concurrency to hide export latency.
#   A full non-blocking memory queue drops on enqueue and increments
#   otelcol_exporter_enqueue_failed_spans. That is the data loss you measured.
#
# ---------------------------------------------------------------------------
# FIX A — VERTICAL SCALING (tune the single instance). File: gateway-fixed.yaml
# ---------------------------------------------------------------------------
# receivers:
#   otlp:
#     protocols:
#       grpc:
#         endpoint: 0.0.0.0:4317
#
# processors:
#   # memory_limiter FIRST: a backpressure/safety valve so scaling up the queue
#   # cannot OOM the instance. It refuses data before memory runs out.
#   memory_limiter:
#     check_interval: 1s
#     limit_percentage: 75
#     spike_limit_percentage: 15
#   # batch: the single most important throughput lever. Coalesce spans into
#   # fewer, larger export requests -> far less per-request overhead.
#   batch:
#     send_batch_size: 8192
#     send_batch_max_size: 10000
#     timeout: 5s
#
# exporters:
#   otlp:
#     endpoint: otca-backend:4317
#     tls:
#       insecure: true
#     sending_queue:
#       enabled: true
#       queue_size: 5000      # deep buffer to absorb bursts
#       num_consumers: 10     # concurrency to hide export latency
#     retry_on_failure:
#       enabled: true         # ride out transient backend hiccups instead of dropping
#       initial_interval: 5s
#       max_interval: 30s
#       max_elapsed_time: 300s
#
# service:
#   telemetry:
#     metrics:
#       address: 0.0.0.0:8888
#   pipelines:
#     traces:
#       receivers: [otlp]
#       processors: [memory_limiter, batch]   # order matters: limiter, then batch
#       exporters: [otlp]
#
# Apply and verify:
#   docker rm -f otca-gateway
#   docker run -d --name otca-gateway --network otca-lab-net --memory=256m --cpus=1 \
#     -p 8888:8888 -p 4317:4317 \
#     -v "$HOME/otca-3.3-scaling-lab/gateway-fixed.yaml:/etc/otelcol-contrib/config.yaml:ro" \
#     otel/opentelemetry-collector-contrib:0.104.0
#   docker run --rm --network otca-lab-net \
#     ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest traces \
#     --otlp-endpoint otca-gateway:4317 --otlp-insecure --traces 200000 --workers 20
#   curl -s http://localhost:8888/metrics | grep -E 'enqueue_failed|sent_spans'
#   # Expect: otelcol_exporter_enqueue_failed_spans 0   and sent_spans == produced.
#
# ---------------------------------------------------------------------------
# FIX B — HORIZONTAL SCALING (add replicas). Why round-robin is NOT enough.
# ---------------------------------------------------------------------------
# One tuned instance has a ceiling. Beyond it you run N gateway replicas. But a
# naive L4 round-robin load balancer sprays the spans of a single trace across
# different replicas. That is fine for a stateless pass-through, and FATAL for
# any trace-aware processor:
#   * tail_sampling needs to see ALL spans of a trace to decide keep/drop.
#   * spanmetrics / servicegraph aggregate per-trace relationships.
# If spans of one trace hit different replicas, each replica sees a partial
# trace and makes a wrong, independent decision.
#
# The OpenTelemetry answer is a TWO-LAYER gateway: a thin front layer whose only
# job is to route by trace ID using the loadbalancing exporter, in front of a
# back layer that does the trace-aware work.
#
#   FRONT LAYER (routing) — loadbalancing.yaml:
#   -------------------------------------------
#   receivers:
#     otlp:
#       protocols:
#         grpc:
#           endpoint: 0.0.0.0:4317
#   exporters:
#     loadbalancing:
#       routing_key: traceID          # ALL spans of a trace -> the same backend
#       protocol:
#         otlp:
#           tls:
#             insecure: true
#       resolver:
#         dns:                        # replicas discovered behind a headless service
#           hostname: otel-sampling-gateway.observability.svc.cluster.local
#           port: 4317
#   service:
#     pipelines:
#       traces:
#         receivers: [otlp]
#         exporters: [loadbalancing]
#
#   BACK LAYER (trace-aware) — sampling-gateway.yaml:
#   -------------------------------------------------
#   receivers:
#     otlp:
#       protocols:
#         grpc:
#           endpoint: 0.0.0.0:4317
#   processors:
#     memory_limiter: { check_interval: 1s, limit_percentage: 75, spike_limit_percentage: 15 }
#     tail_sampling:
#       decision_wait: 10s
#       policies:
#         - name: errors,      type: status_code, status_code: { status_codes: [ERROR] }
#         - name: slow,        type: latency,     latency: { threshold_ms: 500 }
#         - name: baseline,    type: probabilistic, probabilistic: { sampling_percentage: 10 }
#     batch: { send_batch_size: 8192, timeout: 5s }
#   exporters:
#     otlp: { endpoint: backend:4317, tls: { insecure: true } }
#   service:
#     pipelines:
#       traces:
#         receivers: [otlp]
#         processors: [memory_limiter, tail_sampling, batch]
#         exporters: [otlp]
#
# Operational notes for scaling the Collector (exam-relevant):
#   * Agent (per-node/sidecar) vs Gateway (standalone service) are the two
#     deployment patterns; you scale the GATEWAY, keep agents thin.
#   * Split pipelines by SIGNAL and by cost — a heavy tail_sampling/spanmetrics
#     tier scales independently from a cheap logs pass-through.
#   * Drive autoscaling on the RIGHT signal: exporter queue length / CPU, not
#     raw request count. In Kubernetes an HPA on otelcol_exporter_queue_size or
#     CPU is typical; keep the loadbalancing resolver (dns/k8s) in sync with the
#     replica set so routing stays consistent as pods come and go.
#   * loadbalancing changes membership when replicas scale, which reshuffles some
#     trace-to-replica assignments; size decision_wait so in-flight traces are
#     tolerant of that churn.
#
# ---------------------------------------------------------------------------
# OFFICIAL SOURCES
# ---------------------------------------------------------------------------
#   Scaling the Collector .... https://opentelemetry.io/docs/collector/scaling/
#   Gateway deployment ....... https://opentelemetry.io/docs/collector/deployment/gateway/
#   Agent deployment ......... https://opentelemetry.io/docs/collector/deployment/agent/
#   exporterhelper (queue/retry)
#     https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
#   batch processor .......... https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/batchprocessor
#   memory_limiter processor . https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
#   loadbalancing exporter ... https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
#   tail sampling processor .. https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
#   Sampling concepts ........ https://opentelemetry.io/docs/concepts/sampling/
# ###########################################################################