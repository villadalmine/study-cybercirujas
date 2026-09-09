#!/usr/bin/env bash
#===============================================================================
#  Google Cloud Digital Leader (gcp-cdl) -- exam guide version 2026-08-12
#  Domain 2: Innovating with Data and Google Cloud
#  Topic 2.3: How smart analytics, business intelligence tools and streaming
#             analytics add value in different business use cases (weight 6.0)
#
#  BREAK & FIX LAB -- "The dashboard that lied"
#
#  WHAT THIS SCRIPT DOES
#    It builds, inside ONE disposable directory, a miniature but structurally
#    faithful streaming analytics platform:
#
#        checkout service  --->  Pub/Sub topic  --->  Dataflow streaming job
#                                                            |
#                                             +--------------+--------------+
#                                             |                             |
#                                     BigQuery table                 dead-letter topic
#                                             |
#                                     Looker Studio report
#
#    Then it breaks it the way it actually breaks in production: an upstream
#    application team ships a new event schema without telling the data
#    platform team. Nothing crashes. No alert fires. The subscription backlog
#    stays at zero. The revenue dashboard keeps rendering, keeps saying
#    "fresh", and quietly stops telling the truth.
#
#  WHY A CONCEPTUAL EXAM DESERVES A HANDS-ON LAB
#    CDL 2.3 is scored on business judgement, not on gcloud syntax. But the
#    business judgement questions ("when is streaming worth its cost?",
#    "what is the value of a dead-letter topic?", "what does data freshness
#    mean to a decision maker?") are impossible to answer honestly if you have
#    never watched a pipeline fail silently. This lab makes you watch it.
#
#  SAFETY CONTRACT
#    * Everything is created under a single directory (default
#      $HOME/gcp-cdl-lab/2.3-smart-analytics). Nothing else on the machine is
#      touched: no root, no package installs, no systemd, no firewall rules,
#      no network calls, no GCP API calls, no billing.
#    * The only processes started are two ordinary user-space bash loops,
#      tracked by PID files, stoppable with `$0 stop`.
#    * `$0 clean` removes the lab, and refuses to remove any directory that
#      does not contain the lab's own marker file.
#    * Still: run it on a throwaway VM. That is what break & fix means.
#
#  USAGE
#    ./break-and-fix-2.3.sh [setup] [--yes]   build the lab and inject the fault
#    ./break-and-fix-2.3.sh status            metrics: backlog, DLQ, freshness
#    ./break-and-fix-2.3.sh dashboard         render the BI report right now
#    ./break-and-fix-2.3.sh logs              tail the streaming job log
#    ./break-and-fix-2.3.sh verify            grade your fix (this is the goal)
#    ./break-and-fix-2.3.sh start | stop      control the running pipeline
#    ./break-and-fix-2.3.sh clean             delete the lab directory
#
#    Set LAB_VM=1 to skip the interactive confirmation (unattended runs).
#    Tunables: GCP_CDL_LAB_HOME, WARMUP_SECS, BREAK_SECS, PUBLISH_INTERVAL.
#
#  THE STEP-BY-STEP SOLUTION IS AT THE BOTTOM OF THIS FILE, COMMENTED OUT.
#  Do not read it until `verify` has beaten you at least twice.
#===============================================================================

set -euo pipefail

LAB_ROOT="${GCP_CDL_LAB_HOME:-$HOME/gcp-cdl-lab/2.3-smart-analytics}"
MARKER_FILE=".gcp-cdl-disposable-lab"
WARMUP_SECS="${WARMUP_SECS:-24}"
BREAK_SECS="${BREAK_SECS:-16}"
PUBLISH_INTERVAL="${PUBLISH_INTERVAL:-2}"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s[ ok ]%s %s\n'   "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n'   "$C_YELLOW" "$C_RESET" "$*"; }
bad()  { printf '%s[FAIL]%s %s\n'   "$C_RED"    "$C_RESET" "$*"; }
die()  { printf '%s[FATAL]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

#------------------------------------------------------------------------------
# Preflight and consent
#------------------------------------------------------------------------------
preflight() {
  [ -n "${BASH_VERSION:-}" ] || die "this lab requires bash, not sh"
  case "${BASH_VERSINFO[0]}" in
    [0-3]) die "bash 4+ required (found $BASH_VERSION)" ;;
  esac
  for tool in awk sed date mktemp wc sort head tail; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
  done
  date -u -d @0 +%s >/dev/null 2>&1 || die "GNU date required (date -d); this lab targets Linux"
  [ "$(id -u)" -ne 0 ] || warn "running as root is unnecessary here; the lab is user-space only"
}

consent() {
  [ "${LAB_VM:-0}" = "1" ] && return 0
  [ "${FORCE:-0}" = "1" ] && return 0
  if [ ! -t 0 ]; then
    die "non-interactive run without consent. Re-run with --yes or LAB_VM=1 (disposable VM only)."
  fi
  head1 "DISPOSABLE LAB VM CONFIRMATION"
  say "This script will:"
  say "  * create and populate    : $LAB_ROOT"
  say "  * start two background bash loops owned by $(id -un)"
  say "  * deliberately break the simulated data pipeline it just built"
  say "It will NOT touch anything outside that directory, and makes no network calls."
  printf '\nType BREAK to continue, anything else to abort: '
  local answer=""
  read -r answer || true
  [ "$answer" = "BREAK" ] || die "aborted by the operator. Nothing was created."
}

