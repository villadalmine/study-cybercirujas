#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 1: OpenTelemetry Fundamentals
#  Topic 1.2: Semantic Conventions   (exam weight: 4.5)
#
#  BREAK & FIX LAB  —  run ONLY on a disposable lab VM you can throw away.
# ============================================================================
#
#  WHY THIS TOPIC MATTERS
#  ----------------------
#  Semantic Conventions are the shared vocabulary of OpenTelemetry: a registry
#  of well-known attribute keys, their types, and their stability level. They
#  are what turns raw telemetry into *portable* telemetry. If two services use
#  `service.name` the same way, ANY conformant backend (Jaeger, Tempo,
#  Prometheus, a vendor) can correlate, group and alert on them without custom
#  glue. If one service invents `service_name` or `svc`, that telemetry becomes
#  an island.
#
#  Rules the conventions encode (the ones this lab exercises):
#    * Attribute keys are lowercase, dot-namespaced, and DO NOT use underscores
#      to separate namespaces:  service.name  service.version  service.namespace
#      service.instance.id  — NOT service_name, NOT ServiceName, NOT svc.name.
#    * `service.name` is a REQUIRED Resource attribute. When it is absent an SDK
#      falls back to `unknown_service` (or `unknown_service:<process>`), which is
#      exactly the "my traces disappeared" symptom SREs hit in the field.
#    * Resource attributes (the emitting entity: service.*, host.*, k8s.*,
#      deployment.environment.name) live on the Resource, not on individual
#      spans/metrics/logs. Span attributes (http.*, url.*, db.*, rpc.*) describe
#      the operation.
#    * Stability matters. HTTP conventions were stabilized in v1.23.0: the modern
#      stable keys are `http.request.method`, `http.response.status_code`,
#      `url.path`, `url.full`, `server.address`, `server.port`. The pre-stable
#      keys `http.method`, `http.status_code`, `http.url`, `net.peer.name` are
#      DEPRECATED — dashboards and processors keyed on the stable names go blank
#      when a hop silently rewrites them back to the old ones.
#
#  Sources (official):
#    * OTel Semantic Conventions:      https://opentelemetry.io/docs/specs/semconv/
#    * General / Resource attributes:  https://opentelemetry.io/docs/specs/semconv/resource/
#    * HTTP conventions (stable):      https://opentelemetry.io/docs/specs/semconv/http/http-spans/
#    * Attribute naming rules:         https://opentelemetry.io/docs/specs/semconv/general/naming/
#    * Semconv registry:               https://opentelemetry.io/docs/specs/semconv/registry/attributes/
#    * OTCA curriculum:                https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#
#  WHAT THIS LAB DOES
#  ------------------
#  It stands up a single-node OpenTelemetry Collector, sends it a perfectly
#  spec-compliant OTLP trace, and inserts a pipeline that SILENTLY rewrites two
#  attribute keys to convention-violating names. Your job is to diagnose the
#  drift from the exported telemetry and repair the pipeline — without touching
#  the sender. The commented, step-by-step solution is at the very bottom.
#
#  Usage:
#    ./break-fix-semconv.sh up        # set up lab, break it, print the symptom
#    ./break-fix-semconv.sh symptom   # re-print the current exported telemetry
#    ./break-fix-semconv.sh restart   # restart the collector after editing config
#    ./break-fix-semconv.sh send      # re-send the sample trace
#    ./break-fix-semconv.sh retry     # restart + send + verify (edit-test loop)
#    ./break-fix-semconv.sh verify    # grade your fix
#    ./break-fix-semconv.sh logs      # tail the collector (debug exporter) output
#    ./break-fix-semconv.sh solution  # reveal the walkthrough
#    ./break-fix-semconv.sh down      # stop collector and delete the lab dir
# ============================================================================

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Configuration (override via env if you like)
# ----------------------------------------------------------------------------
OTELCOL_VERSION="${OTELCOL_VERSION:-0.116.0}"
LAB_DIR="${LAB_DIR:-$HOME/otca-1.2-semconv-lab}"
BIN_DIR="$LAB_DIR/bin"
CONFIG="$LAB_DIR/collector.yaml"
LOGFILE="$LAB_DIR/collector.log"
PIDFILE="$LAB_DIR/collector.pid"
EXPORT_FILE="$LAB_DIR/export.json"
PAYLOAD="$LAB_DIR/trace.json"
OTLP_HTTP="127.0.0.1:4318"          # bound to loopback ONLY — nothing leaves the VM
OTLP_GRPC="127.0.0.1:4317"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
log()  { printf '%s[lab]%s %s\n'  "$CYN" "$RST" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Safety guard — refuse to run anywhere that is not a throwaway lab
# ----------------------------------------------------------------------------
guard() {
  # 1) Everything this script writes lives under $LAB_DIR. It never edits a
  #    system file, never uses sudo, and binds the Collector to 127.0.0.1 only.
  # 2) Require an explicit acknowledgement that this host is disposable.
  if [[ "${I_HAVE_A_DISPOSABLE_VM:-}" != "1" ]]; then
    cat >&2 <<EOF
${RED}${BLD}Refusing to run without an explicit disposable-VM acknowledgement.${RST}

This lab starts a network listener and downloads a binary. Run it ONLY on a
lab VM whose state you do not care about. When you are on such a VM:

    I_HAVE_A_DISPOSABLE_VM=1 $0 up

EOF
    exit 1
  fi
  # 3) Cheap production tripwires — bail out on anything that smells like a real host.
  local host; host="$(hostname 2>/dev/null || echo unknown)"
  case "$host" in
    *prod*|*prd*|*live*) die "Hostname '$host' looks like production. Aborting." ;;
  esac
  if command -v kubectl >/dev/null 2>&1 && kubectl config current-context >/dev/null 2>&1; then
    warn "An active kubectl context is present on this host. Make sure this is a lab VM."
  fi
  # 4) Ports must be free.
  for hp in "${OTLP_HTTP##*:}" "${OTLP_GRPC##*:}"; do
    if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :$hp )" 2>/dev/null | grep -q ":$hp"; then
      die "Port $hp is already in use. Stop the other process or change the endpoint."
    fi
  done
}

