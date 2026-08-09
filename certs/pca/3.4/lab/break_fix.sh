#!/usr/bin/env bash
#
# PCA — Domain 3: Instrumentation & Exporters
# Topic 3.4: Push vs Pull  (exam weight: 3)
#
# BREAK & FIX LAB — the Pushgateway "honor_labels" trap
# -----------------------------------------------------
# Prometheus is a PULL system: it scrapes /metrics endpoints on a schedule and,
# for every sample it ingests, it stamps the scrape target's own `job` and
# `instance` labels. The Pushgateway is the escape hatch for the PUSH model:
# short-lived / batch jobs that die before Prometheus can scrape them push their
# metrics to the gateway, and Prometheus scrapes the gateway instead.
#
# That hand-off is exactly where students get burned, and it is the heart of
# topic 3.4: when Prometheus PULLS from the Pushgateway, the pushed job/instance
# labels COLLIDE with the scrape target's job/instance. This lab starts a real
# Prometheus + Pushgateway, pushes a batch-job metric, and ships a scrape config
# with the collision left UNRESOLVED so you can see, query and fix the symptom.
#
# SAFE TO RUN because everything lives in throwaway Docker containers on a
# dedicated network, in a scratch workdir, all prefixed `pca34-`. Nothing on the
# host is touched. Intended for a DISPOSABLE lab VM. Tear down with:  $0 cleanup
#
# Reference syllabus: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#
set -euo pipefail

# ---- knobs (override via env) ----------------------------------------------
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v2.53.0}"
PGW_IMAGE="${PGW_IMAGE:-prom/pushgateway:v1.9.0}"
NET="pca34-net"
PROM_CTR="pca34-prometheus"
PGW_CTR="pca34-pushgateway"
WORKDIR="${WORKDIR:-/tmp/pca-3.4-push-vs-pull}"
PROM_PORT=9090
PGW_PORT=9091