#------------------------------------------------------------------------------
# Lab construction
#------------------------------------------------------------------------------
build_lab() {
  head1 "PROVISIONING THE SIMULATED ANALYTICS PLATFORM"
  mkdir -p "$LAB_ROOT"/{bin,pubsub/subscriptions,pipeline/dead_letter,warehouse,bi,logs,run,incidents}
  : > "$LAB_ROOT/$MARKER_FILE"

  local topic="$LAB_ROOT/pubsub/topic-retail-orders.ndjson"
  local cursor="$LAB_ROOT/pubsub/subscriptions/analytics.cursor"
  local table="$LAB_ROOT/warehouse/fact_orders.tsv"

  [ -f "$topic" ]  || : > "$topic"
  [ -f "$cursor" ] || echo 0 > "$cursor"
  [ -f "$LAB_ROOT/pubsub/ledger.expected" ] || : > "$LAB_ROOT/pubsub/ledger.expected"
  if [ ! -f "$table" ]; then
    printf '# event_time_epoch\torder_id\tregion\tamount_cents\tingest_epoch\n' > "$table"
  fi
  echo v1 > "$LAB_ROOT/pubsub/schema_version"

  #--------------------------------------------------------------------------
  # bin/publisher.sh -- stands in for the checkout service + Pub/Sub publisher
  #--------------------------------------------------------------------------
  cat > "$LAB_ROOT/bin/publisher.sh" <<'PUBLISHER_EOF'
#!/usr/bin/env bash
# Simulated producer: the retail "checkout-service" publishing one order event
# per interval to the topic. Real equivalent:
#   gcloud pubsub topics publish retail-orders --message='{"order_id":...}'
# The event payload version is read from pubsub/schema_version on every loop,
# so an "application release" can change the contract while the lab runs -
# exactly what happens when a mobile/web team deploys without a schema review.
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOPIC="$LAB/pubsub/topic-retail-orders.ndjson"
LEDGER="$LAB/pubsub/ledger.expected"
SCHEMA_FILE="$LAB/pubsub/schema_version"
SEQ_FILE="$LAB/pubsub/.seq"
INTERVAL="${PUBLISH_INTERVAL:-2}"
REGIONS=(us-central1 europe-west1 asia-south1 southamerica-east1)

while :; do
  [ -f "$LAB/.stop" ] && exit 0
  seq_no=$(( $(cat "$SEQ_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$seq_no" > "$SEQ_FILE"
  order_id="$(printf 'ord-%06d' "$seq_no")"
  region="${REGIONS[$(( seq_no % ${#REGIONS[@]} ))]}"
  cents=$(( 500 + (seq_no * 137) % 24500 ))
  now="$(date +%s)"
  version="$(cat "$SCHEMA_FILE" 2>/dev/null || echo v1)"

  if [ "$version" = "v1" ]; then
    printf '{"schema":"v1","order_id":"%s","ts":%s,"region":"%s","amount":%d.%02d,"channel":"web"}\n' \
      "$order_id" "$now" "$region" "$((cents / 100))" "$((cents % 100))" >> "$TOPIC"
  else
    printf '{"schema":"v2","order_id":"%s","event_time":"%s","geo":{"region":"%s"},"amount_cents":%s,"channel":"web"}\n' \
      "$order_id" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" "$region" "$cents" >> "$TOPIC"
  fi

  # Ground truth. In production this is the OLTP system of record (Cloud SQL /
  # Spanner). Reconciling the warehouse against it is how you prove that a
  # streaming pipeline lost nothing.
  printf '%s\t%s\t%s\t%s\n' "$order_id" "$cents" "$region" "$now" >> "$LEDGER"
  sleep "$INTERVAL"
done
PUBLISHER_EOF

  #--------------------------------------------------------------------------
  # pipeline/stream_job.sh -- stands in for the Dataflow streaming pipeline.
  # THIS IS THE FILE THE STUDENT REPAIRS.
  #--------------------------------------------------------------------------
  cat > "$LAB_ROOT/pipeline/stream_job.sh" <<'STREAMJOB_EOF'
#!/usr/bin/env bash
#==============================================================================
# STREAMING JOB  "orders-to-warehouse"   (simulated Apache Beam / Dataflow job)
#
# Real equivalent: a Dataflow streaming pipeline reading a Pub/Sub subscription,
# applying a ParDo transform, and writing to BigQuery through the Storage Write
# API. Here: read new lines from the topic beyond the subscription cursor,
# transform them, append to the warehouse table.
#
# Operational contract of this job:
#   * a message that parses becomes exactly one warehouse row (ACK)
#   * a message that does not parse is routed to the dead-letter directory
#   * EITHER WAY the cursor advances - i.e. the message is acknowledged.
#     That is the standard dead-letter pattern, and it is also the reason the
#     subscription backlog metric stays at zero during a total data outage.
#     A green backlog means "messages were consumed", never "data arrived".
#==============================================================================
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOPIC="$LAB/pubsub/topic-retail-orders.ndjson"
CURSOR="$LAB/pubsub/subscriptions/analytics.cursor"
TABLE="$LAB/warehouse/fact_orders.tsv"
DLQ="$LAB/pipeline/dead_letter"
LOG="$LAB/pipeline/job.log"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# Minimal JSON field readers. Deliberately dependency-free (no jq): the point of
# the lab is the contract between producer and consumer, not the parser.
json_str() { printf '%s' "$2" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; }
json_num() { printf '%s' "$2" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9.]\{1,\}\).*/\1/p'; }

#------------------------------------------------------------------------------
# THE TRANSFORM.  Emits one TSV warehouse row on stdout, or fails with:
#   1 = no order_id     2 = no usable event timestamp     3 = no usable amount
#
# It was written when the checkout service emitted schema v1 and nobody
# imagined it would ever emit anything else.
#------------------------------------------------------------------------------
process_message() {
  local raw="$1" order_id ts region amount cents
  order_id="$(json_str order_id "$raw")"
  ts="$(json_num ts "$raw")"
  region="$(json_str region "$raw")"
  amount="$(json_num amount "$raw")"

  [ -n "$order_id" ] || return 1
  [ -n "$ts" ]       || return 2
  [ -n "$amount" ]   || return 3

  # money is stored as an integer number of cents; never as a float
  cents="$(awk -v a="$amount" 'BEGIN { printf "%d", (a * 100) + 0.5 }')"
  printf '%s\t%s\t%s\t%s\t%s' "$ts" "$order_id" "${region:-unknown}" "$cents" "$(date +%s)"
}

reason_for() {
  case "$1" in
    1) echo "MISSING_ORDER_ID" ;;
    2) echo "UNPARSEABLE_EVENT_TIME" ;;
    3) echo "UNPARSEABLE_AMOUNT" ;;
    *) echo "UNKNOWN_ERROR_$1" ;;
  esac
}

log "streaming job starting (pid $$)"
while :; do
  [ -f "$LAB/.stop" ] && { log "streaming job stopping on sentinel"; exit 0; }
  total="$(wc -l < "$TOPIC" 2>/dev/null || echo 0)"
  cursor="$(cat "$CURSOR" 2>/dev/null || echo 0)"
  while [ "${cursor:-0}" -lt "${total:-0}" ]; do
    cursor=$(( cursor + 1 ))
    raw="$(sed -n "${cursor}p" "$TOPIC")"
    if [ -z "$raw" ]; then echo "$cursor" > "$CURSOR"; continue; fi
    if row="$(process_message "$raw")"; then
      printf '%s\n' "$row" >> "$TABLE"
      log "ACK    line=$cursor order=$(json_str order_id "$raw") -> warehouse"
    else
      rc=$?
      printf '%s\n' "$raw" > "$DLQ/$(printf 'msg-%06d.json' "$cursor")"
      log "DEADLETTER line=$cursor reason=$(reason_for "$rc") payload_schema=$(json_str schema "$raw")"
    fi
    echo "$cursor" > "$CURSOR"   # acknowledged either way - see header note
  done
  sleep 1
done
STREAMJOB_EOF

  #--------------------------------------------------------------------------
  # bi/dashboard.sh -- stands in for the Looker Studio executive report
  #--------------------------------------------------------------------------
  cat > "$LAB_ROOT/bi/dashboard.sh" <<'DASHBOARD_EOF'
