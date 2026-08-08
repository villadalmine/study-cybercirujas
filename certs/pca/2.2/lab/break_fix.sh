#!/usr/bin/env bash
#
# =============================================================================
#  Prometheus Certified Associate (PCA)
#  Domain 2 — Prometheus Fundamentals
#  Topic 2.2 — Configuration and Scraping   (exam weight: 4)
#
#  BREAK & FIX LAB — "The vanishing target"
#
#  This script provisions a tiny, self-contained Prometheus + node_exporter
#  stack inside a lab directory, proves the node target is being scraped, and
#  then INTENTIONALLY BREAKS the scrape configuration in one specific, common,
#  and realistic way. It prints the symptom you will observe and the goal you
#  must reach. The fully commented, step-by-step solution is at the END of the
#  file — try to solve it before reading it.
#
#  RUN THIS ONLY ON A DISPOSABLE LAB VM. It binds to 127.0.0.1 and writes only
#  under $LAB_DIR, but it starts background processes and rewrites a config on
#  purpose. Do not point it at a production Prometheus.
#
#  Official references:
#    - Configuration reference:
#        https://prometheus.io/docs/prometheus/latest/configuration/configuration/
#    - relabel_config:
#        https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
#    - Management API (config reload):
#        https://prometheus.io/docs/prometheus/latest/management_api/
#    - Querying HTTP API:
#        https://prometheus.io/docs/prometheus/latest/querying/api/
#    - PCA curriculum:
#        https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
# =============================================================================

set -euo pipefail

# ------------------------------- parameters ---------------------------------
LAB_DIR="${LAB_DIR:-$HOME/pca-lab-2.2}"
PROM_VERSION="${PROM_VERSION:-2.53.1}"
NODE_VERSION="${NODE_VERSION:-1.8.2}"
PROM_ADDR="127.0.0.1:9090"
NODE_ADDR="127.0.0.1:9100"
PROM_URL="http://${PROM_ADDR}"

# ------------------------------- helpers ------------------------------------
say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

# HTTP GET that never aborts the script under `set -e`
http_get() { curl -sf --max-time 5 "$@" 2>/dev/null || true; }

# ------------------------------ lifecycle -----------------------------------
stop_stack() {
  for name in prometheus node_exporter; do
    local pidfile="$LAB_DIR/${name}.pid"
    if [[ -f "$pidfile" ]]; then
      local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$pidfile"
    fi
  done
}

provision() {
  local arch; arch="$(detect_arch)"
  mkdir -p "$LAB_DIR/data"
  cd "$LAB_DIR"

  local prom_dir="prometheus-${PROM_VERSION}.linux-${arch}"
  local node_dir="node_exporter-${NODE_VERSION}.linux-${arch}"

  if [[ ! -x "$LAB_DIR/$prom_dir/prometheus" ]]; then
    say "Downloading Prometheus v${PROM_VERSION} (${arch})"
    curl -fL -o prom.tgz \
      "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${prom_dir}.tar.gz"
    tar xzf prom.tgz && rm -f prom.tgz
  fi

  if [[ ! -x "$LAB_DIR/$node_dir/node_exporter" ]]; then
    say "Downloading node_exporter v${NODE_VERSION} (${arch})"
    curl -fL -o node.tgz \
      "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/${node_dir}.tar.gz"
    tar xzf node.tgz && rm -f node.tgz
  fi

  PROM_BIN="$LAB_DIR/$prom_dir/prometheus"
  PROMTOOL="$LAB_DIR/$prom_dir/promtool"
  NODE_BIN="$LAB_DIR/$node_dir/node_exporter"

  # Write the KNOWN-GOOD configuration. This is also the reference the student
  # will compare against once the fault is injected.
  cat > "$LAB_DIR/prometheus.yml" <<'YAML'
global:
  scrape_interval: 5s
  scrape_timeout: 4s
  evaluation_interval: 15s

scrape_configs:
  # Prometheus scraping itself — this target must STAY up the whole time.
  # It is your control: if it is up but 'node' is gone, the fault is scoped
  # to the node job, not to Prometheus as a whole.
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']

  # The node_exporter target. This is the one that will vanish.
  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']
        labels:
          env: lab
YAML

  cp -f "$LAB_DIR/prometheus.yml" "$LAB_DIR/prometheus.good.yml"
}

