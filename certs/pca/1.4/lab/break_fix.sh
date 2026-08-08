#!/usr/bin/env bash
#
# =============================================================================
#  PCA · Prometheus Certified Associate
#  Domain 1 — Observability Concepts · Topic 1.4: "Aggregating over dimensions"
#  Exam weight: 4
#
#  BREAK & FIX LAB — self-contained, disposable, non-destructive.
#
#  What this teaches
#  -----------------
#  A PromQL aggregation operator (sum, avg, max, min, count, ...) collapses a
#  set of time series into fewer series. WHICH label dimensions survive that
#  collapse is decided entirely by the grouping modifier:
#
#      sum by (instance, mode) (...)   -> keep ONLY instance and mode
#      sum without (cpu)      (...)   -> keep everything EXCEPT cpu
#      sum                    (...)   -> keep NOTHING (one series total)
#
#  The single most common production incident on this topic is aggregating
#  away a dimension you still needed. The number is not "wrong" — it is a
#  correct sum over the wrong grouping — so it passes every syntax check and
#  silently destroys the signal. This lab reproduces that failure with real
#  node_exporter CPU counters and asks you to restore the lost dimension.
#
#  Reference (official curriculum):
#    https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#  PromQL aggregation operators:
#    https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators
#
#  Safety
#  ------
#  * Runs ONLY inside Docker containers named "pca-*" and writes ONLY under a
#    dedicated working directory. It touches no host services or system config.
#  * Fully idempotent: re-running re-creates the lab cleanly.
#  * Run "<script> cleanup" to remove every trace.
#  Intended for a THROWAWAY lab VM. Do not run on anything you care about.
# =============================================================================

set -euo pipefail

# ------------------------------ configuration --------------------------------
LAB_DIR="${PCA_LAB_DIR:-$HOME/pca-lab-1.4}"
NET="pca-lab"
PROM="pca-prometheus"
NODE="pca-node-exporter"
PROM_IMAGE="prom/prometheus:latest"
NODE_IMAGE="prom/node-exporter:latest"
PROM_PORT="9090"
PROM_URL="http://localhost:${PROM_PORT}"
RULES_FILE="${LAB_DIR}/rules.yml"
CONF_FILE="${LAB_DIR}/prometheus.yml"

# The recording rule at the centre of the exercise.
RULE_NAME="instance_mode:node_cpu_seconds:rate5m"

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is required but not found. Install Docker and retry."
  docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon (is it running / do you have permission?)."
}

# ------------------------------ teardown -------------------------------------
cleanup() {
  need_docker
  say "Tearing down the lab..."
  docker rm -f "$PROM" "$NODE" >/dev/null 2>&1 || true
  docker network rm "$NET"      >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  say "Done. Nothing left behind."
}

# ------------------------------ scaffolding ----------------------------------
write_config() {
  mkdir -p "$LAB_DIR"

  cat > "$CONF_FILE" <<'YAML'
# Fast intervals so rule evaluation and rate() produce data within seconds.
global:
  scrape_interval: 5s
  evaluation_interval: 5s

rule_files:
  - /etc/prometheus/rules.yml

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['pca-node-exporter:9100']
YAML

  # ---- THE BROKEN RULE -----------------------------------------------------
  # The record name advertises TWO dimensions: instance AND mode.
  # The expression, however, groups "by (instance)" only. The `mode` label is
  # aggregated away. Syntactically perfect; semantically it destroys the
  # per-mode breakdown the rule name promises.
  cat > "$RULES_FILE" <<YAML
groups:
  - name: cpu.rules
    interval: 5s
    rules:
      - record: ${RULE_NAME}
        expr: sum by (instance) (rate(node_cpu_seconds_total[5m]))
YAML
}

# ------------------------------ bring-up -------------------------------------
start_stack() {
  need_docker
  say "Pulling images (first run only)..."
  docker pull "$NODE_IMAGE" >/dev/null
  docker pull "$PROM_IMAGE" >/dev/null

  say "Recreating network and containers (idempotent)..."
  docker rm -f "$PROM" "$NODE" >/dev/null 2>&1 || true
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

  docker run -d --name "$NODE" --network "$NET" "$NODE_IMAGE" >/dev/null

  docker run -d --name "$PROM" --network "$NET" \
    -p "${PROM_PORT}:9090" \
    -v "${CONF_FILE}:/etc/prometheus/prometheus.yml:ro" \
    -v "${RULES_FILE}:/etc/prometheus/rules.yml:ro" \
    "$PROM_IMAGE" \
    --config.file=/etc/prometheus/prometheus.yml \
    --web.enable-lifecycle >/dev/null
  # --web.enable-lifecycle lets you reload after editing the rule with:
  #     curl -X POST ${PROM_URL}/-/reload
}

wait_ready() {
  say "Waiting for Prometheus to become ready..."
  for _ in $(seq 1 30); do
    if curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1 || die "Prometheus did not come up on ${PROM_URL}."
  say "Letting scrapes and rule evaluations accumulate (~20s)..."
  sleep 20
}

# ------------------------------ verification ---------------------------------
# Returns the number of distinct `mode` groups present in the recording rule.
# Broken  -> 1  (all modes collapsed into a single, unlabelled group)
# Fixed   -> N  (one series per mode: idle, system, user, iowait, ...)
count_mode_groups() {
  local q="count(count by (mode) (${RULE_NAME}))"
  local json
  json="$(curl -s -G "${PROM_URL}/api/v1/query" --data-urlencode "query=${q}")" || return 1
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    r = d["data"]["result"]
    print(int(float(r[0]["value"][1])) if r else 0)
except Exception:
    print(0)
'
  else
    # Fallback without python3: crude but works for a single scalar result.
    printf '%s' "$json" | grep -oE '"[0-9]+"\]' | tail -n1 | tr -dc '0-9' || echo 0
  fi
}

