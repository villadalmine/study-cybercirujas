#!/usr/bin/env bash
#
# ==============================================================================
# PCA — Prometheus Certified Associate
# Domain 4: Instrumentation and Alerting  |  Topic 4.3: Understand and Use Alertmanager
# Exam weight: 4.5
#
# BREAK & FIX LAB — "The config that silently refuses to reload"
#
# WARNING: This script MUTATES the live Alertmanager configuration.
#          Run it ONLY on a disposable lab VM you can throw away.
#          Do NOT run it against anything you care about.
#
# What this lab teaches:
#   - How Alertmanager loads and hot-reloads its configuration (SIGHUP / reload).
#   - The critical difference between "service is running" and "config is loaded".
#   - How to diagnose a failed reload using amtool, the runtime metrics endpoint,
#     and the process logs — the exact signals the exam expects you to reach for.
#
# Reference sources (official):
#   - Alertmanager overview:      https://prometheus.io/docs/alerting/latest/alertmanager/
#   - Configuration reference:    https://prometheus.io/docs/alerting/latest/configuration/
#   - amtool (check-config):      https://github.com/prometheus/alertmanager/blob/main/README.md
#   - Reloading configuration:    https://prometheus.io/docs/alerting/latest/management_api/
#   - PCA curriculum:             https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Tunables (override via environment if your lab differs)
# ------------------------------------------------------------------------------
AM_URL="${AM_URL:-http://localhost:9093}"          # Alertmanager web endpoint
AM_SERVICE="${AM_SERVICE:-alertmanager}"           # systemd unit name, if any
BOGUS_RECEIVER="page-oncall-DOES-NOT-EXIST"        # receiver we will reference but never define
STAMP="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\033[1;34m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; }

# ------------------------------------------------------------------------------
# 0. Safety gate — force the student to acknowledge this is destructive
# ------------------------------------------------------------------------------
if [[ "${I_UNDERSTAND:-}" != "yes" ]]; then
  warn "This script will deliberately break the Alertmanager config on THIS host."
  warn "It is safe ONLY on a throwaway lab VM."
  read -r -p "Type 'break-it' to continue: " ANSWER
  [[ "$ANSWER" == "break-it" ]] || { err "Aborted. (Set I_UNDERSTAND=yes to skip this prompt.)"; exit 1; }
fi

# ------------------------------------------------------------------------------
# 1. Locate the running Alertmanager and its --config.file
# ------------------------------------------------------------------------------
AM_PID="$(pidof alertmanager 2>/dev/null || true)"
if [[ -z "$AM_PID" ]]; then
  err "Alertmanager process not found. Start it before running this lab (e.g. 'systemctl start ${AM_SERVICE}')."
  exit 1
fi

# Read the actual --config.file flag straight off the process command line.
CONFIG="$(tr '\0' '\n' < "/proc/${AM_PID}/cmdline" \
          | grep -m1 -- '--config.file' \
          | sed -E 's/^--config\.file[= ]?//' || true)"

# Fallback: the well-known default locations.
if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
  for c in /etc/alertmanager/alertmanager.yml \
           /etc/alertmanager/config.yml \
           /etc/prometheus/alertmanager.yml; do
    [[ -f "$c" ]] && CONFIG="$c" && break
  done
fi

[[ -f "$CONFIG" ]] || { err "Could not find the Alertmanager config file. Set it manually and re-run."; exit 1; }
log "Alertmanager PID    : $AM_PID"
log "Config file in use  : $CONFIG"

# ------------------------------------------------------------------------------
# 2. Snapshot the healthy state BEFORE breaking anything
# ------------------------------------------------------------------------------
BACKUP="${CONFIG}.healthy-backup.${STAMP}"
cp -a "$CONFIG" "$BACKUP"
log "Backed up healthy config to: $BACKUP"

