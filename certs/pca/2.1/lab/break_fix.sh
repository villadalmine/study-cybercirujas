#!/usr/bin/env bash
#
# ============================================================================
#  PCA · Prometheus Certified Associate
#  Domain 2 — Prometheus Fundamentals
#  Topic 2.1 — System Architecture        (exam weight: 4%)
#
#  BREAK-AND-FIX LAB :: "The self-scrape target went DOWN"
#
#  WHY THIS EXERCISE MAPS TO 2.1 SYSTEM ARCHITECTURE
#  -------------------------------------------------
#  Prometheus is a PULL-based system built from decoupled components:
#
#      +-----------------------------------------------------------+
#      |  Prometheus server                                        |
#      |                                                           |
#      |   Service Discovery ---> Retrieval (scrape loop)          |
#      |                              |   ^                         |
#      |                              v   | HTTP GET /metrics       |
#      |                            TSDB (local WAL + blocks)       |
#      |                              |                             |
#      |                              v                             |
#      |   HTTP API / PromQL engine / Web UI  (listens on :9090)   |
#      +-----------------------------------------------------------+
#                 |  pull                        ^  pull
#                 v                              |
#         exporter :9100               itself (self-scrape :9090)
#
#  Two facts this lab makes tangible:
#    1. Retrieval reads `scrape_configs` and, every `scrape_interval`, does an
#       HTTP GET against each target's /metrics. Success/failure is recorded in
#       the TSDB as the synthetic sample `up` (1 = scrape ok, 0 = scrape failed),
#       so a broken target is observable FROM INSIDE Prometheus.
#    2. The HTTP server (:9090) is a SEPARATE component from Retrieval. Breaking
#       a scrape target does not take the server down — which is exactly why you
#       keep the UI/API available to diagnose the fault, just like in production.
#
#  The lab rewrites the port of the built-in `prometheus` self-scrape target to
#  a port where nothing listens, then hot-reloads the config. The server stays
#  up; the self-scrape target goes DOWN. The edit is valid YAML, so the fault is
#  SEMANTIC, not syntactic — an important distinction the student must discover.
#
#  Official sources:
#    - Overview / architecture ...... https://prometheus.io/docs/introduction/overview/
#    - scrape_config ................ https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
#    - Jobs & instances / `up` ...... https://prometheus.io/docs/concepts/jobs_instances/
#    - Reloading configuration ...... https://prometheus.io/docs/prometheus/latest/management_api/
#    - promtool ..................... https://prometheus.io/docs/prometheus/latest/command-line/promtool/
#    - HTTP query API ............... https://prometheus.io/docs/prometheus/latest/querying/api/
#  Curriculum:
#    - https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf
#
#  SAFETY — read before running
#  ----------------------------
#    * Intended for a DISPOSABLE lab VM only.
#    * It edits prometheus.yml IN PLACE but always writes a timestamped backup
#      first, and NEVER touches the TSDB, so no metric data is lost.
#    * The change is reversible valid YAML; the server keeps serving on :9090.
#    * `reset` subcommand restores the latest backup (instructor escape hatch).
#
#  Usage:
#      sudo ./pca-2.1-system-architecture-breakfix.sh          # break it
#      sudo ./pca-2.1-system-architecture-breakfix.sh reset    # undo (instructor)
#      FORCE=1 sudo ./pca-2.1-...sh                             # skip confirmation
#      PROM_URL=http://127.0.0.1:9090 BROKEN_PORT=19090 ...     # overrides
# ============================================================================

set -uo pipefail

PROM_URL="${PROM_URL:-http://localhost:9090}"
GOOD_PORT="9090"
BROKEN_PORT="${BROKEN_PORT:-19090}"   # uncommon port; nothing should listen here
BACKUP_TAG="pca-2.1.bak"

# ---- pretty output ---------------------------------------------------------
info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
rule() { printf '\033[2m%s\033[0m\n' '----------------------------------------------------------------------'; }

