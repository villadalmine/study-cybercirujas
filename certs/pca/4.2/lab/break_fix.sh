#!/usr/bin/env bash
#
# PCA — Prometheus Certified Associate
# Domain 4: PromQL / Alerting — Topic 4.2: Configuring Alerting rules (weight 4.5)
# Reference: CNCF PCA Curriculum
#   https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
# Prometheus alerting rules docs:
#   https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
#   https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
#
# ---------------------------------------------------------------------------
# BREAK & FIX LAB — "The alert that took down every alert in the file"
# ---------------------------------------------------------------------------
# This script builds a fully isolated Prometheus instance inside a disposable
# directory, on a non-standard port (127.0.0.1:9091), proves the alerting rules
# load and evaluate correctly, and THEN introduces one controlled fault into the
# rule file. Your job is to diagnose and repair it.
#
# SAFETY MODEL (why this is safe to run on a lab VM):
#   * It never touches a system-wide Prometheus, systemd unit, or port 9090.
#   * Everything lives under $PCA_LAB_DIR (default: /tmp/pca-4.2-lab).
#   * It binds only to loopback (127.0.0.1) on $PORT (default: 9091).
#   * It downloads a pinned Prometheus release ONLY if none is on PATH.
#   * `--cleanup` removes the whole lab directory and stops the lab instance.
#
# It is still a "break" tool: run it ONLY on a throwaway VM.
# ---------------------------------------------------------------------------

set -euo pipefail

# --------------------------- configuration ---------------------------------
PCA_LAB_DIR="${PCA_LAB_DIR:-/tmp/pca-4.2-lab}"
PORT="${PORT:-9091}"
PROM_VERSION="${PROM_VERSION:-2.53.2}"
RULES_FILE="$PCA_LAB_DIR/rules/lab_alerts.yml"
CONFIG_FILE="$PCA_LAB_DIR/prometheus.yml"
LOG_FILE="$PCA_LAB_DIR/prometheus.log"
PID_FILE="$PCA_LAB_DIR/prometheus.pid"
DATA_DIR="$PCA_LAB_DIR/data"
BIN_DIR="$PCA_LAB_DIR/bin"

PROM_BIN=""
PROMTOOL_BIN=""

# --------------------------- pretty output ---------------------------------
if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; C=$'\033[0;36m'; Z=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; Z=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C" "$Z" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$Y" "$Z" "$*"; }
err()  { printf '%s[X]%s %s\n'  "$R" "$Z" "$*" >&2; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

on_err() { err "Unexpected failure at line $1. Inspect $LOG_FILE (if present)."; }
trap 'on_err $LINENO' ERR

# --------------------------- cleanup mode ----------------------------------
cleanup_lab() {
  if [ -f "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      info "Stopping lab Prometheus (PID $pid)..."
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
  fi
  info "Removing $PCA_LAB_DIR ..."
  rm -rf "$PCA_LAB_DIR"
  ok "Lab removed. Nothing left behind."
}

# --------------------------- guard -----------------------------------------
confirm_lab() {
  if [ "${PCA_LAB_CONFIRM:-}" = "yes" ]; then return 0; fi
  if [ -t 0 ]; then
    say "${B}This lab will build and then BREAK a local Prometheus under:${Z}"
    say "    $PCA_LAB_DIR  (loopback port $PORT)"
    printf 'Proceed on this DISPOSABLE VM? [y/N] '
    read -r ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) err "Aborted."; exit 1 ;; esac
  else
    err "Non-interactive shell. Re-run with PCA_LAB_CONFIRM=yes to confirm this is a lab VM."
    exit 1
  fi
}

# --------------------------- binary resolution -----------------------------
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) echo "unsupported" ;;
  esac
}

