#!/usr/bin/env bash
#
# PCA Certification — Topic 1.5 "Binary operators" (exam weight: 4)
# Break & Fix lab — PromQL binary operators and vector matching
#
# WHAT THIS TEACHES
#   PromQL binary operators (arithmetic +-*/%^, comparison ==,!=,>,<,>=,<=,
#   and set/logical and,or,unless) do NOT combine two instant vectors blindly.
#   When both operands are instant vectors, Prometheus performs *vector
#   matching*: for every series on one side it looks for a series with an
#   identical label set on the other side. Getting the matching wrong is the
#   single most common real-world PromQL mistake, and it is exactly what
#   on()/ignoring() and group_left()/group_right() exist to control.
#
# WHAT THIS SCRIPT DOES
#   Stands up a fully self-contained, throwaway Prometheus on 127.0.0.1:9099
#   (its own data dir, its own config, it will NOT touch any system service)
#   plus a tiny metrics exposer on 127.0.0.1:9109. It then loads a *recording
#   rule* that divides two vectors with a broken matching clause. The config
#   parses cleanly and promtool is happy — the break only surfaces at
#   evaluation time, which is precisely how this bug bites you in production.
#
# SAFETY
#   - Everything lives under a single lab dir and two loopback-only ports.
#   - No systemd unit, package, or file outside the lab dir is modified.
#   - `stop` tears the whole thing down and deletes the lab dir.
#   Intended for a DISPOSABLE lab VM. Do not run against a shared host.
#
# USAGE
#   ./pca-1.5-break-and-fix.sh up       # build lab and break it (default)
#   ./pca-1.5-break-and-fix.sh status   # show the rule health + recorded series
#   ./pca-1.5-break-and-fix.sh stop     # tear down and clean everything
#
# Reference sources:
#   PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#   PromQL operators & vector matching:
#     https://prometheus.io/docs/prometheus/latest/querying/operators/

set -euo pipefail

LAB_DIR="${PCA_LAB_DIR:-/tmp/pca-lab-1.5}"
PROM_ADDR="127.0.0.1:9099"
PROM_URL="http://${PROM_ADDR}"
EXPO_ADDR="127.0.0.1:9109"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:latest}"
CONTAINER_NAME="pca-lab-prom"
RULE_NAME="service:request_error_ratio"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- runtime selection: prefer a local prometheus binary, else a container ---
select_runtime() {
  if have prometheus && have promtool; then
    RUNTIME="binary"
  elif have podman; then
    RUNTIME="container"; CT="podman"
  elif have docker; then
    RUNTIME="container"; CT="docker"
  else
    die "Need either the 'prometheus'+'promtool' binaries in PATH, or podman/docker.
     Grab them from https://prometheus.io/download/ and re-run."
  fi
}

require_common() {
  have python3 || die "python3 is required (used for the metrics exposer and JSON parsing)."
  have curl    || die "curl is required."
}

# --- write all lab files (idempotent: 'up' always rewrites a fresh break) ----
write_files() {
  mkdir -p "$LAB_DIR/data"

  # Tiny exposer. It answers every path with a fixed set of series, using the
  # correct Prometheus text exposition Content-Type so parsing never depends on
  # MIME guessing.
  cat > "$LAB_DIR/exposer.py" <<'PYEOF'
import http.server, socketserver

METRICS = b"""# HELP app_requests_total Total requests handled per service.
# TYPE app_requests_total counter
app_requests_total{service="checkout"} 1000
app_requests_total{service="catalog"} 5000
app_requests_total{service="payments"} 800
# HELP app_errors_total Errors per service and HTTP status code.
# TYPE app_errors_total counter
app_errors_total{service="checkout",code="500"} 30
app_errors_total{service="checkout",code="503"} 10
app_errors_total{service="catalog",code="500"} 25
app_errors_total{service="payments",code="500"} 8
app_errors_total{service="payments",code="502"} 4
"""

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(METRICS)))
        self.end_headers()
        self.wfile.write(METRICS)
    def log_message(self, *a):
        pass

with socketserver.TCPServer(("127.0.0.1", 9109), H) as srv:
    srv.serve_forever()
PYEOF

  cat > "$LAB_DIR/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s
rule_files:
  - rules.yml
scrape_configs:
  - job_name: pca-lab-app
    static_configs:
      - targets: ['${EXPO_ADDR}']