# ---- tiny helpers ----------------------------------------------------------
say()  { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

show_json() {
  # pretty-print stdin JSON with whatever is available
  if command -v jq >/dev/null 2>&1; then jq .
  elif command -v python3 >/dev/null 2>&1; then python3 -m json.tool
  else cat; fi
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is required for this lab."
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (are you in the docker group / is it running?)."
}

wait_ready() {  # wait_ready <url> <name>
  local url="$1" name="$2" i
  for i in $(seq 1 30); do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "$name did not become ready at $url"
}

# ---- teardown --------------------------------------------------------------
cleanup() {
  need_docker
  say "Tearing down the PCA 3.4 lab..."
  docker rm -f "$PROM_CTR" "$PGW_CTR" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
  say "Clean. Nothing left behind."
  exit 0
}

# ---- the break -------------------------------------------------------------
setup() {
  need_docker

  # Guard: this genuinely starts services and is meant for a scratch VM.
  if [[ "${FORCE:-0}" != "1" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Start the break&fix lab (containers on ports ${PROM_PORT}/${PGW_PORT})? Run ONLY on a disposable lab VM. [y/N] " ans
      [[ "$ans" == [yY] ]] || die "Aborted by user."
    else
      die "Non-interactive shell. Re-run with FORCE=1 to confirm this is a disposable lab VM."
    fi
  fi

  say "[1/5] Preparing scratch workdir: $WORKDIR"
  rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"

  # --- THE INTENTIONAL BREAK -----------------------------------------------
  # The 'pushgateway' scrape job below is missing `honor_labels: true`.
  # Consequence (pull model): Prometheus overwrites the pushed job/instance
  # with the scrape target's labels (job="pushgateway"), and renames the pushed
  # ones to exported_job / exported_instance. Your batch metric becomes
  # unqueryable by its real job.
  # --------------------------------------------------------------------------
  cat > "$WORKDIR/prometheus.yml" <<'EOF'
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  # Prometheus scraping itself — proof the PULL model is healthy.
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Prometheus PULLING from the Pushgateway (which was PUSHED to).
  - job_name: 'pushgateway'
    # >>> BROKEN ON PURPOSE: `honor_labels: true` is missing here. <<<
    static_configs:
      - targets: ['pushgateway:9091']
EOF

  say "[2/5] Creating network + starting Pushgateway and Prometheus"
  docker network create "$NET" >/dev/null 2>&1 || true

  docker rm -f "$PGW_CTR" "$PROM_CTR" >/dev/null 2>&1 || true

  docker run -d --name "$PGW_CTR" \
    --network "$NET" --network-alias pushgateway \
    -p "${PGW_PORT}:9091" \
    "$PGW_IMAGE" >/dev/null

  docker run -d --name "$PROM_CTR" \
    --network "$NET" \
    -p "${PROM_PORT}:9090" \
    -v "$WORKDIR/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    "$PROM_IMAGE" \
    --config.file=/etc/prometheus/prometheus.yml \
    --web.enable-lifecycle >/dev/null   # lifecycle => you can hot-reload with POST /-/reload

  wait_ready "http://localhost:${PGW_PORT}/-/ready"  "Pushgateway"
  wait_ready "http://localhost:${PROM_PORT}/-/ready" "Prometheus"

  say "[3/5] Simulating a batch job PUSHING metrics to the gateway"
  # The grouping key in the URL (/job/<j>/instance/<i>) sets the pushed labels.
  cat <<EOF | curl -sf --data-binary @- \
      "http://localhost:${PGW_PORT}/metrics/job/backup_job/instance/db01" >/dev/null
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds $(date +%s)
# TYPE backup_duration_seconds gauge
backup_duration_seconds 42.7
EOF
  echo "Pushed: backup_last_success_timestamp_seconds, backup_duration_seconds  (job=backup_job, instance=db01)"

  say "[4/5] Waiting one scrape cycle so Prometheus pulls the gateway..."
  sleep 8

  say "[5/5] Demonstrating the SYMPTOM"
  echo
  echo "You expect to find your backup metric by its job. It is GONE:"
  echo '  $ curl -sG http://localhost:9090/api/v1/query \'
  echo '        --data-urlencode '\''query=backup_last_success_timestamp_seconds{job="backup_job"}'\'''
  curl -sG "http://localhost:${PROM_PORT}/api/v1/query" \
    --data-urlencode 'query=backup_last_success_timestamp_seconds{job="backup_job"}' | show_json
  echo
  echo "But the sample IS in the TSDB — under the WRONG labels (note exported_job):"
  echo '  $ curl -sG http://localhost:9090/api/v1/query \'
  echo '        --data-urlencode '\''query=backup_last_success_timestamp_seconds'\'''
  curl -sG "http://localhost:${PROM_PORT}/api/v1/query" \
    --data-urlencode 'query=backup_last_success_timestamp_seconds' | show_json

  cat <<'BRIEF'

============================================================================
  SYMPTOM  — what you just saw
----------------------------------------------------------------------------
  * `backup_last_success_timestamp_seconds{job="backup_job"}`  -> EMPTY.
  * The very same series exists, but carries:
        job="pushgateway"           <- the SCRAPE target's job (pull model)
        instance="pushgateway:9091" <- the SCRAPE target's instance
        exported_job="backup_job"   <- your real push label, demoted with a prefix
        exported_instance="db01"
  * Every alert rule, dashboard or recording rule that selects
    {job="backup_job"} silently matches NOTHING. This is the classic
    push-vs-pull label collision.

  YOUR GOAL  — the fix condition
----------------------------------------------------------------------------
  Make this query return the pushed value with its ORIGINAL identity:

      backup_last_success_timestamp_seconds{job="backup_job", instance="db01"}

  Constraint: the batch job and the push command may NOT change. Fix it purely
  on the Prometheus (pull) side, and apply it WITHOUT restarting Prometheus.

  Files & endpoints you have:
    * Config on disk:   /tmp/pca-3.4-push-vs-pull/prometheus.yml
    * Prometheus UI/API http://localhost:9090     (started with --web.enable-lifecycle)
    * Pushgateway UI    http://localhost:9091
  Inspect targets:  curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[].labels'

  When you think it works:  re-run the two queries above.
  Give up / reset:          FORCE=1 ./break-fix-3.4.sh   (rebuilds broken state)
  Tear the lab down:        ./break-fix-3.4.sh cleanup
============================================================================
BRIEF
}

# ---- dispatch --------------------------------------------------------------
case "${1:-setup}" in
  setup)   setup ;;
  cleanup) cleanup ;;
  *) die "usage: $0 [setup|cleanup]" ;;
esac


