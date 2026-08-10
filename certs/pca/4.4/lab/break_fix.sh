#!/usr/bin/env bash
#
# ==============================================================================
#  PCA (Prometheus Certified Associate) — Topic 4.4: Alerting basics
#  (when, what, and why)   |  Exam weight: 4.5
#
#  BREAK & FIX LAB — "The alert that fires but never notifies"
#
#  Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#  Docs:
#    - Alerting overview:        https://prometheus.io/docs/alerting/latest/overview/
#    - Alerting rules:           https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
#    - Alertmanager config ref:  https://prometheus.io/docs/prometheus/latest/configuration/configuration/#alertmanager_config
#    - Alertmanager routing:     https://prometheus.io/docs/alerting/latest/configuration/
#    - Notification pipeline:    https://prometheus.io/docs/alerting/latest/alertmanager/
#
#  WHAT THIS LAB TEACHES
#  --------------------------------------------------------------------------
#  Alerting in Prometheus is TWO independent stages, and knowing which one is
#  broken is the core diagnostic skill of topic 4.4:
#     1. EVALUATION  — Prometheus evaluates alerting rules and, if the `expr`
#                      holds for `for:`, moves an alert Inactive -> Pending -> Firing.
#     2. NOTIFICATION — Prometheus PUSHES firing alerts to Alertmanager, which
#                      groups, deduplicates, silences and routes them to receivers.
#  A firing alert in Prometheus is NOT the same thing as a delivered notification.
#  This lab breaks stage 2 only, so the student learns to tell them apart.
#
#  !!  SAFETY  !!
#  Run ONLY on a disposable lab VM. It creates containers named `pca-*`, a
#  container network `pca-net`, and a working directory of config files. It
#  binds host ports 9090 (Prometheus) and 9093 (Alertmanager). Nothing on the
#  host OS is modified. Tear everything down with:  ./break-fix.sh cleanup
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
LAB_DIR="${PCA_LAB_DIR:-$PWD/pca-4.4-alerting-lab}"
NET="pca-net"
PROM_CT="pca-prometheus"
AM_CT="pca-alertmanager"
PROM_IMG="${PROM_IMG:-docker.io/prom/prometheus:v2.53.1}"
AM_IMG="${AM_IMG:-docker.io/prom/alertmanager:v0.27.0}"
PROM_URL="http://localhost:9090"
AM_URL="http://localhost:9093"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Container runtime detection (podman preferred on Fedora; docker also fine)
# ------------------------------------------------------------------------------
detect_runtime() {
  if command -v podman >/dev/null 2>&1; then RT=podman
  elif command -v docker >/dev/null 2>&1; then RT=docker
  else die "Neither podman nor docker is installed. Install one to run this lab."; fi
  log "Using container runtime: $RT"
}

# ------------------------------------------------------------------------------
# Small JSON helpers (jq if present, else python3 — Fedora ships python3)
# ------------------------------------------------------------------------------
count_am_alerts() {   # number of active alerts currently held by Alertmanager
  local out; out=$(curl -s "${AM_URL}/api/v2/alerts?active=true" 2>/dev/null) || { echo 0; return; }
  if command -v jq >/dev/null 2>&1; then
    echo "$out" | jq 'length' 2>/dev/null || echo 0
  else
    echo "$out" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0
  fi
}

count_prom_firing() { # number of alerts in state=firing according to Prometheus
  local out; out=$(curl -s "${PROM_URL}/api/v1/alerts" 2>/dev/null) || { echo 0; return; }
  if command -v jq >/dev/null 2>&1; then
    echo "$out" | jq '[.data.alerts[]|select(.state=="firing")]|length' 2>/dev/null || echo 0
  else
    echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for a in d["data"]["alerts"] if a["state"]=="firing"))' 2>/dev/null || echo 0
  fi
}

notify_errors() {     # value of sum(prometheus_notifications_errors_total)
  local out; out=$(curl -s "${PROM_URL}/api/v1/query?query=sum(prometheus_notifications_errors_total)" 2>/dev/null) || { echo 0; return; }
  if command -v jq >/dev/null 2>&1; then
    echo "$out" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo 0
  else
    echo "$out" | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else 0)' 2>/dev/null || echo 0
  fi
}

wait_http() {         # wait_http <url> <label> <timeout_s>
  local url="$1" label="$2" timeout="${3:-60}" i=0
  until curl -sf "$url" >/dev/null 2>&1; do
    i=$((i+2)); [ "$i" -ge "$timeout" ] && die "$label did not become ready in ${timeout}s"
    sleep 2
  done
  ok "$label is ready"
}

# ------------------------------------------------------------------------------
# Teardown
# ------------------------------------------------------------------------------
cleanup() {
  detect_runtime
  log "Removing lab containers, network and files..."
  $RT rm -f "$PROM_CT" "$AM_CT" >/dev/null 2>&1 || true
  $RT network rm "$NET"          >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  ok "Lab environment removed."
}