#!/usr/bin/env bash
#==============================================================================
# "Revenue Operations" BI report  (simulated Looker Studio / Looker dashboard
# on top of the BigQuery table warehouse.fact_orders).
#
# Equivalent BigQuery SQL for the tiles below:
#
#   SELECT region,
#          COUNT(*)                    AS orders,
#          SUM(amount_cents) / 100.0   AS revenue_usd
#   FROM   `retail.fact_orders`
#   WHERE  event_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 MINUTE)
#   GROUP  BY region
#   ORDER  BY revenue_usd DESC;
#
#   SELECT TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(event_time), SECOND)
#          AS data_freshness_seconds
#   FROM   `retail.fact_orders`;
#==============================================================================
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$LAB/warehouse/fact_orders.tsv"

now="$(date +%s)"
report_generated_at="$(date +%s)"

# Freshness KPI, as originally implemented by the analyst who built the report.
data_freshness_seconds=$(( now - report_generated_at ))

rows_total="$(awk -F'\t' '$1 ~ /^[0-9]+$/' "$TABLE" | wc -l)"
window_start=$(( now - 900 ))
rows_window="$(awk -F'\t' -v w="$window_start" '$1 ~ /^[0-9]+$/ && $1 + 0 >= w' "$TABLE" | wc -l)"

echo "==============================================================================="
echo " REVENUE OPERATIONS  -  live report"
echo " report run at : $(date -u -d "@$report_generated_at" +%Y-%m-%dT%H:%M:%SZ)"
echo " source        : warehouse.fact_orders (BigQuery stand-in)"
echo "==============================================================================="
echo " Revenue by region, last 15 minutes"
awk -F'\t' -v w="$window_start" '
  $1 ~ /^[0-9]+$/ && $1 + 0 >= w { rev[$3] += $4; cnt[$3]++ }
  END {
    if (length(rev) == 0) { print "   (no rows in window)"; }
    for (r in rev) printf "   %-24s %6d orders   $ %12.2f\n", r, cnt[r], rev[r] / 100.0
  }' "$TABLE" | sort
echo "-------------------------------------------------------------------------------"
printf ' rows_total=%s\n' "$rows_total"
printf ' rows_last_15m=%s\n' "$rows_window"
printf 'data_freshness_seconds=%s\n' "$data_freshness_seconds"
if [ "$data_freshness_seconds" -lt 120 ]; then
  echo "dashboard_status=OK"
else
  echo "dashboard_status=STALE"
fi
DASHBOARD_EOF

  #--------------------------------------------------------------------------
  # bin/ctl.sh -- process control for the two simulated services
  #--------------------------------------------------------------------------
  cat > "$LAB_ROOT/bin/ctl.sh" <<'CTL_EOF'
#!/usr/bin/env bash
# Lifecycle control for the simulated producer and streaming job.
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$LAB/run"; LOGS="$LAB/logs"
mkdir -p "$RUN" "$LOGS"

is_running() {
  local pidfile="$RUN/$1.pid" pid
  [ -f "$pidfile" ] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || echo)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start_one() {
  local name="$1" script="$2"
  if is_running "$name"; then
    echo "[ctl] $name already running (pid $(cat "$RUN/$name.pid"))"
    return 0
  fi
  rm -f "$LAB/.stop"
  nohup bash "$script" >>"$LOGS/$name.out" 2>&1 &
  echo $! > "$RUN/$name.pid"
  echo "[ctl] started $name (pid $!)"
}

stop_one() {
  local name="$1" pidfile="$RUN/$1.pid" pid
  if ! is_running "$name"; then rm -f "$pidfile"; echo "[ctl] $name not running"; return 0; fi
  pid="$(cat "$pidfile")"
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.4; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$pidfile"
  echo "[ctl] stopped $name (was pid $pid)"
}

case "${1:-status}" in
  start)
    start_one publisher "$LAB/bin/publisher.sh"
    start_one streamjob "$LAB/pipeline/stream_job.sh"
    ;;
  stop)
    touch "$LAB/.stop"; stop_one streamjob; stop_one publisher; sleep 1; rm -f "$LAB/.stop"
    ;;
  start-job)   start_one streamjob "$LAB/pipeline/stream_job.sh" ;;
  stop-job)    stop_one streamjob ;;
  restart-job) stop_one streamjob; sleep 1; start_one streamjob "$LAB/pipeline/stream_job.sh" ;;
  status)
    for svc in publisher streamjob; do
      if is_running "$svc"; then echo "$svc: RUNNING (pid $(cat "$RUN/$svc.pid"))"
      else echo "$svc: STOPPED"; fi
    done
    ;;
  *) echo "usage: ctl.sh {start|stop|start-job|stop-job|restart-job|status}"; exit 2 ;;
esac
CTL_EOF

  #--------------------------------------------------------------------------
  # bin/replay_dlq.sh -- the dead-letter replay tool
  #--------------------------------------------------------------------------
  cat > "$LAB_ROOT/bin/replay_dlq.sh" <<'REPLAY_EOF'
#!/usr/bin/env bash
# Dead-letter replay. Real equivalent: subscribe to the dead-letter topic and
# re-publish its messages to the main topic after the consumer is fixed, or use
# Pub/Sub seek/snapshot to rewind the subscription.
#   https://cloud.google.com/pubsub/docs/handling-failures
#   https://cloud.google.com/pubsub/docs/replay-overview
#
# It is idempotent by construction: every replayed payload is MOVED to
# dead_letter/replayed/, so running it twice cannot duplicate revenue.
# Replaying before the consumer is fixed simply dead-letters the messages
# again - harmless, and a lesson about ordering.
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DLQ="$LAB/pipeline/dead_letter"
DONE="$DLQ/replayed"
TOPIC="$LAB/pubsub/topic-retail-orders.ndjson"
mkdir -p "$DONE"
shopt -s nullglob
count=0
for f in "$DLQ"/msg-*.json; do
  payload="$(cat "$f")"
  [ -z "$payload" ] && { rm -f "$f"; continue; }
  printf '%s\n' "$payload" >> "$TOPIC"
  mv "$f" "$DONE/"
  count=$(( count + 1 ))
done
echo "[replay] re-published $count dead-lettered message(s) to the topic"
echo "[replay] archived under: $DONE"
REPLAY_EOF

  #--------------------------------------------------------------------------
  # verify.sh -- the acceptance test. This file is the definition of "fixed".
  #--------------------------------------------------------------------------
  cat > "$LAB_ROOT/verify.sh" <<'VERIFY_EOF'
#!/usr/bin/env bash
#==============================================================================
# ACCEPTANCE TEST for gcp-cdl topic 2.3 break & fix.
# Do not edit this file. Editing the exam is not the same as passing it.
#
#   CHECK 1  the streaming job is running
#   CHECK 2  data freshness measured from the warehouse is under 120 s
#   CHECK 3  the BI report publishes the TRUE freshness, proven by aging the
#            data on purpose (the job is paused ~25 s, then restarted)
#   CHECK 4  schema evolution: a v1 AND a v2 probe both land, correctly typed
#   CHECK 5  zero data loss: every published order is in the warehouse exactly
#            once with the right amount, and the dead-letter queue is drained
#==============================================================================
set -uo pipefail
LAB="$(cd "$(dirname "$0")" && pwd)"
TABLE="$LAB/warehouse/fact_orders.tsv"
LEDGER="$LAB/pubsub/ledger.expected"
TOPIC="$LAB/pubsub/topic-retail-orders.ndjson"
DLQ="$LAB/pipeline/dead_letter"
PASS=0; FAIL=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

