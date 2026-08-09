#!/usr/bin/env bash
#
# ==============================================================================
#  PCA — Prometheus Certified Associate
#  Domain 3: PromQL / Observability fundamentals
#  Topic 3.6 — Basics of SLOs, SLAs, and SLIs   (exam weight: 3)
#
#  Break & Fix lab:  "The SLO alert that never fires"
#
#  Reference (official):
#    - CNCF PCA Curriculum:
#        https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#    - Prometheus recording rules:
#        https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
#    - Prometheus alerting rules:
#        https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
#    - Google SRE Workbook, "Alerting on SLOs" (multiwindow, multi-burn-rate):
#        https://sre.google/workbook/alerting-on-slos/
# ==============================================================================
#
#  CONCEPTS THIS LAB EXERCISES
#  ---------------------------
#  SLI  (Service Level Indicator): a *measured* number describing how good the
#       service is right now. Here: availability = good_requests / total_requests,
#       expressed as its complement, the ERROR RATIO = 5xx_rate / total_rate.
#
#  SLO  (Service Level Objective): the *internal target* for that SLI over a
#       window. Here: 99.9% availability over 30 days  ->  error budget = 0.001
#       (0.1% of requests are allowed to fail before the objective is missed).
#
#  SLA  (Service Level Agreement): the *external, contractual* promise with
#       consequences (credits/penalties). Typically LOOSER than the SLO, e.g.
#       99.5%. You never page on the SLA directly; you page on the SLO so you
#       have headroom to react before the contract is breached.
#
#  ERROR BUDGET = 1 - SLO. BURN RATE = how many times faster than "sustainable"
#       you are consuming that budget. A 14.4x fast burn over a short window
#       means the whole 30-day budget would be gone in ~2 days -> page.
#
#  The whole point of the topic is the CHAIN:
#       raw metric  ->  SLI (recording rule)  ->  SLO threshold  ->  burn-rate
#       alert (alerting rule).
#  If ANY link is silently wrong, the service can be on fire and the pager
#  stays quiet. That is exactly the failure this lab injects.
#
#  SAFETY
#  ------
#  - Everything lives under a single disposable directory ($LAB_DIR).
#  - Both processes bind ONLY to 127.0.0.1 (no exposure on the network).
#  - No root, no package manager, no system services touched.
#  - `./slo-breakfix.sh clean` stops the processes and deletes the lab dir.
#  Run this on a throwaway lab VM. Do not point it at anything real.
# ==============================================================================

set -euo pipefail

# ------------------------------- configuration --------------------------------
LAB_DIR="${SLO_LAB_DIR:-$HOME/slo-lab}"
BIN_DIR="$LAB_DIR/bin"
STATE_DIR="$LAB_DIR/state"
PROM_VERSION="${PROM_VERSION:-2.53.2}"     # 2.53 LTS
PROM_ADDR="127.0.0.1:9090"
EXPORTER_ADDR="127.0.0.1:9109"
OUTAGE_FLAG="$STATE_DIR/outage"

# ------------------------------- small helpers --------------------------------
log()  { printf '\033[1;36m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[lab]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[lab]\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

port_busy() {
  # returns 0 if something is already listening on 127.0.0.1:<port>
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${port}\b|\*:${port}\b|0\.0\.0\.0:${port}\b"
  else
    (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1
  fi
}

fetch_prometheus() {
  # Idempotent: only downloads if prometheus/promtool are not already present.
  if [[ -x "$BIN_DIR/prometheus" && -x "$BIN_DIR/promtool" ]]; then
    return 0
  fi
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported architecture: $arch (install prometheus/promtool into $BIN_DIR manually)" ;;
  esac
  local pkg="prometheus-${PROM_VERSION}.linux-${arch}"
  local url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${pkg}.tar.gz"
  require curl; require tar
  log "downloading Prometheus ${PROM_VERSION} (${arch}) ..."
  mkdir -p "$BIN_DIR"
  curl -fsSL "$url" -o "$LAB_DIR/${pkg}.tar.gz" \
    || die "download failed. On an offline VM, drop 'prometheus' and 'promtool' into $BIN_DIR yourself."
  tar -xzf "$LAB_DIR/${pkg}.tar.gz" -C "$LAB_DIR"
  cp "$LAB_DIR/${pkg}/prometheus" "$LAB_DIR/${pkg}/promtool" "$BIN_DIR/"
  rm -rf "$LAB_DIR/${pkg}" "$LAB_DIR/${pkg}.tar.gz"
}

# --------------------------- lab artifact generators --------------------------
write_exporter() {
  # A tiny synthetic service. It has NO real traffic; a background ticker just
  # advances two counters so that rate() is meaningful. When the outage flag
  # exists, 5xx starts climbing at the same rate as 2xx  -> ~50% error ratio.
  # NOTE THE LABEL NAME: it is `status`. Remember it.
  cat > "$STATE_DIR/exporter.py" <<'PYEOF'
import http.server, socketserver, threading, time, os

OUTAGE_FLAG = os.environ["OUTAGE_FLAG"]
state = {"ok": 0, "err": 0}
lock = threading.Lock()

def ticker():
    while True:
        with lock:
            state["ok"] += 20                     # healthy baseline traffic
            if os.path.exists(OUTAGE_FLAG):
                state["err"] += 20                # incident: half the calls 5xx
        time.sleep(0.2)

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404); self.end_headers(); return
        with lock:
            ok, err = state["ok"], state["err"]
        body = (
            "# HELP http_requests_total Total HTTP requests by status code.\n"
            "# TYPE http_requests_total counter\n"
            'http_requests_total{job="checkout",method="get",status="200"} %d\n'
            'http_requests_total{job="checkout",method="get",status="500"} %d\n'
        ) % (ok, err)
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a): pass

threading.Thread(target=ticker, daemon=True).start()
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 9109), H) as httpd:
    httpd.serve_forever()