# ===========================================================================
#  SOLUTION — step by step   (read only after you have tried it yourself)
# ===========================================================================
#
#  ROOT CAUSE
#  ----------
#  Prometheus pulls. On every scrape it attaches the target's own `job` and
#  `instance` labels to each sample. The Pushgateway, however, is a store of
#  metrics that ALREADY carry job/instance (set by the batch job's push URL).
#  When those two identities collide, Prometheus' default policy is: the SCRAPE
#  (target-side) labels win, and the pre-existing pushed labels are kept but
#  renamed with an `exported_` prefix. So your batch series ends up as
#  {job="pushgateway", exported_job="backup_job", ...} — invisible to any
#  selector written against job="backup_job".
#
#  The Pushgateway is precisely the case the `honor_labels` scrape option was
#  invented for: it tells Prometheus "trust the labels the target already
#  exposes; do NOT overwrite them with the target's job/instance."
#
#  STEP 1 — Confirm the diagnosis (prove it is a label collision, not a missing
#           metric). The series exists, only mislabelled:
#
#      curl -sG http://localhost:9090/api/v1/query \
#        --data-urlencode 'query=backup_last_success_timestamp_seconds' | jq .
#      # -> job="pushgateway", exported_job="backup_job", exported_instance="db01"
#
#  STEP 2 — Edit the scrape config and set honor_labels on the pushgateway job:
#
#      # /tmp/pca-3.4-push-vs-pull/prometheus.yml
#      - job_name: 'pushgateway'
#        honor_labels: true          # <-- the fix: keep the PUSHED job/instance
#        static_configs:
#          - targets: ['pushgateway:9091']
#
#      One-liner (sed) to insert it right under the job name:
#      sed -i "/job_name: 'pushgateway'/a\\    honor_labels: true" \
#          /tmp/pca-3.4-push-vs-pull/prometheus.yml
#
#  STEP 3 — Hot-reload WITHOUT restarting (Prometheus was started with
#           --web.enable-lifecycle, so the reload endpoint is enabled):
#
#      curl -s -X POST http://localhost:9090/-/reload
#      # empty body + HTTP 200 on success.
#      # Verify it took the new config:
#      curl -s http://localhost:9090/api/v1/status/config | jq -r .data.yaml | grep -A2 pushgateway
#      # (If reload were disabled you'd get 403 "lifecycle APIs are not enabled"
#      #  and would instead: docker restart pca34-prometheus)
#
#  STEP 4 — Wait one scrape interval (~5s) and re-verify the fix condition:
#
#      curl -sG http://localhost:9090/api/v1/query \
#        --data-urlencode 'query=backup_last_success_timestamp_seconds{job="backup_job", instance="db01"}' | jq .
#      # Expected: a single result, value ~ the unix timestamp pushed,
#      #           labels {job="backup_job", instance="db01"} — no exported_ prefix.
#
#  WHY IT WORKS
#  ------------
#  honor_labels: true flips the collision policy for that one scrape job: the
#  labels the target already exposes take precedence, so the gateway's stored
#  job="backup_job"/instance="db01" survive the scrape untouched. This is the
#  ONLY correct setting for scraping a Pushgateway; use it nowhere else, because
#  on a normal exporter it would let a target impersonate any job/instance.
#
#  EXAM TAKEAWAYS (topic 3.4 — Push vs Pull)
#  -----------------------------------------
#    * Prometheus' native model is PULL: it scrapes targets and owns their
#      job/instance identity. Pushing is the exception, not the default.
#    * Use the Pushgateway ONLY for service-level batch/cron jobs too short-lived
#      to be scraped. It is an anti-pattern for long-running, scrapable services
#      (it hides `up`, breaks per-instance health, and persists stale metrics).
#    * A Pushgateway scrape job needs honor_labels: true; without it the pushed
#      job/instance are shadowed as exported_job / exported_instance.
#    * Pushed metrics live forever in the gateway until deleted
#      (DELETE /metrics/job/<j>/instance/<i>) or the gateway restarts — the pull
#      model's automatic staleness does NOT apply to them.
#    * Prefer `--web.enable-lifecycle` + POST /-/reload for config changes over a
#      full restart, to avoid a scrape/eval gap.
#
#  SOURCES (official)
#  ------------------
#    * Pushing metrics / when to use it:  https://prometheus.io/docs/instrumenting/pushing/
#    * When NOT to use the Pushgateway:   https://prometheus.io/docs/practices/pushing/
#    * scrape_config & honor_labels:      https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
#    * Pushgateway (honor_labels note):   https://github.com/prometheus/pushgateway#about-the-pushgateway
#    * Lifecycle / reload endpoint:       https://prometheus.io/docs/prometheus/latest/management_api/
#    * PCA curriculum:                    https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
# ===========================================================================