pass() { printf '  [ PASS ] %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  [ FAIL ] %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
info() { printf '  [ .... ] %s\n' "$*"; }

rows_only() { awk -F'\t' '$1 ~ /^[0-9]+$/' "$TABLE"; }
max_event_time() { rows_only | awk -F'\t' '$1 + 0 > m { m = $1 + 0 } END { print m + 0 }'; }

echo "==============================================================================="
echo " VERIFY - topic 2.3 streaming analytics break & fix"
echo "==============================================================================="

echo
echo "CHECK 1  streaming job liveness"
if bash "$LAB/bin/ctl.sh" status | grep -q '^streamjob: RUNNING'; then
  pass "the streaming job is running"
else
  fail "the streaming job is not running (bin/ctl.sh start-job)"
fi

echo
echo "CHECK 2  warehouse data freshness"
now="$(date +%s)"; mx="$(max_event_time)"
if [ "$mx" -eq 0 ]; then
  fail "the warehouse contains no data rows at all"
else
  fresh=$(( now - mx ))
  if [ "$fresh" -lt 120 ]; then pass "newest event is ${fresh}s old (< 120s)"
  else fail "newest event is ${fresh}s old - the pipeline is not delivering"; fi
fi

echo
echo "CHECK 3  does the BI report tell the truth about freshness?"
info "pausing the streaming job for 25s to age the data on purpose..."
bash "$LAB/bin/ctl.sh" stop-job >/dev/null 2>&1
sleep 25
dash_out="$(bash "$LAB/bi/dashboard.sh" 2>/dev/null || true)"
sample_now="$(date +%s)"; sample_mx="$(max_event_time)"
true_fresh=$(( sample_now - sample_mx ))
bash "$LAB/bin/ctl.sh" start-job >/dev/null 2>&1
reported="$(printf '%s\n' "$dash_out" | sed -n 's/^ *data_freshness_seconds=\(-\{0,1\}[0-9]\{1,\}\)$/\1/p' | tail -n1)"
if [ -z "$reported" ]; then
  fail "the report did not emit a data_freshness_seconds=<n> line"
else
  delta=$(( reported - true_fresh )); [ "$delta" -lt 0 ] && delta=$(( -delta ))
  info "report says ${reported}s, warehouse truth is ${true_fresh}s"
  if [ "$delta" -le 12 ]; then
    pass "the freshness KPI is derived from the data (delta ${delta}s)"
  else
    fail "the freshness KPI is not measuring the data (delta ${delta}s)"
  fi
fi
if printf '%s\n' "$dash_out" | grep -q 'dashboard_status='; then
  pass "the report still publishes a dashboard_status line"
else
  fail "the report no longer publishes dashboard_status=OK|STALE"
fi

echo
echo "CHECK 4  schema evolution - v1 and v2 must both be accepted"
stamp="$$"
p1="probe-v1-$stamp"; p2="probe-v2-$stamp"; tnow="$(date +%s)"
printf '{"schema":"v1","order_id":"%s","ts":%s,"region":"us-central1","amount":123.45,"channel":"probe"}\n' \
  "$p1" "$tnow" >> "$TOPIC"
printf '{"schema":"v2","order_id":"%s","event_time":"%s","geo":{"region":"us-central1"},"amount_cents":12345,"channel":"probe"}\n' \
  "$p2" "$(date -u -d "@$tnow" +%Y-%m-%dT%H:%M:%SZ)" >> "$TOPIC"
info "two probe messages published; waiting up to 30s for them to land..."
landed1=""; landed2=""
for _ in $(seq 1 30); do
  landed1="$(rows_only | awk -F'\t' -v k="$p1" '$2 == k { print $4; exit }')"
  landed2="$(rows_only | awk -F'\t' -v k="$p2" '$2 == k { print $4; exit }')"
  [ -n "$landed1" ] && [ -n "$landed2" ] && break
  sleep 1
done
[ "$landed1" = "12345" ] && pass "v1 probe landed with amount_cents=12345" \
  || fail "v1 probe: expected amount_cents=12345, got '${landed1:-<nothing>}'"
[ "$landed2" = "12345" ] && pass "v2 probe landed with amount_cents=12345" \
  || fail "v2 probe: expected amount_cents=12345, got '${landed2:-<nothing>}'"

echo
echo "CHECK 5  zero data loss and no double counting"
rows_only | awk -F'\t' '{ print $2 "\t" $4 }' > "$tmp/wh.tsv"
head -n -3 "$LEDGER" > "$tmp/led.tsv" 2>/dev/null || : > "$tmp/led.tsv"
expected="$(wc -l < "$tmp/led.tsv" | tr -d ' ')"
if [ "${expected:-0}" -lt 1 ]; then
  info "ledger too small to reconcile yet - let the publisher run a little longer"
else
  missing="$(awk -F'\t' 'NR == FNR { seen[$1] = 1; next } !($1 in seen) { m++ } END { print m + 0 }' "$tmp/wh.tsv" "$tmp/led.tsv")"
  dupes="$(awk -F'\t' 'NR == FNR { c[$1]++; next } ($1 in c) && c[$1] > 1 { d++ } END { print d + 0 }' "$tmp/wh.tsv" "$tmp/led.tsv")"
  wrong="$(awk -F'\t' 'NR == FNR { amt[$1] = $2; next } ($1 in amt) && ($2 + 0) != (amt[$1] + 0) { b++ } END { print b + 0 }' "$tmp/led.tsv" "$tmp/wh.tsv")"
  info "reconciling $expected published orders against the warehouse"
  [ "$missing" -eq 0 ] && pass "no missing orders" || fail "$missing published order(s) never reached the warehouse"
  [ "$dupes"   -eq 0 ] && pass "no duplicated orders" || fail "$dupes order(s) counted more than once"
  [ "$wrong"   -eq 0 ] && pass "every amount_cents matches the system of record" || fail "$wrong order(s) have the wrong amount"
fi
shopt -s nullglob
pending=( "$DLQ"/msg-*.json )
[ "${#pending[@]}" -eq 0 ] && pass "dead-letter queue is drained" \
  || fail "${#pending[@]} message(s) still stuck in the dead-letter queue"

echo
echo "-------------------------------------------------------------------------------"
printf " RESULT: %d passed, %d failed\n" "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo " STATUS: FIXED - the pipeline delivers, reconciles, and the report is honest."
  echo "-------------------------------------------------------------------------------"
  exit 0
fi
echo " STATUS: STILL BROKEN"
echo "-------------------------------------------------------------------------------"
exit 1
VERIFY_EOF

  chmod +x "$LAB_ROOT/bin/publisher.sh" "$LAB_ROOT/bin/ctl.sh" "$LAB_ROOT/bin/replay_dlq.sh" \
           "$LAB_ROOT/pipeline/stream_job.sh" "$LAB_ROOT/bi/dashboard.sh" "$LAB_ROOT/verify.sh"

  cat > "$LAB_ROOT/incidents/architecture.txt" <<'ARCH_EOF'
LAB COMPONENT                                  REAL GOOGLE CLOUD SERVICE
------------------------------------------------------------------------------
bin/publisher.sh                               checkout microservice on GKE /
                                               Cloud Run, publishing to Pub/Sub
pubsub/topic-retail-orders.ndjson              Pub/Sub topic
pubsub/subscriptions/analytics.cursor          Pub/Sub subscription + ack state
pipeline/stream_job.sh                         Dataflow streaming pipeline
                                               (Apache Beam, ParDo transform)
pipeline/dead_letter/                          Pub/Sub dead-letter topic
warehouse/fact_orders.tsv                      BigQuery table retail.fact_orders
bi/dashboard.sh                                Looker Studio / Looker report
pubsub/ledger.expected                         the OLTP system of record
                                               (Cloud SQL / Spanner)
verify.sh                                      data quality + reconciliation
                                               job (Dataplex / Dataform tests)
ARCH_EOF

  ok "lab provisioned at $LAB_ROOT"
}

