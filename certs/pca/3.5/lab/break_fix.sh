#!/usr/bin/env bash
#
# PCA — Prometheus Certified Associate
# Topic 3.5: Service Discovery  (exam weight: 3)
# Lab type: BREAK & FIX  (run only on a disposable lab VM)
#
# What this exercise trains:
#   How Prometheus turns *discovered* targets into *scraped* targets, and how a
#   single relabel_configs rule can silently remove every target from a job
#   WITHOUT the configuration ever becoming invalid. This is the number-one
#   real-world Service Discovery trap: `promtool check config` passes, Prometheus
#   stays healthy, the logs are clean — and yet the job scrapes nothing.
#
# Reference sources (official):
#   - PCA curriculum:      https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#   - file_sd_config:      https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config
#   - relabel_config:      https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
#   - Service discovery:   https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
#   - File SD guide:       https://prometheus.io/docs/guides/file-sd/
#   - Targets API:         https://prometheus.io/docs/prometheus/latest/querying/api/#targets
#
# The scenario uses file-based service discovery (file_sd_configs) with two
# targets that both scrape Prometheus' own /metrics endpoint, so no external
# exporter is required and both targets are UP in the healthy baseline.

set -euo pipefail

# ----------------------------------------------------------------------------
# Tunables (override via environment)
# ----------------------------------------------------------------------------
LAB_DIR="${LAB_DIR:-/tmp/pca-lab-sd}"
PROM_PORT="${PROM_PORT:-9090}"
IMAGE="${IMAGE:-docker.io/prom/prometheus:v2.53.1}"
CONTAINER="${CONTAINER:-pca-lab-sd-prometheus}"
JOB="payments-fleet"

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
hr()  { printf '%s\n' "------------------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_lab_confirmation() {
  if [[ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB:-}" == "yes" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "Refusing to run non-interactively without I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes"
  fi
  say "This script starts a throwaway Prometheus container and deliberately breaks"
  say "its Service Discovery. Run it ONLY on a disposable lab VM you can wipe."
  read -r -p "Type 'yes' to continue: " ans
  [[ "$ans" == "yes" ]] || die "Aborted by user."
}

detect_runtime() {
  local c
  for c in podman docker; do
    if command -v "$c" >/dev/null 2>&1; then RUNTIME="$c"; return 0; fi
  done
  die "Need 'podman' or 'docker' in PATH for this lab."
}

# Count active, scraping targets of the job via the instant-query API.
# `up{job="payments-fleet"}` returns one series per ACTIVE target: 2 healthy, 0 broken.
active_targets() {
  curl -fsS "http://localhost:${PROM_PORT}/api/v1/query?query=up%7Bjob%3D%22${JOB}%22%7D" 2>/dev/null \
    | grep -o '"metric"' | wc -l | tr -d ' '
}

wait_ready() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS "http://localhost:${PROM_PORT}/-/ready" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "Prometheus did not become ready on port ${PROM_PORT}."
}

wait_active_count() {
  local want="$1" i got
  for i in $(seq 1 30); do
    got="$(active_targets || echo 0)"
    [[ "$got" == "$want" ]] && return 0
    sleep 2
  done
  return 1
}

# ----------------------------------------------------------------------------
# Config writers
# ----------------------------------------------------------------------------
write_targets_file() {
  cat > "${LAB_DIR}/sd/targets.json" <<'JSON'
[
  { "targets": ["localhost:9090"], "labels": { "team": "payments", "service": "api" } },
  { "targets": ["localhost:9090"], "labels": { "team": "checkout", "service": "web" } }
]
JSON
}

write_baseline_config() {
  cat > "${LAB_DIR}/prometheus.yml" <<'YAML'
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  # File-based Service Discovery: targets are read (and hot-reloaded) from JSON.
  - job_name: 'payments-fleet'
    file_sd_configs:
      - files:
          - '/etc/prometheus/sd/targets.json'
        refresh_interval: 5s
YAML
}