reload_metric() {
  # 1 = last reload succeeded, 0 = last reload failed. This is your ground truth.
  curl -fsS "${AM_URL}/metrics" 2>/dev/null \
    | awk '/^alertmanager_config_last_reload_successful /{print $2}' \
    | head -n1
}

BEFORE="$(reload_metric || echo '?')"
log "alertmanager_config_last_reload_successful (before break) = ${BEFORE:-?}"

# ------------------------------------------------------------------------------
# 3. THE CONTROLLED BREAK
#    Point the top-level route at a receiver that does not exist in 'receivers:'.
#    This is the single most common Alertmanager misconfiguration: the router
#    references a receiver name that was never declared. The YAML still parses;
#    the semantic validation is what fails.
#
#    We surgically rewrite ONLY the first 'receiver:' line (the route's default
#    receiver in a standard config) and leave the receivers list untouched.
# ------------------------------------------------------------------------------
TMP="$(mktemp)"
awk -v bogus="$BOGUS_RECEIVER" '
  BEGIN { patched = 0 }
  # First indented "receiver:" line == the route.receiver in a normal config.
  !patched && $0 ~ /^[[:space:]]+receiver:/ {
    match($0, /^[[:space:]]+/); indent = substr($0, 1, RLENGTH)
    print indent "receiver: " bogus
    patched = 1
    next
  }
  { print }
' "$CONFIG" > "$TMP"

if ! grep -q "$BOGUS_RECEIVER" "$TMP"; then
  err "Could not locate a route 'receiver:' line to break. Config layout is unusual; nothing changed."
  rm -f "$TMP"
  exit 1
fi
cat "$TMP" > "$CONFIG"
rm -f "$TMP"
log "Injected broken route: route.receiver -> '${BOGUS_RECEIVER}' (undefined receiver)."

# ------------------------------------------------------------------------------
# 4. Ask Alertmanager to reload — it will REJECT the new config and keep the old.
# ------------------------------------------------------------------------------
log "Triggering a hot-reload (SIGHUP)..."
if command -v systemctl >/dev/null 2>&1 && systemctl cat "$AM_SERVICE" >/dev/null 2>&1; then
  systemctl reload "$AM_SERVICE" 2>/dev/null \
    || systemctl kill -s HUP "$AM_SERVICE" 2>/dev/null \
    || kill -HUP "$AM_PID"
else
  kill -HUP "$AM_PID"
fi

sleep 2
AFTER="$(reload_metric || echo '?')"

# ------------------------------------------------------------------------------
# 5. Brief the student
# ------------------------------------------------------------------------------
cat <<EOF

================================================================================
  BREAK INJECTED — Topic 4.3, Understand and Use Alertmanager
================================================================================

THE TRAP:
  The Alertmanager *process* is still running and its web UI still answers.
  Everything LOOKS green. But the configuration you see on disk is NOT the
  configuration currently loaded in memory: the last reload was refused.

SYMPTOMS YOU WILL OBSERVE:
  * The reload metric flipped:
        alertmanager_config_last_reload_successful  before = ${BEFORE:-?}   now = ${AFTER:-?}
    (0 = the running process is refusing your on-disk config.)
  * Any change you make to routing/receivers/silences will "not take effect",
    because Alertmanager is still serving the previous good config from memory.
  * The logs show the real reason (something like):
        error loading config ... undefined receiver "${BOGUS_RECEIVER}" used in route

YOUR MISSION (definition of done):
  1. Prove the config is broken WITHOUT reading this script — use the tooling.
  2. Identify the exact misconfiguration.
  3. Repair the config so it is semantically valid.
  4. Reload successfully and confirm:
        alertmanager_config_last_reload_successful == 1

INVESTIGATION STARTING POINTS (do NOT scroll to the solution yet):
  * amtool check-config ${CONFIG}
  * curl -s ${AM_URL}/metrics | grep config_last_reload
  * journalctl -u ${AM_SERVICE} -n 40    # or your container/stdout logs
  * ${AM_URL}/#/status                    # UI shows the LOADED config, not the file