PYEOF
}

write_prometheus_config() {
  cat > "$LAB_DIR/prometheus.yml" <<'YMLEOF'
global:
  scrape_interval: 5s
  evaluation_interval: 5s

rule_files:
  - rules.yml

scrape_configs:
  - job_name: checkout
    static_configs:
      - targets: ["127.0.0.1:9109"]
YMLEOF
}

write_broken_rules() {
  # -------------------------------------------------------------------------
  #  THIS FILE CONTAINS THE INJECTED FAULT.
  #  The SLI recording rule selects 5xx by a label that DOES NOT EXIST on the
  #  metric (`code` instead of `status`). The selector matches zero series, so
  #  sum(rate(...)) has no samples, the ratio is EMPTY (not 0), and every
  #  downstream link — SLO comparison, burn-rate alert — silently evaluates to
  #  nothing. The service can be 50% down and the pager never rings.
  # -------------------------------------------------------------------------
  cat > "$LAB_DIR/rules.yml" <<'RULEEOF'
groups:
  - name: checkout-slo
    interval: 5s
    rules:
      # ---- SLI: short-window error ratio (the measured indicator) ----------
      # BUG: label is `code`, but the exporter emits `status`.  <-- FIX HERE
      - record: job:slo_request_errors:ratio_rate1m
        expr: |
          sum(rate(http_requests_total{code=~"5.."}[1m]))
          /
          sum(rate(http_requests_total[1m]))

      # ---- SLO burn-rate alert (the objective + the page) ------------------
      # SLO = 99.9% availability over 30d  ->  error budget = 0.001
      # Fast burn: 14.4x the budget over a short window -> exhausts 30d in ~2d.
      - alert: CheckoutErrorBudgetFastBurn
        expr: job:slo_request_errors:ratio_rate1m > (14.4 * 0.001)
        for: 30s
        labels:
          severity: page
          slo: checkout-availability
        annotations:
          summary: "Checkout is burning its error budget fast"
          description: >-
            Error ratio {{ $value | humanizePercentage }} exceeds 14.4x the
            99.9% SLO budget over the fast-burn window.
RULEEOF
}

# ------------------------------- lifecycle ------------------------------------
start_stack() {
  export PATH="$BIN_DIR:$PATH"
  export OUTAGE_FLAG

  require python3
  log "starting synthetic 'checkout' service on http://${EXPORTER_ADDR}/metrics"
  ( cd "$STATE_DIR" && OUTAGE_FLAG="$OUTAGE_FLAG" python3 exporter.py ) &
  echo $! > "$STATE_DIR/exporter.pid"

  log "starting Prometheus on http://${PROM_ADDR}"
  ( "$BIN_DIR/prometheus" \
      --config.file="$LAB_DIR/prometheus.yml" \
      --storage.tsdb.path="$LAB_DIR/tsdb" \
      --web.listen-address="$PROM_ADDR" \
      --web.enable-lifecycle \
      --log.level=warn \
      >"$STATE_DIR/prometheus.log" 2>&1 ) &
  echo $! > "$STATE_DIR/prometheus.pid"

  # Give both a couple of scrape cycles to warm up.
  sleep 8
}