EOF

  # THE BREAK.
  # We want a per-service error ratio: errors / requests.
  #   - app_requests_total has label set {service}              (one series per service)
  #   - app_errors_total   has label set {service, code}        (several per service)
  # `on(service)` tells Prometheus to match ONLY on `service`. That makes the
  # right side (requests) unique per service, but the left side (errors) has
  # many series per service -> a many-to-one match with no declared direction.
  # Prometheus refuses to guess: the rule fails to evaluate.
  cat > "$LAB_DIR/rules.yml" <<EOF
groups:
  - name: pca-lab-binary-operators
    interval: 5s
    rules:
      - record: ${RULE_NAME}
        expr: app_errors_total / on(service) app_requests_total
EOF
}

# --- validate config the way the exam expects: promtool check rules ----------
check_rules() {
  log "Validating rules with promtool (this SUCCEEDS — the break is at eval time, not parse time)"
  if [ "$RUNTIME" = "binary" ]; then
    promtool check rules "$LAB_DIR/rules.yml" || die "promtool reported a syntax error (unexpected)."
  else
    "$CT" run --rm -v "$LAB_DIR/rules.yml":/rules.yml:ro --entrypoint promtool "$PROM_IMAGE" \
      check rules /rules.yml || die "promtool reported a syntax error (unexpected)."
  fi
}

# --- process management ------------------------------------------------------
teardown_procs() {
  if [ -f "$LAB_DIR/exposer.pid" ]; then
    kill "$(cat "$LAB_DIR/exposer.pid")" 2>/dev/null || true
    rm -f "$LAB_DIR/exposer.pid"
  fi
  if [ -f "$LAB_DIR/prometheus.pid" ]; then
    kill "$(cat "$LAB_DIR/prometheus.pid")" 2>/dev/null || true
    rm -f "$LAB_DIR/prometheus.pid"
  fi
  for ct in podman docker; do
    command -v "$ct" >/dev/null 2>&1 && "$ct" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  done
}

start_exposer() {
  log "Starting metrics exposer on ${EXPO_ADDR}"
  nohup python3 "$LAB_DIR/exposer.py" >"$LAB_DIR/exposer.log" 2>&1 &
  echo $! > "$LAB_DIR/exposer.pid"
  sleep 1
  curl -sf "http://${EXPO_ADDR}/metrics" >/dev/null \
    || die "exposer did not come up — see $LAB_DIR/exposer.log"
}

start_prometheus() {
  log "Starting a private Prometheus on ${PROM_ADDR}"
  if [ "$RUNTIME" = "binary" ]; then
    nohup prometheus \
      --config.file="$LAB_DIR/prometheus.yml" \
      --storage.tsdb.path="$LAB_DIR/data" \
      --web.listen-address="$PROM_ADDR" \
      --web.enable-lifecycle \
      --log.level=warn >"$LAB_DIR/prometheus.log" 2>&1 &
    echo $! > "$LAB_DIR/prometheus.pid"
  else
    "$CT" run -d --name "$CONTAINER_NAME" --network host \
      -v "$LAB_DIR/prometheus.yml":/etc/prometheus/prometheus.yml:ro \
      -v "$LAB_DIR/rules.yml":/etc/prometheus/rules.yml:ro \
      "$PROM_IMAGE" \
      --config.file=/etc/prometheus/prometheus.yml \
      --web.listen-address="$PROM_ADDR" \
      --web.enable-lifecycle >/dev/null \
      || die "failed to start Prometheus container"
  fi
}

wait_ready() {
  log "Waiting for Prometheus to become ready"
  for _ in $(seq 1 30); do
    curl -sf "${PROM_URL}/-/ready" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Prometheus never became ready — check $LAB_DIR/prometheus.log (binary) or '${CT:-docker} logs $CONTAINER_NAME' (container)."
}

wait_first_eval() {
  # The rule health is 'unknown' until the group evaluates once. Wait for it to
  # flip to 'err' (or 'ok', if the student already fixed it before re-running).
  for _ in $(seq 1 20); do
    local h
    h="$(rule_health)"
    [ "$h" = "err" ] || [ "$h" = "ok" ] && return 0
    sleep 1
  done
}

rule_health() {
  curl -s "${PROM_URL}/api/v1/rules" 2>/dev/null | python3 - "$RULE_NAME" <<'PY'
import sys, json
name = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit(0)
for g in d.get("data", {}).get("groups", []):
    for r in g.get("rules", []):
        if r.get("name") == name:
            print(r.get("health", "unknown")); sys.exit(0)
print("unknown")
PY
}