# ---- locate the live prometheus.yml ----------------------------------------
find_config() {
  local cfg c
  # 1) ask the running process what --config.file it was started with
  cfg="$(ps -eo args 2>/dev/null | grep -m1 '[p]rometheus .*--config.file' \
        | sed -n 's/.*--config\.file[= ]\{1,\}\([^[:space:]]*\).*/\1/p')"
  if [[ -n "${cfg:-}" && -f "$cfg" ]]; then echo "$cfg"; return 0; fi
  # 2) fall back to common install locations
  for c in /etc/prometheus/prometheus.yml \
           /opt/prometheus/prometheus.yml \
           /usr/local/etc/prometheus/prometheus.yml \
           ./prometheus.yml; do
    [[ -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# ---- hot-reload the Retrieval configuration (no restart, TSDB untouched) ----
reload_prometheus() {
  if curl -sf -X POST "${PROM_URL}/-/reload" >/dev/null 2>&1; then
    ok "config reloaded via POST ${PROM_URL}/-/reload"; return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl reload prometheus >/dev/null 2>&1; then
    ok "config reloaded via 'systemctl reload prometheus'"; return 0
  fi
  local pid; pid="$(pgrep -x prometheus | head -n1)"
  if [[ -n "${pid:-}" ]] && kill -HUP "$pid" 2>/dev/null; then
    ok "config reloaded via SIGHUP to pid ${pid}"; return 0
  fi
  warn "could not reload automatically; reload/restart Prometheus by hand"
  return 1
}

# ---- read up{job="prometheus"} straight out of the TSDB via the HTTP API ----
query_up() {
  local out
  out="$(curl -sf --get "${PROM_URL}/api/v1/query" \
         --data-urlencode 'query=up{job="prometheus"}' 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then
    echo "$out" | jq -r '.data.result[0].value[1] // empty'
  else
    echo "$out" | grep -o '"value":\[[^]]*\]' | grep -o '"[01]"' | tr -d '"' | tail -n1
  fi
}

# ---- poll `up` until it reaches $1 or timeout (covers one scrape_interval) --
wait_for_up() {
  local want="$1" tries="${2:-15}" v
  for ((i=0; i<tries; i++)); do
    v="$(query_up)"
    [[ "$v" == "$want" ]] && { echo "$v"; return 0; }
    sleep 2
  done
  echo "${v:-<unknown>}"; return 1
}

# ---- instructor reset ------------------------------------------------------
do_reset() {
  local latest
  latest="$(ls -1t "${CONFIG}".*."${BACKUP_TAG}" 2>/dev/null | head -n1)"
  [[ -z "${latest:-}" ]] && die "no '${BACKUP_TAG}' backup found next to ${CONFIG}"
  cp -f "$latest" "$CONFIG" || die "restore failed (need sudo?)"
  ok "restored ${CONFIG} from ${latest}"
  reload_prometheus
  info "up{job=\"prometheus\"} = $(wait_for_up 1)"
  exit 0
}

# ============================================================================
#  MAIN
# ============================================================================
CONFIG="$(find_config)" || die "prometheus.yml not found — is Prometheus installed on this VM?"
info "using config: ${CONFIG}"
[[ -w "$CONFIG" ]] || die "cannot write ${CONFIG} — re-run with sudo"

case "${1:-break}" in
  reset|--reset|-r) do_reset ;;
  break|--break|"") : ;;
  *) die "unknown subcommand '$1' (use: break | reset)" ;;
esac

# --- confirmation -----------------------------------------------------------
rule
warn "This will break a scrape target on THIS host ($(hostname)). Disposable lab VMs only."
if [[ "${FORCE:-0}" != "1" ]]; then
  read -r -p "Type 'break' to proceed: " ans
  [[ "$ans" == "break" ]] || die "aborted"
fi

# --- baseline check (prove the target is UP before we break it) -------------
base="$(query_up || true)"
if [[ "$base" == "1" ]]; then
  ok "baseline: up{job=\"prometheus\"} = 1  (self-scrape healthy)"
elif [[ -z "$base" ]]; then
  warn "could not reach ${PROM_URL} — continuing, but check the server is running"
else
  warn "baseline up = ${base}  (self-scrape already not healthy; continuing anyway)"
fi