need() { command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' not found in PATH."; }

# ----------------------------------------------------------------------------
# Install the OpenTelemetry Collector Contrib (pinned) if it is not already present
# ----------------------------------------------------------------------------
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

ensure_collector() {
  if command -v otelcol-contrib >/dev/null 2>&1; then
    OTELCOL="$(command -v otelcol-contrib)"; ok "Using otelcol-contrib from PATH: $OTELCOL"; return
  fi
  OTELCOL="$BIN_DIR/otelcol-contrib"
  if [[ -x "$OTELCOL" ]]; then ok "Using cached collector: $OTELCOL"; return; fi

  need curl; need tar
  local arch tarball url
  arch="$(detect_arch)"
  tarball="otelcol-contrib_${OTELCOL_VERSION}_linux_${arch}.tar.gz"
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/${tarball}"
  mkdir -p "$BIN_DIR"
  log "Downloading OpenTelemetry Collector Contrib v${OTELCOL_VERSION} (${arch}) ..."
  # In a hardened lab you would also fetch the matching *_checksums.txt and verify
  # the sha256 before extracting; left as an exercise so the lab keeps working offline-ish.
  curl -fsSL "$url" -o "$LAB_DIR/$tarball" || die "Download failed: $url"
  tar -xzf "$LAB_DIR/$tarball" -C "$BIN_DIR" otelcol-contrib \
    || die "Extraction failed (unexpected archive layout for this version)."
  chmod +x "$OTELCOL"
  ok "Collector ready: $OTELCOL"
}

# ----------------------------------------------------------------------------
# The BREAK — a Collector pipeline that rewrites two keys to non-conforming names
# ----------------------------------------------------------------------------
write_broken_config() {
  cat > "$CONFIG" <<EOF
# OTCA 1.2 Semantic Conventions — INTENTIONALLY BROKEN COLLECTOR CONFIG
# Your task is to repair this pipeline. See the sender: it is already compliant.
receivers:
  otlp:
    protocols:
      http:
        endpoint: ${OTLP_HTTP}
      grpc:
        endpoint: ${OTLP_GRPC}

processors:
  # ===================== INTENTIONAL BREAK #1 (Resource) =====================
  # Renames the REQUIRED resource attribute service.name -> service_name.
  # Underscores are not how semconv namespaces are separated, so downstream the
  # service becomes 'unknown_service'.
  resource:
    attributes:
      - key: service_name
        from_attribute: service.name
        action: upsert
      - key: service.name
        action: delete
  # ===================== INTENTIONAL BREAK #2 (Span/OTTL) =====================
  # Rewrites the STABLE http.request.method (semconv v1.23) back to the
  # DEPRECATED http.method, blanking any dashboard keyed on the stable name.
  transform/http:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - set(attributes["http.method"], attributes["http.request.method"]) where attributes["http.request.method"] != nil
          - delete_key(attributes, "http.request.method")

exporters:
  debug:
    verbosity: detailed
  file:
    path: ${EXPORT_FILE}

service:
  telemetry:
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [resource, transform/http]     # <-- the corrupting pipeline
      exporters: [debug, file]
EOF
  ok "Wrote broken collector config: $CONFIG"
}

# A perfectly spec-compliant OTLP/JSON trace. DO NOT change this file when fixing.
write_payload() {
  cat > "$PAYLOAD" <<'EOF'
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name",                  "value": {"stringValue": "checkout"}},
        {"key": "service.version",               "value": {"stringValue": "1.4.2"}},
        {"key": "service.namespace",             "value": {"stringValue": "shop"}},
        {"key": "deployment.environment.name",   "value": {"stringValue": "lab"}}
      ]
    },
    "scopeSpans": [{
      "scope": {"name": "manual-lab", "version": "1.0.0"},
      "spans": [{
        "traceId": "5b8efff798038103d269b633813fc60c",
        "spanId": "eee19b7ec3c1b174",
        "name": "GET /checkout",
        "kind": 2,
        "startTimeUnixNano": "1700000000000000000",
        "endTimeUnixNano":   "1700000000500000000",
        "attributes": [
          {"key": "http.request.method",       "value": {"stringValue": "GET"}},
          {"key": "url.path",                  "value": {"stringValue": "/checkout"}},
          {"key": "http.response.status_code", "value": {"intValue": "200"}},
          {"key": "server.address",            "value": {"stringValue": "shop.internal"}},
          {"key": "server.port",               "value": {"intValue": "8443"}}
        ]
      }]
    }]
  }]
}
EOF
}