resolve_binaries() {
  if command -v prometheus >/dev/null 2>&1 && command -v promtool >/dev/null 2>&1; then
    PROM_BIN="$(command -v prometheus)"
    PROMTOOL_BIN="$(command -v promtool)"
    ok "Using system prometheus/promtool from PATH."
    return 0
  fi
  if [ -x "$BIN_DIR/prometheus" ] && [ -x "$BIN_DIR/promtool" ]; then
    PROM_BIN="$BIN_DIR/prometheus"; PROMTOOL_BIN="$BIN_DIR/promtool"
    ok "Using previously downloaded prometheus/promtool from $BIN_DIR."
    return 0
  fi

  local arch; arch="$(detect_arch)"
  if [ "$arch" = "unsupported" ]; then
    err "No prometheus/promtool on PATH and CPU arch $(uname -m) is not auto-downloadable."
    err "Install Prometheus manually: https://prometheus.io/download/"
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || { err "curl is required to download Prometheus."; exit 1; }
  command -v tar  >/dev/null 2>&1 || { err "tar is required to unpack Prometheus."; exit 1; }

  local tarball="prometheus-${PROM_VERSION}.linux-${arch}.tar.gz"
  local url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${tarball}"
  info "No Prometheus found; downloading pinned v${PROM_VERSION} (${arch})..."
  mkdir -p "$BIN_DIR"
  curl -fsSL "$url" -o "$PCA_LAB_DIR/$tarball"
  tar -xzf "$PCA_LAB_DIR/$tarball" -C "$PCA_LAB_DIR"
  cp "$PCA_LAB_DIR/prometheus-${PROM_VERSION}.linux-${arch}/prometheus" "$BIN_DIR/"
  cp "$PCA_LAB_DIR/prometheus-${PROM_VERSION}.linux-${arch}/promtool"   "$BIN_DIR/"
  rm -rf "$PCA_LAB_DIR/prometheus-${PROM_VERSION}.linux-${arch}" "$PCA_LAB_DIR/$tarball"
  PROM_BIN="$BIN_DIR/prometheus"; PROMTOOL_BIN="$BIN_DIR/promtool"
  ok "Prometheus v${PROM_VERSION} ready in $BIN_DIR."
}