# --- back up, then apply the SEMANTIC break --------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${CONFIG}.${STAMP}.${BACKUP_TAG}"
cp -f "$CONFIG" "$BACKUP" || die "backup failed"
ok "backup written: ${BACKUP}"

before="$(sha1sum "$CONFIG" | awk '{print $1}')"
# Repoint every self-scrape target (localhost/127.0.0.1:9090) to a dead port.
sed -i "s/\(localhost\|127\.0\.0\.1\):${GOOD_PORT}\b/\1:${BROKEN_PORT}/g" "$CONFIG"
after="$(sha1sum "$CONFIG" | awk '{print $1}')"

if [[ "$before" == "$after" ]]; then
  warn "no ':${GOOD_PORT}' self-scrape target found to break."
  warn "restoring backup and aborting to avoid corrupting an unfamiliar layout."
  cp -f "$BACKUP" "$CONFIG"
  die "inspect ${CONFIG} manually; expected a 'prometheus' job targeting :${GOOD_PORT}"
fi

# Guard: the edit MUST remain syntactically valid (this is a semantic break).
if command -v promtool >/dev/null 2>&1; then
  if ! promtool check config "$CONFIG" >/dev/null 2>&1; then
    warn "edit unexpectedly broke YAML syntax; restoring backup."
    cp -f "$BACKUP" "$CONFIG"
    die "aborted — no changes left on disk"
  fi
  ok "promtool: config still SYNTACTICALLY valid (fault is semantic, by design)"
fi

# --- reload and reveal the symptom -----------------------------------------
reload_prometheus || warn "reload not confirmed; symptom may lag"
info "waiting up to one scrape_interval for the TSDB to record the failure..."
final="$(wait_for_up 0 15 || true)"

rule
cat <<EOF

  =====================  STUDENT BRIEFING  (PCA 2.1)  =====================

  WHAT WAS DONE
    The 'prometheus' self-scrape target in ${CONFIG}
    was repointed from :${GOOD_PORT} to :${BROKEN_PORT}, and the config was
    hot-reloaded. The Prometheus HTTP server is STILL UP on :${GOOD_PORT};
    only the Retrieval component's scrape of that target now fails.

  SYMPTOM YOU WILL OBSERVE
    * Web UI  -> Status -> Targets : the 'prometheus' job is red / DOWN,
      with an error like:
        Get "http://localhost:${BROKEN_PORT}/metrics":
        dial tcp 127.0.0.1:${BROKEN_PORT}: connect: connection refused
    * PromQL  -> up{job="prometheus"}  evaluates to  0   (currently: ${final})
    * Any alert or dashboard keyed on this job's freshness starts to fire/gap,
      even though the Prometheus process itself is perfectly healthy.

  WHAT YOU MUST ACHIEVE (definition of done)
    1. Keep the Prometheus SERVER running the whole time (do NOT reinstall,
       do NOT wipe the TSDB).
    2. Diagnose using Prometheus' OWN architecture — /-/healthy, /-/ready,
       Status->Targets, the /api/v1/targets endpoint, and the up metric.
    3. Restore the correct scrape target and hot-reload the config so that:
           up{job="prometheus"} == 1     and the Targets page shows UP.

  HINT (architectural)
    'promtool check config' will report SUCCESS — the YAML is valid. That
    tool checks STRUCTURE, not INTENT. The truth about a live scrape lives in
    the Retrieval component's target state, not in the config parser.

  Backup for reference / instructor reset: ${BACKUP}
  Instructor reset:  sudo $0 reset
  ========================================================================

EOF

exit 0