# ----------------------------------------------------------------------------
# Collector lifecycle
# ----------------------------------------------------------------------------
start_collector() {
  stop_collector >/dev/null 2>&1 || true
  : > "$EXPORT_FILE"
  nohup "$OTELCOL" --config "$CONFIG" >"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    warn "Collector failed to start. Last lines of $LOGFILE:"; tail -n 20 "$LOGFILE" >&2
    die "Collector is not running (usually a YAML/OTTL syntax error in your edit)."
  fi
  ok "Collector running (pid $(cat "$PIDFILE")), OTLP/HTTP on http://${OTLP_HTTP}"
}

stop_collector() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    sleep 1
    kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true
    log "Collector stopped."
  fi
  rm -f "$PIDFILE"
}

restart_collector() { ensure_collector; start_collector; }

send_sample() {
  need curl
  : > "$EXPORT_FILE"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
          -X POST "http://${OTLP_HTTP}/v1/traces" \
          -H 'Content-Type: application/json' \
          --data @"$PAYLOAD")" || die "curl failed to reach the collector."
  [[ "$code" == "200" ]] || die "OTLP/HTTP export returned HTTP $code (expected 200)."
  sleep 1
  ok "Sample trace accepted by the collector (HTTP 200)."
}

# ----------------------------------------------------------------------------
# Symptom + challenge
# ----------------------------------------------------------------------------
show_symptom() {
  [[ -s "$EXPORT_FILE" ]] || { warn "No telemetry exported yet. Run: $0 send"; return; }
  local line; line="$(tail -n 1 "$EXPORT_FILE")"
  echo
  echo "${BLD}What the backend actually received (last exported batch):${RST}"
  if command -v python3 >/dev/null 2>&1; then
    echo "$line" | python3 -c 'import sys,json;print(json.dumps(json.loads(sys.stdin.read()),indent=2))' \
      | grep -E '"key"|"stringValue"|"intValue"' | sed 's/^/    /'
  else
    echo "    $line"
  fi
  echo
  echo "${BLD}Semantic-convention drift detected:${RST}"
  grep -Eq '"key" *: *"service_name"'        <<<"$line" && echo "  ${RED}✗${RST} resource carries 'service_name' (underscore — NOT a semconv key)"
  grep -Eq '"key" *: *"service\.name"'        <<<"$line" || echo "  ${RED}✗${RST} required resource attribute 'service.name' is MISSING → backend shows 'unknown_service'"
  grep -Eq '"key" *: *"http\.method"'         <<<"$line" && echo "  ${RED}✗${RST} span uses deprecated 'http.method' instead of stable 'http.request.method'"
}