A healthy backup exists at:
  ${BACKUP}
...but restoring blindly is not the point. Diagnose first, then fix.
================================================================================
EOF

exit 0

# ==============================================================================
# ====================  STEP-BY-STEP SOLUTION (spoilers)  ======================
# ==============================================================================
#
# STEP 1 — Confirm the reload failed (the definitive signal).
#   $ curl -s http://localhost:9093/metrics | grep alertmanager_config_last_reload_successful
#   alertmanager_config_last_reload_successful 0
#   A value of 0 means: the process is alive but is REFUSING the on-disk config.
#   Cross-check the timestamp of the last successful reload:
#   $ curl -s http://localhost:9093/metrics | grep alertmanager_config_last_reload_success_timestamp_seconds
#
# STEP 2 — Get the exact error. amtool validates the same way the server does.
#   $ amtool check-config /etc/alertmanager/alertmanager.yml
#   Checking '/etc/alertmanager/alertmanager.yml'  FAILED: undefined receiver
#   "page-oncall-DOES-NOT-EXIST" used in route
#   (Equivalently, the server logs show the identical "undefined receiver" line.)
#
# STEP 3 — Understand the model. In Alertmanager the 'route' tree only *references*
#   receivers by name; the receivers themselves are declared under 'receivers:'.
#   Every 'receiver:' named anywhere in the route tree MUST match a 'name:' in the
#   receivers list. Here the route points at a name that was never declared.
#     Docs: https://prometheus.io/docs/alerting/latest/configuration/#route
#           https://prometheus.io/docs/alerting/latest/configuration/#receiver
#
# STEP 4 — Fix it. Two valid repairs; pick ONE:
#
#   (a) Repoint the route at an existing receiver. Inspect the receivers list:
#         $ grep -nE '^\s*-?\s*name:' /etc/alertmanager/alertmanager.yml
#       Then set the top-level route.receiver back to a real name, e.g.:
#         route:
#           receiver: 'web.hook'        # <-- a name that exists under receivers:
#
#   (b) OR declare the missing receiver so the reference resolves:
#         receivers:
#           - name: 'page-oncall-DOES-NOT-EXIST'   # (rename to something sane)
#             webhook_configs:
#               - url: 'http://127.0.0.1:5001/'
#
#   Quick lab shortcut (restores the known-good file):
#         $ cp -a /etc/alertmanager/alertmanager.yml.healthy-backup.* /etc/alertmanager/alertmanager.yml
#
# STEP 5 — Re-validate BEFORE reloading. Never reload a config you have not checked.
#   $ amtool check-config /etc/alertmanager/alertmanager.yml
#   Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
#   Found: <n> receivers, <n> routing rules, ...
#
# STEP 6 — Reload and make the new config take effect.
#   $ systemctl reload alertmanager        # or:  kill -HUP $(pidof alertmanager)
#   (Management-API alternative, if --web.enable-lifecycle is set:
#     $ curl -X POST http://localhost:9093/-/reload )
#
# STEP 7 — Verify the fix. The metric must return to 1.
#   $ curl -s http://localhost:9093/metrics | grep alertmanager_config_last_reload_successful
#   alertmanager_config_last_reload_successful 1
#   Confirm the loaded config in the UI matches the file: http://localhost:9093/#/status
#
# KEY EXAM TAKEAWAYS:
#   * "Running" != "config loaded". alertmanager_config_last_reload_successful is
#     the metric that tells the truth; alert on it in production.
#   * amtool check-config is your pre-flight — validate before every reload.
#   * A YAML file can parse perfectly and still be semantically invalid; the
#     route/receiver name linkage is the classic offender.
#   * SIGHUP / systemctl reload / POST /-/reload all perform the same validated
#     hot-reload; a rejected reload leaves the previous good config in memory.
# ==============================================================================