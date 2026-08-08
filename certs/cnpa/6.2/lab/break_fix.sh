#!/usr/bin/env bash
#
# CNPA — Cloud Native Platform Engineering Associate
# Domain 6: Measuring Your Platform  |  Topic 6.2: DORA Metrics and Indicators
#                                        for Platform Initiatives  (weight 4.0)
# Exam version: 2025-04-01
#
# Lab type: BREAK & FIX  (safe on a disposable lab VM)
#
# What this lab teaches
# ---------------------
# A platform team ships an Internal Developer Platform (IDP) "golden path" —
# a standardized CI/CD template every service adopts. To prove the initiative
# worked, they measure the four DORA keys over a rolling window:
#
#     1. Deployment Frequency        (throughput)
#     2. Lead Time for Changes       (throughput)
#     3. Change Failure Rate         (stability)
#     4. Failed Deployment Recovery  (stability, formerly "MTTR")
#
# The keys are computed from two independent event streams the platform emits:
#   - deployments.csv : one row per deploy, with an `outcome` classification
#   - incidents.csv   : one row per production incident, joined to a deploy
#
# This script builds that tiny metrics pipeline inside a scratch directory,
# then injects ONE realistic fault. Your job is to find it and restore a
# metric you can trust. Nothing outside the lab directory is touched: no root,
# no network, no system services, no containers. Re-running the script resets
# the lab.
#
# Sources
#   - CNPA Curriculum (CNCF):
#       https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
#   - DORA — the Four Keys / core model:
#       https://dora.dev/guides/dora-metrics-four-keys/
#   - DORA research & Accelerate State of DevOps reports (performance bands):
#       https://dora.dev/research/
#   - Reference implementation (Google/DORA "Four Keys"):
#       https://github.com/dora-team/fourkeys
#
set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/dora-lab}"

# ---------------------------------------------------------------------------
# 0. Preconditions — coreutils only, no privileges required.
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  echo "WARNING: running as root is unnecessary for this lab." >&2
fi
for tool in awk sort date printf seq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: '$tool' not found." >&2; exit 1; }
done

mkdir -p "$LAB_DIR"
echo ">> Building DORA metrics lab in: $LAB_DIR"

# ---------------------------------------------------------------------------
# 1. The metrics engine (compute-dora.sh) — this is CORRECT, do not blame it.
#    It reads its metric DEFINITIONS from dora.env, then aggregates the two
#    event streams into the four keys.
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/compute-dora.sh" <<'DORA_EOF'
#!/usr/bin/env bash
# DORA four-key aggregator. Reads metric definitions from dora.env and computes
# the keys over a rolling window ending "now".
set -euo pipefail
cd "$(dirname "$0")"

# --- metric definitions (data-driven; edit dora.env, not this file) ----------
. ./dora.env
NOW="${NOW_OVERRIDE:-$(date +%s)}"
WINDOW_START=$(( NOW - WINDOW_DAYS * 86400 ))

# median: read whitespace-separated numbers on stdin, print integer median.
median() {
  sort -n | awk '
    { a[NR] = $1 }
    END {
      if (NR == 0) { print 0; exit }
      if (NR % 2) { print a[int((NR+1)/2)] }
      else        { print int((a[NR/2] + a[NR/2 + 1]) / 2) }
    }'
}

# human-readable duration.
fmt() { printf '%dh %02dm' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )); }

# deployments.csv columns: deploy_id,service,committed_at,deployed_at,outcome
total=$(awk -F, -v s="$WINDOW_START" 'NR>1 && $4>=s {c++} END{print c+0}' deployments.csv)