challenge() {
  cat <<EOF

${BLD}${YEL}================= YOUR MISSION (OTCA 1.2) =================${RST}
SYMPTOM
  The 'checkout' service is emitting correct OTLP, yet in the backend every
  trace lands under the service ${BLD}unknown_service${RST} instead of 'checkout',
  and the HTTP request-rate dashboard (built on ${BLD}http.request.method${RST})
  is empty. A hop in the Collector is silently rewriting attribute keys to
  names that violate the OpenTelemetry Semantic Conventions.

WHAT YOU MUST ACHIEVE
  Make the EXPORTED telemetry conform to the semantic conventions again:
    1. The Resource must carry ${BLD}service.name = checkout${RST} (dot notation;
       it is a REQUIRED resource attribute) and must NOT carry 'service_name'.
    2. HTTP spans must use the stable ${BLD}http.request.method${RST}
       (semconv v1.23) and must NOT carry the deprecated 'http.method'.
  Constraint: fix the COLLECTOR PIPELINE only — do not touch the sender
  ($PAYLOAD).

EDIT–TEST LOOP
    \$EDITOR $CONFIG
    $0 retry        # restart + re-send + grade
  When 'verify' prints PASS, you have restored convention compliance.
  Stuck? Reveal the walkthrough:  $0 solution
${YEL}==========================================================${RST}
EOF
}

verify() {
  [[ -s "$EXPORT_FILE" ]] || { warn "Nothing exported yet. Run: $0 send"; return 1; }
  local line pass=1; line="$(tail -n 1 "$EXPORT_FILE")"
  echo "${BLD}Grading the last exported batch against OTel Semantic Conventions...${RST}"

  if grep -Eq '"key" *: *"service\.name"' <<<"$line"; then ok "service.name present (required resource attribute)"
  else printf '%s✗%s service.name is missing\n' "$RED" "$RST"; pass=0; fi

  if grep -Eq '"key" *: *"service_name"' <<<"$line"; then printf '%s✗%s stray non-conforming key 'service_name' still present\n' "$RED" "$RST"; pass=0
  else ok "no underscore variant 'service_name'"; fi

  if grep -Eq '"key" *: *"http\.request\.method"' <<<"$line"; then ok "http.request.method present (stable HTTP convention)"
  else printf '%s✗%s stable http.request.method is missing\n' "$RED" "$RST"; pass=0; fi

  if grep -Eq '"key" *: *"http\.method"' <<<"$line"; then printf '%s✗%s deprecated http.method still present\n' "$RED" "$RST"; pass=0
  else ok "no deprecated 'http.method'"; fi

  echo
  if [[ $pass -eq 1 ]]; then
    printf '%s%s  PASS — the pipeline emits semantic-convention-compliant telemetry.  %s\n' "$GRN" "$BLD" "$RST"
  else
    printf '%s%s  FAIL — keep fixing. Try:  %s solution %s\n' "$RED" "$BLD" "$0" "$RST"; return 1
  fi
}

logs()    { tail -n 40 -f "$LOGFILE"; }
cleanup() { stop_collector; rm -rf "$LAB_DIR"; ok "Lab directory removed: $LAB_DIR"; }