check() {
  need_docker
  local n; n="$(count_mode_groups)"
  echo
  echo "  Recording rule : ${RULE_NAME}"
  echo "  Distinct mode dimensions currently exposed : ${n}"
  if [ "${n:-0}" -gt 1 ]; then
    say "PASS — the 'mode' dimension is preserved. The break is fixed. Nicely done."
  else
    warn "STILL BROKEN — only ${n} group. The 'mode' dimension has been aggregated away."
  fi
}

# ------------------------------ the briefing ---------------------------------
briefing() {
  cat <<EOF

=================================================================
  LAB READY — ${RULE_NAME}
=================================================================

WHAT WE DID
  A recording rule was created that is *meant* to expose CPU usage rate
  broken down by host (instance) AND by CPU mode (idle, system, user,
  iowait, ...). Its name even says so: "instance_mode:...".

THE SYMPTOM YOU WILL SEE
  1. Open the expression browser:  ${PROM_URL}/graph
  2. Query:   ${RULE_NAME}
     -> You get a SINGLE series per host, with NO 'mode' label.
  3. Try to see it per mode:
        sum by (mode) (${RULE_NAME})
     -> Still one lumped series. The per-mode signal is gone.
  4. Anything downstream that needs 'mode' now silently breaks, e.g. the
     canonical CPU-busy formula becomes impossible to compute:
        1 - ( <idle rate> / <total rate> )
     ...because you can no longer isolate mode="idle".

  The value itself is a *correct* sum. That is exactly what makes this
  class of bug dangerous: no error, no NaN, no empty result — just a
  correct number over the wrong grouping.

YOUR GOAL
  Make the recording rule preserve the 'mode' dimension, WITHOUT changing
  which metric is summed and WITHOUT losing the per-instance grouping.
  Success = one series per CPU mode.

  Edit the rule file, then reload Prometheus:
      \$EDITOR ${RULES_FILE}
      curl -X POST ${PROM_URL}/-/reload

CHECK YOUR WORK
      $0 check          # PASS when the mode dimension is back

WHEN FINISHED
      $0 cleanup        # remove containers, network and files

(The full step-by-step solution is at the bottom of this script, commented out.)
=================================================================
EOF
}

# ------------------------------ entrypoint -----------------------------------
main() {
  case "${1:-setup}" in
    setup)
      write_config
      start_stack
      wait_ready
      check || true
      briefing
      ;;
    check)   check ;;
    cleanup) cleanup ;;
    *) die "Usage: $0 [setup|check|cleanup]" ;;
  esac
}

main "$@"

# #############################################################################
# #                        SOLUTION  (read only if stuck)                     #
# #############################################################################
#
# ROOT CAUSE
#   The expression was:
#
#       sum by (instance) (rate(node_cpu_seconds_total[5m]))
#
#   node_cpu_seconds_total carries the labels: cpu, mode, instance, job.
#   `by (instance)` tells sum() to keep ONLY `instance` and discard every
#   other label — including `mode`. So all CPUs and all modes are added into
#   one number per host. The dimension the rule name promised ("mode") is
#   destroyed at aggregation time.
#
# THE FIX — add `mode` back to the grouping list.
#   Edit ${RULES_FILE} and change the expr to:
#
#       expr: sum by (instance, mode) (rate(node_cpu_seconds_total[5m]))
#
#   `by (instance, mode)` keeps exactly those two dimensions and collapses
#   only the `cpu` (and `job`) dimension — which is what we actually want:
#   one aggregated rate per host, per mode, summed across all cores.
#
# EQUIVALENT FIX with the complementary modifier (know both for the exam):
#
#       expr: sum without (cpu) (rate(node_cpu_seconds_total[5m]))
#
#   `without (cpu)` keeps EVERYTHING except `cpu`. It therefore also retains
#   `job`, giving the output series labels {instance, mode, job}. Choose:
#     * `by`      when you want an explicit, minimal, whitelisted label set
#                 (stable output schema, immune to new labels appearing).
#     * `without` when you want to strip a known nuisance label and keep the
#                 rest.
#   Both restore the `mode` dimension and both make this lab pass.
#
# APPLY AND RELOAD
#       sed -i 's/sum by (instance)/sum by (instance, mode)/' ${RULES_FILE}
#       curl -X POST ${PROM_URL}/-/reload
#
# VERIFY
#       $0 check
#   Expected: "distinct mode dimensions" jumps from 1 to ~7-8, PASS.
#   In the UI, `sum by (mode) (${RULE_NAME})` now shows one line per mode.
#
# BONUS — the payoff of keeping the dimension: real CPU-busy ratio per host,
# now computable because mode="idle" is separable again:
#
#       1 - (
#             sum by (instance) (${RULE_NAME}{mode="idle"})
#           /
#             sum by (instance) (${RULE_NAME})
#           )
#
# TAKEAWAYS
#   * An aggregation's grouping modifier defines the output's dimensionality;
#     it is not a filter, it is a projection.
#   * `by` = whitelist of labels to KEEP; `without` = blacklist to DROP;
#     bare aggregation keeps nothing and yields a single series.
#   * A dimension lost to aggregation cannot be recovered downstream — the
#     information is gone the moment the operator runs. Aggregate as late as
#     possible and keep every dimension a consumer might still need.
# #############################################################################