# Change Failure Rate: a deploy is a "failure" iff its outcome is one of the
# tokens the platform declares failing in FAILED_STATES.
failed=$(awk -F, -v s="$WINDOW_START" -v states="$FAILED_STATES" '
  BEGIN { n = split(states, arr, /[ ,]+/); for (i=1;i<=n;i++) fail[arr[i]] = 1 }
  NR>1 && $4>=s && ($5 in fail) { c++ }
  END { print c+0 }' deployments.csv)

lead_med=$(awk -F, -v s="$WINDOW_START" 'NR>1 && $4>=s {print $4-$3}' deployments.csv | median)

# incidents.csv columns: incident_id,deploy_id,detected_at,restored_at
inc_count=$(awk -F, -v s="$WINDOW_START" 'NR>1 && $3>=s {c++} END{print c+0}' incidents.csv)
rec_med=$(awk -F, -v s="$WINDOW_START" 'NR>1 && $3>=s {print $4-$3}' incidents.csv | median)

dfday=$(awk -v t="$total" -v d="$WINDOW_DAYS" 'BEGIN{printf "%.2f", (d>0)? t/d : 0}')
cfr=$(awk   -v f="$failed" -v t="$total"     'BEGIN{printf "%.1f", (t>0)? f/t*100 : 0}')

echo   "==========================================================="
printf 'DORA four keys — golden-path initiative (rolling %s-day window)\n' "$WINDOW_DAYS"
echo   "==========================================================="
printf '  Deployment Frequency     : %s deploys   (%s/day)\n' "$total" "$dfday"
printf '  Lead Time for Changes    : %s   (median)\n' "$(fmt "$lead_med")"
printf '  Change Failure Rate      : %s%%   (%s failed / %s total)\n' "$cfr" "$failed" "$total"
printf '  Failed Deploy Recovery   : %s   (median over %s incidents)\n' "$(fmt "$rec_med")" "$inc_count"
echo   "-----------------------------------------------------------"
echo   "  Bands: see dora.dev/research (Elite/High/Medium/Low vary by report)"
echo   "==========================================================="
DORA_EOF
chmod +x "$LAB_DIR/compute-dora.sh"

# ---------------------------------------------------------------------------
# 2. Generate the two event streams (the raw telemetry — this is the TRUTH).
#    25 deploys spread over ~14 days; 5 of them genuinely failed and each
#    produced a production incident.
# ---------------------------------------------------------------------------
now=$(date +%s)
total_deploys=25
spacing=48384                       # ~14 days / 25 deploys, in seconds
services=(checkout-api payments-api web-frontend)

{
  echo "deploy_id,service,committed_at,deployed_at,outcome"
  for i in $(seq 1 "$total_deploys"); do
    deployed=$(( now - (total_deploys - i) * spacing ))
    lead=$(( 1800 + (i % 6) * 1200 ))          # 30m .. 2h10m of lead time
    committed=$(( deployed - lead ))
    svc="${services[$(( (i - 1) % ${#services[@]} ))]}"
    outcome=success
    case "$i" in 5|11|18|23|25) outcome=failed ;; esac
    printf 'dep-%03d,%s,%d,%d,%s\n' "$i" "$svc" "$committed" "$deployed" "$outcome"
  done
} > "$LAB_DIR/deployments.csv"

failed_list=(5 11 18 23 25)
recoveries=(1200 2400 900 3600 1800)           # seconds to restore each incident
{
  echo "incident_id,deploy_id,detected_at,restored_at"
  for n in "${!failed_list[@]}"; do
    i="${failed_list[$n]}"
    deployed=$(( now - (total_deploys - i) * spacing ))
    detected=$(( deployed + 300 ))             # detected 5 min after the bad deploy
    restored=$(( detected + recoveries[n] ))
    printf 'inc-%03d,dep-%03d,%d,%d\n' "$(( n + 1 ))" "$i" "$detected" "$restored"
  done
} > "$LAB_DIR/incidents.csv"

# ---------------------------------------------------------------------------
# 3. THE BREAK — inject the fault into the metric DEFINITION, not the data.
#    The deployment pipeline emits the outcome token `failed`, but the metric
#    definition below tells the aggregator that failures are called something
#    else. Classic "definition drift": the config was copied from a different
#    tool's vocabulary and never reconciled with what this pipeline emits.
# ---------------------------------------------------------------------------
cat > "$LAB_DIR/dora.env" <<'ENV_EOF'
# DORA metric definitions for the golden-path platform initiative.
# WINDOW_DAYS   : size of the rolling reporting window.
# FAILED_STATES : outcome tokens (space/comma separated) that count as a
#                 Change Failure for CFR. MUST match what the deploy pipeline
#                 actually writes into deployments.csv column `outcome`.
WINDOW_DAYS=21
FAILED_STATES="failure crashloop"
ENV_EOF

# ---------------------------------------------------------------------------
# 4. Brief the student.
# ---------------------------------------------------------------------------
cat <<BRIEF

===============================================================================
 LAB READY — Topic 6.2: DORA Metrics and Indicators for Platform Initiatives
===============================================================================

 Run the platform's metrics report now:

     cd "$LAB_DIR" && ./compute-dora.sh

 SYMPTOM YOU WILL SEE
 --------------------
 The report shows:

     Change Failure Rate : 0.0%   (0 failed / 25 total)

 A flawless, "impossibly perfect" stability score — and leadership is ready to
 declare the golden-path initiative a success on the strength of it. Yet the
 SAME report shows 5 production incidents were recorded and recovered, and the
 raw deployment log plainly contains failed deployments. The other three keys
 (Deployment Frequency, Lead Time, Failed Deploy Recovery) look reasonable.
 Only the Change Failure Rate is silently lying.

 YOUR GOAL
 ---------
 Make the Change Failure Rate reflect reality. With 5 failed deployments out of
 25, a trustworthy CFR is 20.0%. Fix the METRIC PIPELINE, not the telemetry:

     - You may edit configuration / metric definitions.
     - You may NOT edit deployments.csv or incidents.csv (that is fabricating
       the number, the exact anti-pattern this topic warns against).

 All four keys must be defensible when leadership asks "how do you know?".

 Everything lives in: $LAB_DIR   (delete it to clean up; re-run this script to reset)