# ============================================================================
#  SOLUTION  —  step by step  (do NOT read until you have tried it yourself)
#  Paths below assume /etc/prometheus/prometheus.yml and the default :9090.
# ============================================================================
#
#  STEP 0 — Confirm the SERVER is healthy (rule out a server-down problem).
#           The pull architecture separates "server up" from "target up":
#
#     $ curl -s http://localhost:9090/-/healthy
#     Prometheus Server is Healthy.
#     $ curl -s http://localhost:9090/-/ready
#     Prometheus Server is Ready.
#
#           Both OK => the process and HTTP server are fine; the fault is in
#           Retrieval (a scrape), not in the server itself.
#
#  STEP 1 — Ask Retrieval for its live target inventory. This is the single
#           most important screen for 2.1 troubleshooting (UI: Status->Targets):
#
#     $ curl -s http://localhost:9090/api/v1/targets \
#         | jq '.data.activeTargets[] | {job:.labels.job, health, scrapeUrl, lastError}'
#     {
#       "job": "prometheus",
#       "health": "down",
#       "scrapeUrl": "http://localhost:19090/metrics",
#       "lastError": "Get \"http://localhost:19090/metrics\": dial tcp 127.0.0.1:19090: connect: connection refused"
#     }
#
#           The scrapeUrl reveals the bug immediately: port 19090, not 9090.
#
#  STEP 2 — Confirm the failure is recorded in the TSDB via the `up` series.
#           Prometheus writes `up=0` for every failed scrape (self-observability):
#
#     $ curl -s --get http://localhost:9090/api/v1/query \
#         --data-urlencode 'query=up{job="prometheus"}' \
#         | jq -r '.data.result[0].value[1]'
#     0
#
#  STEP 3 — Prove the fault is SEMANTIC, not syntactic. promtool passes:
#
#     $ promtool check config /etc/prometheus/prometheus.yml
#     Checking /etc/prometheus/prometheus.yml
#       SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax
#
#           Lesson: a valid config can still point at the wrong place. The
#           config parser cannot know your intent — only the scrape can.
#
#  STEP 4 — Confirm nothing actually listens on the wrong port (rule out a
#           firewall or a real exporter that just died):
#
#     $ ss -ltnp | grep -E ':9090|:19090'
#     LISTEN 0  4096  *:9090  *:*  users:(("prometheus",pid=1234,fd=7))
#     # note: no line for :19090  -> nothing is bound there, hence "connection refused"
#
#  STEP 5 — Fix the scrape target back to the real port. Either edit by hand
#           so the block reads:
#
#             scrape_configs:
#               - job_name: "prometheus"
#                 static_configs:
#                   - targets: ["localhost:9090"]
#
#           ...or, non-interactively:
#
#     $ sudo sed -i 's/:19090/:9090/g' /etc/prometheus/prometheus.yml
#
#  STEP 6 — Re-validate, then HOT-RELOAD (no restart => TSDB stays intact):
#
#     $ promtool check config /etc/prometheus/prometheus.yml
#       SUCCESS: ... valid prometheus config file syntax
#
#     # Preferred: lifecycle reload (requires the server flag --web.enable-lifecycle)
#     $ curl -s -X POST http://localhost:9090/-/reload
#     # Alternatives if that flag is off:
#     $ sudo systemctl reload prometheus
#     $ sudo kill -HUP "$(pgrep -x prometheus)"
#
#  STEP 7 — Verify recovery. Wait one scrape_interval (default 15s) for the
#           next scrape to land, then re-query the TSDB:
#
#     $ curl -s --get http://localhost:9090/api/v1/query \
#         --data-urlencode 'query=up{job="prometheus"}' \
#         | jq -r '.data.result[0].value[1]'
#     1
#
#           Status->Targets now shows the 'prometheus' job GREEN / UP. Done.
#
#  ARCHITECTURE TAKEAWAYS (exam-relevant, 2.1)
#    * Pull model: Prometheus initiates every scrape; a target being DOWN means
#      *Prometheus could not reach it*, not that Prometheus itself is broken.
#    * Component isolation: the HTTP/PromQL server (:9090) is independent of the
#      Retrieval scrape loop, so you diagnose scrape faults using the very
#      server whose target is failing.
#    * `up` is Prometheus' built-in self-observability primitive — one sample
#      per target per scrape, stored in the local TSDB. `up == 0` with a
#      "connection refused" lastError is the canonical "wrong host/port or dead
#      exporter" signature.
#    * Config reload is hot and validated: an invalid file is rejected and the
#      previous config keeps running; a valid-but-wrong file is accepted, which
#      is why syntactic checks (promtool) and semantic checks (Targets/`up`)
#      are complementary, not redundant.
# ============================================================================