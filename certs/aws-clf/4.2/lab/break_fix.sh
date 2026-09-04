#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02)
#  Domain 4: Billing, Pricing, and Support
#  Task Statement 4.2: Understand resources for billing, budget, and cost management
#
#  BREAK & FIX LAB — "The Budget That Never Fired"
#
#  Exam guide:
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
# ------------------------------------------------------------------------------
#  WHAT THIS LAB IS
# ------------------------------------------------------------------------------
#  Domain 4.2 is about the *cost management control plane*: AWS Budgets, Cost
#  Explorer, Cost and Usage Report (CUR), Cost Allocation Tags, Billing alarms in
#  CloudWatch, AWS Pricing Calculator, Cost Anomaly Detection, and the IAM /
#  account-settings switches that decide who may even look at them.
#
#  Running that control plane against the real AWS billing APIs costs money and
#  requires a payer account, so this lab ships a LOCAL, OFFLINE SIMULATOR: a
#  small file-backed "billing service" with the same object model and the same
#  failure modes as the real one. Everything below runs on a throwaway VM with
#  nothing but bash, and it breaks in the exact five ways real budgets fail in
#  production. No AWS credentials are read, no network call is made, no charge
#  is incurred.
#
#  This is a DESTRUCTIVE-BY-DESIGN script, but only inside its own sandbox
#  directory (LAB_ROOT, default /opt/awslab-4.2). It never touches anything
#  outside that directory. Run it on a disposable VM anyway — that is the habit
#  you want.
#
#  USAGE
#    sudo ./clf-c02-4.2-break-fix.sh break     # arm the lab (breaks 5 things)
#    ./clf-c02-4.2-break-fix.sh status         # student's read-only view
#    ./clf-c02-4.2-break-fix.sh verify         # grade yourself (5 checks)
#    ./clf-c02-4.2-break-fix.sh hint <n>       # progressive hints, 1..5
#    sudo ./clf-c02-4.2-break-fix.sh reset     # wipe LAB_ROOT and start over
#
#  The student fixes things with the provided `awsbill` CLI shim (a stand-in for
#  `aws budgets` / `aws ce` / `aws iam`) or by editing the JSON directly. Both
#  are legitimate: the point is understanding the object model, not the syntax.
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

LAB_ROOT="${LAB_ROOT:-/opt/awslab-4.2}"
ACCOUNT_ID="111122223333"
PAYER_ID="111122223333"
LINKED_ID="444455556666"
TODAY="2026-09-04"
MONTH="2026-09"
LAB_VERSION="1.0"