start_stack() {
  say "Starting node_exporter on ${NODE_ADDR}"
  nohup "$NODE_BIN" --web.listen-address="$NODE_ADDR" \
    > "$LAB_DIR/node_exporter.log" 2>&1 &
  echo $! > "$LAB_DIR/node_exporter.pid"

  say "Starting Prometheus on ${PROM_ADDR} (lifecycle API enabled)"
  nohup "$PROM_BIN" \
    --config.file="$LAB_DIR/prometheus.yml" \
    --storage.tsdb.path="$LAB_DIR/data" \
    --web.listen-address="$PROM_ADDR" \
    --web.enable-lifecycle \
    > "$LAB_DIR/prometheus.log" 2>&1 &
  echo $! > "$LAB_DIR/prometheus.pid"
}

wait_ready() {
  say "Waiting for Prometheus to become ready"
  for _ in $(seq 1 30); do
    if [[ "$(http_get "${PROM_URL}/-/ready")" == *"Prometheus"* ]]; then
      return 0
    fi
    sleep 1
  done
  die "Prometheus did not become ready — inspect $LAB_DIR/prometheus.log"
}

# Reload config through the management API (requires --web.enable-lifecycle).
reload_config() {
  curl -sf -X POST "${PROM_URL}/-/reload" >/dev/null \
    || die "Config reload was REJECTED — check syntax with promtool (see below)"
}

# Return 0 when up{job="node"} evaluates to exactly 1 (target scraped & healthy).
node_target_up() {
  local out
  out="$(http_get --get "${PROM_URL}/api/v1/query" \
        --data-urlencode 'query=up{job="node"}')"
  [[ "$out" == *'"value":['*',"1"]'* ]]
}

# Return 0 when the node job has NO active target at all (empty result vector).
node_target_gone() {
  local out
  out="$(http_get --get "${PROM_URL}/api/v1/query" \
        --data-urlencode 'query=up{job="node"}')"
  [[ "$out" == *'"result":[]'* ]]
}

poll() {  # poll <predicate-fn> <timeout-seconds>
  local fn="$1" timeout="$2"
  for _ in $(seq 1 "$timeout"); do
    if "$fn"; then return 0; fi
    sleep 1
  done
  return 1
}

# --------------------------- the intentional break --------------------------
break_it() {
  say "Injecting the fault into $LAB_DIR/prometheus.yml"

  # We add a relabel_configs stage to the 'node' job. relabel_configs runs
  # DURING service discovery, BEFORE the scrape happens, so a matching
  # 'drop' action removes the target from the scrape set entirely — it will
  # not even appear as DOWN. This is the whole point of the exercise for 2.2:
  # relabeling shapes WHICH targets get scraped, not just their labels.
  cat > "$LAB_DIR/prometheus.yml" <<'YAML'
global:
  scrape_interval: 5s
  scrape_timeout: 4s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']

  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']
        labels:
          env: lab
    relabel_configs:
      - source_labels: [__address__]
        regex: '(.*):9100'
        action: drop
YAML

  reload_config
}