#------------------------------------------------------------------------------
# Fault injection
#------------------------------------------------------------------------------
inject_break() {
  echo v2 > "$LAB_ROOT/pubsub/schema_version"
  cat >> "$LAB_ROOT/incidents/changelog-app-team.txt" <<'CHANGELOG_EOF'
release: checkout-service v2.4.0            channel: #eng-releases
-------------------------------------------------------------------------------
  * order events migrated to payload schema v2:
        amount (USD float)   -> amount_cents (integer)
        ts (epoch seconds)   -> event_time (RFC3339 string)
        region (top level)   -> geo.region (nested)
    Rationale: floats were causing rounding drift in refunds; RFC3339 is what
    the mobile SDK emits natively.
  * no consumer changes required (we did not change the topic name)
  * data platform review: [ ] TODO - will file a ticket next sprint
-------------------------------------------------------------------------------
CHANGELOG_EOF
  printf '[%s] BREAK INJECTED: producer switched to payload schema v2\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LAB_ROOT/logs/lab.log"
}

#------------------------------------------------------------------------------
# Observability helpers
#------------------------------------------------------------------------------
lab_status() {
  local topic="$LAB_ROOT/pubsub/topic-retail-orders.ndjson"
  local cursor_f="$LAB_ROOT/pubsub/subscriptions/analytics.cursor"
  local table="$LAB_ROOT/warehouse/fact_orders.tsv"
  local published cursor backlog rows dlq mx fresh

  published="$(wc -l < "$topic" 2>/dev/null | tr -d ' ' || echo 0)"
  cursor="$(cat "$cursor_f" 2>/dev/null || echo 0)"
  backlog=$(( published - cursor ))
  rows="$(awk -F'\t' '$1 ~ /^[0-9]+$/' "$table" 2>/dev/null | wc -l | tr -d ' ')"
  dlq="$(find "$LAB_ROOT/pipeline/dead_letter" -maxdepth 1 -name 'msg-*.json' 2>/dev/null | wc -l | tr -d ' ')"
  mx="$(awk -F'\t' '$1 ~ /^[0-9]+$/ && $1 + 0 > m { m = $1 + 0 } END { print m + 0 }' "$table" 2>/dev/null || echo 0)"

  head1 "PLATFORM STATUS"
  bash "$LAB_ROOT/bin/ctl.sh" status | sed 's/^/  /'
  say "  producer payload schema     : $(cat "$LAB_ROOT/pubsub/schema_version" 2>/dev/null || echo '?')"
  say "  messages published          : $published"
  say "  subscription backlog        : $backlog        <- Pub/Sub num_undelivered_messages"
  say "  dead-lettered (pending)     : $dlq"
  say "  warehouse rows              : $rows"
  if [ "$mx" -gt 0 ]; then
    fresh=$(( $(date +%s) - mx ))
    say "  newest event in warehouse   : ${fresh}s ago  ($(date -u -d "@$mx" +%Y-%m-%dT%H:%M:%SZ))"
  else
    say "  newest event in warehouse   : (empty table)"
  fi
}

#------------------------------------------------------------------------------
# The student briefing
#------------------------------------------------------------------------------
briefing() {
  cat <<'BRIEF_EOF'

===============================================================================
 INCIDENT BRIEFING -- you are the on-call data platform engineer
===============================================================================

THE BUSINESS SITUATION
  Your company runs a retail site. Orders flow through a streaming analytics
  pipeline into a warehouse table, and the "Revenue Operations" report on top
  of it is what the pricing committee looks at every morning before deciding
  regional discounts. The whole reason the business paid for streaming instead
  of a nightly batch load is that a discount decision made on yesterday's
  numbers costs real money.

  Fifteen minutes ago the checkout team deployed. Nothing paged. Nothing
  crashed. The pipeline is "healthy".

THE SYMPTOM YOU WILL SEE
  1. `status` shows subscription backlog at or near ZERO. Every message is
     being consumed. By the classic queue metric, the platform is perfect.
  2. The warehouse row count has STOPPED GROWING. Revenue for the last window
     flatlines and then empties out, region by region, as the 15-minute window
     slides past the last good record.
  3. The BI report still prints data_freshness_seconds=0 and
     dashboard_status=OK. It will keep printing that forever, including a week
     from now, on data that stopped moving today. This is the dangerous part:
     a broken pipeline is an incident, a broken pipeline with a green freshness
     KPI is a wrong business decision.
  4. pipeline/dead_letter/ is filling with rejected payloads, and
     pipeline/job.log is full of DEADLETTER lines with a reason code.

YOUR MISSION -- all five checks in ./verify.sh must pass
  1. The streaming job must be running.
  2. Warehouse freshness must be under 120 seconds: new orders arriving now
     must reach the table now.
  3. The report must publish the TRUE freshness of the DATA, not the time the
     report ran. verify.sh proves this by pausing the pipeline for 25 seconds
     and checking whether the report notices.
  4. The pipeline must accept BOTH payload versions. You do not get to break
     the old clients: mobile app builds already in users' hands still emit v1,
     and every historical dead-lettered message is v2. Backward and forward
     compatibility, in the same transform.
  5. Zero data loss and zero double counting. Every order in the system of
     record (pubsub/ledger.expected) must appear in the warehouse EXACTLY ONCE
     with the correct amount_cents, and the dead-letter queue must be drained.
     Money already earned while the pipeline was down must be recovered, not
     written off.

RULES OF ENGAGEMENT
  * You may edit  pipeline/stream_job.sh  and  bi/dashboard.sh.
  * You may not edit verify.sh, publisher.sh, or the ledger.
  * You may not hand-write rows into the warehouse table. Recovery goes
    through the pipeline, exactly as a dead-letter replay does in production.
  * Restart the job after editing it:  bin/ctl.sh restart-job
    (a Dataflow streaming job is likewise redeployed, not hot-patched)

WHERE TO START LOOKING (the exact commands)
    ./break-and-fix-2.3.sh status
    ./break-and-fix-2.3.sh dashboard
    tail -n 20 pipeline/job.log                 # what is the reason code?
    ls pipeline/dead_letter/ | head             # how much is stuck?
    cat pipeline/dead_letter/msg-*.json | head -1   # what does the payload
                                                    # look like NOW?
    tail -n 3 pubsub/topic-retail-orders.ndjson     # ...versus earlier
    head -n 1 pubsub/topic-retail-orders.ndjson
    cat incidents/changelog-app-team.txt        # somebody did tell you
    diff <(head -n1 pubsub/topic-retail-orders.ndjson) \
         <(tail -n1 pubsub/topic-retail-orders.ndjson)

  Then grade yourself:   ./verify.sh
===============================================================================
BRIEF_EOF
}