# ------------------------------------------------------------------------------
# Config generation — a realistic, symptom-based alert
# ------------------------------------------------------------------------------
write_configs() {
  mkdir -p "$LAB_DIR"

  # prometheus.yml — note the CORRECT Alertmanager target on port 9093.
  cat > "$LAB_DIR/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s

# Stage 2 target: where firing alerts are PUSHED.
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['${AM_CT}:9093']

rule_files:
  - /etc/prometheus/alert.rules.yml

scrape_configs:
  - job_name: 'prometheus'          # always up (self scrape)
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'demo_app'            # nothing listens on :9999 -> up == 0
    static_configs:
      - targets: ['localhost:9999']
EOF

  # alert.rules.yml — the canonical "a thing that should be up is down" alert.
  #   WHAT:  a service instance is unreachable (up == 0)
  #   WHEN:  only after it has been down for 15s (the `for:` debounces flaps)
  #   WHY:   a down instance means users cannot reach the service -> page it
  cat > "$LAB_DIR/alert.rules.yml" <<'EOF'
groups:
  - name: demo-alerts
    rules:
      - alert: DemoAppDown
        expr: up{job="demo_app"} == 0
        for: 15s
        labels:
          severity: critical
        annotations:
          summary: "demo_app instance {{ $labels.instance }} is down"
          description: "Target {{ $labels.instance }} has failed scraping for >15s."
EOF

  # alertmanager.yml — minimal valid routing; the null receiver just holds the
  # alert so we can observe delivery via the API without an external webhook.
  cat > "$LAB_DIR/alertmanager.yml" <<'EOF'
route:
  receiver: 'null'
  group_by: ['alertname']
  group_wait: 3s
  group_interval: 10s
  repeat_interval: 1h
receivers:
  - name: 'null'
EOF
  ok "Config files written under $LAB_DIR"
}

# ------------------------------------------------------------------------------
# Bring up a HEALTHY stack, then prove the full pipeline works
# ------------------------------------------------------------------------------
bring_up() {
  $RT rm -f "$PROM_CT" "$AM_CT" >/dev/null 2>&1 || true
  $RT network rm "$NET" >/dev/null 2>&1 || true
  $RT network create "$NET" >/dev/null

  log "Starting Alertmanager..."
  $RT run -d --name "$AM_CT" --network "$NET" -p 9093:9093 \
    -v "$LAB_DIR":/etc/alertmanager:z \
    "$AM_IMG" --config.file=/etc/alertmanager/alertmanager.yml >/dev/null

  log "Starting Prometheus (with --web.enable-lifecycle so we can hot-reload)..."
  $RT run -d --name "$PROM_CT" --network "$NET" -p 9090:9090 \
    -v "$LAB_DIR":/etc/prometheus:z \
    "$PROM_IMG" \
      --config.file=/etc/prometheus/prometheus.yml \
      --web.enable-lifecycle \
      --rules.alert.resend-delay=5s >/dev/null

  wait_http "${AM_URL}/-/ready"   "Alertmanager" 60
  wait_http "${PROM_URL}/-/ready" "Prometheus"   60

  log "Waiting for DemoAppDown to fire and be delivered end-to-end..."
  local i=0
  until [ "$(count_am_alerts)" -ge 1 ]; do
    i=$((i+3)); [ "$i" -ge 90 ] && die "Baseline failed: alert never reached Alertmanager."
    sleep 3
  done
  ok "Baseline healthy: Prometheus firing=$(count_prom_firing), Alertmanager holding=$(count_am_alerts)."
}

# ------------------------------------------------------------------------------
# THE CONTROLLED BREAK — misdirect the notification path (stage 2 only)
# ------------------------------------------------------------------------------
apply_break() {
  log "Injecting fault: repointing the Alertmanager target to a dead port..."
  # Change 9093 -> 9999 in the alerting.alertmanagers block, then hot-reload.
  sed -i "s#'${AM_CT}:9093'#'${AM_CT}:9999'#" "$LAB_DIR/prometheus.yml"
  curl -sf -X POST "${PROM_URL}/-/reload" >/dev/null || die "Reload failed"

  log "Confirming the fault took effect (notification errors should climb)..."
  local i=0
  until [ "$(printf '%.0f' "$(notify_errors)")" -gt 0 ] 2>/dev/null; do
    i=$((i+3)); [ "$i" -ge 45 ] && { warn "errors_total still 0 — check manually"; break; }
    sleep 3
  done
  ok "Fault active. Rule EVALUATION still works; NOTIFICATION is broken."
}

