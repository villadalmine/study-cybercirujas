#!/usr/bin/env bash
#
# ============================================================================
#  OTCA — OpenTelemetry Certified Associate
#  Domain 3: The OpenTelemetry Collector   ·   Topic 3.1: Configuration (5.2%)
#  Reference: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#
#  Break & Fix lab: "The processor that was never declared"
#
#  WHAT THIS DOES
#    Deploys a known-good OpenTelemetry Collector config, proves it validates,
#    then introduces ONE controlled fault in the `service::pipelines` wiring so
#    the Collector refuses to start. Your job is to read the startup error and
#    repair the configuration.
#
#  This teaches the single most important idea of Collector configuration:
#    the top-level maps (receivers / processors / exporters / connectors /
#    extensions) only DEFINE components; the `service::pipelines` block WIRES
#    them. A name used in a pipeline that is not defined above is a hard,
#    fail-to-start error — not a warning.
#
#  SAFETY
#    * Designed for a DISPOSABLE lab VM. It edits /etc/otelcol-contrib/config.yaml
#      and restarts a systemd unit. Do NOT run on anything you care about.
#    * The very first pre-existing config it finds is backed up once, verbatim,
#      to <config>.orig.pre-otca so you can always get back to your starting
#      point. The reproducible lab baseline is kept at <config>.baseline.
#    * Idempotent: re-running re-applies the baseline before breaking, so the
#      lab always starts from the same clean state. `--reset` and `--solution`
#      let you restore or auto-fix.
#
#  USAGE
#    sudo OTCA_LAB_CONFIRM=yes ./otca_3_1_break_fix.sh          # break it (default)
#    sudo ./otca_3_1_break_fix.sh --status                      # show current state
#    sudo ./otca_3_1_break_fix.sh --reset                       # back to clean baseline
#    sudo ./otca_3_1_break_fix.sh --solution                    # apply the fix for you
#
#  ENV OVERRIDES
#    OTCA_SERVICE   systemd unit name         (default: auto-detect)
#    OTCA_CONFIG    collector config path     (default: /etc/otelcol-contrib/config.yaml)
#    OTCA_BIN       collector binary          (default: auto-detect)
# ============================================================================

set -Eeuo pipefail