# ------------------------------------------------------------------------------
# Presentation helpers. Colour is disabled when stdout is not a TTY so that
# `... | tee lab.log` produces a readable file.
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
ok()    { printf '%s  [PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
bad()   { printf '%s  [FAIL]%s %s\n' "$C_RED"   "$C_RESET" "$*"; }
warn()  { printf '%s  [WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
info()  { printf '%s        %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

die() { printf '%sfatal:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "this subcommand writes under ${LAB_ROOT}; re-run with sudo."
}

require_tools() {
  local missing=()
  for t in jq python3 awk sed grep; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    die "missing required tools: ${missing[*]}
     Debian/Ubuntu: sudo apt-get install -y jq python3
     Amazon Linux / RHEL: sudo dnf install -y jq python3"
  fi
}

# ==============================================================================
#  THE SIMULATED BILLING BACKEND
# ==============================================================================
#  Layout under $LAB_ROOT — deliberately mirrors the real service boundaries,
#  because on the exam you must know WHICH service owns WHICH object:
#
#    account/settings.json      Billing console access switch + IAM policy
#                               (the "Activate IAM Access" checkbox, which lives
#                               in Account Settings, NOT in IAM)
#    budgets/*.json             AWS Budgets: budget definition + notifications +
#                               subscribers. One file per budget.
#    ce/tags.json               Cost allocation tags and their activation state
#                               (Billing console -> Cost allocation tags)
#    ce/usage-YYYY-MM.jsonl     The line items Cost Explorer would aggregate
#    cur/report-definition.json Cost and Usage Report delivery config (S3)
#    anomaly/monitors.json      AWS Cost Anomaly Detection monitors
#    sns/topics.json            SNS topics + confirmed subscriptions
#    var/notifications.log      What the budget evaluator actually delivered
#
#  The evaluator (`awsbill budgets evaluate`) is the heart of the lab: it walks
#  every budget, computes actual + forecasted spend from the usage line items,
#  applies the notification thresholds, and refuses to deliver to an SNS topic
#  whose subscription is not CONFIRMED — exactly like production.
# ==============================================================================

write_backend() {
  local bin="${LAB_ROOT}/bin/awsbill"
  mkdir -p "${LAB_ROOT}/bin"
  cat > "${bin}" <<'AWSBILL_EOF'
#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# awsbill — offline stand-in for the AWS cost-management APIs.
#
# Command map to the real CLI (memorise the right-hand column for the exam):
#
#   awsbill budgets list                 aws budgets describe-budgets
#   awsbill budgets show <name>          aws budgets describe-budget
#   awsbill budgets create ...           aws budgets create-budget
#   awsbill budgets set-limit <n> <amt>  aws budgets update-budget
#   awsbill budgets add-notification ..  aws budgets create-notification
#   awsbill budgets evaluate             (internal: what AWS runs ~3x/day)
#   awsbill ce get-cost-and-usage        aws ce get-cost-and-usage
#   awsbill ce list-tags                 aws ce list-cost-allocation-tags
#   awsbill ce activate-tag <key>        aws ce update-cost-allocation-tags-status
#   awsbill cur describe                 aws cur describe-report-definitions
#   awsbill cur put <s3bucket> <prefix>  aws cur put-report-definition
#   awsbill anomaly list                 aws ce get-anomaly-monitors
#   awsbill sns confirm <topic> <email>  (the click in the confirmation email)
#   awsbill account get-billing-access   aws iam get-account-summary (analogue)
#   awsbill account set-billing-access   Account Settings -> IAM user/role access
#                                        to Billing information
# ------------------------------------------------------------------------------
set -euo pipefail
LAB_ROOT="${LAB_ROOT:-/opt/awslab-4.2}"
B="${LAB_ROOT}/budgets"; CE="${LAB_ROOT}/ce"; CUR="${LAB_ROOT}/cur"
AN="${LAB_ROOT}/anomaly"; SNS="${LAB_ROOT}/sns"; ACC="${LAB_ROOT}/account"
VAR="${LAB_ROOT}/var"
MONTH="2026-09"

j() { jq "$@"; }
err() { printf 'An error occurred: %s\n' "$*" >&2; exit 254; }

# --- authorization gate -------------------------------------------------------
# Every read of billing data goes through this. In the real account, a non-root
# principal that fails this check gets:
#   AccessDeniedException: User: arn:aws:iam::111122223333:user/finops is not
#   authorized to perform: budgets:ViewBudget
authz() {
  local action="$1"
  local enabled policy
  enabled="$(j -r '.iam_billing_access_enabled' "${ACC}/settings.json")"
  policy="$(j -r '.principals.finops.attached_policies | join(",")' "${ACC}/settings.json")"
  if [[ "${AWSBILL_PRINCIPAL:-finops}" == "root" ]]; then return 0; fi
  if [[ "${enabled}" != "true" ]]; then
    err "AccessDeniedException: User: arn:aws:iam::111122223333:user/${AWSBILL_PRINCIPAL:-finops} is not authorized to perform: ${action} (IAM user/role access to Billing information is DISABLED in Account Settings)"
  fi
  if [[ "${policy}" != *Billing* && "${policy}" != *AdministratorAccess* ]]; then
    err "AccessDeniedException: User: arn:aws:iam::111122223333:user/${AWSBILL_PRINCIPAL:-finops} is not authorized to perform: ${action} (no billing policy attached)"
  fi
}

# --- cost engine --------------------------------------------------------------
# Sums the month's line items. --filter/--group-by mimic Cost Explorer.
ce_total() {
  local f="${CE}/usage-${MONTH}.jsonl"
  [[ -f "$f" ]] || { echo "0.00"; return; }
  awk -F'"amount":' '{split($2,a,","); s+=a[1]} END {printf "%.2f", s+0}' "$f"
}
ce_days_elapsed() { echo 4; }   # 2026-09-04 -> 4 days into a 30-day month
ce_forecast() {
  local actual days
  actual="$(ce_total)"; days="$(ce_days_elapsed)"
  python3 -c "print('%.2f' % (${actual} / ${days} * 30))"
}

case "${1:-}" in
  budgets)
    case "${2:-}" in
      list)
        authz "budgets:ViewBudget"
        printf '%-28s %-12s %-10s %10s %10s %10s\n' NAME TYPE TIMEUNIT LIMIT ACTUAL FORECAST
        shopt -s nullglob
        local_total="$(ce_total)"; local_fc="$(ce_forecast)"
        for f in "${B}"/*.json; do
          n="$(j -r '.BudgetName' "$f")"; t="$(j -r '.BudgetType' "$f")"
          u="$(j -r '.TimeUnit' "$f")"
          l="$(j -r '.BudgetLimit.Amount // "unset"' "$f")"
          printf '%-28s %-12s %-10s %10s %10s %10s\n' "$n" "$t" "$u" "$l" "$local_total" "$local_fc"
        done
        ;;
      show)
        authz "budgets:ViewBudget"
        [[ -n "${3:-}" ]] || err "usage: awsbill budgets show <name>"
        f="${B}/${3}.json"; [[ -f "$f" ]] || err "NotFoundException: Unable to get budget: ${3} - the budget doesn't exist."
        j . "$f"
        ;;
      create)
        # awsbill budgets create <name> <COST|USAGE> <MONTHLY|QUARTERLY|ANNUALLY> <amount>
        authz "budgets:ModifyBudget"
        n="${3:?name}"; bt="${4:?COST|USAGE}"; tu="${5:?MONTHLY|...}"; amt="${6:?amount}"
        cat > "${B}/${n}.json" <<EOF
{
  "BudgetName": "${n}",
  "BudgetType": "${bt}",
  "TimeUnit": "${tu}",
  "BudgetLimit": { "Amount": "${amt}", "Unit": "USD" },
  "CostFilters": {},
  "CostTypes": {
    "IncludeCredit": false,
    "IncludeRefund": false,
    "IncludeSupport": true,
    "IncludeTax": true,
    "IncludeUpfront": true,
    "UseAmortized": false,
    "UseBlended": false
  },
  "NotificationsWithSubscribers": []
}
EOF
        echo "Budget ${n} created."
        ;;
      set-limit)
        authz "budgets:ModifyBudget"
        n="${3:?name}"; amt="${4:?amount}"
        f="${B}/${n}.json"; [[ -f "$f" ]] || err "NotFoundException: Unable to get budget: ${n}"
        tmp="$(mktemp)"; j --arg a "$amt" '.BudgetLimit = {Amount:$a, Unit:"USD"}' "$f" > "$tmp" && mv "$tmp" "$f"
        echo "Budget ${n} limit set to ${amt} USD."
        ;;
      add-notification)
        # awsbill budgets add-notification <name> <ACTUAL|FORECASTED> <pct> <sns-topic|email>
        authz "budgets:ModifyBudget"
        n="${3:?name}"; nt="${4:?ACTUAL|FORECASTED}"; pct="${5:?threshold}"; sub="${6:?target}"
        f="${B}/${n}.json"; [[ -f "$f" ]] || err "NotFoundException: Unable to get budget: ${n}"
        if [[ "$sub" == *@* ]]; then st=EMAIL; addr="$sub"; else st=SNS; addr="arn:aws:sns:us-east-1:111122223333:${sub}"; fi
        tmp="$(mktemp)"
        j --arg nt "$nt" --argjson pct "$pct" --arg st "$st" --arg addr "$addr" '
          .NotificationsWithSubscribers += [{
            Notification: {
              NotificationType: $nt,
              ComparisonOperator: "GREATER_THAN",
              Threshold: $pct,
              ThresholdType: "PERCENTAGE",
              NotificationState: "ALARM"
            },
            Subscribers: [{ SubscriptionType: $st, Address: $addr }]
          }]' "$f" > "$tmp" && mv "$tmp" "$f"
        echo "Notification added to ${n}: ${nt} > ${pct}% -> ${addr}"
        ;;
      evaluate)
        # What AWS Budgets does roughly three times a day.
        authz "budgets:ViewBudget"
        actual="$(ce_total)"; fc="$(ce_forecast)"
        : > "${VAR}/notifications.log"
        shopt -s nullglob
        for f in "${B}"/*.json; do
          n="$(j -r '.BudgetName' "$f")"
          lim="$(j -r '.BudgetLimit.Amount // empty' "$f")"
          if [[ -z "$lim" ]]; then
            echo "SKIP ${n}: no BudgetLimit set" >> "${VAR}/notifications.log"; continue
          fi
          cnt="$(j '.NotificationsWithSubscribers | length' "$f")"
          if [[ "$cnt" -eq 0 ]]; then
            echo "SKIP ${n}: budget exists but has ZERO notifications - it will never alert" >> "${VAR}/notifications.log"; continue
          fi
          for i in $(seq 0 $((cnt-1))); do
            nt="$(j -r ".NotificationsWithSubscribers[$i].Notification.NotificationType" "$f")"
            th="$(j -r ".NotificationsWithSubscribers[$i].Notification.Threshold" "$f")"
            observed="$actual"; [[ "$nt" == "FORECASTED" ]] && observed="$fc"
            pct="$(python3 -c "print('%.1f' % (${observed} / ${lim} * 100))")"
            fired="$(python3 -c "print(1 if ${pct} > ${th} else 0)")"
            [[ "$fired" == "1" ]] || { echo "QUIET ${n}[${i}] ${nt} ${pct}% <= ${th}%" >> "${VAR}/notifications.log"; continue; }
            subs="$(j -r ".NotificationsWithSubscribers[$i].Subscribers[] | .SubscriptionType + \"|\" + .Address" "$f")"
            while IFS='|' read -r st addr; do
              [[ -n "$st" ]] || continue
              if [[ "$st" == "SNS" ]]; then
                topic="${addr##*:}"
                state="$(j -r --arg t "$topic" '.topics[] | select(.name==$t) | .subscriptions[0].status // "MISSING"' "${SNS}/topics.json" 2>/dev/null || echo MISSING)"
                [[ -n "$state" ]] || state=MISSING
                if [[ "$state" != "Confirmed" ]]; then
                  echo "DROP  ${n}[${i}] ${nt} ${pct}%>${th}% -> ${addr} (SNS subscription state=${state}; nothing delivered)" >> "${VAR}/notifications.log"
                  continue
                fi
              fi
              echo "SENT  ${n}[${i}] ${nt} ${pct}%>${th}% -> ${st}:${addr}" >> "${VAR}/notifications.log"
            done <<< "$subs"
          done
        done
        cat "${VAR}/notifications.log"
        ;;
      *) err "unknown budgets subcommand: ${2:-}";;
    esac
    ;;
  ce)
    case "${2:-}" in
      get-cost-and-usage)
        authz "ce:GetCostAndUsage"
        grp="${3:-SERVICE}"
        f="${CE}/usage-${MONTH}.jsonl"
        echo "TimePeriod: ${MONTH}-01 to ${MONTH}-30   GroupBy: ${grp}   Metric: UnblendedCost"
        if [[ "$grp" == "TAG" ]]; then
          act="$(j -r '[.tags[] | select(.status=="Active")] | length' "${CE}/tags.json")"
          if [[ "$act" -eq 0 ]]; then
            err "DataUnavailableException: no ACTIVE cost allocation tag keys. Group-by TAG returns nothing until a tag key is activated in the Billing console (and it only applies to usage recorded AFTER activation)."
          fi
          j -r --slurp 'group_by(.tags.CostCenter // "(not tagged)")[] | "\(.[0].tags.CostCenter // "(not tagged)")\t\([.[].amount]|add|.*100|round/100)"' "$f" \
            | sort | awk -F'\t' '{printf "%-24s %10.2f\n", $1, $2}'
        else
          j -r --slurp 'group_by(.service)[] | "\(.[0].service)\t\([.[].amount]|add|.*100|round/100)"' "$f" \
            | sort -t$'\t' -k2 -rn | awk -F'\t' '{printf "%-24s %10.2f\n", $1, $2}'
        fi
        echo "----------------------------------------"
        printf '%-24s %10s\n' TOTAL "$(ce_total)"
        ;;
      list-tags)
        authz "ce:ListCostAllocationTags"
        j -r '.tags[] | "\(.key)\t\(.type)\t\(.status)"' "${CE}/tags.json" \
          | awk -F'\t' 'BEGIN{printf "%-16s %-12s %-10s\n","KEY","TYPE","STATUS"} {printf "%-16s %-12s %-10s\n",$1,$2,$3}'
        ;;
      activate-tag)
        authz "ce:UpdateCostAllocationTagsStatus"
        k="${3:?tag key}"
        tmp="$(mktemp)"
        j --arg k "$k" '(.tags[] | select(.key==$k) | .status) = "Active"' "${CE}/tags.json" > "$tmp" && mv "$tmp" "${CE}/tags.json"
        echo "Cost allocation tag key '${k}' status -> Active."
        ;;
      *) err "unknown ce subcommand: ${2:-}";;
    esac
    ;;
  cur)
    case "${2:-}" in
      describe)
        authz "cur:DescribeReportDefinitions"
        if [[ ! -s "${CUR}/report-definition.json" ]]; then
          echo '{ "ReportDefinitions": [] }'
        else
          j . "${CUR}/report-definition.json"
        fi
        ;;
      put)
        authz "cur:PutReportDefinition"
        bkt="${3:?s3 bucket}"; pfx="${4:-cur/}"
        cat > "${CUR}/report-definition.json" <<EOF
{
  "ReportDefinitions": [
    {
      "ReportName": "finops-hourly-cur",
      "TimeUnit": "HOURLY",
      "Format": "Parquet",
      "Compression": "Parquet",
      "AdditionalSchemaElements": ["RESOURCES"],
      "S3Bucket": "${bkt}",
      "S3Prefix": "${pfx}",
      "S3Region": "us-east-1",
      "RefreshClosedReports": true,
      "ReportVersioning": "OVERWRITE_REPORT"
    }
  ]
}
EOF
        echo "CUR report definition finops-hourly-cur written to s3://${bkt}/${pfx}"
        ;;
      *) err "unknown cur subcommand: ${2:-}";;
    esac
    ;;
  anomaly)
    case "${2:-}" in
      list)
        authz "ce:GetAnomalyMonitors"
        j -r '.monitors[] | "\(.MonitorName)\t\(.MonitorType)\t\(.subscriptions|length) subscription(s)"' "${AN}/monitors.json" \
          | awk -F'\t' 'BEGIN{printf "%-26s %-14s %s\n","MONITOR","TYPE","ALERTS"} {printf "%-26s %-14s %s\n",$1,$2,$3}'
        ;;
      *) err "unknown anomaly subcommand: ${2:-}";;
    esac
    ;;
  sns)
    case "${2:-}" in
      confirm)
        t="${3:?topic}"; e="${4:?email}"
        tmp="$(mktemp)"
        j --arg t "$t" --arg e "$e" '
          (.topics[] | select(.name==$t) | .subscriptions) |= (
            if (map(select(.endpoint==$e)) | length) > 0
            then map(if .endpoint==$e then .status="Confirmed" else . end)
            else . + [{protocol:"email", endpoint:$e, status:"Confirmed"}] end)' \
          "${SNS}/topics.json" > "$tmp" && mv "$tmp" "${SNS}/topics.json"
        echo "Subscription ${e} on topic ${t} is now Confirmed."
        ;;
      list)
        j -r '.topics[] | .name as $n | (.subscriptions[]? | "\($n)\t\(.protocol)\t\(.endpoint)\t\(.status)") // "\($n)\t-\t-\tNO SUBSCRIPTIONS"' "${SNS}/topics.json" \
          | awk -F'\t' 'BEGIN{printf "%-22s %-8s %-28s %s\n","TOPIC","PROTO","ENDPOINT","STATUS"} {printf "%-22s %-8s %-28s %s\n",$1,$2,$3,$4}'
        ;;
      *) err "unknown sns subcommand: ${2:-}";;
    esac
    ;;
  account)
    case "${2:-}" in
      get-billing-access) j . "${ACC}/settings.json";;
      set-billing-access)
        v="${3:?true|false}"
        [[ "$v" == "true" || "$v" == "false" ]] || err "ValidationException: value must be true or false"
        tmp="$(mktemp)"; j --argjson v "$v" '.iam_billing_access_enabled=$v' "${ACC}/settings.json" > "$tmp" && mv "$tmp" "${ACC}/settings.json"
        echo "Account setting 'IAM user and role access to Billing information' -> ${v}"
        ;;
      attach-policy)
        p="${3:?policy name}"
        tmp="$(mktemp)"; j --arg p "$p" '.principals.finops.attached_policies += [$p] | .principals.finops.attached_policies |= unique' "${ACC}/settings.json" > "$tmp" && mv "$tmp" "${ACC}/settings.json"
        echo "Attached ${p} to user finops."
        ;;
      *) err "unknown account subcommand: ${2:-}";;
    esac
    ;;
  *)
    cat <<'USAGE'
usage: awsbill <service> <operation> [args]

  budgets   list | show <n> | create <n> <TYPE> <UNIT> <amt> | set-limit <n> <amt>
            | add-notification <n> <ACTUAL|FORECASTED> <pct> <topic|email>
            | evaluate
  ce        get-cost-and-usage [SERVICE|TAG] | list-tags | activate-tag <key>
  cur       describe | put <bucket> [prefix]
  anomaly   list
  sns       list | confirm <topic> <email>
  account   get-billing-access | set-billing-access <true|false> | attach-policy <p>

Environment: AWSBILL_PRINCIPAL=root bypasses the billing-access gate, exactly
like the account root user can always see the Billing console.
USAGE
    exit 64;;
esac
AWSBILL_EOF
  chmod 0755 "${bin}"
}

# ==============================================================================
#  SEED: a HEALTHY, correctly configured cost-management setup
# ==============================================================================
seed_healthy() {
  mkdir -p "${LAB_ROOT}"/{account,budgets,ce,cur,anomaly,sns,var,bin}

  cat > "${LAB_ROOT}/account/settings.json" <<EOF
{
  "AccountId": "${ACCOUNT_ID}",
  "OrganizationRole": "MANAGEMENT_ACCOUNT",
  "LinkedAccounts": ["${LINKED_ID}"],
  "SupportPlan": "Developer",
  "iam_billing_access_enabled": true,
  "principals": {
    "finops": {
      "type": "IAMUser",
      "attached_policies": ["Billing", "AWSBudgetsReadOnlyAccess"]
    }
  }
}
EOF

  # --- The month's usage line items (what Cost Explorer aggregates) -----------
  # Total is deliberately ~ $1,043 over 4 days -> forecast ~ $7,822/month.
  # The healthy budget limit is 6000 USD, so:
  #   ACTUAL    1043 / 6000 = 17.4%  -> below an 80% ACTUAL threshold  (quiet)
  #   FORECAST  7822 / 6000 = 130.4% -> above a 100% FORECASTED one    (fires)
  # That asymmetry is the whole point of FORECASTED notifications and it is
  # heavily tested: a forecast alert warns you on day 4, an actual alert waits
  # until the money is already gone.
  cat > "${LAB_ROOT}/ce/usage-${MONTH}.jsonl" <<'EOF'
{"date":"2026-09-01","service":"Amazon EC2","amount":121.40,"tags":{"CostCenter":"platform"}}
{"date":"2026-09-01","service":"Amazon RDS","amount":63.10,"tags":{"CostCenter":"platform"}}
{"date":"2026-09-01","service":"Amazon S3","amount":18.75,"tags":{"CostCenter":"data"}}
{"date":"2026-09-01","service":"AWS Lambda","amount":4.02,"tags":{"CostCenter":"apps"}}
{"date":"2026-09-01","service":"Amazon CloudWatch","amount":9.31,"tags":{}}
{"date":"2026-09-02","service":"Amazon EC2","amount":128.66,"tags":{"CostCenter":"platform"}}
{"date":"2026-09-02","service":"Amazon RDS","amount":63.10,"tags":{"CostCenter":"platform"}}
{"date":"2026-09-02","service":"Amazon S3","amount":19.44,"tags":{"CostCenter":"data"}}
{"date":"2026-09-02","service":"AWS Lambda","amount":4.55,"tags":{"CostCenter":"apps"}}
{"date":"2026-09-02","service":"Amazon CloudWatch","amount":9.60,"tags":{}}
{"date":"2026-09-03","service":"Amazon EC2","amount":174.20,"tags":{"CostCenter":"platform"}}
{"date":"2026-09-03","service":"Amazon RDS","amount":63.10,"tags":{"CostCenter":"platform"}}
{"date":"2026-09-03","service":"Amazon S3","amount":21.08,"tags":{"CostCenter":"data"}}
{"date":"2026-09-03","service":"AWS Lambda","amount":5.11,"tags":{"CostCenter":"apps"}}
{"date":"2026-09-03","service":"Amazon CloudWatch","amount":10.02,"tags":{}}
{"date":"2026-09-04","service":"Amazon EC2","amount":216.93,"tags":{"CostCenter":"platform"}}
{"date":"2026-09-04","service":"Amazon RDS","amount":63.10,"tags":{"CostCenter":"platform"}}
{"date":"2026-09-04","service":"Amazon S3","amount":22.90,"tags":{"CostCenter":"data"}}
{"date":"2026-09-04","service":"AWS Lambda","amount":14.77,"tags":{"CostCenter":"apps"}}
{"date":"2026-09-04","service":"Amazon CloudWatch","amount":10.44,"tags":{}}
EOF

  cat > "${LAB_ROOT}/ce/tags.json" <<'EOF'
{
  "tags": [
    { "key": "CostCenter",  "type": "UserDefined", "status": "Active" },
    { "key": "Environment", "type": "UserDefined", "status": "Inactive" },
    { "key": "aws:createdBy", "type": "AWSGenerated", "status": "Active" }
  ]
}
EOF

  cat > "${LAB_ROOT}/sns/topics.json" <<'EOF'
{
  "topics": [
    {
      "name": "finops-budget-alerts",
      "arn": "arn:aws:sns:us-east-1:111122223333:finops-budget-alerts",
      "subscriptions": [
        { "protocol": "email", "endpoint": "finops@example.com", "status": "Confirmed" }
      ]
    }
  ]
}
EOF

  cat > "${LAB_ROOT}/budgets/monthly-cloud-spend.json" <<'EOF'
{
  "BudgetName": "monthly-cloud-spend",
  "BudgetType": "COST",
  "TimeUnit": "MONTHLY",
  "BudgetLimit": { "Amount": "6000", "Unit": "USD" },
  "CostFilters": {},
  "CostTypes": {
    "IncludeCredit": false,
    "IncludeRefund": false,
    "IncludeSupport": true,
    "IncludeTax": true,
    "IncludeUpfront": true,
    "UseAmortized": false,
    "UseBlended": false
  },
  "NotificationsWithSubscribers": [
    {
      "Notification": {
        "NotificationType": "ACTUAL",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 80,
        "ThresholdType": "PERCENTAGE",
        "NotificationState": "OK"
      },
      "Subscribers": [
        { "SubscriptionType": "SNS", "Address": "arn:aws:sns:us-east-1:111122223333:finops-budget-alerts" }
      ]
    },
    {
      "Notification": {
        "NotificationType": "FORECASTED",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 100,
        "ThresholdType": "PERCENTAGE",
        "NotificationState": "ALARM"
      },
      "Subscribers": [
        { "SubscriptionType": "SNS", "Address": "arn:aws:sns:us-east-1:111122223333:finops-budget-alerts" }
      ]
    }
  ]
}
EOF

  cat > "${LAB_ROOT}/budgets/rds-reserved-coverage.json" <<'EOF'
{
  "BudgetName": "rds-reserved-coverage",
  "BudgetType": "RI_COVERAGE",
  "TimeUnit": "MONTHLY",
  "BudgetLimit": { "Amount": "80", "Unit": "PERCENTAGE" },
  "CostFilters": { "Service": ["Amazon Relational Database Service"] },
  "NotificationsWithSubscribers": []
}
EOF

  cat > "${LAB_ROOT}/cur/report-definition.json" <<'EOF'
{
  "ReportDefinitions": [
    {
      "ReportName": "finops-hourly-cur",
      "TimeUnit": "HOURLY",
      "Format": "Parquet",
      "Compression": "Parquet",
      "AdditionalSchemaElements": ["RESOURCES"],
      "S3Bucket": "acme-finops-cur-111122223333",
      "S3Prefix": "cur/",
      "S3Region": "us-east-1",
      "RefreshClosedReports": true,
      "ReportVersioning": "OVERWRITE_REPORT"
    }
  ]
}
EOF

  cat > "${LAB_ROOT}/anomaly/monitors.json" <<'EOF'
{
  "monitors": [
    {
      "MonitorName": "acme-services-monitor",
      "MonitorType": "DIMENSIONAL",
      "MonitorDimension": "SERVICE",
      "subscriptions": [
        {
          "SubscriptionName": "daily-anomaly-digest",
          "Frequency": "DAILY",
          "ThresholdExpression": "ANOMALY_TOTAL_IMPACT_ABSOLUTE > 100",
          "Subscribers": [{ "Type": "EMAIL", "Address": "finops@example.com" }]
        }
      ]
    }
  ]
}
EOF

  : > "${LAB_ROOT}/var/notifications.log"
  write_backend
}

# ==============================================================================
#  BREAK — five independent, realistic faults
# ==============================================================================
do_break() {
  need_root
  require_tools
  say "${C_BOLD}Provisioning the lab under ${LAB_ROOT} ...${C_RESET}"
  rm -rf "${LAB_ROOT:?}"
  seed_healthy

  # -- FAULT 1 -----------------------------------------------------------------
  # "Activate IAM Access" turned off in Account Settings. The finops IAM user
  # has the correct IAM policy and STILL gets AccessDenied, because this account
  # -level switch gates ALL non-root access to billing data. Classic exam trap:
  # the fix is not in IAM.
  jq '.iam_billing_access_enabled = false' "${LAB_ROOT}/account/settings.json" > "${LAB_ROOT}/.t" \
    && mv "${LAB_ROOT}/.t" "${LAB_ROOT}/account/settings.json"

  # -- FAULT 2 -----------------------------------------------------------------
  # Someone "cleaned up noisy alerts" and deleted the notification block from
  # the only cost budget. The budget still exists, still shows a limit, still
  # renders a pretty bar in the console — and can never notify anybody.
  jq '.NotificationsWithSubscribers = []' "${LAB_ROOT}/budgets/monthly-cloud-spend.json" > "${LAB_ROOT}/.t" \
    && mv "${LAB_ROOT}/.t" "${LAB_ROOT}/budgets/monthly-cloud-spend.json"

  # -- FAULT 3 -----------------------------------------------------------------
  # The SNS email subscription was re-created and never confirmed. AWS Budgets
  # will publish to the topic; SNS silently drops it. PendingConfirmation is the
  # single most common reason a correctly-configured budget "doesn't send mail".
  jq '(.topics[] | select(.name=="finops-budget-alerts") | .subscriptions[0].status) = "PendingConfirmation"' \
    "${LAB_ROOT}/sns/topics.json" > "${LAB_ROOT}/.t" && mv "${LAB_ROOT}/.t" "${LAB_ROOT}/sns/topics.json"

  # -- FAULT 4 -----------------------------------------------------------------
  # The CostCenter cost allocation tag key was deactivated in the Billing
  # console, so Cost Explorer's group-by-tag and any tag-filtered budget go
  # blind. Note the real-world sting reproduced here: activation is not
  # retroactive in AWS, so showback for the current period stays broken.
  jq '(.tags[] | select(.key=="CostCenter") | .status) = "Inactive"' \
    "${LAB_ROOT}/ce/tags.json" > "${LAB_ROOT}/.t" && mv "${LAB_ROOT}/.t" "${LAB_ROOT}/ce/tags.json"

  # -- FAULT 5 -----------------------------------------------------------------
  # The Cost and Usage Report definition is gone (bucket policy was rewritten
  # and the report was deleted). Cost Explorer still works — CUR is the
  # line-item-level, hourly, resource-ID export that finance actually reconciles
  # against. Losing it is invisible until month-end close.
  : > "${LAB_ROOT}/cur/report-definition.json"

  chmod -R a+rX "${LAB_ROOT}"
  chmod -R a+w  "${LAB_ROOT}/account" "${LAB_ROOT}/budgets" "${LAB_ROOT}/ce" \
                "${LAB_ROOT}/cur" "${LAB_ROOT}/sns" "${LAB_ROOT}/var"

  print_briefing
}

# ==============================================================================
#  STUDENT BRIEFING
# ==============================================================================
print_briefing() {
  cat <<BRIEF

${C_BOLD}================================================================${C_RESET}
${C_BOLD} CLF-C02 / 4.2 — BREAK & FIX: "The Budget That Never Fired"${C_RESET}
${C_BOLD}================================================================${C_RESET}

${C_BOLD}SCENARIO${C_RESET}
You are on call for FinOps at Acme. Account ${ACCOUNT_ID} is the management
account of an AWS Organization with one linked account (${LINKED_ID}).
Yesterday finance discovered that September spend is tracking far above plan.
Nobody received a single alert. Your job is to find out why nothing fired and
restore the cost-management controls — today is ${TODAY}, four days into
the month, so there is still time to act if the alerting works.

Everything lives under ${LAB_ROOT}. Your CLI is:

    export PATH="${LAB_ROOT}/bin:\$PATH"
    export LAB_ROOT="${LAB_ROOT}"
    awsbill                       # prints the command map

${C_BOLD}SYMPTOMS YOU WILL SEE${C_RESET}

  1. As the ${C_BOLD}finops${C_RESET} IAM user, every billing call fails:
       $ awsbill budgets list
       An error occurred: AccessDeniedException: User:
       arn:aws:iam::${ACCOUNT_ID}:user/finops is not authorized to perform:
       budgets:ViewBudget (IAM user/role access to Billing information is
       DISABLED in Account Settings)
     ...even though that user has the Billing policy attached. Read that
     carefully: the policy is not the problem.

  2. Once you can read again, ${C_BOLD}awsbill budgets evaluate${C_RESET} prints:
       SKIP monthly-cloud-spend: budget exists but has ZERO notifications -
       it will never alert
     The budget looks perfectly healthy in a list view. It is inert.

  3. After you add notifications, evaluate starts printing ${C_BOLD}DROP${C_RESET} instead
     of ${C_BOLD}SENT${C_RESET}:
       DROP monthly-cloud-spend[1] FORECASTED 130.4%>100% ->
       arn:aws:sns:us-east-1:${ACCOUNT_ID}:finops-budget-alerts
       (SNS subscription state=PendingConfirmation; nothing delivered)
     The budget fires. The message dies one hop later.

  4. Per-team showback is empty:
       $ awsbill ce get-cost-and-usage TAG
       An error occurred: DataUnavailableException: no ACTIVE cost allocation
       tag keys...
     Resources ARE tagged. Tagging a resource is not the same act as making
     that tag key usable for cost reporting.

  5. Month-end reconciliation has no source data:
       $ awsbill cur describe
       { "ReportDefinitions": [] }
     Cost Explorer still answers questions; the hourly, resource-level export
     finance reconciles against is gone.

${C_BOLD}WHAT YOU MUST ACHIEVE${C_RESET} (run '${C_BOLD}awsbill-verify${C_RESET}' — that is
'$0 verify' — to grade yourself; all five must pass)

  [ ] G1  The finops IAM user can read Budgets and Cost Explorer WITHOUT
          becoming root (do not set AWSBILL_PRINCIPAL=root to "pass").
  [ ] G2  Budget 'monthly-cloud-spend' has at least two notifications: one
          ACTUAL at 80% and one FORECASTED at 100%, both GREATER_THAN,
          both PERCENTAGE.
  [ ] G3  'awsbill budgets evaluate' produces at least one ${C_BOLD}SENT${C_RESET} line and
          ${C_BOLD}zero DROP${C_RESET} lines. Delivery must actually reach a subscriber.
  [ ] G4  'awsbill ce get-cost-and-usage TAG' returns a per-CostCenter
          breakdown instead of an exception.
  [ ] G5  'awsbill cur describe' shows a report definition with TimeUnit
          HOURLY and a non-empty S3Bucket.

${C_BOLD}THINK ABOUT THIS WHILE YOU WORK${C_RESET} (exam-relevant, no points)
  - Why does a FORECASTED notification fire on day 4 while the ACTUAL one
    stays quiet? Which one would have saved Acme money?
  - Which of these five objects is free, and which one bills you? (Budgets:
    first two are free, then a small per-budget-per-day charge. Cost Explorer:
    the console UI is free, the GetCostAndUsage API is charged per request.
    CUR itself is free — you pay for the S3 storage. Cost Anomaly Detection
    is free.)
  - AWS Budgets vs. AWS Cost Anomaly Detection vs. a CloudWatch billing
    alarm: three different answers, three different exam questions. One is a
    threshold you choose, one is ML-detected deviation from your own pattern,
    one is a metric alarm on EstimatedCharges published only in us-east-1.
  - Consolidated billing on an Organization: the payer gets one bill, volume
    discounts and RI/Savings Plans are shared across accounts by default, and
    that sharing can be turned off per account.

${C_DIM}Hints: $0 hint 1 ... $0 hint 5   (use them only after trying)
Reset:  sudo $0 reset && sudo $0 break${C_RESET}

BRIEF
}

# ==============================================================================
#  STATUS — read-only situational view for the student
# ==============================================================================
do_status() {
  [[ -d "${LAB_ROOT}" ]] || die "lab not provisioned; run: sudo $0 break"
  export LAB_ROOT
  local bin="${LAB_ROOT}/bin/awsbill"

  head1 "Account settings (billing console access)"
  jq -r '"AccountId: \(.AccountId)  Role: \(.OrganizationRole)  Support: \(.SupportPlan)",
         "IAM access to Billing information: \(.iam_billing_access_enabled)",
         "finops policies: \(.principals.finops.attached_policies | join(", "))"' \
    "${LAB_ROOT}/account/settings.json"

  head1 "Budgets on disk"
  for f in "${LAB_ROOT}"/budgets/*.json; do
    jq -r '"\(.BudgetName)  type=\(.BudgetType)  limit=\(.BudgetLimit.Amount // "unset") \(.BudgetLimit.Unit // "")  notifications=\(.NotificationsWithSubscribers | length)"' "$f"
  done

  head1 "SNS topics"
  "${bin}" sns list || true

  head1 "Cost allocation tags"
  AWSBILL_PRINCIPAL=root "${bin}" ce list-tags || true

  head1 "CUR report definitions"
  AWSBILL_PRINCIPAL=root "${bin}" cur describe | jq -r '.ReportDefinitions | length | "definitions: \(.)"'

  head1 "Last budget evaluation"
  if [[ -s "${LAB_ROOT}/var/notifications.log" ]]; then
    cat "${LAB_ROOT}/var/notifications.log"
  else
    info "(never evaluated — run: awsbill budgets evaluate)"
  fi
  say ""
}

# ==============================================================================
#  VERIFY — five objective goals
# ==============================================================================
do_verify() {
  [[ -d "${LAB_ROOT}" ]] || die "lab not provisioned; run: sudo $0 break"
  require_tools
  export LAB_ROOT
  local bin="${LAB_ROOT}/bin/awsbill"
  local pass=0 fail=0
  local acc="${LAB_ROOT}/account/settings.json"
  local bud="${LAB_ROOT}/budgets/monthly-cloud-spend.json"

  head1 "Grading CLF-C02 4.2 break & fix"

  # G1: non-root principal can read billing
  if AWSBILL_PRINCIPAL=finops "${bin}" budgets list >/dev/null 2>&1 \
     && [[ "$(jq -r '.iam_billing_access_enabled' "$acc")" == "true" ]]; then
    ok "G1  finops can read Budgets/Cost Explorer (account billing access enabled)"
    ((pass++))
  else
    bad "G1  finops still gets AccessDenied"
    info "The IAM policy is already correct. The blocker is an ACCOUNT setting."
    ((fail++))
  fi

  # G2: both notification types present with the right shape
  local n_actual n_fc
  n_actual="$(jq '[.NotificationsWithSubscribers[]?.Notification
                   | select(.NotificationType=="ACTUAL" and .Threshold==80
                            and .ComparisonOperator=="GREATER_THAN"
                            and .ThresholdType=="PERCENTAGE")] | length' "$bud" 2>/dev/null || echo 0)"
  n_fc="$(jq '[.NotificationsWithSubscribers[]?.Notification
               | select(.NotificationType=="FORECASTED" and .Threshold==100
                        and .ComparisonOperator=="GREATER_THAN"
                        and .ThresholdType=="PERCENTAGE")] | length' "$bud" 2>/dev/null || echo 0)"
  if [[ "$n_actual" -ge 1 && "$n_fc" -ge 1 ]]; then
    ok "G2  monthly-cloud-spend has ACTUAL>80% and FORECASTED>100% notifications"
    ((pass++))
  else
    bad "G2  missing notifications (ACTUAL@80: ${n_actual}, FORECASTED@100: ${n_fc})"
    info "A budget with an empty NotificationsWithSubscribers list never alerts."
    ((fail++))
  fi

  # G3: evaluation delivers
  local evalout sent dropped
  evalout="$(AWSBILL_PRINCIPAL=root "${bin}" budgets evaluate 2>/dev/null || true)"
  sent="$(grep -c '^SENT'  <<<"$evalout" || true)"
  dropped="$(grep -c '^DROP' <<<"$evalout" || true)"
  if [[ "${sent:-0}" -ge 1 && "${dropped:-0}" -eq 0 ]]; then
    ok "G3  budget evaluation delivered ${sent} notification(s), 0 dropped"
    ((pass++))
  else
    bad "G3  delivery broken (SENT=${sent:-0}, DROP=${dropped:-0})"
    info "AWS Budgets publishing to SNS is not the same as SNS delivering to a human."
    ((fail++))
  fi

  # G4: tag-based reporting works
  if AWSBILL_PRINCIPAL=root "${bin}" ce get-cost-and-usage TAG >/dev/null 2>&1; then
    ok "G4  Cost Explorer group-by-TAG returns a CostCenter breakdown"
    ((pass++))
  else
    bad "G4  group-by-TAG still raises DataUnavailableException"
    info "Tagging the resource and activating the tag KEY for cost reporting are two separate acts."
    ((fail++))
  fi

  # G5: CUR restored
  local cur="${LAB_ROOT}/cur/report-definition.json"
  if [[ -s "$cur" ]] \
     && [[ "$(jq -r '.ReportDefinitions[0].TimeUnit // empty' "$cur")" == "HOURLY" ]] \
     && [[ -n "$(jq -r '.ReportDefinitions[0].S3Bucket // empty' "$cur")" ]]; then
    ok "G5  CUR report definition restored (HOURLY, S3 delivery configured)"
    ((pass++))
  else
    bad "G5  no usable Cost and Usage Report definition"
    info "Cost Explorer answers questions; CUR is the line-item export finance reconciles."
    ((fail++))
  fi

  say ""
  if [[ "$fail" -eq 0 ]]; then
    printf '%sALL %d GOALS PASSED — the cost-management control plane is restored.%s\n' \
      "$C_GREEN$C_BOLD" "$pass" "$C_RESET"
    say ""
    info "Now answer, out loud: which of the five faults would a CloudWatch"
    info "billing alarm on EstimatedCharges have caught, and which would it not?"
    return 0
  fi
  printf '%s%d/%d passed, %d still broken.%s\n' "$C_YELLOW$C_BOLD" "$pass" "$((pass+fail))" "$fail" "$C_RESET"
  return 1
}

# ==============================================================================
#  HINTS
# ==============================================================================
do_hint() {
  case "${1:-}" in
    1) cat <<'H'
HINT 1 (G1 — AccessDenied)
  The finops user already has the Billing policy. In AWS there is a second,
  account-wide gate: Account Settings -> "IAM user and role access to Billing
  information". Until that is activated, only the account ROOT user sees the
  Billing console, no matter what IAM says. This is one of the few settings
  that genuinely requires the root user to change.
  Look at: awsbill account get-billing-access
H
;;
    2) cat <<'H'
HINT 2 (G2 — the inert budget)
  In the Budgets data model a budget is TWO things: the budget itself
  (BudgetLimit, TimeUnit, CostFilters, CostTypes) and a separate list of
  NotificationsWithSubscribers. Deleting the second leaves a perfectly valid
  budget that tracks spend and tells nobody. Each notification needs a
  NotificationType (ACTUAL or FORECASTED), a ComparisonOperator, a Threshold,
  a ThresholdType, and at least one subscriber (EMAIL or SNS).
  Look at: awsbill budgets show monthly-cloud-spend
H
;;
    3) cat <<'H'
HINT 3 (G3 — DROP instead of SENT)
  Budgets published the message; SNS refused to deliver it. An SNS email
  subscription is inert in state PendingConfirmation until the recipient clicks
  the link in the confirmation mail. Nothing in Budgets can fix that — the
  problem is one service downstream.
  Look at: awsbill sns list
H
;;
    4) cat <<'H'
HINT 4 (G4 — empty showback)
  Applying a tag to a resource makes it visible in the API. Making that tag KEY
  usable as a cost dimension is a separate action in the Billing console:
  Cost allocation tags -> select key -> Activate. Real-world sting: activation
  is NOT retroactive, so historical periods stay untagged even after you fix it.
  Look at: awsbill ce list-tags
H
;;
    5) cat <<'H'
HINT 5 (G5 — nothing to reconcile)
  Cost Explorer is an interactive analysis tool with ~daily granularity in the
  UI and a 13-month/12-month-forecast horizon. The Cost and Usage Report (CUR)
  is the exhaustive export: every line item, hourly (or per-resource) detail,
  delivered as CSV/Parquet to an S3 bucket you own, queryable with Athena.
  Recreate the report definition and point it at an S3 bucket.
  Look at: awsbill cur describe
H
;;
    *) die "usage: $0 hint <1..5>";;
  esac
}

do_reset() {
  need_root
  [[ "${LAB_ROOT}" == /* && "${LAB_ROOT}" != "/" ]] || die "refusing to remove ${LAB_ROOT}"
  rm -rf "${LAB_ROOT:?}"
  say "Removed ${LAB_ROOT}. Run: sudo $0 break"
}

case "${1:-}" in
  break)  do_break;;
  status) do_status;;
  verify) do_verify;;
  hint)   do_hint "${2:-}";;
  reset)  do_reset;;
  brief)  print_briefing;;
  *) cat <<USAGE
CLF-C02 Task 4.2 break & fix lab (v${LAB_VERSION})

  sudo $0 break     provision the lab and break five things
       $0 brief     reprint the scenario and goals
       $0 status    read-only view of the current configuration
       $0 verify    grade yourself against the five goals
       $0 hint <n>  progressive hint 1..5
  sudo $0 reset     remove ${LAB_ROOT}

Run on a disposable VM. Everything is confined to ${LAB_ROOT}; no AWS
credentials are read and no network call is made.
USAGE
     exit 64;;
esac

# ==============================================================================
# ==============================================================================
#
#   S O L U T I O N   —   do not read until you have tried
#
# ==============================================================================
# ==============================================================================
#
# Setup for every step:
#
#   export LAB_ROOT=/opt/awslab-4.2
#   export PATH="$LAB_ROOT/bin:$PATH"
#
# ------------------------------------------------------------------------------
# STEP 0 — Reproduce the failure before changing anything.
# ------------------------------------------------------------------------------
#
#   $ awsbill budgets list
#   An error occurred: AccessDeniedException: User: arn:aws:iam::111122223333:
#   user/finops is not authorized to perform: budgets:ViewBudget (IAM user/role
#   access to Billing information is DISABLED in Account Settings)
#
# Two facts to separate immediately: the identity has the policy, and the call
# still fails. That combination points away from IAM.
#
#   $ awsbill account get-billing-access
#   {
#     "AccountId": "111122223333",
#     "OrganizationRole": "MANAGEMENT_ACCOUNT",
#     "LinkedAccounts": ["444455556666"],
#     "SupportPlan": "Developer",
#     "iam_billing_access_enabled": false,
#     "principals": { "finops": { "type": "IAMUser",
#       "attached_policies": ["Billing", "AWSBudgetsReadOnlyAccess"] } }
#   }
#
# ------------------------------------------------------------------------------
# STEP 1 (G1) — Activate IAM access to billing data at the ACCOUNT level.
# ------------------------------------------------------------------------------
#
#   $ AWSBILL_PRINCIPAL=root awsbill account set-billing-access true
#   Account setting 'IAM user and role access to Billing information' -> true
#
#   $ awsbill budgets list
#   NAME                         TYPE         TIMEUNIT        LIMIT     ACTUAL   FORECAST
#   monthly-cloud-spend          COST         MONTHLY          6000    1043.58    7826.85
#   rds-reserved-coverage        RI_COVERAGE  MONTHLY            80    1043.58    7826.85
#
# Real console path: sign in as the account root user -> Account -> "IAM user
# and role access to Billing information" -> Edit -> Activate IAM Access.
# Real CLI equivalent: `aws iam ...` cannot do it; it is an account attribute.
# In an AWS Organization the management account can push this down with a
# Service Control Policy / the BILLING feature set, but the checkbox itself is
# per-account and root-only.
#
# WHY IT MATTERS ON THE EXAM: the two-gate model. A principal needs (a) an IAM
# policy granting budgets:/ce:/cur: actions AND (b) the account-level activation.
# Missing either one produces the same AccessDenied, which is exactly why the
# question is worth asking.
#
# ------------------------------------------------------------------------------
# STEP 2 (G2) — Give the budget its notifications back.
# ------------------------------------------------------------------------------
#
#   $ awsbill budgets show monthly-cloud-spend | jq '.NotificationsWithSubscribers'
#   []
#
#   $ awsbill budgets evaluate
#   SKIP monthly-cloud-spend: budget exists but has ZERO notifications - it will never alert
#   SKIP rds-reserved-coverage: budget exists but has ZERO notifications - it will never alert
#
# Add both notification types. ACTUAL tells you the money is already spent;
# FORECASTED tells you it is going to be. On day 4 of the month only the second
# one can still save you:
#
#   $ awsbill budgets add-notification monthly-cloud-spend ACTUAL 80 finops-budget-alerts
#   Notification added to monthly-cloud-spend: ACTUAL > 80% -> arn:aws:sns:us-east-1:111122223333:finops-budget-alerts
#
#   $ awsbill budgets add-notification monthly-cloud-spend FORECASTED 100 finops-budget-alerts
#   Notification added to monthly-cloud-spend: FORECASTED > 100% -> arn:aws:sns:us-east-1:111122223333:finops-budget-alerts
#
# Real CLI equivalent:
#
#   aws budgets create-notification \
#     --account-id 111122223333 \
#     --budget-name monthly-cloud-spend \
#     --notification NotificationType=FORECASTED,ComparisonOperator=GREATER_THAN,Threshold=100,ThresholdType=PERCENTAGE \
#     --subscribers SubscriptionType=SNS,Address=arn:aws:sns:us-east-1:111122223333:finops-budget-alerts
#
# A single budget supports up to five notifications, each with up to ten
# subscribers. Threshold is a percentage of the limit by default
# (ThresholdType=PERCENTAGE); ThresholdType=ABSOLUTE_VALUE compares against a
# currency amount instead.
#
# ------------------------------------------------------------------------------
# STEP 3 (G3) — Confirm the SNS subscription so the message is actually
#               delivered.
# ------------------------------------------------------------------------------
#
#   $ awsbill budgets evaluate
#   QUIET monthly-cloud-spend[0] ACTUAL 17.4% <= 80%
#   DROP  monthly-cloud-spend[1] FORECASTED 130.4%>100% -> arn:aws:sns:us-east-1:111122223333:finops-budget-alerts (SNS subscription state=PendingConfirmation; nothing delivered)
#   SKIP  rds-reserved-coverage: budget exists but has ZERO notifications - it will never alert
#
# Read those three lines carefully — they are the whole lesson:
#   QUIET = threshold correctly not crossed (actual spend is only 17.4% so far)
#   DROP  = budget fired, SNS discarded it
#   SKIP  = object exists, has no alerting at all
#
#   $ awsbill sns list
#   TOPIC                  PROTO    ENDPOINT                     STATUS
#   finops-budget-alerts   email    finops@example.com           PendingConfirmation
#
#   $ awsbill sns confirm finops-budget-alerts finops@example.com
#   Subscription finops@example.com on topic finops-budget-alerts is now Confirmed.
#
# Real world: SNS sends a confirmation email; the recipient clicks the link, or
# you call `aws sns confirm-subscription --topic-arn ... --token ...` with the
# token from that mail. There is no way for the account owner to self-confirm an
# email endpoint — that is a deliberate anti-abuse design.
#
# Also required in a real account and worth knowing: the SNS topic's ACCESS
# POLICY must allow budgets.amazonaws.com to sns:Publish, e.g.
#
#   { "Sid": "AWSBudgetsSNSPublishingPermissions",
#     "Effect": "Allow",
#     "Principal": { "Service": "budgets.amazonaws.com" },
#     "Action": "SNS:Publish",
#     "Resource": "arn:aws:sns:us-east-1:111122223333:finops-budget-alerts" }
#
#   $ awsbill budgets evaluate
#   QUIET monthly-cloud-spend[0] ACTUAL 17.4% <= 80%
#   SENT  monthly-cloud-spend[1] FORECASTED 130.4%>100% -> SNS:arn:aws:sns:us-east-1:111122223333:finops-budget-alerts
#   SKIP  rds-reserved-coverage: budget exists but has ZERO notifications - it will never alert
#
# ------------------------------------------------------------------------------
# STEP 4 (G4) — Re-activate the CostCenter cost allocation tag key.
# ------------------------------------------------------------------------------
#
#   $ awsbill ce get-cost-and-usage TAG
#   An error occurred: DataUnavailableException: no ACTIVE cost allocation tag
#   keys. Group-by TAG returns nothing until a tag key is activated...
#
#   $ awsbill ce list-tags
#   KEY              TYPE         STATUS
#   CostCenter       UserDefined  Inactive
#   Environment      UserDefined  Inactive
#   aws:createdBy    AWSGenerated Active
#
#   $ awsbill ce activate-tag CostCenter
#   Cost allocation tag key 'CostCenter' status -> Active.
#
#   $ awsbill ce get-cost-and-usage TAG
#   TimePeriod: 2026-09-01 to 2026-09-30   GroupBy: TAG   Metric: UnblendedCost
#   (not tagged)                  39.37
#   apps                          28.45
#   data                          82.17
#   platform                     893.59
#   ----------------------------------------
#   TOTAL                        1043.58
#
# Real CLI equivalent:
#   aws ce update-cost-allocation-tags-status \
#     --cost-allocation-tags-status TagKey=CostCenter,Status=Active
#
# Three things the exam expects you to distinguish:
#   - AWS-generated keys are prefixed `aws:` (aws:createdBy, aws:cloudformation:
#     stack-name) and cannot be edited; user-defined keys are yours.
#   - Activation happens ONLY in the management/payer account of an Organization.
#   - Activation is NOT retroactive: the key becomes available for billing data
#     recorded from roughly the activation date forward. Tag early, or the
#     showback you need for last quarter simply does not exist.
#
# ------------------------------------------------------------------------------
# STEP 5 (G5) — Recreate the Cost and Usage Report definition.
# ------------------------------------------------------------------------------
#
#   $ awsbill cur describe
#   { "ReportDefinitions": [] }
#
#   $ awsbill cur put acme-finops-cur-111122223333 cur/
#   CUR report definition finops-hourly-cur written to s3://acme-finops-cur-111122223333/cur/
#
#   $ awsbill cur describe | jq -r '.ReportDefinitions[0] | "\(.ReportName) \(.TimeUnit) \(.Format) s3://\(.S3Bucket)/\(.S3Prefix)"'
#   finops-hourly-cur HOURLY Parquet s3://acme-finops-cur-111122223333/cur/
#
# Real CLI equivalent (note: the CUR API endpoint is us-east-1 only):
#
#   aws cur put-report-definition --region us-east-1 --report-definition '{
#     "ReportName": "finops-hourly-cur",
#     "TimeUnit": "HOURLY",
#     "Format": "Parquet",
#     "Compression": "Parquet",
#     "AdditionalSchemaElements": ["RESOURCES"],
#     "S3Bucket": "acme-finops-cur-111122223333",
#     "S3Prefix": "cur/",
#     "S3Region": "us-east-1",
#     "AdditionalArtifacts": ["ATHENA"],
#     "RefreshClosedReports": true,
#     "ReportVersioning": "OVERWRITE_REPORT"
#   }'
#
# The destination bucket needs a policy allowing billingreports.amazonaws.com
# (and bcm-data-exports.amazonaws.com for the newer Data Exports path) to
# s3:GetBucketAcl, s3:GetBucketPolicy and s3:PutObject. A missing bucket policy
# is the classic "the report was created but no files ever appear" failure.
#
# ------------------------------------------------------------------------------
# STEP 6 — Verify.
# ------------------------------------------------------------------------------
#
#   $ ./clf-c02-4.2-break-fix.sh verify
#
#   ==> Grading CLF-C02 4.2 break & fix
#     [PASS] G1  finops can read Budgets/Cost Explorer (account billing access enabled)
#     [PASS] G2  monthly-cloud-spend has ACTUAL>80% and FORECASTED>100% notifications
#     [PASS] G3  budget evaluation delivered 1 notification(s), 0 dropped
#     [PASS] G4  Cost Explorer group-by-TAG returns a CostCenter breakdown
#     [PASS] G5  CUR report definition restored (HOURLY, S3 delivery configured)
#
#   ALL 5 GOALS PASSED — the cost-management control plane is restored.
#
# ------------------------------------------------------------------------------
# STEP 7 (optional, no points) — close the remaining real gap.
# ------------------------------------------------------------------------------
#
# 'rds-reserved-coverage' still reports SKIP. It is an RI_COVERAGE budget with
# no notifications, which is a genuine (if lower-severity) hole: nobody learns
# when Reserved Instance coverage falls below 80%.
#
#   $ awsbill budgets add-notification rds-reserved-coverage ACTUAL 80 finops@example.com
#
# Budget types you must be able to tell apart on the exam:
#   COST         — spend against a currency amount (the common one)
#   USAGE        — units consumed (GB, hours), not dollars
#   RI_UTILIZATION / RI_COVERAGE          — Reserved Instance efficiency
#   SP_UTILIZATION / SP_COVERAGE          — Savings Plans efficiency
#
# ------------------------------------------------------------------------------
# WHAT THIS LAB WAS REALLY TEACHING
# ------------------------------------------------------------------------------
#
# The five faults are five distinct failure classes, and each maps to a
# different CLF-C02 4.2 concept:
#
#   Fault                     Failure class            Concept tested
#   -----------------------   ----------------------   ------------------------
#   Billing access off        authorization gate       Account settings vs IAM
#   No notifications          incomplete object        Budgets data model
#   PendingConfirmation SNS   broken delivery path     Budgets -> SNS coupling
#   Tag key inactive          missing dimension        Cost allocation tags
#   CUR deleted               missing data export      Cost Explorer vs CUR
#
# The unifying idea: in AWS cost management, "configured" and "working" are
# different states, and every layer can be individually correct while the chain
# is dead. A budget with a limit and no notification, a notification pointing at
# an unconfirmed topic, a tag applied but not activated, and a report that
# exists in nobody's bucket all look fine in isolation. You verify the chain
# end to end, or you verify nothing.
#
# The tool you would reach for, per question:
#   "What did we spend, and on what?"        -> Cost Explorer (analysis, ~13 mo
#                                               history, 12 mo forecast)
#   "Every line item, for Athena/finance"    -> Cost and Usage Report (CUR) /
#                                               Data Exports, to your S3 bucket
#   "Warn me before I exceed a number"       -> AWS Budgets (COST/USAGE/RI/SP;
#                                               free for the first two budgets)
#   "Warn me when spend behaves oddly"       -> AWS Cost Anomaly Detection (ML,
#                                               no threshold to pick, free)
#   "A metric alarm on total charges"        -> CloudWatch EstimatedCharges
#                                               (us-east-1 only, 6-hour cadence)
#   "What will this design cost before I
#    build it?"                              -> AWS Pricing Calculator
#   "One bill for many accounts, shared
#    volume discounts and commitments"       -> AWS Organizations consolidated
#                                               billing
#   "Where is my invoice / tax document?"    -> Billing console -> Bills /
#                                               Payments
#
# ------------------------------------------------------------------------------
# SOURCES (official)
# ------------------------------------------------------------------------------
#  - AWS Certified Cloud Practitioner (CLF-C02) Exam Guide
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#  - AWS Cost Management User Guide — Managing your costs with AWS Budgets
#    https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
#  - AWS Cost Management User Guide — Creating an Amazon SNS topic for budget
#    notifications
#    https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-sns-policy.html
#  - AWS Cost Management User Guide — Analyzing your costs with AWS Cost Explorer
#    https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html
#  - AWS Billing User Guide — Using AWS cost allocation tags
#    https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
#  - AWS Billing User Guide — Activating user-defined cost allocation tags
#    https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html
#  - AWS Cost and Usage Report User Guide — What are AWS Cost and Usage Reports?
#    https://docs.aws.amazon.com/cur/latest/userguide/what-is-cur.html
#  - AWS Billing User Guide — Activating access to the Billing and Cost
#    Management console
#    https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/control-access-billing.html
#  - AWS Cost Management User Guide — Detecting unusual spend with AWS Cost
#    Anomaly Detection
#    https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html
#  - AWS Billing User Guide — Consolidated billing for AWS Organizations
#    https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/consolidated-billing.html
#  - AWS Pricing Calculator User Guide
#    https://docs.aws.amazon.com/pricing-calculator/latest/userguide/what-is-pricing-calculator.html
# ==============================================================================