solution() { sed -n '/^# ==== SOLUTION/,/^# ==== END SOLUTION/p' "$0"; }

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------
cmd="${1:-up}"
case "$cmd" in
  up)
    guard
    mkdir -p "$LAB_DIR" "$BIN_DIR"
    ensure_collector
    write_broken_config
    write_payload
    start_collector
    send_sample
    show_symptom
    challenge
    ;;
  symptom)  show_symptom ;;
  restart)  restart_collector ;;
  send)     send_sample ;;
  retry)    restart_collector; send_sample; verify || true ;;
  verify)   verify ;;
  logs)     logs ;;
  solution) solution ;;
  down)     cleanup ;;
  *) die "Unknown command '$cmd'. Try: up | symptom | restart | send | retry | verify | logs | solution | down" ;;
esac

# ============================================================================
# ==== SOLUTION (OTCA 1.2 Semantic Conventions) — step by step ================
# ============================================================================
#
# STEP 0 — Confirm the failure and read the evidence.
#     I_HAVE_A_DISPOSABLE_VM=1 ./break-fix-semconv.sh verify   # -> FAIL
#     tail -n1 ~/otca-1.2-semconv-lab/export.json | python3 -m json.tool
#   You will see the Resource holds "service_name" (no "service.name") and the
#   span holds "http.method" (no "http.request.method"). The sender (trace.json)
#   is compliant, so the corruption is INSIDE the Collector pipeline.
#
# STEP 1 — Name the violations (this is the exam knowledge):
#     * service.name is a REQUIRED resource attribute. Keys are lowercase and
#       dot-namespaced; "service_name" (underscore) is NOT the same key, so any
#       conformant backend reports the service as "unknown_service".
#     * http.request.method is the STABLE HTTP span attribute (semconv v1.23).
#       "http.method" is the DEPRECATED pre-stable spelling; dashboards keyed on
#       the stable name go blank.
#
# STEP 2 — Locate the offenders in collector.yaml: the `resource` processor and
#   the `transform/http` processor, both wired into the traces pipeline.
#
# STEP 3 — Primary fix: stop mangling. Remove both processors from the pipeline
#   so compliant telemetry passes through unchanged. Edit collector.yaml:
#
#       service:
#         pipelines:
#           traces:
#             receivers: [otlp]
#             processors: []          # <-- was [resource, transform/http]
#             exporters: [debug, file]
#
#   (You may also delete the two processor blocks entirely; an empty list is fine.)
#
# STEP 4 — Apply and grade:
#     I_HAVE_A_DISPOSABLE_VM=1 ./break-fix-semconv.sh retry     # -> PASS
#
# STEP 5 — Production remediation pattern (the deeper lesson). In the real world
#   you often CANNOT fix the sender (a legacy service, a third-party agent) and
#   the Collector's job is to NORMALIZE non-compliant data TO the conventions.
#   Same processors, inverted mappings — keep them in the pipeline like this:
#
#       processors:
#         resource:
#           attributes:
#             - key: service.name
#               from_attribute: service_name     # promote the wrong key...
#               action: upsert
#             - key: service_name
#               action: delete                   # ...and drop the non-conforming one
#         transform/http:
#           error_mode: ignore
#           trace_statements:
#             - context: span
#               statements:
#                 - set(attributes["http.request.method"], attributes["http.method"]) where attributes["http.method"] != nil
#                 - delete_key(attributes, "http.method")
#
#   This also PASSES verify, and it is what you would ship: the collector becomes
#   the enforcement point that guarantees every downstream consumer sees
#   convention-compliant keys, regardless of what the producers emit.
#
# STEP 6 — Tear down the disposable lab:
#     ./break-fix-semconv.sh down
#
# KEY TAKEAWAYS
#   * service.name is required; missing it => unknown_service. Keys are
#     lowercase + dot-namespaced, never underscore-separated between namespaces.
#   * Prefer STABLE conventions (http.request.method, http.response.status_code,
#     url.path, server.address) over deprecated pre-1.23 ones.
#   * A Collector processor is a two-edged tool: it can silently BREAK semantic
#     conventions or, deliberately, ENFORCE them. Audit exported telemetry, not
#     just what the SDK emits.
#   Refs: https://opentelemetry.io/docs/specs/semconv/
#         https://opentelemetry.io/docs/specs/semconv/general/naming/
#         https://opentelemetry.io/docs/specs/semconv/http/http-spans/
# ==== END SOLUTION ==========================================================