exam_notes() {
  cat <<'EXAM_EOF'

===============================================================================
 EXAM CONTEXT -- what this incident is teaching for CDL objective 2.3
===============================================================================

THE THREE ANALYTICS SHAPES, AND WHEN EACH EARNS ITS COST
  Batch analytics       hours-to-days latency, lowest cost per TB. Correct for
                        month-end close, cohort analysis, ML training sets.
                        The answer is not less true for being late.
  Streaming analytics   seconds latency, higher cost and higher operational
                        surface (windows, watermarks, late data, schemas).
                        Justified only when a DECISION or an ACTION happens
                        inside that window: fraud blocking, dynamic pricing,
                        inventory reservation, live logistics ETAs.
  Business intelligence self-service exploration on top of whichever of the two
                        fed the warehouse. Its value is decided entirely by the
                        trust the audience has in the number on screen.
  The exam-level judgement: streaming is not "better" than batch, it is a
  latency purchase. If nobody acts on the data before tomorrow, streaming is
  money spent on latency nobody consumes.

THE GOOGLE CLOUD SERVICE MAP (and what each one is FOR)
  Pub/Sub          global message ingestion, decoupling producers from
                   consumers; at-least-once delivery, dead-letter topics,
                   optional schema enforcement.
  Dataflow         serverless Apache Beam; ONE programming model for batch and
                   streaming, so the same transform serves both.
  BigQuery         serverless analytical warehouse: petabyte SQL, separated
                   storage and compute, streaming ingest via the Storage Write
                   API, and BigQuery ML for models written in SQL.
  Bigtable         NOT a warehouse. Low-latency wide-column store for very high
                   write throughput and key-based lookups (time series, IoT).
                   Choosing it for ad-hoc analytics is a classic exam trap.
  Looker           governed semantic layer: metrics defined ONCE in LookML, so
                   "revenue" means the same thing in every report.
  Looker Studio    free, self-service reporting and dashboards.
  Dataproc         managed Hadoop/Spark, chiefly for LIFTING AND SHIFTING an
                   existing OSS estate rather than for greenfield pipelines.
  Dataplex         data governance, cataloguing and quality across the estate.
  Datastream       change data capture from operational databases.
  Pub/Sub -> BigQuery subscriptions: for pass-through ingest with no transform,
                   they remove the Dataflow job entirely - less to break, and
                   the schema is enforced by the subscription.

QUESTIONS THIS LAB SHOULD LET YOU ANSWER FROM EXPERIENCE, NOT MEMORY
  1. The subscription backlog was zero throughout a total data outage. Why?
     What metric would actually have paged you, and who owns defining it?
  2. What did the dead-letter topic buy the business, in money, during the
     incident? Compute it: (dead-lettered messages) x (average order value)
     is exactly the revenue that would have been lost forever if those
     messages had merely been dropped or infinitely retried.
  3. Which single Google Cloud feature would have prevented the whole incident
     at the source, and where does it sit in the architecture?
     (Pub/Sub schema enforcement: an incompatible payload is rejected AT
     PUBLISH TIME, so the failure lands on the team that caused it, at deploy,
     instead of on the analytics team, at 3 a.m., invisibly.)
  4. The pricing committee made a decision at 09:00 using this report. What is
     the cost of a green freshness KPI over stale data, versus the cost of a
     red one that is honest? Which failure mode does a data leader design for?
  5. If this workload were month-end reporting instead of live pricing, what
     would you delete from the architecture, and how much would you save?
  6. Your CFO asks why "the dashboard" costs money. Separate for them: ingest
     (Pub/Sub), transform (Dataflow), storage (BigQuery), query (BigQuery
     on-demand vs editions/slots), acceleration (BI Engine), and licensing
     (Looker vs Looker Studio). Which line item does streaming actually grow?

OFFICIAL SOURCES
  Cloud Digital Leader exam guide
    https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
  Pub/Sub - handling message failures (dead-letter topics)
    https://cloud.google.com/pubsub/docs/handling-failures
  Pub/Sub - schemas
    https://cloud.google.com/pubsub/docs/schemas
  Pub/Sub - replay and discard messages
    https://cloud.google.com/pubsub/docs/replay-overview
  Pub/Sub - BigQuery subscriptions
    https://cloud.google.com/pubsub/docs/bigquery
  Dataflow - streaming pipelines with Pub/Sub
    https://cloud.google.com/dataflow/docs/concepts/streaming-with-cloud-pubsub
  Beam programming model - windows, watermarks, late data
    https://cloud.google.com/dataflow/docs/concepts/beam-programming-model
  BigQuery - Storage Write API
    https://cloud.google.com/bigquery/docs/write-api
  BigQuery - modifying table schemas
    https://cloud.google.com/bigquery/docs/managing-table-schemas
  BigQuery BI Engine
    https://cloud.google.com/bigquery/docs/bi-engine-intro
  Looker Studio documentation
    https://cloud.google.com/looker/docs/studio
  Bigtable overview
    https://cloud.google.com/bigtable/docs/overview
  Dataproc overview
    https://cloud.google.com/dataproc/docs/concepts/overview
  Datastream overview
    https://cloud.google.com/datastream/docs/overview
  Dataplex overview
    https://cloud.google.com/dataplex/docs/introduction
  Google Cloud metrics (pubsub.googleapis.com/subscription/...)
    https://cloud.google.com/monitoring/api/metrics_gcp
===============================================================================
EXAM_EOF
}