# --- observable state: rule health, last error, recorded series count --------
status() {
  select_runtime; require_common
  [ -d "$LAB_DIR" ] || die "No lab found at $LAB_DIR. Run '$0 up' first."

  echo
  echo "----------------------------------------------------------------------"
  echo " PCA 1.5 lab — current state of recording rule '$RULE_NAME'"
  echo "----------------------------------------------------------------------"

  curl -s "${PROM_URL}/api/v1/rules" | python3 - "$RULE_NAME" <<'PY'
import sys, json
name = sys.argv[1]
d = json.load(sys.stdin)
found = False
for g in d.get("data", {}).get("groups", []):
    for r in g.get("rules", []):
        if r.get("name") == name:
            found = True
            print(f"  expr      : {r.get('query','')}")
            print(f"  health    : {r.get('health','unknown')}")
            le = (r.get('lastError') or '').strip()
            print(f"  lastError : {le if le else '(none)'}")
if not found:
    print("  rule not found (is Prometheus up? run '"+__import__('os').path.basename(sys.argv[0])+" up')")
PY

  local n
  n="$(curl -s -G "${PROM_URL}/api/v1/query" \
        --data-urlencode "query=${RULE_NAME}" \
        | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",{}).get("result",[])))' 2>/dev/null || echo 0)"
  echo "  recorded series produced now: ${n}"
  if [ "$n" -eq 0 ]; then
    echo "  => BROKEN: the binary operation matched nothing (or errored). Goal not yet met."
  else
    echo "  => FIXED:  the vector matching now yields ${n} series. Well done."
  fi
  echo "----------------------------------------------------------------------"
  echo
}

# --- main break flow ---------------------------------------------------------
up() {
  select_runtime; require_common
  log "Runtime: $RUNTIME   Lab dir: $LAB_DIR"
  teardown_procs
  write_files
  check_rules
  start_exposer
  start_prometheus
  wait_ready
  wait_first_eval

  cat <<EOF

######################################################################
#  PCA 1.5 — BINARY OPERATORS — BREAK IS ACTIVE
######################################################################

Open the UI:            ${PROM_URL}/graph
Rules page (symptom):   ${PROM_URL}/rules
Raw metrics source:     http://${EXPO_ADDR}/metrics

THE SYMPTOM YOU WILL SEE
  A recording rule named:
      ${RULE_NAME}  =  app_errors_total / on(service) app_requests_total
  is loaded, but on the /rules page it is RED / in "err" state, and its
  recorded time series is empty. promtool check rules said SUCCESS, so the
  problem is not a typo — it is the semantics of the binary '/' operation.
  The last error will read roughly:
      "found duplicate series for the match group {service=\"checkout\"}
       on the many side of the operation ... many-to-one matching must be
       explicit (group_left/group_right)"
  (exact wording varies slightly by Prometheus version.)

WHAT YOU MUST ACHIEVE (the challenge)
  Rewrite ONLY the 'expr:' of the rule in:
      ${LAB_DIR}/rules.yml
  so that '${RULE_NAME}' evaluates cleanly (health "ok") and produces one
  error-ratio series per service (a value strictly between 0 and 1).
  You may NOT change the exposed metrics — fix it purely in PromQL, using the
  binary-operator matching modifiers this topic is about.

HOW TO INVESTIGATE
  In ${PROM_URL}/graph run each side on its own and read the labels:
      app_requests_total        -> label set {service}
      app_errors_total          -> label set {service, code}
  The two sides do not share the same label set, and one side has several
  series per 'service'. Ask yourself: on WHICH labels should they match, and
  in WHICH direction is the many-to-one relationship?

APPLY YOUR FIX
  1) edit ${LAB_DIR}/rules.yml
  2) validate:  promtool check rules ${LAB_DIR}/rules.yml
                (container: ${CT:-docker} run --rm -v ${LAB_DIR}/rules.yml:/r.yml:ro \\
                            --entrypoint promtool ${PROM_IMAGE} check rules /r.yml)
  3) reload:    curl -X POST ${PROM_URL}/-/reload
  4) verify:    $0 status

WHEN FINISHED
  $0 stop        # remove the lab and its data

The worked solution is in the comments at the very bottom of this script —
try it yourself before you look.
######################################################################
EOF
}