# --------------------------- lab scaffolding -------------------------------
port_busy() { curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/-/ready" 2>/dev/null; }

stop_lab_prom() {
  if [ -f "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    fi
    rm -f "$PID_FILE"
  fi
}

write_config() {
  mkdir -p "$PCA_LAB_DIR/rules" "$DATA_DIR"
  cat > "$CONFIG_FILE" <<EOF
# PCA 4.2 lab — Prometheus main configuration.
global:
  scrape_interval: 15s
  evaluation_interval: 5s   # short interval so alerts light up fast in the lab

rule_files:
  - "rules/*.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["127.0.0.1:${PORT}"]
EOF
}

write_good_rules() {
  cat > "$RULES_FILE" <<'EOF'
# PCA 4.2 lab — alerting rules (HEALTHY baseline).
groups:
  - name: lab-alerts
    rules:
      # A "watchdog"/"deadman's switch": always firing. If this alert is NOT
      # firing, your alerting pipeline itself is broken. (Pattern used by
      # kube-prometheus.) Use it to prove the evaluation path is healthy.
      - alert: LabWatchdog
        expr: vector(1)
        labels:
          severity: none
        annotations:
          summary: "Alerting pipeline heartbeat"
          description: "Always-on watchdog proving rule evaluation works."

      # A realistic critical alert: fires when a scrape target is down.
      - alert: PrometheusTargetMissing
        expr: up{job="prometheus"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Scrape target down (instance {{ $labels.instance }})"
          description: "up == 0 for job=prometheus for more than 1 minute."
EOF
}

start_prom_bg() {
  rm -f "$LOG_FILE"
  "$PROM_BIN" \
    --config.file="$CONFIG_FILE" \
    --storage.tsdb.path="$DATA_DIR" \
    --web.listen-address="127.0.0.1:${PORT}" \
    --web.enable-lifecycle \
    --log.level=info \
    >"$LOG_FILE" 2>&1 &
  echo "$!" > "$PID_FILE"
}

wait_ready() {
  local timeout="${1:-25}" i=0
  while [ "$i" -lt "$timeout" ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/-/ready" 2>/dev/null; then
      return 0
    fi
    # If the process already died, stop waiting.
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 1; i=$((i+1))
  done
  return 1
}

show_loaded_rules() {
  local out; out="$(curl -fsS "http://127.0.0.1:${PORT}/api/v1/rules" 2>/dev/null || true)"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$out" | python3 - <<'PY' 2>/dev/null || printf '%s\n' "$out"
import json,sys
d=json.load(sys.stdin)
for g in d.get("data",{}).get("groups",[]):
    print(f"  group: {g['name']}")
    for r in g.get("rules",[]):
        st=r.get("state","-"); h=r.get("health","-")
        print(f"    - {r.get('name')}: state={st} health={h}")
PY
  else
    printf '%s\n' "$out" | tr ',' '\n' | grep -E '"(name|state|health)":' || printf '%s\n' "$out"
  fi
}

write_helper_scripts() {
  cat > "$PCA_LAB_DIR/run.sh" <<EOF
#!/usr/bin/env bash
# Start (or restart) the lab Prometheus in the foreground.
set -e
cd "$PCA_LAB_DIR"
exec "$PROM_BIN" \\
  --config.file="$CONFIG_FILE" \\
  --storage.tsdb.path="$DATA_DIR" \\
  --web.listen-address="127.0.0.1:${PORT}" \\
  --web.enable-lifecycle \\
  --log.level=info
EOF
  cat > "$PCA_LAB_DIR/check.sh" <<EOF
#!/usr/bin/env bash
# Validate the rule file and the config the way promtool would in CI.
set -e
echo "== promtool check rules =="
"$PROMTOOL_BIN" check rules "$RULES_FILE"
echo "== promtool check config =="
"$PROMTOOL_BIN" check config "$CONFIG_FILE"
EOF
  chmod +x "$PCA_LAB_DIR/run.sh" "$PCA_LAB_DIR/check.sh"
}

# --------------------------- the controlled break --------------------------
break_rules() {
  # Introduce ONE fault: delete the closing brace of the label matcher in the
  # PrometheusTargetMissing expression. The YAML still parses, but the embedded
  # PromQL becomes a syntax error. Because Prometheus validates the ENTIRE rule
  # file as a unit, this single typo invalidates BOTH alerts in the group and
  # makes Prometheus refuse to (re)start.
  #   good: expr: up{job="prometheus"} == 0
  #   bad : expr: up{job="prometheus" == 0
  sed -i 's/up{job="prometheus"} == 0/up{job="prometheus" == 0/' "$RULES_FILE"
}

# --------------------------- main flow -------------------------------------
main() {
  case "${1:-}" in
    --cleanup) cleanup_lab; exit 0 ;;
    --yes) export PCA_LAB_CONFIRM=yes ;;
  esac

  confirm_lab
  mkdir -p "$PCA_LAB_DIR"

  if port_busy; then
    warn "Something is already answering on 127.0.0.1:${PORT}."
    warn "Stopping any previous lab instance..."
    stop_lab_prom
    if port_busy; then
      err "Port ${PORT} is still in use by a non-lab process. Set PORT=<free-port> and retry."
      exit 1
    fi
  fi

  resolve_binaries
  write_config
  write_good_rules
  write_helper_scripts

  hr
  info "STEP 1/3 — Bring up a HEALTHY Prometheus and prove the alerts load."
  hr
  start_prom_bg
  if wait_ready 30; then
    ok "Prometheus is up on http://127.0.0.1:${PORT}"
    info "Currently loaded rules (expect LabWatchdog=firing, PrometheusTargetMissing=inactive):"
    sleep 3
    show_loaded_rules
  else
    err "Baseline Prometheus failed to start. Log tail:"
    tail -n 20 "$LOG_FILE" || true
    exit 1
  fi

  hr
  info "STEP 2/3 — Injecting one controlled fault into the rule file, then restarting."
  hr
  stop_lab_prom
  break_rules
  ok "Fault injected into: $RULES_FILE"
  start_prom_bg
  if wait_ready 12; then
    warn "Prometheus came up unexpectedly — the injected fault may not have taken. Inspect the rules."
  else
    ok "As designed: Prometheus is NOT ready. The lab is now broken and waiting for you."
  fi

  hr
  say "${B}================  YOUR MISSION  ================${Z}"
  hr
  say "A teammate edited ${B}$RULES_FILE${Z} and now the monitoring stack is down."
  say ""
  say "${B}SYMPTOM you will observe:${Z}"
  say "  * http://127.0.0.1:${PORT} is unreachable — Prometheus exits on start."
  say "  * The process dies immediately; there is no PID listening on ${PORT}:"
  say "        curl -s http://127.0.0.1:${PORT}/-/ready        # connection refused"
  say "  * The log names a rule file and a PromQL parse problem:"
  say "        tail -n 25 $LOG_FILE"
  say "  * Because the whole file is rejected, BOTH alerts vanish — even the"
  say "    healthy watchdog. One bad expression takes down the entire group."
  say ""
  say "${B}GOAL (acceptance criteria):${Z}"
  say "  1. '$PROMTOOL_BIN check rules $RULES_FILE'  ->  SUCCESS"
  say "  2. Prometheus starts and '/-/ready' returns HTTP 200 on port ${PORT}."
  say "  3. The rules API shows BOTH alerts healthy, with LabWatchdog firing:"
  say "        curl -s http://127.0.0.1:${PORT}/api/v1/rules"
  say ""
  say "${B}Helpers created for you:${Z}"
  say "  * $PCA_LAB_DIR/check.sh   -> runs promtool check rules + check config"
  say "  * $PCA_LAB_DIR/run.sh     -> starts Prometheus in the foreground"
  say "  * Reset everything:  $0 --cleanup"
  hr
  say "Do NOT scroll to the bottom of this script until you have tried it. The"
  say "full step-by-step solution is at the end, commented out."
  hr
}

main "$@"

# ===========================================================================
# ============================  SOLUTION  (spoilers)  =======================
# ===========================================================================
#
# The fault: the closing brace of the label matcher was removed, turning a
# valid instant-vector selector into an invalid PromQL expression.
#
#     BROKEN:  expr: up{job="prometheus" == 0
#     FIXED :  expr: up{job="prometheus"} == 0
#                                       ^ this "}" is what was missing
#
# ---------------------------------------------------------------------------
# STEP 1 — Read the symptom, don't guess. Prometheus refused to start.
# ---------------------------------------------------------------------------
#   curl -s http://127.0.0.1:9091/-/ready        # -> connection refused
#   tail -n 25 /tmp/pca-4.2-lab/prometheus.log
#
#   The log points straight at the culprit, e.g.:
#     level=error ... msg="Failed to apply configuration" ...
#     ... could not parse expression: ... rules/lab_alerts.yml ...
#     ... unexpected "==" in label matching, expected "}" or "," ...
#
#   Lesson: at STARTUP an invalid rule file is fatal — Prometheus exits.
#   On a RELOAD of an already-running instance it is not fatal: the reload is
#   rejected and the previous good config is kept, which can silently mask a
#   bad rule. Always validate before you ship.
#
# ---------------------------------------------------------------------------
# STEP 2 — Reproduce the failure deterministically with promtool (offline).
# ---------------------------------------------------------------------------
#   promtool check rules /tmp/pca-4.2-lab/rules/lab_alerts.yml
#
#   -> FAILED, with the file, line, and the parse error. This is exactly what
#      you should run in CI so a bad rule never reaches production.
#   (Equivalent one-shot helper:  bash /tmp/pca-4.2-lab/check.sh)
#
# ---------------------------------------------------------------------------
# STEP 3 — Fix the expression: put the missing "}" back.
# ---------------------------------------------------------------------------
#   Edit the file:
#     ${EDITOR:-vi} /tmp/pca-4.2-lab/rules/lab_alerts.yml
#   ...or apply it non-interactively:
#     sed -i 's/up{job="prometheus" == 0/up{job="prometheus"} == 0/' \
#         /tmp/pca-4.2-lab/rules/lab_alerts.yml
#
# ---------------------------------------------------------------------------
# STEP 4 — Re-validate BEFORE restarting (validate-then-apply discipline).
# ---------------------------------------------------------------------------
#   promtool check rules  /tmp/pca-4.2-lab/rules/lab_alerts.yml   # -> SUCCESS
#   promtool check config /tmp/pca-4.2-lab/prometheus.yml         # -> SUCCESS
#
# ---------------------------------------------------------------------------
# STEP 5 — Bring Prometheus back up.
# ---------------------------------------------------------------------------
#   bash /tmp/pca-4.2-lab/run.sh        # foreground; Ctrl-C to stop
#   # or in the background:
#   /tmp/pca-4.2-lab/bin/prometheus \
#     --config.file=/tmp/pca-4.2-lab/prometheus.yml \
#     --storage.tsdb.path=/tmp/pca-4.2-lab/data \
#     --web.listen-address=127.0.0.1:9091 \
#     --web.enable-lifecycle &
#
# ---------------------------------------------------------------------------
# STEP 6 — Confirm the acceptance criteria.
# ---------------------------------------------------------------------------
#   curl -s http://127.0.0.1:9091/-/ready                         # -> "...is Ready."
#   curl -s http://127.0.0.1:9091/api/v1/rules | python3 -m json.tool
#     Expect: group "lab-alerts" with
#       - LabWatchdog:            state=firing   health=ok
#       - PrometheusTargetMissing: state=inactive health=ok
#   Open the UI: http://127.0.0.1:9091/alerts  and  .../rules
#
# ---------------------------------------------------------------------------
# STEP 7 — The production habit: reload WITHOUT a restart.
# ---------------------------------------------------------------------------
#   Because we passed --web.enable-lifecycle, a live instance reloads rules and
#   config with an HTTP POST (or SIGHUP) — no downtime, no lost scrape data:
#     curl -X POST http://127.0.0.1:9091/-/reload
#     # or:  kill -HUP <prometheus-pid>
#   If the new rules are invalid, the reload is REJECTED and the running rules
#   are kept — which is why STEP 4 (promtool in CI) is non-negotiable.
#
# ---------------------------------------------------------------------------
# WHY THIS MATTERS FOR PCA 4.2 (and beyond the typo):
#   * A rule file is validated and loaded atomically per group/file: one broken
#     expression disables every rule beside it. Keep noisy/experimental rules
#     in a separate file from your critical ones.
#   * Loud failures (syntax errors) are the easy case. The dangerous ones are
#     SILENT: a valid expression that never fires (wrong metric name, wrong
#     comparison), a 'for:' so long the alert never leaves "pending", or a
#     'rule_files:' glob that doesn't match the filename so rules load "0 rules"
#     with no error at all. Always confirm the alert actually appears AND
#     reaches the expected state in /api/v1/rules — presence is not correctness.
#   * The Watchdog/deadman's-switch pattern (an always-firing alert wired to a
#     receiver that pages if it ever STOPS) is how you detect a dead alerting
#     pipeline, since a broken pipeline cannot page you about itself.
#
# Sources:
#   https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
#   https://prometheus.io/docs/prometheus/latest/command-line/promtool/
#   https://prometheus.io/docs/prometheus/latest/management_api/  (/-/reload)
#   https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
# ===========================================================================