# ------------------------------------------------------------------------------
# Student briefing
# ------------------------------------------------------------------------------
brief_student() {
  cat <<EOF

================================================================================
  PCA 4.4 BREAK & FIX  —  "It's firing on the dashboard, so why no page?"
================================================================================

The stack is up but SICK. A real alerting rule (DemoAppDown) is genuinely
firing, yet notifications are no longer arriving at Alertmanager.

WHAT YOU WILL SEE (the symptom)
  * Prometheus  ${PROM_URL}/alerts        -> DemoAppDown is RED / FIRING.
  * Alertmanager ${AM_URL}/#/alerts       -> empty (or emptying out).
  * prometheus_notifications_errors_total  -> increasing.
  Right now:  Prometheus firing = $(count_prom_firing) | Alertmanager holding = $(count_am_alerts)

YOUR GOAL (definition of done)
  Restore end-to-end delivery WITHOUT silencing, deleting or weakening the
  alert. Success = the SAME DemoAppDown alert shows up in Alertmanager again
  and notification errors stop climbing:

      curl -s '${AM_URL}/api/v2/alerts?active=true' | jq 'length'    # must be >= 1
      curl -s '${PROM_URL}/api/v1/query?query=sum(prometheus_notifications_errors_total)'

DIAGNOSTIC HINTS (the "when / what / why" toolkit)
  1. Is the alert actually firing?     ${PROM_URL}/alerts   (yes -> stage 1 is fine)
  2. Is Prometheus even trying to notify, and failing?
        ${PROM_URL}/api/v1/query?query=rate(prometheus_notifications_errors_total[1m])
  3. WHERE is it trying to notify? Inspect the live runtime config:
        curl -s ${PROM_URL}/api/v1/status/config | ${RT:+} grep -A4 alertmanagers
        (or open ${PROM_URL}/config in the UI)
  4. Read the Prometheus logs for the delivery error:
        ${RT} logs ${PROM_CT} 2>&1 | grep -i 'notify\|alertmanager' | tail
  5. Fix the config file under ${LAB_DIR}, then RELOAD (do not restart blindly):
        curl -X POST ${PROM_URL}/-/reload

When you are stuck, scroll to the SOLUTION block at the bottom of this script.
Tear the lab down when finished:   $0 cleanup
================================================================================
EOF
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------
main() {
  case "${1:-run}" in
    cleanup) cleanup; exit 0 ;;
    run)     ;;
    *)       die "Usage: $0 [run|cleanup]" ;;
  esac
  detect_runtime
  write_configs
  bring_up
  apply_break
  brief_student
}
main "$@"

# ==============================================================================
#  SOLUTION — step by step (try it yourself before reading!)
# ==============================================================================
#
#  ROOT CAUSE
#  ----------
#  Alerting is two stages. Stage 1 (rule evaluation) is healthy: DemoAppDown is
#  firing because up{job="demo_app"} == 0 has held for its `for: 15s`. Stage 2
#  (notification) is broken: Prometheus is configured to push alerts to
#  `pca-alertmanager:9999`, but Alertmanager listens on 9093. Every flush ends in
#  "connection refused", so prometheus_notifications_errors_total climbs and the
#  alert never reaches Alertmanager. Because Prometheus can no longer refresh the
#  alert, its copy in Alertmanager expires (EndsAt lapses) and disappears —
#  hence "firing on the dashboard, silent everywhere else".
#
#  STEP 1 — Confirm stage 1 is fine (rule is truly firing):
#    curl -s http://localhost:9090/api/v1/alerts \
#      | jq '.data.alerts[] | {alertname:.labels.alertname, state}'
#    # -> DemoAppDown ... "firing"
#
#  STEP 2 — Confirm stage 2 is failing, and find the bad address:
#    curl -s 'http://localhost:9090/api/v1/query?query=prometheus_notifications_errors_total' \
#      | jq '.data.result[] | {alertmanager:.metric.alertmanager, errors:.value[1]}'
#    # -> alertmanager "http://pca-alertmanager:9999/api/v2/alerts", errors "N" (rising)
#    #    The :9999 is the smoking gun. Cross-check the live config:
#    curl -s http://localhost:9090/api/v1/status/config | grep -A5 alertmanagers
#
#  STEP 3 — Fix the target port in the config file:
#    sed -i "s#'pca-alertmanager:9999'#'pca-alertmanager:9093'#" \
#      "$PWD/pca-4.4-alerting-lab/prometheus.yml"
#    #  (or edit prometheus.yml by hand: alerting.alertmanagers.static_configs.targets
#    #   must be ['pca-alertmanager:9093'])
#
#  STEP 4 — Hot-reload Prometheus (no restart needed thanks to --web.enable-lifecycle):
#    curl -X POST http://localhost:9090/-/reload
#
#  STEP 5 — Verify end-to-end delivery is restored (within ~15s):
#    curl -s 'http://localhost:9093/api/v2/alerts?active=true' | jq 'length'   # -> >= 1
#    curl -s 'http://localhost:9090/api/v1/query?query=rate(prometheus_notifications_errors_total[1m])' \
#      | jq '.data.result[0].value[1]'                                          # -> "0"
#    # Open http://localhost:9093/#/alerts : DemoAppDown is present again.
#
#  KEY TAKEAWAYS (exam-relevant)
#  -----------------------------
#   * A firing alert in Prometheus != a delivered notification. Always locate the
#     failure in the EVALUATION vs NOTIFICATION stage before "fixing" anything.
#   * prometheus_notifications_errors_total / _sent_total and the Prometheus logs
#     are the fastest way to prove the push side is broken.
#   * `for:` controls WHEN an alert fires (debounces transient conditions);
#     up == 0 is a canonical example of WHAT/WHY to alert on (symptom of impact).
#   * Prefer `curl -X POST /-/reload` over restarts: it preserves alert state and
#     `for:` timers instead of resetting them.
# ==============================================================================