#------------------------------------------------------------------------------
# Subcommands
#------------------------------------------------------------------------------
cmd_setup() {
  preflight
  consent
  build_lab

  head1 "STARTING THE PLATFORM (healthy, payload schema v1)"
  bash "$LAB_ROOT/bin/ctl.sh" start | sed 's/^/  /'
  say "  warming up for ${WARMUP_SECS}s so the report has real traffic..."
  sleep "$WARMUP_SECS"
  lab_status
  head1 "THE REPORT, BEFORE THE INCIDENT"
  bash "$LAB_ROOT/bi/dashboard.sh"

  head1 "INJECTING THE FAULT"
  say "  the checkout team is deploying checkout-service v2.4.0..."
  inject_break
  warn "producer payload contract changed. No consumer was told."
  say "  letting the incident develop for ${BREAK_SECS}s..."
  sleep "$BREAK_SECS"

  lab_status
  head1 "THE REPORT, AFTER THE INCIDENT (note what it still claims)"
  bash "$LAB_ROOT/bi/dashboard.sh"
  head1 "STREAMING JOB LOG (last 8 lines)"
  tail -n 8 "$LAB_ROOT/pipeline/job.log" 2>/dev/null | sed 's/^/  /' || true

  briefing
  exam_notes

  head1 "YOUR WORKING DIRECTORY"
  say "  cd $LAB_ROOT"
  say "  ./verify.sh          # the goal: 'STATUS: FIXED'"
  rule
  say "The pipeline keeps running while you work. Stop it with: $0 stop"
  say "Delete the whole lab with: $0 clean"
  rule
}

cmd_clean() {
  [ -d "$LAB_ROOT" ] || { warn "nothing to clean at $LAB_ROOT"; return 0; }
  [ -f "$LAB_ROOT/$MARKER_FILE" ] || die "refusing to delete $LAB_ROOT: marker $MARKER_FILE not found"
  case "$LAB_ROOT" in
    /|/home|/root|"$HOME") die "refusing to delete $LAB_ROOT" ;;
  esac
  bash "$LAB_ROOT/bin/ctl.sh" stop >/dev/null 2>&1 || true
  rm -rf -- "$LAB_ROOT"
  ok "removed $LAB_ROOT"
}

require_lab() { [ -f "$LAB_ROOT/$MARKER_FILE" ] || die "no lab at $LAB_ROOT - run: $0 setup"; }

FORCE=0
CMD=""
for arg in "$@"; do
  case "$arg" in
    --yes|-y) FORCE=1 ;;
    -h|--help) sed -n '1,60p' "$0"; exit 0 ;;
    *) [ -z "$CMD" ] && CMD="$arg" ;;
  esac
done
CMD="${CMD:-setup}"

case "$CMD" in
  setup)     cmd_setup ;;
  status)    require_lab; lab_status ;;
  dashboard) require_lab; bash "$LAB_ROOT/bi/dashboard.sh" ;;
  logs)      require_lab; tail -n 40 "$LAB_ROOT/pipeline/job.log" ;;
  verify)    require_lab; bash "$LAB_ROOT/verify.sh" ;;
  start)     require_lab; bash "$LAB_ROOT/bin/ctl.sh" start ;;
  stop)      require_lab; bash "$LAB_ROOT/bin/ctl.sh" stop ;;
  brief)     briefing; exam_notes ;;
  clean)     cmd_clean ;;
  *)         die "unknown command '$CMD' (setup|status|dashboard|logs|verify|start|stop|brief|clean)" ;;
esac

exit 0