===============================================================================

BRIEF

exit 0

# =============================================================================
# SOLUTION — step by step (do not peek until you have tried).
# =============================================================================
#
# Root cause
# ----------
# The metric is broken by DEFINITION DRIFT, a leading cause of untrustworthy
# platform metrics. The deployment pipeline classifies bad deploys with the
# outcome token `failed`, but dora.env declares:
#
#     FAILED_STATES="failure crashloop"
#
# Neither token matches `failed`, so the aggregator's classifier
# (`$5 in fail`) never matches a single row: 0 failures counted, CFR = 0.0%.
# Nothing is wrong with the engine or the raw data — the *meaning* of "failure"
# was configured wrong. Change Failure Rate is the only key affected because
# it is the only key that depends on this classification; Failed Deploy
# Recovery is computed straight from incidents.csv and is unaffected, which is
# exactly why the two signals contradict each other.
#
# Diagnosis
# ---------
#   1. Notice the contradiction. CFR = 0% while the report also states there
#      were 5 incidents. Two independent signals disagree — treat that, and any
#      "perfect" stability metric, as a red flag, never as good news.
#
#        cd "$LAB_DIR"
#        ./compute-dora.sh
#
#   2. Trust the raw telemetry over the summary. What outcome tokens does the
#      pipeline actually emit?
#
#        awk -F, 'NR>1 {print $5}' deployments.csv | sort | uniq -c
#        #   -> 20 success
#        #   ->  5 failed        <-- the real vocabulary
#
#   3. Inspect the metric definition the classifier consumes, and confirm the
#      classifier keys on that variable:
#
#        cat dora.env
#        #   FAILED_STATES="failure crashloop"     <-- does NOT include "failed"
#        grep -n 'FAILED_STATES\|in fail' compute-dora.sh
#
#      The set {failure, crashloop} and the set {failed} are disjoint: the bug.
#
# Fix
# ---
#   Align the definition with what the pipeline emits (edit config, not data):
#
#        sed -i 's/^FAILED_STATES=.*/FAILED_STATES="failed"/' dora.env
#
#   (If your pipeline could legitimately emit several failing tokens, list them
#   all, e.g. FAILED_STATES="failed rolled_back timeout" — but only tokens that
#   deployments.csv actually contains.)
#
# Verify
# ------
#        ./compute-dora.sh
#        #   Change Failure Rate : 20.0%   (5 failed / 25 total)
#
#   Cross-check the two once-contradictory signals now agree: 5 failed deploys
#   and 5 incidents. Sanity-check independently of the tool:
#
#        f=$(awk -F, 'NR>1 && $5=="failed"{c++} END{print c+0}' deployments.csv)
#        t=$(awk -F, 'NR>1{c++} END{print c+0}' deployments.csv)
#        awk -v f="$f" -v t="$t" 'BEGIN{printf "expected CFR = %.1f%%\n", f/t*100}'
#        #   expected CFR = 20.0%
#
# Why this matters for a platform initiative (the exam-level takeaway)
# -------------------------------------------------------------------
#   - DORA metrics are only as trustworthy as the EVENT CLASSIFICATION behind
#     them. A platform initiative "proved" by a CFR of 0% is a vanity metric
#     that hides regressions from the very people funding the platform.
#   - The four keys are two pairs in tension — throughput (Deployment
#     Frequency, Lead Time) vs stability (Change Failure Rate, Failed Deploy
#     Recovery). Reporting throughput while stability is miscomputed lets a
#     team "look elite" while shipping breakage. Always report the pair.
#   - Reconcile independent signals. Incidents and CFR should tell the same
#     story; when they diverge, the instrumentation is suspect, not reality.
#   - Treat metric definitions as code: version them, review them against the
#     emitter's actual vocabulary, and test the classifier — the same rigor you
#     apply to the platform it measures.
#
# References
#   - DORA four keys:        https://dora.dev/guides/dora-metrics-four-keys/
#   - DORA research/bands:   https://dora.dev/research/
#   - Four Keys reference:   https://github.com/dora-team/fourkeys
#   - CNPA Curriculum:       https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# =============================================================================