write_broken_config() {
  # Same job, but with a relabeling stage bolted on. The config is 100% VALID.
  cat > "${LAB_DIR}/prometheus.yml" <<'YAML'
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  - job_name: 'payments-fleet'
    file_sd_configs:
      - files:
          - '/etc/prometheus/sd/targets.json'
        refresh_interval: 5s
    relabel_configs:
      # THE FAULT (introduced on purpose):
      # An over-restrictive `keep` rule. Only targets whose `team` label equals
      # "sre-platform" survive relabeling. The discovered teams are "payments"
      # and "checkout", so EVERY target fails the regex and is dropped BEFORE
      # any scrape happens. Relabeling runs at discovery time, not scrape time.
      - source_labels: [team]
        regex: 'sre-platform'
        action: keep
YAML
}

# ----------------------------------------------------------------------------
# Runtime control
# ----------------------------------------------------------------------------
start_prometheus() {
  "$RUNTIME" rm -f "$CONTAINER" >/dev/null 2>&1 || true
  "$RUNTIME" run -d --name "$CONTAINER" \
    -p "${PROM_PORT}:9090" \
    -v "${LAB_DIR}:/etc/prometheus:Z" \
    "$IMAGE" \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --web.enable-lifecycle \
    --web.listen-address=0.0.0.0:9090 >/dev/null
}

reload_prometheus() {
  curl -fsS -X POST "http://localhost:${PROM_PORT}/-/reload" >/dev/null
}

cleanup() {
  detect_runtime
  say "Removing lab container '${CONTAINER}' and directory '${LAB_DIR}' ..."
  "$RUNTIME" rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  say "Lab cleaned up."
}

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------
run_exercise() {
  require_lab_confirmation
  detect_runtime
  command -v curl >/dev/null 2>&1 || die "This lab needs 'curl'."

  hr
  say "PCA 3.5 — Service Discovery :: BREAK & FIX"
  say "Runtime: ${RUNTIME}   Image: ${IMAGE}   UI: http://localhost:${PROM_PORT}"
  hr

  mkdir -p "${LAB_DIR}/sd"
  write_targets_file
  write_baseline_config

  say "[1/4] Starting a healthy Prometheus with file_sd Service Discovery ..."
  start_prometheus
  wait_ready

  say "[2/4] Waiting for the baseline to become healthy (2 active targets) ..."
  if wait_active_count 2; then
    say "      OK — job '${JOB}' has 2 ACTIVE targets, both UP. Baseline is good."
  else
    say "      WARNING: baseline did not reach 2 active targets; check '${RUNTIME} logs ${CONTAINER}'."
  fi

  say "[3/4] Injecting the fault into Service Discovery and reloading ..."
  write_broken_config
  reload_prometheus
  # Give file_sd + relabeling a moment to take effect.
  wait_active_count 0 || true

  say "[4/4] Fault is live."
  hr
  say "SYMPTOM you will observe:"
  say "  * Job '${JOB}' now shows 0 ACTIVE targets."
  say "      curl -s 'http://localhost:${PROM_PORT}/api/v1/query?query=up{job=\"${JOB}\"}'  -> empty result"
  say "  * The Prometheus UI /targets page no longer lists the two instances."
  say "  * BUT the config is still valid and Prometheus is healthy:"
  say "      ${RUNTIME} exec ${CONTAINER} promtool check config /etc/prometheus/prometheus.yml   -> SUCCESS"
  say "  * The two targets did NOT disappear — they were DISCOVERED and then DROPPED."
  say "      Open  http://localhost:${PROM_PORT}/service-discovery  and expand '${JOB}':"
  say "      you will see them under 'Dropped targets', with their discovered __meta_* labels,"
  say "      dropped by the relabeling stage."
  hr
  say "YOUR GOAL:"
  say "  Restore both instances to ACTIVE / UP status WITHOUT deleting the job and"
  say "  WITHOUT changing the JSON in ${LAB_DIR}/sd/targets.json."
  say "  The fix lives entirely in the scrape job's relabeling stage."
  hr
  say "HINTS (dig here before reading the spoiler at the bottom of this file):"
  say "  1. Compare /service-discovery (what was discovered) vs /targets (what is scraped)."
  say "  2. Read the 'Dropped targets' entry: which relabel action removed them?"
  say "  3. Recall the semantics of action: keep  — it KEEPS only what MATCHES the regex."
  say "  4. Edit ${LAB_DIR}/prometheus.yml, then reload:"
  say "         curl -X POST http://localhost:${PROM_PORT}/-/reload"
  say "     Verify: the two targets return to ACTIVE within one refresh_interval."
  hr
  say "Files you may edit:   ${LAB_DIR}/prometheus.yml"
  say "Tear down when done:  I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes bash \"$0\" cleanup"
  hr
}