#===============================================================================
#
#   S O L U T I O N   --   do not read before verify.sh has failed on you twice
#
#===============================================================================
#
# STEP 0 - REPRODUCE AND NAME THE FAULT BEFORE TOUCHING ANYTHING
#
#   cd "$HOME/gcp-cdl-lab/2.3-smart-analytics"
#   ./verify.sh                      # baseline: which checks fail, and why
#   tail -n 5 pipeline/job.log
#
#   Expected log lines:
#     DEADLETTER line=27 reason=UNPARSEABLE_EVENT_TIME payload_schema=v2
#
#   The reason code names the field, and payload_schema=v2 names the cause.
#   Confirm it against the wire format - first message versus last message:
#
#     head -n 1 pubsub/topic-retail-orders.ndjson
#       {"schema":"v1","order_id":"ord-000001","ts":1757160000,
#        "region":"us-central1","amount":124.37,"channel":"web"}
#     tail -n 1 pubsub/topic-retail-orders.ndjson
#       {"schema":"v2","order_id":"ord-000042","event_time":"2026-09-06T11:34:02Z",
#        "geo":{"region":"europe-west1"},"amount_cents":12437,"channel":"web"}
#
#   Three simultaneous contract changes:
#     ts (epoch int)     -> event_time (RFC3339 string)
#     amount (USD float) -> amount_cents (integer)
#     region (top level) -> geo.region (nested)
#
#   Note which of the three actually broke the job: the timestamp and the
#   amount, because the transform REQUIRED them. `region` moved too, and the
#   naive field reader kept finding it by key name anyway. Not every contract
#   change is an outage - the required fields are the blast radius.
#
#   Also confirm the diagnosis that matters for the exam:
#     ./break-and-fix-2.3.sh status
#   Backlog is 0. Consumption is perfect. Delivery is zero. Write down why:
#   the job acknowledges dead-lettered messages, because a poison message that
#   is never acked blocks the subscription forever. Availability and
#   correctness are different SLOs, and only one of them was being measured.
#
# STEP 1 - MAKE THE TRANSFORM SCHEMA-TOLERANT (fixes CHECK 4 and re-opens flow)
#
#   Edit pipeline/stream_job.sh and replace process_message() with a version
#   that accepts BOTH contracts. The rule is: prefer the new field, fall back
#   to the old one, normalise both to the warehouse's canonical types
#   (epoch seconds, integer cents). Never break the old producer - v1 clients
#   are still out there, and every dead-lettered payload you must replay is v2.
#
#     process_message() {
#       local raw="$1" order_id ts region cents amount event_time
#       order_id="$(json_str order_id "$raw")"
#       region="$(json_str region "$raw")"          # works flat AND nested
#
#       # --- event time: v1 "ts" epoch, v2 "event_time" RFC3339 -------------
#       ts="$(json_num ts "$raw")"
#       if [ -z "$ts" ]; then
#         event_time="$(json_str event_time "$raw")"
#         if [ -n "$event_time" ]; then
#           ts="$(date -u -d "$event_time" +%s 2>/dev/null || true)"
#         fi
#       fi
#
#       # --- money: v2 integer cents wins, v1 float dollars is converted -----
#       cents="$(json_num amount_cents "$raw")"
#       if [ -z "$cents" ]; then
#         amount="$(json_num amount "$raw")"
#         if [ -n "$amount" ]; then
#           cents="$(awk -v a="$amount" 'BEGIN { printf "%d", (a * 100) + 0.5 }')"
#         fi
#       fi
#
#       [ -n "$order_id" ] || return 1
#       [ -n "$ts" ]       || return 2
#       [ -n "$cents" ]    || return 3
#
#       printf '%s\t%s\t%s\t%s\t%s' \
#         "$ts" "$order_id" "${region:-unknown}" "$cents" "$(date +%s)"
#     }
#
#   Order matters in the money branch: check amount_cents FIRST. If you check
#   `amount` first you will not match v2 at all (json_num anchors on the exact
#   quoted key, so "amount_cents" never matches "amount") - but the day someone
#   ships a payload carrying both, prefer-new-then-fallback is what keeps you
#   from multiplying an already-integer cents value by 100 and inflating
#   revenue 100x. Silent 100x revenue is worse than an outage: an outage is
#   visible.
#
#   Redeploy the job (streaming jobs are redeployed, not edited in place):
#
#     bin/ctl.sh restart-job
#     sleep 8
#     tail -n 5 pipeline/job.log         # ACK lines again, no DEADLETTER
#     ./break-and-fix-2.3.sh status      # warehouse rows growing again
#
#   CHECK 2 and CHECK 4 pass now. CHECK 5 still fails: new orders flow, but the
#   ones dead-lettered during the incident are still missing revenue.
#
# STEP 2 - REPLAY THE DEAD LETTERS (fixes the data-loss half of CHECK 5)
#
#     ls pipeline/dead_letter/ | wc -l          # how much money is stuck
#     bin/replay_dlq.sh
#     sleep 8
#     ls pipeline/dead_letter/msg-*.json 2>/dev/null | wc -l   # -> 0
#
#   Order is not optional: replay AFTER the consumer is fixed. Replaying into a
#   broken consumer just dead-letters everything a second time. Notice also
#   what replay_dlq.sh does with each payload - it MOVES it to replayed/ - so
#   running it twice cannot double-count. That is the whole idea behind
#   idempotent recovery, and it is why CHECK 5 tests for duplicates as well as
#   for missing rows. In real Pub/Sub the same recovery is either a subscriber
#   on the dead-letter topic re-publishing to the main topic, or a `seek` to a
#   snapshot/timestamp taken before the bad deploy.
#
#   Sanity check the recovered revenue by hand:
#
#     awk -F'\t' '$1 ~ /^[0-9]+$/ { s += $4 } END { printf "warehouse: $%.2f\n", s/100 }' \
#       warehouse/fact_orders.tsv
#     awk -F'\t' '{ s += $2 } END { printf "ledger:    $%.2f\n", s/100 }' \
#       pubsub/ledger.expected
#
#   (The warehouse total also contains verify.sh's probes; reconcile per
#   order_id, as verify.sh does, not on the grand total.)
#
# STEP 3 - MAKE THE DASHBOARD TELL THE TRUTH (fixes CHECK 3)
#
#   The pipeline is healthy again, and the report has been green throughout -
#   including while it was showing nothing. That KPI was never measuring the
#   data. In bi/dashboard.sh, replace:
#
#     data_freshness_seconds=$(( now - report_generated_at ))     # always 0
#
#   with a value derived from the newest event actually in the table:
#
#     max_event_time="$(awk -F'\t' '
#       $1 ~ /^[0-9]+$/ && $1 + 0 > m { m = $1 + 0 }
#       END { print m + 0 }' "$TABLE")"
#     if [ "$max_event_time" -eq 0 ]; then
#       data_freshness_seconds=999999      # empty table is maximally stale,
#     else                                 # never "fresh"
#       data_freshness_seconds=$(( now - max_event_time ))
#     fi
#
#   The BigQuery equivalent, which is what you would actually put behind the
#   tile in Looker Studio:
#
#     SELECT TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(event_time), SECOND)
#              AS data_freshness_seconds
#     FROM `retail.fact_orders`;
#
#   Two subtleties worth carrying into the exam and into real reviews:
#     * measure EVENT time (when the order happened), not ingestion time. An
#       ingestion-time KPI goes green the moment a backfill lands, even if the
#       backfill is a week old.
#     * the empty-table case must fail LOUD. NULL/0/absent must render as
#       stale, never as fresh. Most false-green dashboards are one unhandled
#       empty result set.
#
#     ./break-and-fix-2.3.sh dashboard      # freshness now moves with the data
#
# STEP 4 - PROVE IT
#
#     ./verify.sh
#
#   Expected:
#     [ PASS ] the streaming job is running
#     [ PASS ] newest event is 3s old (< 120s)
#     [ PASS ] the freshness KPI is derived from the data (delta 1s)
#     [ PASS ] the report still publishes a dashboard_status line
#     [ PASS ] v1 probe landed with amount_cents=12345
#     [ PASS ] v2 probe landed with amount_cents=12345
#     [ PASS ] no missing orders
#     [ PASS ] no duplicated orders
#     [ PASS ] every amount_cents matches the system of record
#     [ PASS ] dead-letter queue is drained
#     RESULT: 10 passed, 0 failed
#     STATUS: FIXED - the pipeline delivers, reconciles, and the report is honest.
#
#   Watch CHECK 3 while it runs: verify.sh pauses the streaming job for 25
#   seconds on purpose. A correct report notices and reports ~25s. The original
#   report would have reported 0 - which is exactly what it reported during a
#   fifteen-minute total outage.
#
# STEP 5 - THE PART THAT IS ACTUALLY ON THE EXAM: PREVENTION
#
#   Fixing the parser is engineering. The CDL-level answer is that the fix
#   belongs upstream of the incident, at four different layers:
#
#   a) CONTRACT AT THE SOURCE. Attach a schema to the Pub/Sub topic (Avro or
#      protocol buffer) with a compatibility mode. An incompatible payload is
#      then rejected at PUBLISH time: the checkout team's deploy fails in their
#      own CI, in their own sprint, instead of silently emptying someone else's
#      dashboard at 3 a.m. This single control would have prevented the entire
#      incident.
#      https://cloud.google.com/pubsub/docs/schemas
#
#   b) ALERT ON THE OUTCOME, NOT ON THE PLUMBING. Backlog was zero all along.
#      The signals that would have paged you:
#        - freshness SLO: MAX(event_time) older than N minutes
#        - dead-letter arrival rate > 0 for M consecutive minutes
#        - a rows-per-minute floor: expected volume vs observed
#      Two of those are business metrics, and the platform team cannot define
#      them alone. Deciding the freshness SLO is a business conversation:
#      "how stale can this number be before the decision it drives is wrong?"
#      https://cloud.google.com/monitoring/api/metrics_gcp
#
#   c) NEVER DROP, ALWAYS QUARANTINE. The dead-letter topic is what turned a
#      permanent revenue loss into a fifteen-minute delay. Quantify it for your
#      leadership in money, not in messages: dead-lettered count x average
#      order value is the number the CFO understands, and it is the entire
#      business case for the pattern.
#      https://cloud.google.com/pubsub/docs/handling-failures
#
#   d) LESS PIPELINE, LESS BLAST RADIUS. This transform did almost nothing:
#      rename, retype, write. A Pub/Sub BigQuery subscription with a schema
#      would have carried it with no custom code to break - and where a
#      transform IS genuinely needed, one Beam pipeline serves batch and
#      streaming both, so the recovery path and the live path are the same
#      code. Every line of bespoke pipeline is a line that can silently
#      disagree with its producer.
#      https://cloud.google.com/pubsub/docs/bigquery
#
#   And the one-sentence version, which is the actual content of objective 2.3:
#   the value of smart analytics, BI and streaming is not the latency, the
#   dashboards, or the technology - it is whether a human can bet a business
#   decision on the number in front of them. A pipeline that stops is an
#   incident; a dashboard that lies about having stopped is a wrong decision,
#   made confidently, at scale.
#
# TEARDOWN
#     ./break-and-fix-2.3.sh clean
#===============================================================================