inject_outage() {
  touch "$OUTAGE_FLAG"
  log "INCIDENT INJECTED: 'checkout' is now returning ~50% HTTP 500s."
}

stop_procs() {
  for p in prometheus exporter; do
    if [[ -f "$STATE_DIR/$p.pid" ]]; then
      kill "$(cat "$STATE_DIR/$p.pid")" 2>/dev/null || true
      rm -f "$STATE_DIR/$p.pid"
    fi
  done
}

clean() {
  log "stopping processes and removing $LAB_DIR"
  [[ -d "$STATE_DIR" ]] && stop_procs || true
  rm -rf "$LAB_DIR"
  log "clean."
}

brief_student() {
  cat <<BRIEF

================================================================================
  BREAK & FIX  —  Topic 3.6: SLOs, SLAs, SLIs
  Scenario: "The SLO alert that never fires"
================================================================================

WHAT IS RUNNING
  - A service 'checkout' exposing Prometheus metrics at:
        http://${EXPORTER_ADDR}/metrics
  - Prometheus (with lifecycle reload enabled) at:
        http://${PROM_ADDR}
  - An SLI recording rule + an SLO burn-rate alert in:
        ${LAB_DIR}/rules.yml
  - An outage is ALREADY HAPPENING: 'checkout' is serving ~50% HTTP 500s.

THE SYMPTOM YOU WILL SEE
  The service is clearly broken, yet the pager is silent. Concretely:

    1) The raw error traffic is real and growing — this returns data:
         curl -s '${PROM_ADDR/#/http://}/api/v1/query' \\
              --data-urlencode 'query=rate(http_requests_total{status="500"}[1m])' | \
              python3 -m json.tool

    2) But the SLI — the thing your SLO is built on — returns NOTHING:
         curl -s '${PROM_ADDR/#/http://}/api/v1/query' \\
              --data-urlencode 'query=job:slo_request_errors:ratio_rate1m' | \
              python3 -m json.tool
       -> "result": []   (empty, not 0.0)

    3) The burn-rate alert is stuck 'inactive' and will never fire:
         curl -s '${PROM_ADDR/#/http://}/api/v1/alerts' | python3 -m json.tool

  An empty SLI is far more dangerous than a wrong number: dashboards look
  blank-but-calm and the alert has no data to compare against, so it can
  never page. The SLO -> error-budget -> alert chain is severed at the SLI.

YOUR OBJECTIVE
  Make the observability chain honest again. Success = ALL of:
    (a) job:slo_request_errors:ratio_rate1m evaluates to ~0.5 during the outage
    (b) CheckoutErrorBudgetFastBurn transitions to state "firing"
    (c) After you clear the outage (rm ${OUTAGE_FLAG}) the ratio drops back
        under the 0.0144 budget threshold and the alert resolves.

RULES OF ENGAGEMENT
  - Do not touch the exporter or the alert threshold. The fault is upstream of
    the alert, in how the SLI is measured.
  - After editing rules.yml, validate then hot-reload — do not restart the VM:
        promtool check rules ${LAB_DIR}/rules.yml
        curl -s -X POST '${PROM_ADDR/#/http://}/-/reload'
  - Recording/alerting rules need a few evaluation cycles + 'for: 30s' to
    settle. Wait ~60-90s after reload before declaring victory.

HINT LADDER (uncover only as many as you need)
  H1. Trust the data layer first: is the 500 traffic actually there? (query 1)
  H2. The SLI is empty. An empty vector in PromQL almost always means a
      selector matched zero series. Which selector, and why zero?
  H3. Compare what the RULE selects against what the METRIC actually exposes:
        curl -s http://${EXPORTER_ADDR}/metrics | grep http_requests_total
      Read the label keys. Read the recording rule. They disagree.

  When done: verify, then run  './$(basename "$0") clean'  to tear everything down.
================================================================================

BRIEF
}

# ------------------------------- entrypoint -----------------------------------
usage() {
  cat <<USG
usage: $(basename "$0") [up|status|clean]
  up      (default) build the lab, inject the fault + outage, brief the student
  status  print current SLI value and alert state
  clean   stop processes and delete ${LAB_DIR}
USG
}