case "${1:-break}" in
  break)   run_exercise ;;
  cleanup) require_lab_confirmation; cleanup ;;
  *)       die "Usage: $0 [break|cleanup]" ;;
esac

# ============================================================================
# SPOILER — STEP-BY-STEP SOLUTION (do not read until you have solved it)
# ============================================================================
#
# Root cause
# ----------
# Service Discovery in Prometheus has two phases:
#   (a) DISCOVERY  — file_sd_configs reads targets.json and produces target
#                    candidates, each carrying __meta_* and user labels (team, service).
#   (b) RELABELING — relabel_configs runs over each candidate. A target that is
#                    dropped here NEVER becomes an active target and is NEVER scraped.
# The injected rule:
#       - source_labels: [team]
#         regex: 'sre-platform'
#         action: keep
# means "keep ONLY targets whose `team` value matches ^sre-platform$; drop the rest."
# The discovered teams are "payments" and "checkout", so both fail the regex and
# are dropped. Nothing is broken syntactically, so promtool and the logs stay clean.
# That is exactly why /service-discovery (which shows dropped targets) is the tool
# that reveals it, not /targets and not the config validator.
#
# Diagnosis walk-through
# ----------------------
#   1. Confirm the job has 0 active targets:
#        curl -s 'http://localhost:9090/api/v1/query?query=up{job="payments-fleet"}'
#        # -> {"status":"success","data":{"resultType":"vector","result":[]}}
#   2. Confirm the config is still valid (rules out a typo / YAML error):
#        <runtime> exec pca-lab-sd-prometheus promtool check config /etc/prometheus/prometheus.yml
#        # -> SUCCESS
#   3. Confirm the targets ARE being discovered but dropped:
#        curl -s 'http://localhost:9090/api/v1/targets?state=dropped' | tr ',' '\n' | grep -i team
#        # or open the UI:  http://localhost:9090/service-discovery  -> expand payments-fleet
#        # You will see 2 dropped targets with team="payments" / team="checkout".
#   4. Read the relabel stage: an `action: keep` with a regex nothing matches.
#
# Fix (any ONE of these; option A is the cleanest)
# ------------------------------------------------
#   Edit  /tmp/pca-lab-sd/prometheus.yml  and change the relabel stage:
#
#   Option A — remove the erroneous restriction entirely (the job never needed it):
#       scrape_configs:
#         - job_name: 'payments-fleet'
#           file_sd_configs:
#             - files: ['/etc/prometheus/sd/targets.json']
#               refresh_interval: 5s
#           # (relabel_configs removed)
#
#   Option B — keep the rule but make the regex match the real teams:
#       relabel_configs:
#         - source_labels: [team]
#           regex: 'payments|checkout'
#           action: keep
#
#   Option C — if the intent was truly to keep everything, use a match-all regex:
#       relabel_configs:
#         - source_labels: [team]
#           regex: '.*'
#           action: keep
#
# Apply and verify (no restart needed — hot reload):
#   curl -X POST http://localhost:9090/-/reload
#   sleep 6
#   curl -s 'http://localhost:9090/api/v1/query?query=up{job="payments-fleet"}' \
#     | grep -o '"metric"' | wc -l          # expect 2
#   # UI: http://localhost:9090/targets -> payments-fleet shows 2 targets, state=UP.
#
# Key exam takeaways (PCA 3.5)
# ----------------------------
#   * Discovery and scraping are distinct phases; relabeling sits between them.
#   * `action: keep`  drops everything that does NOT match the regex;
#     `action: drop`  drops everything that DOES match. Confusing the two, or a
#     too-narrow regex, silently empties a job.
#   * A dropped target is not "down": it is absent from /targets and appears only
#     under /service-discovery (or /api/v1/targets?state=dropped).
#   * A valid config that scrapes nothing is a Service Discovery / relabeling bug,
#     not a syntax bug — promtool cannot catch it.
#   * file_sd hot-reloads target files on refresh_interval; changes to the scrape
#     config itself require SIGHUP or POST /-/reload (--web.enable-lifecycle).
#
# ============================================================================