stop() {
  select_runtime 2>/dev/null || true
  log "Tearing down the PCA 1.5 lab"
  teardown_procs
  rm -rf "$LAB_DIR"
  log "Removed $LAB_DIR. Lab fully cleaned."
}

case "${1:-up}" in
  up|break|start) up ;;
  status|check)   status ;;
  stop|clean|down) stop ;;
  *) die "Unknown command '$1'. Use: up | status | stop" ;;
esac

# =============================================================================
# SOLUTION — step by step (read only after you have tried it)
# =============================================================================
#
# WHY IT BREAKS
#   Binary operators between two instant vectors do VECTOR MATCHING. By default
#   ("one-to-one") a series on the left is paired with the series on the right
#   that has an IDENTICAL label set (metric name excluded). Here the sides are:
#       app_errors_total{service,code}   /   app_requests_total{service}
#   The `on(service)` modifier narrows matching to just `service`. That makes
#   the right side unique per service, but the left side still has several
#   series per service (one per `code`). So each right series would match many
#   left series: a many-to-one relationship. Prometheus will not silently pick
#   a direction — you must declare it with group_left / group_right, or remove
#   the ambiguity by aggregating first. Until you do, the rule errors and its
#   recorded series is empty.
#
# HOW TO CONFIRM THE DIAGNOSIS
#   1) ./pca-1.5-break-and-fix.sh status
#         -> health: err ; lastError mentions "many-to-one matching must be
#            explicit (group_left/group_right)" ; recorded series: 0
#   2) In ${PROM_URL}/graph:
#         app_requests_total   -> 3 series, labels {service}
#         app_errors_total     -> 5 series, labels {service, code}
#      Different label sets, and >1 error series per service. That is the tell.
#
# FIX OPTION A — keep the per-(service,code) granularity (LEFT is the many side)
#   Edit ${LAB_DIR}/rules.yml, expr becomes:
#
#       expr: app_errors_total / on(service) group_left app_requests_total
#
#   `group_left` declares that the LEFT vector is the "many" side; each error
#   series is divided by its service's request total, and the extra left-side
#   label `code` is carried into the result. Result: 5 series.
#   Equivalent using ignoring() instead of on() (match on everything EXCEPT the
#   label that differs):
#
#       expr: app_errors_total / ignoring(code) group_left app_requests_total
#
#   Tip: `group_left(label...)` can also COPY labels from the one side, e.g.
#   `group_left(region)` would pull a `region` label off the right vector into
#   the output — useful for enrichment joins.
#
# FIX OPTION B — one ratio per service (aggregate the many side away first)
#   Collapse the `code` dimension so both sides are one-to-one on {service};
#   then no on()/group_left is needed at all:
#
#       expr: sum by(service) (app_errors_total) / app_requests_total
#
#   `sum by(service)` yields exactly {service}, identical to the request vector,
#   so default one-to-one matching just works. Result: 3 series. (You could also
#   spell it `sum by(service)(app_errors_total) / on(service) app_requests_total`.)
#
# APPLY AND VERIFY
#   promtool check rules ${LAB_DIR}/rules.yml        # SUCCESS
#   curl -X POST ${PROM_URL}/-/reload                # hot reload, no restart
#   ./pca-1.5-break-and-fix.sh status                # health: ok, series > 0
#
# EXAM TAKEAWAYS FOR TOPIC 1.5 (Binary operators)
#   * Categories: arithmetic (+ - * / % ^), comparison (== != > < >= <=),
#     and logical/set (and, or, unless). Comparison ops filter by default; add
#     the `bool` modifier (e.g. `up == bool 1`) to return 0/1 instead of filtering.
#   * vector-vector ops need matching; scalar-vector ops apply elementwise.
#   * on(<labels>)      -> match ONLY on the listed labels.
#     ignoring(<labels>)-> match on everything EXCEPT the listed labels.
#   * group_left / group_right -> declare the "many" side for many-to-one /
#     one-to-many joins; the optional label list copies labels from the "one"
#     side into the result. Many-to-many is only legal with `and`/`or`/`unless`.
#   * Operator precedence (high->low): ^ ; * / % ; + - ; == != <= < >= > ;
#     and unless ; or. `^` is right-associative; use parentheses when in doubt.
#   Source: https://prometheus.io/docs/prometheus/latest/querying/operators/
# =============================================================================