# --- pretty output ---------------------------------------------------------
c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'
c_cya=$'\033[0;36m'; c_bld=$'\033[1m';    c_rst=$'\033[0m'
info() { printf '%s[*]%s %s\n' "$c_cya" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_rst" "$*"; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
die()  { err "$*"; exit 1; }
rule() { printf '%s\n' "------------------------------------------------------------------------"; }

trap 'err "aborted at line $LINENO"' ERR

# --- config ----------------------------------------------------------------
CONFIG="${OTCA_CONFIG:-/etc/otelcol-contrib/config.yaml}"
BASELINE="${CONFIG}.baseline"
ORIG="${CONFIG}.orig.pre-otca"
ACTION="${1:-break}"

# --- privilege check -------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  die "Editing $CONFIG and restarting systemd needs root. Re-run with: sudo $0 $ACTION"
fi

# --- locate the collector binary ------------------------------------------
detect_bin() {
  if [[ -n "${OTCA_BIN:-}" ]] && command -v "$OTCA_BIN" >/dev/null 2>&1; then
    printf '%s' "$OTCA_BIN"; return 0
  fi
  local cand
  for cand in otelcol-contrib otelcol otelcol-otlp; do
    if command -v "$cand" >/dev/null 2>&1; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}
BIN="$(detect_bin)" || die "No otelcol binary on PATH. Install otelcol-contrib first: https://opentelemetry.io/docs/collector/installation/"

# --- locate the systemd unit ----------------------------------------------
detect_service() {
  if [[ -n "${OTCA_SERVICE:-}" ]]; then printf '%s' "$OTCA_SERVICE"; return 0; fi
  local u
  for u in otelcol-contrib otelcol; do
    if systemctl list-unit-files "${u}.service" >/dev/null 2>&1 \
       && systemctl cat "${u}.service" >/dev/null 2>&1; then
      printf '%s' "$u"; return 0
    fi
  done
  return 1
}
SERVICE="$(detect_service)" || die "No otelcol systemd unit found. Set OTCA_SERVICE=<unit> and retry."

# --- baseline (a valid, minimal, pedagogical config) -----------------------
write_baseline() {
  install -d -m 0755 "$(dirname "$BASELINE")"
  cat > "$BASELINE" <<'YAML'
# OTCA 3.1 lab baseline — a valid Collector config.
# receivers / processors / exporters DEFINE components.
# service::pipelines WIRES the defined components into signal paths.
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 5s

exporters:
  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [batch]
      exporters:  [debug]
  telemetry:
    logs:
      level: info
YAML
}

validate_file() {  # validate_file <path>
  "$BIN" validate --config "file:$1"
}

restart_service() {
  systemctl restart "$SERVICE" 2>/dev/null || true
  sleep 2
}

show_status() {
  rule
  info "Unit:   $SERVICE"
  info "Binary: $BIN"
  info "Config: $CONFIG"
  rule
  systemctl --no-pager --full status "$SERVICE" 2>&1 | sed -n '1,12p' || true
  rule
  info "Last 15 log lines:"
  journalctl -u "$SERVICE" --no-pager -n 15 2>&1 | sed 's/^/    /' || true
  rule
}

ensure_original_backup() {
  # Preserve the student's very first config exactly once.
  if [[ -f "$CONFIG" && ! -f "$ORIG" ]]; then
    cp -a "$CONFIG" "$ORIG"
    ok "Saved your original config → $ORIG"
  fi
}

apply_baseline() {
  ensure_original_backup
  write_baseline
  install -m 0644 "$BASELINE" "$CONFIG"
  info "Validating clean baseline..."
  if validate_file "$CONFIG"; then
    ok "Baseline is valid."
  else
    die "Baseline failed to validate — is '$BIN' the right binary/version? Aborting to avoid a confusing lab."
  fi
  restart_service
  if systemctl is-active --quiet "$SERVICE"; then
    ok "Collector is running on the clean baseline."
  else
    warn "Collector did not become active on the baseline; check: journalctl -u $SERVICE"
  fi
}

# --- the controlled fault --------------------------------------------------
# We add 'memory_limiter' to the traces pipeline's processor list WITHOUT
# declaring it under the top-level `processors:` map. This is a real-world
# slip: you copy a pipeline line from a blog post but forget to paste the
# component definition. The Collector treats it as a fatal wiring error.
introduce_break() {
  apply_baseline
  info "Introducing the controlled fault (undeclared processor in a pipeline)..."
  # Reference an undeclared processor in the traces pipeline.
  sed -i 's/^\( *processors:\) *\[batch\]/\1 [memory_limiter, batch]/' "$CONFIG"

  if ! grep -q 'memory_limiter' "$CONFIG"; then
    die "Failed to inject the fault (unexpected baseline layout)."
  fi

  info "Restarting the Collector with the broken config..."
  restart_service
}

print_briefing() {
  rule
  printf '%s OTCA 3.1 — BREAK & FIX: the processor that was never declared %s\n' "$c_bld" "$c_rst"
  rule
  cat <<EOF
${c_yel}SYMPTOM YOU WILL SEE${c_rst}
  * The '${SERVICE}' service is NOT active. \`systemctl status ${SERVICE}\`
    shows it as 'failed' or flapping in 'activating (auto-restart)'.
  * \`journalctl -u ${SERVICE} -n 20\` ends with a line resembling:

      Error: invalid configuration: service::pipelines::traces:
             references processor "memory_limiter" which is not configured

    (Exact wording varies slightly by Collector version; the shape is
     "pipeline X references <component> which is not configured".)
  * No telemetry flows: nothing listens on :4317 / :4318 because the
    process exits during config load, before any receiver starts.

${c_yel}WHY IT HAPPENS${c_rst}
  A Collector config has two layers:
    1) DEFINITION  — the top-level maps receivers:/processors:/exporters:
                     create named components with their settings.
    2) WIRING      — service::pipelines lists those NAMES to build signal
                     paths (traces/metrics/logs).
  A name used in step 2 that does not exist in step 1 is a hard startup
  error. The pipeline references 'memory_limiter', but no such processor is
  defined. Definition and wiring have drifted out of sync.

${c_grn}YOUR GOAL${c_rst}
  Make '${SERVICE}' start cleanly again:
    * \`${BIN} validate --config file:${CONFIG}\`  must report the config is valid.
    * \`systemctl is-active ${SERVICE}\`            must print 'active'.
    * The traces pipeline must still function (otlp -> ... -> debug).
  Do NOT just delete the pipeline. There are two legitimate repairs — find
  them. One of them is also a production best practice; the other is the
  quick honest revert.

${c_cya}HELPFUL COMMANDS${c_rst}
  ${BIN} validate --config file:${CONFIG}
  sudo systemctl restart ${SERVICE} && systemctl status ${SERVICE}
  journalctl -u ${SERVICE} -f
  sudoedit ${CONFIG}          # or: sudo \$EDITOR ${CONFIG}

${c_cya}LAB CONTROLS${c_rst}
  sudo $0 --status     show the current state
  sudo $0 --reset      restore the clean baseline (start over)
  sudo $0 --solution   apply the recommended fix for you (spoiler)

  Baseline kept at:        ${BASELINE}
  Your original saved at:  ${ORIG:-<none: no prior config existed>}
EOF
  rule
}

apply_solution() {
  info "Applying the recommended fix: DEFINE memory_limiter and order it FIRST."
  # Recommended production config: memory_limiter declared, and placed as the
  # first processor so it can shed load before batching buffers memory.
  cat > "$CONFIG" <<'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Declared component — the wiring below can now reference it.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  batch:
    timeout: 5s

exporters:
  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers:  [otlp]
      # memory_limiter MUST be first: shed load before batch buffers it.
      processors: [memory_limiter, batch]
      exporters:  [debug]
  telemetry:
    logs:
      level: info
YAML
  info "Validating the fixed config..."
  validate_file "$CONFIG" || die "Fixed config failed to validate."
  restart_service
  if systemctl is-active --quiet "$SERVICE"; then
    ok "Fixed. '$SERVICE' is active and the traces pipeline is wired correctly."
  else
    die "Still not active — inspect: journalctl -u $SERVICE"
  fi
  show_status
}

# --- dispatch --------------------------------------------------------------
case "$ACTION" in
  break)
    if [[ "${OTCA_LAB_CONFIRM:-}" != "yes" ]]; then
      warn "This edits $CONFIG and restarts '$SERVICE' on THIS machine."
      read -r -p "Type 'break' to confirm this is a disposable lab VM: " reply
      [[ "$reply" == "break" ]] || die "Not confirmed. Nothing changed."
    fi
    introduce_break
    print_briefing
    ;;
  --status|status)   show_status ;;
  --reset|reset)     apply_baseline; ok "Reset complete — Collector on clean baseline." ;;
  --solution|solve)  apply_solution ;;
  -h|--help|help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    die "Unknown action '$ACTION'. Try: break | --status | --reset | --solution | --help"
    ;;
esac

exit 0

# ============================================================================
#  SOLUTION — step by step (read only after you have tried it yourself)
# ============================================================================
#
#  STEP 1 — Read the failure, don't guess.
#    $ systemctl --no-pager status otelcol-contrib
#      ... Active: failed (Result: exit-code) ...
#    $ journalctl -u otelcol-contrib -n 20 --no-pager
#      otelcol-contrib[1234]: Error: invalid configuration:
#        service::pipelines::traces: references processor "memory_limiter"
#        which is not configured
#      systemd[1]: otelcol-contrib.service: Main process exited, status=1/FAILURE
#      systemd[1]: otelcol-contrib.service: Failed with result 'exit-code'.
#    The message names the exact location (service::pipelines::traces), the
#    exact component ("memory_limiter") and the exact problem ("not configured").
#    Collector errors are precise — trust them.
#
#  STEP 2 — Reproduce the error offline, without touching the service.
#    $ otelcol-contrib validate --config file:/etc/otelcol-contrib/config.yaml
#      Error: invalid configuration: service::pipelines::traces: references
#             processor "memory_limiter" which is not configured
#    `validate` loads and checks the config and exits non-zero on failure. Use
#    it as your fast feedback loop instead of restart-and-hope.
#
#  STEP 3 — Understand the two layers.
#      processors:                 <-- DEFINITION layer: creates named components
#        batch: { timeout: 5s }
#      service:
#        pipelines:
#          traces:
#            processors: [memory_limiter, batch]   <-- WIRING layer: uses names
#    'batch' exists in both layers -> fine.
#    'memory_limiter' is used in the wiring but missing from the definition
#    layer -> fatal. Every name in a pipeline must be defined above it.
#
#  STEP 4 — Choose a repair.
#
#    OPTION A (recommended, production best practice): DEFINE the component.
#    Add memory_limiter to the top-level processors map, and keep it FIRST in
#    the pipeline. memory_limiter must run before batch so it can refuse data
#    under memory pressure before the batch processor buffers it in RAM.
#
#      processors:
#        memory_limiter:
#          check_interval: 1s
#          limit_percentage: 80
#          spike_limit_percentage: 25
#        batch:
#          timeout: 5s
#      service:
#        pipelines:
#          traces:
#            receivers:  [otlp]
#            processors: [memory_limiter, batch]
#            exporters:  [debug]
#
#    OPTION B (honest quick revert): if you did not intend to add it, remove
#    the reference from the pipeline so definition and wiring match again:
#            processors: [batch]
#
#    Both make the config valid. Prefer Option A on any real Collector: the
#    memory_limiter is the guardrail that keeps the Collector from being OOM-
#    killed under load, and it only works if it is both defined AND placed
#    first in each pipeline.
#
#  STEP 5 — Validate, then apply.
#    $ otelcol-contrib validate --config file:/etc/otelcol-contrib/config.yaml
#      # (no output, exit 0 = valid)
#    $ sudo systemctl restart otelcol-contrib
#    $ systemctl is-active otelcol-contrib
#      active
#    $ ss -lntp | grep -E ':4317|:4318'
#      LISTEN 0 4096 *:4317 *:* users:(("otelcol-contrib",pid=...))
#      LISTEN 0 4096 *:4318 *:* users:(("otelcol-contrib",pid=...))
#    The receivers are listening again; the pipeline is live.
#
#  KEY TAKEAWAYS (OTCA 3.1)
#    * A Collector config defines components in receivers/processors/exporters/
#      connectors/extensions, and wires them in service::pipelines. The two
#      must stay in sync — an undefined name is a fail-to-start error, not a
#      warning.
#    * `otelcol validate --config` is your pre-flight check; never restart to
#      test syntax.
#    * A defined-but-unused component only produces a warning; a used-but-
#      undefined component is fatal. Know the difference.
#    * memory_limiter belongs first in every pipeline that has one.
#
#  SOURCES (official)
#    * OTCA Curriculum:
#      https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
#    * Collector configuration model:
#      https://opentelemetry.io/docs/collector/configuration/
#    * Collector deployment / validate command:
#      https://opentelemetry.io/docs/collector/
#    * memory_limiter processor:
#      https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
#    * batch processor:
#      https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/batchprocessor
# ============================================================================