explain() {
  cat <<EOF

===============================================================================
  BREAK & FIX  —  PCA 2.2 Configuration and Scraping
  Scenario: "The vanishing target"
===============================================================================

WHAT JUST HAPPENED
  A working Prometheus was scraping two targets:
    - job "prometheus"  (127.0.0.1:9090)  -> healthy
    - job "node"        (127.0.0.1:9100)  -> healthy
  The configuration was then edited and reloaded. One target is now gone.

THE SYMPTOM YOU WILL SEE
  * Open the targets page:   ${PROM_URL}/targets
    - The "prometheus" job is still UP.
    - The "node" job shows 0 active targets — not DOWN, GONE. There is no
      red target, no "connection refused", no error string to click. It has
      simply disappeared from the scrape pool.
  * In the expression browser (${PROM_URL}/graph), run:
        up{job="node"}
    It returns "Empty query result". Every node_exporter series
    (node_cpu_seconds_total, node_filesystem_avail_bytes, ...) is now absent.
  * node_exporter itself is FINE — confirm it is still serving metrics:
        curl -s ${NODE_ADDR%:*}:${NODE_ADDR#*:}/metrics | head
    So the exporter is up; Prometheus is deliberately not scraping it.

  This "no error, target just absent" fingerprint is what distinguishes a
  RELABELING problem from a connectivity problem (which would show the target
  as DOWN with an explicit scrape error).

YOUR GOAL
  Make the node target return to the scrape pool and stay healthy:
        up{job="node"} == 1
  and the "node" job visible and UP on ${PROM_URL}/targets, WITHOUT restarting
  or reinstalling anything — fix the configuration and reload it live.

USEFUL FIRST MOVES (no spoilers)
  * See the config Prometheus is actually running (not the file on disk):
        curl -s ${PROM_URL}/api/v1/status/config
  * Ask WHY discovery dropped it — the service-discovery view shows targets
    before relabeling and whether they were kept or dropped:
        ${PROM_URL}/service-discovery
  * The config file to edit:      $LAB_DIR/prometheus.yml
  * The known-good reference:     $LAB_DIR/prometheus.good.yml
  * Validate before reloading:    $LAB_DIR/$(basename "$(dirname "$PROMTOOL")")/promtool check config $LAB_DIR/prometheus.yml
  * Apply your fix live:          curl -X POST ${PROM_URL}/-/reload

  Tear the lab down when finished:   $0 --teardown
===============================================================================
EOF
}

# --------------------------------- main -------------------------------------
main() {
  need_cmd curl
  need_cmd tar
  need_cmd uname

  case "${1:-}" in
    --teardown)
      say "Stopping the lab stack"
      stop_stack
      say "Done. Lab files remain under $LAB_DIR (delete it to reclaim disk)."
      exit 0
      ;;
    --reset)
      warn "Resetting: stopping stack and wiping TSDB data"
      stop_stack
      rm -rf "${LAB_DIR:?}/data"
      ;;
  esac

  if [[ "${PCA_LAB_CONFIRM:-}" != "yes" ]]; then
    warn "This starts a local Prometheus lab and INTENTIONALLY breaks it."
    warn "Only continue on a disposable VM."
    read -r -p "Type 'break' to proceed: " ans
    [[ "$ans" == "break" ]] || die "Aborted by user."
  fi

  provision
  stop_stack            # ensure a clean slate; makes the script idempotent
  start_stack
  wait_ready

  # Always begin from the known-good config so the break is deterministic.
  cp -f "$LAB_DIR/prometheus.good.yml" "$LAB_DIR/prometheus.yml"
  reload_config

  say "Verifying the node target is healthy BEFORE we break anything"
  if poll node_target_up 30; then
    say "Confirmed: up{job=\"node\"} == 1. Baseline is healthy."
  else
    die "Baseline never became healthy — inspect $LAB_DIR/*.log before continuing"
  fi

  break_it

  say "Confirming the fault took effect"
  if poll node_target_gone 20; then
    say "Fault confirmed: the node target has vanished from the scrape pool."
  else
    warn "Expected the node target to disappear but it is still present."
    warn "Check $LAB_DIR/prometheus.log — the reload may have been rejected."
  fi

  explain
}

main "$@"