cmd="${1:-up}"
case "$cmd" in
  up)
    if port_busy 9090 || port_busy 9109; then
      die "port 9090 or 9109 already in use — run './$(basename "$0") clean' or free them first."
    fi
    mkdir -p "$LAB_DIR" "$BIN_DIR" "$STATE_DIR"
    fetch_prometheus
    write_exporter
    write_prometheus_config
    write_broken_rules
    start_stack
    inject_outage
    brief_student
    ;;
  status)
    require python3; require curl
    log "SLI (job:slo_request_errors:ratio_rate1m):"
    curl -s "http://${PROM_ADDR}/api/v1/query" \
         --data-urlencode 'query=job:slo_request_errors:ratio_rate1m' | python3 -m json.tool || true
    log "Alert state (CheckoutErrorBudgetFastBurn):"
    curl -s "http://${PROM_ADDR}/api/v1/alerts" | python3 -m json.tool || true
    ;;
  clean)
    clean
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage; exit 2
    ;;
esac

# ==============================================================================
#  SOLUTION  —  step by step (read only after you have tried)
# ==============================================================================
#
#  ROOT CAUSE
#  ----------
#  The SLI recording rule selects errors with the label `code`:
#        sum(rate(http_requests_total{code=~"5.."}[1m]))
#  but the exporter labels its counter with `status`:
#        http_requests_total{job="checkout",method="get",status="500"}
#  A selector on a non-existent label matches ZERO series. sum(rate(<empty>))
#  produces no samples, so the ratio is an empty vector, the SLO comparison has
#  nothing to compare, and the burn-rate alert can never fire. Classic silent
#  SLI failure: the pipeline is "green" only because it is measuring nothing.
#
#  STEP 1 — Prove the outage is real at the data source (not an SLI artifact):
#        curl -s 'http://127.0.0.1:9090/api/v1/query' \
#             --data-urlencode 'query=rate(http_requests_total{status="500"}[1m])' \
#             | python3 -m json.tool
#     You will see a non-empty result climbing. The service really is failing.
#
#  STEP 2 — Confirm the SLI is blind:
#        curl -s 'http://127.0.0.1:9090/api/v1/query' \
#             --data-urlencode 'query=job:slo_request_errors:ratio_rate1m' \
#             | python3 -m json.tool
#     "result": []   <- the indicator your whole SLO depends on has NO value.
#
#  STEP 3 — Read the metric's real label keys and compare to the rule:
#        curl -s http://127.0.0.1:9109/metrics | grep http_requests_total
#     The label is `status`, the rule filters on `code`. Mismatch found.
#
#  STEP 4 — Fix the SLI selector in $LAB_DIR/rules.yml, changing:
#        sum(rate(http_requests_total{code=~"5.."}[1m]))
#     to:
#        sum(rate(http_requests_total{status=~"5.."}[1m]))
#
#     (One-liner, if you prefer:)
#        sed -i 's/code=~"5\.\."/status=~"5.."/' "$LAB_DIR/rules.yml"
#
#  STEP 5 — Validate the rule file BEFORE loading it:
#        promtool check rules "$LAB_DIR/rules.yml"
#     Expect: "SUCCESS: 2 rules found".
#
#  STEP 6 — Hot-reload Prometheus (no restart, no data loss):
#        curl -s -X POST http://127.0.0.1:9090/-/reload
#
#  STEP 7 — Wait ~60-90s (rate[1m] window + 'for: 30s'), then verify:
#        ./$(basename "$0") status
#     Expect the SLI ≈ 0.5 and CheckoutErrorBudgetFastBurn state "firing".
#     0.5 > 0.0144 (= 14.4 * 0.001) -> the SLO is being violated -> page. Correct.
#
#  STEP 8 — Close the loop: clear the outage and watch the system recover.
#        rm -f "$OUTAGE_FLAG"
#     Within ~1-2 minutes the 500 rate decays out of the [1m] window, the SLI
#     falls back below the error budget, and the alert returns to "inactive".
#     That full cycle — metric -> SLI -> SLO threshold -> burn-rate alert ->
#     resolve — is precisely what topic 3.6 asks you to reason about.
#
#  TAKEAWAYS FOR THE EXAM
#  ----------------------
#  - An SLI is only as trustworthy as its label selectors; a typo turns a
#    critical objective into a decorative one that never fires.
#  - "No data" on an SLI is an outage of the SLO itself — alert on absence too
#    (e.g. `absent(job:slo_request_errors:ratio_rate1m)`), not just on breach.
#  - SLO (99.9%, internal, what you page on) sits ABOVE the SLA (looser,
#    external, contractual) so you have error budget to burn before penalties.
#  - Burn-rate alerting compares the measured error ratio to a multiple of the
#    error budget (1 - SLO); the multiple sets how fast you must react.
#
#  TEARDOWN
#        ./$(basename "$0") clean
# ==============================================================================