# =============================================================================
#  SOLUTION — step by step  (read only after you have tried)
# =============================================================================
#
#  ROOT CAUSE
#  ----------
#  A relabel_configs stage was added to the "node" job:
#
#      relabel_configs:
#        - source_labels: [__address__]
#          regex: '(.*):9100'
#          action: drop
#
#  relabel_configs is applied during target discovery, BEFORE scraping. Each
#  rule can rewrite labels or, with action: keep / drop, decide whether the
#  target survives into the scrape pool at all. Here the rule matches the
#  target's __address__ meta-label (127.0.0.1:9100) against '(.*):9100' and
#  DROPS it. Because the target is discarded at discovery time, it never
#  becomes a scrape target — so it shows as neither UP nor DOWN; it is simply
#  absent. That is the tell-tale signature of a relabeling fault versus a
#  network/port/path fault (which would leave a visible DOWN target with an
#  explicit error message).
#
#  DIAGNOSIS PATH
#  --------------
#  1. Compare against the control. On ${PROM_URL}/targets the "prometheus"
#     job is UP but the "node" job has 0 active targets. Prometheus itself is
#     healthy, so the problem is scoped to one job's configuration.
#
#  2. Confirm the exporter is innocent:
#         curl -s 127.0.0.1:9100/metrics | head
#     It returns metrics, so the target is reachable — Prometheus is choosing
#     not to scrape it.
#
#  3. Look at the running config, not just the file:
#         curl -s ${PROM_URL}/api/v1/status/config
#     You will see the relabel_configs drop rule under the node job.
#
#  4. Use the service-discovery view to see the decision explicitly:
#         ${PROM_URL}/service-discovery
#     The node target appears under "Discovered" with __address__=127.0.0.1:9100
#     but is shown as dropped (not among active targets), pointing straight at
#     relabeling as the cause.
#
#  FIX
#  ---
#  1. Edit the config file:
#         $EDITOR "$LAB_DIR/prometheus.yml"
#     Remove the offending block from the "node" job (delete the whole
#     relabel_configs stanza), so the job reads:
#
#         - job_name: node
#           static_configs:
#             - targets: ['127.0.0.1:9100']
#               labels:
#                 env: lab
#
#     (Shortcut for the lab: copy the reference back:
#         cp "$LAB_DIR/prometheus.good.yml" "$LAB_DIR/prometheus.yml"  )
#
#     Note: had the intent been to KEEP only :9100 targets, the correct rule is
#     `action: keep` — `drop` and `keep` are exact inverses. Mixing them up is
#     the single most common relabeling mistake on the exam.
#
#  2. Validate BEFORE reloading (never reload an unparsed file):
#         "$LAB_DIR"/prometheus-*/promtool check config "$LAB_DIR/prometheus.yml"
#     Expect: "SUCCESS: 1 rule files found ..." / config file is valid.
#
#  3. Apply the change live — no restart needed because Prometheus was started
#     with --web.enable-lifecycle:
#         curl -X POST ${PROM_URL}/-/reload
#     Equivalent without the lifecycle flag:
#         kill -HUP "$(cat "$LAB_DIR/prometheus.pid")"
#     A rejected reload returns HTTP 400 and Prometheus keeps the OLD config —
#     read $LAB_DIR/prometheus.log for the exact line/column of the error.
#
#  4. Verify the fix (allow up to one scrape_interval, 5s here):
#         curl -sG "${PROM_URL}/api/v1/query" \
#              --data-urlencode 'query=up{job="node"}'
#     Expect a single sample with value "1". On ${PROM_URL}/targets the "node"
#     job is UP again, and node_* series reappear in the expression browser.
#
#  WHY THIS MATTERS FOR 2.2
#  ------------------------
#  Configuration and Scraping is not only "list targets in static_configs". The
#  scrape pipeline is: discover -> relabel_configs (shape/keep/drop targets) ->
#  scrape -> metric_relabel_configs (shape/keep/drop samples). A rule in the
#  wrong stage, or drop/keep inverted, silently changes WHAT gets monitored
#  with no error anywhere. Sibling failure modes worth reproducing on this same
#  lab (change one line, reload, observe /targets):
#    * wrong metrics_path (e.g. /wrong) -> target DOWN, error "404 Not Found".
#    * wrong port        (e.g. :9101)   -> target DOWN, "connection refused".
#    * scheme: https on an http target  -> DOWN, "http: server gave HTTP
#      response to HTTPS client".
#    * scrape_timeout > scrape_interval -> reload REJECTED, config never loads.
#  Learn to read the symptom back to the exact stage that produced it.
# =============================================================================