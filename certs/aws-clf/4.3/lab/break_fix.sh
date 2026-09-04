#!/usr/bin/env bash
#
# =============================================================================
#  BREAK & FIX LAB — AWS Certified Cloud Practitioner (CLF-C02) v1.0
#  Domain 4: Billing, Pricing and Support  ·  Task 4.3
#  "Identify AWS technical resources and AWS Support options"  (exam weight 4.0)
#
#  Exam guide:
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
#  WHAT THIS SCRIPT DOES
#    Installs a self-contained, OFFLINE simulator of three AWS control planes
#    (AWS Support, AWS Health, Service Quotas) plus an AWS-CLI-v2 look-alike,
#    then deliberately breaks four things in it. The student must diagnose and
#    repair them using the same commands and the same mental model they would
#    use against a real account.
#
#  SAFETY CONTRACT — read before running
#    * Runs ONLY against 127.0.0.1. No packet leaves the VM. No AWS account,
#      no credentials, no money, no quota consumed.
#    * Touches exactly two places: $LAB_ROOT (default /opt/support-lab, with a
#      fallback to ~/.support-lab) and ~/.aws. ~/.aws is copied to
#      $LAB_ROOT/backup/ before the first change and restored by --restore.
#    * Refuses to run if it detects real AWS credentials, unless you pass
#      --force. Intended for a DISPOSABLE lab VM.
#    * Idempotent: re-running reinstalls the lab and re-seeds the same faults.
#
#  USAGE
#    ./break-fix-4.3-support.sh              # install + break (asks to confirm)
#    ./break-fix-4.3-support.sh --yes        # unattended
#    ./break-fix-4.3-support.sh --reset      # re-seed the faults, keep install
#    ./break-fix-4.3-support.sh --restore    # stop lab, restore ~/.aws
#
#  The full step-by-step solution is at the BOTTOM of this file, commented out.
#  Do not scroll there until you have tried `support-lab verify`.
# =============================================================================

set -euo pipefail

LAB_ID="aws-clf-4.3"
LAB_ROOT="${LAB_ROOT:-/opt/support-lab}"
MOCK_PORT=4599
TS="$(date +%Y%m%d-%H%M%S)"
ASSUME_YES=0
FORCE=0
ACTION="install"

c_reset=""; c_bold=""; c_red=""; c_yel=""; c_grn=""; c_cya=""
if [[ -t 1 ]]; then
  c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'
  c_yel=$'\033[33m';  c_grn=$'\033[32m'; c_cya=$'\033[36m'
fi
info() { printf '%s[lab]%s %s\n'   "$c_cya" "$c_reset" "$*"; }
ok()   { printf '%s[ ok]%s %s\n'   "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[warn]%s %s\n'  "$c_yel" "$c_reset" "$*" >&2; }
die()  { printf '%s[fatal]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1 ;;
    --force)    FORCE=1 ;;
    --reset)    ACTION="reset" ;;
    --restore)  ACTION="restore" ;;
    --help|-h)  sed -n '2,40p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

command -v python3 >/dev/null 2>&1 || die "python3 is required (stdlib only, no pip packages)."
[[ "$(uname -s)" == "Linux" ]] || warn "written for Linux; other kernels are untested."

# -----------------------------------------------------------------------------
# Disposable-VM guard
# -----------------------------------------------------------------------------
guard_disposable() {
  local risky=0 reason=""
  if [[ -f "$HOME/.aws/credentials" ]]; then
    if grep -Eq '^[[:space:]]*aws_access_key_id[[:space:]]*=[[:space:]]*(AKIA|ASIA)' "$HOME/.aws/credentials"; then
      risky=1; reason="real-looking keys in ~/.aws/credentials"
    fi
  fi
  if [[ "${AWS_ACCESS_KEY_ID:-}" == AKIA* || "${AWS_ACCESS_KEY_ID:-}" == ASIA* ]]; then
    risky=1; reason="AWS_ACCESS_KEY_ID is exported in this shell"
  fi
  if timeout 1 bash -c ': </dev/tcp/169.254.169.254/80' 2>/dev/null; then
    warn "the link-local metadata endpoint answered: this may be a real EC2 instance."
  fi
  if [[ $risky -eq 1 && $FORCE -eq 0 ]]; then
    die "refusing to run: $reason. This lab rewrites ~/.aws. Use a disposable VM, or pass --force."
  fi
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  printf '%sThis will rewrite ~/.aws and install a lab under %s. Continue? [y/N] %s' "$c_bold" "$LAB_ROOT" "$c_reset"
  local a; read -r a || true
  [[ "$a" == "y" || "$a" == "Y" ]] || die "aborted by the student."
}

# -----------------------------------------------------------------------------
# Layout
# -----------------------------------------------------------------------------
if ! mkdir -p "$LAB_ROOT" 2>/dev/null; then
  LAB_ROOT="$HOME/.support-lab"
  warn "no write access to the default location; falling back to $LAB_ROOT"
  mkdir -p "$LAB_ROOT"
fi
mkdir -p "$LAB_ROOT"/{bin,mock,state,drafts,logs,backup}

restore_lab() {
  if [[ -f "$LAB_ROOT/state/mock.pid" ]]; then
    kill "$(cat "$LAB_ROOT/state/mock.pid")" 2>/dev/null || true
    rm -f "$LAB_ROOT/state/mock.pid"
  fi
  local last
  last="$(ls -1d "$LAB_ROOT"/backup/aws-* 2>/dev/null | tail -n1 || true)"
  if [[ -n "$last" ]]; then
    rm -rf "$HOME/.aws"
    cp -a "$last" "$HOME/.aws"
    ok "restored ~/.aws from $last"
  else
    rm -rf "$HOME/.aws"
    ok "no backup found; removed the lab ~/.aws"
  fi
  ok "lab stopped. Remove $LAB_ROOT by hand when you are done."
  exit 0
}
[[ "$ACTION" == "restore" ]] && restore_lab

guard_disposable
[[ "$ACTION" == "install" ]] && confirm

# =============================================================================
# 1. The offline control plane (AWS Support / AWS Health / Service Quotas)
# =============================================================================
cat > "$LAB_ROOT/mock/server.py" <<'MOCK_EOF'
#!/usr/bin/env python3
"""Offline mock of the AWS Support, AWS Health and Service Quotas control
planes, for the aws-clf topic 4.3 break & fix lab. Binds 127.0.0.1 only.

It is a SIMULATOR. Two deliberate simplifications, so you are never misled:
  * every service speaks the same JSON-1.1 / X-Amz-Target protocol here, while
    the real Service Quotas API is REST-JSON;
  * check IDs, ARNs and the account number are obviously synthetic.

What the lab grades is real, documented behaviour:
  Support plans and what each unlocks   https://aws.amazon.com/premiumsupport/plans/
  Support API (Business plan and above) https://docs.aws.amazon.com/awssupport/latest/APIReference/Welcome.html
  Case severity and response targets    https://docs.aws.amazon.com/awssupport/latest/user/case-management.html
  Trusted Advisor check availability    https://docs.aws.amazon.com/awssupport/latest/user/trusted-advisor.html
  AWS Health API (Business plan and up) https://docs.aws.amazon.com/health/latest/ug/health-api.html
  Service Quotas                        https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
"""
import datetime
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.environ.get("LAB_STATE") or "@@LAB_ROOT@@/state"
HOST, PORT = "127.0.0.1", 4599

PLAN_ORDER = ["basic", "developer", "business", "enterprise-on-ramp", "enterprise"]
API_MIN_PLAN = "business"          # AWS Support API + AWS Health API + full Trusted Advisor

SEVERITY_NAMES = {
    "low": "General guidance",
    "normal": "System impaired",
    "high": "Production system impaired",
    "urgent": "Production system down",
    "critical": "Business-critical system down",
}
PLAN_SEVERITIES = {
    "basic": [],                                                    # account and billing only
    "developer": ["low", "normal"],
    "business": ["low", "normal", "high", "urgent"],
    "enterprise-on-ramp": ["low", "normal", "high", "urgent", "critical"],
    "enterprise": ["low", "normal", "high", "urgent", "critical"],
}
RESPONSE_TARGET = {
    "developer": {"low": "24 business hours", "normal": "12 business hours"},
    "business": {"low": "24 hours", "normal": "12 hours", "high": "4 hours", "urgent": "1 hour"},
    "enterprise-on-ramp": {"low": "24 hours", "normal": "12 hours", "high": "4 hours",
                           "urgent": "1 hour", "critical": "30 minutes"},
    "enterprise": {"low": "24 hours", "normal": "12 hours", "high": "4 hours",
                   "urgent": "1 hour", "critical": "15 minutes"},
}

# Trusted Advisor: the core set stays visible on Basic/Developer; the full set
# needs Business or above. AWS has widened the free set over time -- always
# confirm against the user guide rather than memorising a number.
CORE_CHECKS = [
    ("LAB-TA-01", "Service Limits", "service_limits"),
    ("LAB-TA-02", "Security Groups - Specific Ports Unrestricted", "security"),
    ("LAB-TA-03", "IAM Use", "security"),
    ("LAB-TA-04", "MFA on Root Account", "security"),
    ("LAB-TA-05", "Amazon S3 Bucket Permissions", "security"),
    ("LAB-TA-06", "Amazon EBS Public Snapshots", "security"),
    ("LAB-TA-07", "Amazon RDS Public Snapshots", "security"),
]
PAID_CHECKS = [
    ("LAB-TA-08", "Low Utilization Amazon EC2 Instances", "cost_optimizing"),
    ("LAB-TA-09", "Idle Load Balancers", "cost_optimizing"),
    ("LAB-TA-10", "Unassociated Elastic IP Addresses", "cost_optimizing"),
    ("LAB-TA-11", "Underutilized Amazon EBS Volumes", "cost_optimizing"),
    ("LAB-TA-12", "Amazon RDS Idle DB Instances", "cost_optimizing"),
    ("LAB-TA-13", "Savings Plans / Reserved Instance Optimization", "cost_optimizing"),
    ("LAB-TA-14", "High Utilization Amazon EC2 Instances", "performance"),
    ("LAB-TA-15", "Large Number of Rules in an EC2 Security Group", "performance"),
    ("LAB-TA-16", "Overutilized Amazon EBS Magnetic Volumes", "performance"),
    ("LAB-TA-17", "CloudFront Content Delivery Optimization", "performance"),
    ("LAB-TA-18", "Amazon EC2 Availability Zone Balance", "fault_tolerance"),
    ("LAB-TA-19", "Amazon RDS Multi-AZ", "fault_tolerance"),
    ("LAB-TA-20", "Auto Scaling Group Health Check", "fault_tolerance"),
    ("LAB-TA-21", "Amazon S3 Bucket Versioning", "fault_tolerance"),
    ("LAB-TA-22", "ELB Connection Draining", "fault_tolerance"),
    ("LAB-TA-23", "Exposed Access Keys", "security"),
    ("LAB-TA-24", "AWS CloudTrail Logging", "security"),
    ("LAB-TA-25", "ELB Listener Security", "security"),
]

# Case classification catalogue, trimmed to what the lab needs.
SERVICE_CATALOGUE = {
    "amazon-elastic-compute-cloud-linux": {
        "name": "Amazon Elastic Compute Cloud (Linux)",
        "categories": ["instance-issue", "performance", "connectivity", "other"],
    },
    "service-limit-increase": {
        "name": "Service limit increase",
        "categories": ["ec2-instances", "elastic-ips", "other"],
    },
    "account-management": {
        "name": "Account and billing support",
        "categories": ["billing", "account-access", "other"],
    },
}

# Quota codes are the ones the Service Quotas console publishes for these
# quotas; L-LABF1XED is invented and clearly marked as non-adjustable so the
# lab can teach the adjustable/non-adjustable distinction without faking a
# real AWS hard limit.
QUOTAS = {
    ("ec2", "L-1216C47A"): {
        "QuotaName": "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances",
        "Value": 5.0, "Adjustable": True, "GlobalQuota": False, "Unit": "None",
        "ServiceName": "Amazon Elastic Compute Cloud (Amazon EC2)"},
    ("ec2", "L-0263D0A3"): {
        "QuotaName": "EC2-VPC Elastic IPs",
        "Value": 5.0, "Adjustable": True, "GlobalQuota": False, "Unit": "None",
        "ServiceName": "Amazon Elastic Compute Cloud (Amazon EC2)"},
    ("ec2", "L-LABF1XED"): {
        "QuotaName": "Lab simulated hard limit (NOT adjustable)",
        "Value": 5.0, "Adjustable": False, "GlobalQuota": False, "Unit": "None",
        "ServiceName": "Amazon Elastic Compute Cloud (Amazon EC2)"},
    ("vpc", "L-F678F1CE"): {
        "QuotaName": "VPCs per Region",
        "Value": 5.0, "Adjustable": True, "GlobalQuota": False, "Unit": "None",
        "ServiceName": "Amazon Virtual Private Cloud (Amazon VPC)"},
}


class LabError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def load(name, default):
    try:
        with open(os.path.join(STATE, name)) as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError):
        return default


def save(name, data):
    with open(os.path.join(STATE, name), "w") as fh:
        json.dump(data, fh, indent=2)


def account():
    return load("account.json", {"accountId": "000000000000", "supportPlan": "basic"})


def param(body, name, default=None):
    """Case-insensitive parameter lookup: the CLI sends camelCase, the Service
    Quotas API models PascalCase. The lab accepts either."""
    for k, v in body.items():
        if k.lower() == name.lower():
            return v
    return default


def require_paid_support(plan):
    if PLAN_ORDER.index(plan) < PLAN_ORDER.index(API_MIN_PLAN):
        raise LabError(
            "SubscriptionRequiredException",
            "Amazon Web Services Premium Support Subscription is required to use this service. "
            f"[lab] current plan: '{plan}'. The AWS Support API, the AWS Health API and the full "
            "Trusted Advisor check set require Business, Enterprise On-Ramp or Enterprise Support.")


# ---------------------------------------------------------------- operations
def op_get_caller_identity(body, region):
    acct = account()
    return {"UserId": "AIDALABSTUDENT0000000",
            "Account": acct["accountId"],
            "Arn": f"arn:aws:iam::{acct['accountId']}:user/lab-student"}


def op_describe_severity_levels(body, region):
    acct = account()
    require_paid_support(acct["supportPlan"])
    plan = acct["supportPlan"]
    return {"severityLevels": [
        {"code": c, "name": SEVERITY_NAMES[c],
         "labFirstResponseTarget": RESPONSE_TARGET.get(plan, {}).get(c, "n/a")}
        for c in PLAN_SEVERITIES[plan]]}


def op_describe_services(body, region):
    require_paid_support(account()["supportPlan"])
    return {"services": [
        {"code": code, "name": meta["name"],
         "categories": [{"code": c, "name": c.replace("-", " ")} for c in meta["categories"]]}
        for code, meta in SERVICE_CATALOGUE.items()]}


def op_describe_trusted_advisor_checks(body, region):
    acct = account()
    require_paid_support(acct["supportPlan"])
    if not param(body, "language"):
        raise LabError("InvalidParameterValueException",
                       "The 'language' parameter is required (for example: --language en).")
    checks = CORE_CHECKS + PAID_CHECKS
    return {"checks": [{"id": i, "name": n, "category": c,
                        "description": f"[lab] simulated Trusted Advisor check: {n}"}
                       for i, n, c in checks]}


def op_create_case(body, region):
    acct = account()
    plan = acct["supportPlan"]
    require_paid_support(plan)

    subject = param(body, "subject")
    service_code = param(body, "serviceCode")
    category_code = param(body, "categoryCode")
    severity_code = param(body, "severityCode", "normal")
    comm = param(body, "communicationBody")
    language = param(body, "language", "en")

    for name, value in (("subject", subject), ("serviceCode", service_code),
                        ("categoryCode", category_code), ("communicationBody", comm)):
        if not value:
            raise LabError("InvalidParameterValueException", f"'{name}' is required.")

    if service_code not in SERVICE_CATALOGUE:
        raise LabError("InvalidParameterValueException",
                       f"Unknown serviceCode '{service_code}'. Run: aws support describe-services")
    if category_code not in SERVICE_CATALOGUE[service_code]["categories"]:
        raise LabError("InvalidParameterValueException",
                       f"categoryCode '{category_code}' is not valid for service '{service_code}'. "
                       f"Valid: {', '.join(SERVICE_CATALOGUE[service_code]['categories'])}")

    allowed = PLAN_SEVERITIES[plan]
    if severity_code not in allowed:
        raise LabError("InvalidParameterValueException",
                       f"severityCode '{severity_code}' is not available for support plan '{plan}'. "
                       f"Available: {', '.join(allowed)}. "
                       "[lab] 'critical' (business-critical system down) exists only on Enterprise "
                       "On-Ramp (30 min target) and Enterprise (15 min target).")

    cases = load("cases.json", [])
    case_id = f"case-{acct['accountId']}-lab-2026-{len(cases) + 1:08x}"
    cases.append({
        "caseId": case_id,
        "displayId": str(1000 + len(cases)),
        "subject": subject,
        "status": "opened",
        "serviceCode": service_code,
        "categoryCode": category_code,
        "severityCode": severity_code,
        "submittedBy": "lab-student@example.com",
        "timeCreated": now(),
        "language": language,
        "labFirstResponseTarget": RESPONSE_TARGET.get(plan, {}).get(severity_code, "n/a"),
        "recentCommunications": {"communications": [
            {"caseId": case_id, "body": comm, "submittedBy": "lab-student@example.com",
             "timeCreated": now()}]},
    })
    save("cases.json", cases)
    return {"caseId": case_id}


def op_describe_cases(body, region):
    require_paid_support(account()["supportPlan"])
    return {"cases": load("cases.json", [])}


def op_describe_events(body, region):
    require_paid_support(account()["supportPlan"])
    return {"events": [
        {"arn": "arn:aws:health:us-east-1::event/EC2/AWS_EC2_OPERATIONAL_ISSUE/LAB_PUBLIC_1",
         "service": "EC2", "eventTypeCode": "AWS_EC2_OPERATIONAL_ISSUE",
         "eventTypeCategory": "issue", "region": "us-east-1",
         "startTime": "2026-08-30T14:02:00+00:00", "endTime": "2026-08-30T15:41:00+00:00",
         "statusCode": "closed", "eventScopeCode": "PUBLIC"},
        {"arn": "arn:aws:health:us-east-1::event/EC2/AWS_EC2_INSTANCE_STORE_DRIVE_PERFORMANCE_DEGRADED/LAB_ACCT_1",
         "service": "EC2", "eventTypeCode": "AWS_EC2_INSTANCE_STORE_DRIVE_PERFORMANCE_DEGRADED",
         "eventTypeCategory": "issue", "region": "us-east-1",
         "startTime": "2026-09-02T08:15:00+00:00", "statusCode": "open",
         "eventScopeCode": "ACCOUNT_SPECIFIC",
         "labAffectedEntities": ["i-0lab00000000000a1"]},
        {"arn": "arn:aws:health:us-east-1::event/RDS/AWS_RDS_MAINTENANCE_SCHEDULED/LAB_ACCT_2",
         "service": "RDS", "eventTypeCode": "AWS_RDS_MAINTENANCE_SCHEDULED",
         "eventTypeCategory": "scheduledChange", "region": "us-east-1",
         "startTime": "2026-09-11T03:00:00+00:00", "statusCode": "upcoming",
         "eventScopeCode": "ACCOUNT_SPECIFIC",
         "labAffectedEntities": ["arn:aws:rds:us-east-1:000000000000:db:lab-orders"]},
    ]}


def _quota_view(service_code, quota_code, region):
    q = QUOTAS[(service_code, quota_code)]
    return {"ServiceCode": service_code, "ServiceName": q["ServiceName"],
            "QuotaCode": quota_code, "QuotaName": q["QuotaName"],
            "Value": q["Value"], "Unit": q["Unit"],
            "Adjustable": q["Adjustable"], "GlobalQuota": q["GlobalQuota"],
            "labRegion": region}


def op_list_service_quotas(body, region):
    service_code = param(body, "serviceCode")
    if not service_code:
        raise LabError("InvalidParameterValueException", "'ServiceCode' is required.")
    items = [_quota_view(s, q, region) for (s, q) in QUOTAS if s == service_code]
    if not items:
        raise LabError("NoSuchResourceException", f"Service '{service_code}' not found in the lab catalogue.")
    return {"Quotas": items}


def op_get_service_quota(body, region):
    service_code, quota_code = param(body, "serviceCode"), param(body, "quotaCode")
    if (service_code, quota_code) not in QUOTAS:
        raise LabError("NoSuchResourceException",
                       f"Quota '{quota_code}' for service '{service_code}' does not exist.")
    return {"Quota": _quota_view(service_code, quota_code, region)}


def op_request_service_quota_increase(body, region):
    service_code, quota_code = param(body, "serviceCode"), param(body, "quotaCode")
    desired = param(body, "desiredValue")
    if (service_code, quota_code) not in QUOTAS:
        raise LabError("NoSuchResourceException",
                       f"Quota '{quota_code}' for service '{service_code}' does not exist. "
                       "Run: aws service-quotas list-service-quotas --service-code " + str(service_code))
    q = QUOTAS[(service_code, quota_code)]
    if not q["Adjustable"]:
        raise LabError("InvalidParameterValueException",
                       f"The quota '{quota_code}' ({q['QuotaName']}) is not adjustable and cannot be increased.")
    if desired is None:
        raise LabError("InvalidParameterValueException", "'DesiredValue' is required.")
    desired = float(desired)
    if desired <= q["Value"]:
        raise LabError("InvalidParameterValueException",
                       f"DesiredValue ({desired}) must be greater than the current quota value ({q['Value']}).")

    reqs = load("quota_requests.json", [])
    req = {"Id": f"lab-{len(reqs) + 1:012d}", "CaseId": "", "ServiceCode": service_code,
           "ServiceName": q["ServiceName"], "QuotaCode": quota_code, "QuotaName": q["QuotaName"],
           "DesiredValue": desired, "Status": "PENDING", "Created": now(),
           "Requester": "lab-student", "labRegion": region}
    reqs.append(req)
    save("quota_requests.json", reqs)
    return {"RequestedQuota": req}


def op_list_requested_service_quota_change_history(body, region):
    service_code = param(body, "serviceCode")
    reqs = load("quota_requests.json", [])
    if service_code:
        reqs = [r for r in reqs if r["ServiceCode"] == service_code]
    return {"RequestedQuotas": reqs}


OPS = {
    "GetCallerIdentity": op_get_caller_identity,
    "DescribeSeverityLevels": op_describe_severity_levels,
    "DescribeServices": op_describe_services,
    "DescribeTrustedAdvisorChecks": op_describe_trusted_advisor_checks,
    "CreateCase": op_create_case,
    "DescribeCases": op_describe_cases,
    "DescribeEvents": op_describe_events,
    "ListServiceQuotas": op_list_service_quotas,
    "GetServiceQuota": op_get_service_quota,
    "RequestServiceQuotaIncrease": op_request_service_quota_increase,
    "ListRequestedServiceQuotaChangeHistory": op_list_requested_service_quota_change_history,
}


class Handler(BaseHTTPRequestHandler):
    server_version = "LabSupportMock/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (now(), fmt % args))

    def _send(self, status, payload, errtype=None):
        raw = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/x-amz-json-1.1")
        self.send_header("Content-Length", str(len(raw)))
        if errtype:
            self.send_header("x-amzn-ErrorType", errtype)
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/_lab/health":
            self._send(200, {"status": "ok", "plan": account()["supportPlan"]})
        else:
            self._send(404, {"__type": "NotFound", "message": self.path}, "NotFound")

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"__type": "SerializationException", "message": "bad JSON"}, "SerializationException")
            return
        target = (self.headers.get("X-Amz-Target") or "").split(".")[-1]
        region = self.headers.get("X-Lab-Region") or "unknown"
        fn = OPS.get(target)
        if fn is None:
            self._send(400, {"__type": "UnknownOperationException", "message": target}, "UnknownOperationException")
            return
        try:
            self._send(200, fn(body, region))
        except LabError as exc:
            self._send(400, {"__type": exc.code, "message": str(exc)}, exc.code)
        except Exception as exc:  # never take the lab down on a student typo
            self._send(500, {"__type": "InternalFailure", "message": repr(exc)}, "InternalFailure")


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
MOCK_EOF

# =============================================================================
# 2. The AWS CLI v2 look-alike
# =============================================================================
cat > "$LAB_ROOT/bin/aws" <<'CLI_EOF'
#!/usr/bin/env python3
"""Offline stand-in for the AWS CLI v2, scoped to the operations used by the
aws-clf topic 4.3 lab. It signs nothing and talks only to 127.0.0.1, so no
request ever leaves this VM.

Argument shapes, credential/region resolution order and error text follow the
real CLI closely enough that everything you practise here transfers verbatim:

  aws sts get-caller-identity
  aws configure get|set region <value>
  aws support describe-severity-levels
  aws support describe-services
  aws support describe-trusted-advisor-checks --language en
  aws support create-case --subject S --service-code C --category-code C \
                          --severity-code S --communication-body B [--language en]
  aws support describe-cases
  aws health describe-events
  aws service-quotas list-service-quotas --service-code ec2
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
  aws service-quotas request-service-quota-increase --service-code ec2 \
                          --quota-code L-1216C47A --desired-value 20
  aws service-quotas list-requested-service-quota-change-history --service-code ec2
"""
import configparser
import json
import os
import re
import sys
import urllib.error
import urllib.request

LAB_ROOT = os.environ.get("LAB_ROOT") or "@@LAB_ROOT@@"
MOCK_URL = "http://127.0.0.1:4599/"

# (target prefix, endpoint host template, forced region for global endpoints)
SERVICES = {
    "support":        ("AWSSupport_20130415", "support.{region}.amazonaws.com", "us-east-1"),
    "health":         ("AWSHealth_20160804", "health.{region}.amazonaws.com", "us-east-1"),
    "service-quotas": ("ServiceQuotasV20190624", "servicequotas.{region}.amazonaws.com", None),
    "sts":            ("AWSSecurityTokenServiceV20110615", "sts.amazonaws.com", "us-east-1"),
}
CONFIG_PATH = os.path.expanduser(os.environ.get("AWS_CONFIG_FILE") or "~/.aws/config")


def fail(msg, code=255):
    sys.stderr.write(msg.rstrip() + "\n")
    sys.exit(code)


def pascal(op):
    return "".join(part.capitalize() for part in op.split("-"))


def camel(name):
    head, *rest = name.split("-")
    return head + "".join(part.capitalize() for part in rest)


def coerce(value):
    if value is None:
        return True
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if re.fullmatch(r"-?\d+\.\d+", value):
        return float(value)
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    return value


def read_config(profile):
    cp = configparser.ConfigParser()
    cp.read(CONFIG_PATH)
    section = "default" if profile in (None, "default") else f"profile {profile}"
    return cp, section


def config_get(profile, key):
    cp, section = read_config(profile)
    if cp.has_option(section, key):
        return (cp.get(section, key) or "").strip() or None
    return None


def config_set(profile, key, value):
    cp, section = read_config(profile)
    if not cp.has_section(section):
        cp.add_section(section)
    cp.set(section, key, value)
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as fh:
        cp.write(fh)


def resolve_region(cli_region, profile):
    for candidate in (cli_region, os.environ.get("AWS_REGION"),
                      os.environ.get("AWS_DEFAULT_REGION"), config_get(profile, "region")):
        if candidate:
            return candidate
    return None


def call(service, operation, params, region, endpoint_url):
    prefix, host_tpl, forced = SERVICES[service]
    effective = forced or region                     # support/health/sts use a global endpoint
    host = host_tpl.format(region=effective)
    url = endpoint_url or MOCK_URL
    req = urllib.request.Request(
        url, data=json.dumps(params).encode(),
        headers={"Content-Type": "application/x-amz-json-1.1",
                 "X-Amz-Target": f"{prefix}.{operation}",
                 "X-Lab-Region": region},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        payload = {}
        try:
            payload = json.loads(exc.read() or b"{}")
        except ValueError:
            pass
        code = payload.get("__type", "ServiceError")
        msg = payload.get("message", str(exc))
        fail(f"\nAn error occurred ({code}) when calling the {operation} operation: {msg}", 254)
    except urllib.error.URLError:
        fail(f'Could not connect to the endpoint URL: "https://{host}/"\n'
             f'[lab] the offline control plane is not answering. Start it with: support-lab start', 255)


def main(argv):
    cli_region = profile = endpoint_url = None
    output = "json"
    i = 0
    while i < len(argv) and argv[i].startswith("-"):
        tok = argv[i]
        if tok == "--version":
            print("aws-cli/2.x (offline lab simulator, aws-clf topic 4.3)")
            return 0
        if tok in ("--no-cli-pager", "--no-paginate", "--debug", "--no-verify-ssl"):
            i += 1
            continue
        if tok in ("--region", "--profile", "--output", "--endpoint-url", "--query", "--cli-read-timeout"):
            if i + 1 >= len(argv):
                fail(f"argument {tok}: expected one argument", 252)
            value = argv[i + 1]
            if tok == "--region":
                cli_region = value
            elif tok == "--profile":
                profile = value
            elif tok == "--output":
                output = value
            elif tok == "--endpoint-url":
                endpoint_url = value
            elif tok == "--query":
                sys.stderr.write("[lab] --query is not implemented in the lab shim; "
                                 "pipe the JSON through python3 or jq instead.\n")
            i += 2
            continue
        fail(f"Unknown options: {tok}", 252)

    if i >= len(argv):
        fail("usage: aws <service> <operation> [parameters]", 252)
    service = argv[i]
    i += 1

    if service == "configure":
        if i >= len(argv):
            fail("usage: aws configure get|set <key> [value]", 252)
        sub = argv[i]
        if sub == "get" and i + 1 < len(argv):
            value = config_get(profile, argv[i + 1])
            if value is None:
                return 1
            print(value)
            return 0
        if sub == "set" and i + 2 < len(argv):
            config_set(profile, argv[i + 1], argv[i + 2])
            return 0
        fail("usage: aws configure get|set <key> [value]", 252)

    if service not in SERVICES:
        fail(f"Invalid choice: '{service}'. The lab shim implements: "
             + ", ".join(sorted(SERVICES)) + ".", 252)
    if i >= len(argv):
        fail(f"usage: aws {service} <operation> [parameters]", 252)
    operation = pascal(argv[i])
    i += 1

    params = {}
    while i < len(argv):
        tok = argv[i]
        if not tok.startswith("--"):
            fail(f"Unknown positional argument: {tok}", 252)
        name = tok[2:]
        value = None
        if "=" in name:
            name, value = name.split("=", 1)
        elif i + 1 < len(argv) and not argv[i + 1].startswith("--"):
            value = argv[i + 1]
            i += 1
        i += 1
        params[camel(name)] = coerce(value)

    region = resolve_region(cli_region, profile)
    if not region:
        fail('You must specify a region. You can also configure your region by running "aws configure".', 255)

    result = call(service, operation, params, region, endpoint_url)
    if output == "json":
        print(json.dumps(result, indent=4))
    else:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
CLI_EOF

# =============================================================================
# 3. The grader
# =============================================================================
cat > "$LAB_ROOT/bin/lab-verify.py" <<'VERIFY_EOF'
#!/usr/bin/env python3
"""Grades the topic 4.3 break & fix lab. Every check runs through the same
CLI shim the student uses, with the student's own ~/.aws configuration, so a
check can only pass if the underlying misconfiguration is genuinely fixed."""
import json
import os
import subprocess
import sys

LAB_ROOT = os.environ.get("LAB_ROOT") or "@@LAB_ROOT@@"
AWS = os.path.join(LAB_ROOT, "bin", "aws")
CASE_TAG = "[LAB4.3]"

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
if not sys.stdout.isatty():
    GREEN = RED = YELLOW = RESET = ""


def aws(*args):
    proc = subprocess.run([sys.executable, AWS, *args], capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def as_json(out):
    try:
        return json.loads(out)
    except ValueError:
        return {}


def check_region():
    rc, out, err = aws("sts", "get-caller-identity")
    if rc != 0:
        return False, err.strip().splitlines()[-1] if err.strip() else "call failed", \
            'set the workload region: aws configure set region us-east-1'
    return True, "identity resolves as " + as_json(out).get("Arn", "?"), ""


def check_support_api():
    rc, out, err = aws("support", "describe-severity-levels")
    if rc != 0:
        return False, err.strip().splitlines()[-1] if err.strip() else "call failed", \
            "the AWS Support API needs Business, Enterprise On-Ramp or Enterprise Support"
    codes = [lvl["code"] for lvl in as_json(out).get("severityLevels", [])]
    return True, "severity levels available: " + ", ".join(codes), ""


def check_trusted_advisor():
    rc, out, err = aws("support", "describe-trusted-advisor-checks", "--language", "en")
    if rc != 0:
        return False, err.strip().splitlines()[-1] if err.strip() else "call failed", \
            "remember --language is a required parameter of DescribeTrustedAdvisorChecks"
    checks = as_json(out).get("checks", [])
    if len(checks) <= 7:
        return False, f"only {len(checks)} checks visible (core set)", \
            "the full check set across all categories requires Business or above"
    cats = sorted({c["category"] for c in checks})
    return True, f"{len(checks)} checks across {len(cats)} categories: {', '.join(cats)}", ""


def check_case():
    rc, out, err = aws("support", "describe-cases")
    if rc != 0:
        return False, err.strip().splitlines()[-1] if err.strip() else "call failed", \
            "fix the Support API access first"
    for case in as_json(out).get("cases", []):
        if CASE_TAG in case.get("subject", ""):
            if case.get("severityCode") != "urgent":
                return False, f"case found but severity is '{case.get('severityCode')}'", \
                    "'production system down' maps to severityCode 'urgent' (1 hour first-response target)"
            return True, f"{case['caseId']} severity={case['severityCode']} " \
                         f"target={case.get('labFirstResponseTarget')}", ""
    return False, f"no case whose subject contains {CASE_TAG}", \
        f"open one with aws support create-case, keeping {CASE_TAG} in the subject"


def check_health():
    rc, out, err = aws("health", "describe-events")
    if rc != 0:
        return False, err.strip().splitlines()[-1] if err.strip() else "call failed", \
            "the AWS Health API (not the public dashboard) requires Business or above"
    events = as_json(out).get("events", [])
    acct = [e for e in events if e.get("eventScopeCode") == "ACCOUNT_SPECIFIC"]
    if not acct:
        return False, "no account-specific events returned", "check the plan"
    return True, f"{len(acct)} ACCOUNT_SPECIFIC of {len(events)} events " \
                 f"({', '.join(e['eventTypeCode'] for e in acct)})", ""


def check_quota_request():
    rc, out, err = aws("service-quotas", "list-requested-service-quota-change-history",
                       "--service-code", "ec2")
    if rc != 0:
        return False, err.strip().splitlines()[-1] if err.strip() else "call failed", \
            "Service Quotas is reachable on every support plan, including Basic"
    for req in as_json(out).get("RequestedQuotas", []):
        if req.get("QuotaCode") == "L-1216C47A" and float(req.get("DesiredValue", 0)) >= 20:
            if req.get("labRegion") != "us-east-1":
                return False, f"request filed in region '{req.get('labRegion')}'", \
                    "quotas are per Region: file it where the workload runs (us-east-1)"
            return True, f"{req['Id']} {req['QuotaName']} -> {req['DesiredValue']} ({req['Status']})", ""
    return False, "no pending increase to >= 20 on L-1216C47A", \
        "list the adjustable quotas first: aws service-quotas list-service-quotas --service-code ec2"


CHECKS = [
    ("region resolution / caller identity", check_region),
    ("AWS Support API access", check_support_api),
    ("full Trusted Advisor check set", check_trusted_advisor),
    ("support case correctly classified", check_case),
    ("AWS Health API account events", check_health),
    ("EC2 On-Demand quota increase filed", check_quota_request),
]

if __name__ == "__main__":
    passed = 0
    print("\n== topic 4.3 verification ==")
    for idx, (title, fn) in enumerate(CHECKS, 1):
        ok, detail, hint = fn()
        tag = f"{GREEN}[PASS]{RESET}" if ok else f"{RED}[FAIL]{RESET}"
        print(f"{tag} {idx}/{len(CHECKS)} {title}")
        print(f"       {detail}")
        if not ok and hint:
            print(f"       {YELLOW}hint:{RESET} {hint}")
        passed += 1 if ok else 0
    print(f"\nscore: {passed}/{len(CHECKS)}")
    sys.exit(0 if passed == len(CHECKS) else 1)
VERIFY_EOF

# =============================================================================
# 4. The lab control CLI (simulated console side: billing, Trusted Advisor view)
# =============================================================================
cat > "$LAB_ROOT/bin/support-lab" <<'CTL_EOF'
#!/usr/bin/env bash
# Console-side companion for the topic 4.3 lab: it stands in for the parts of
# the AWS Management Console that have no CLI equivalent (changing the support
# plan in Billing, and the Trusted Advisor console view).
set -euo pipefail
LAB_ROOT="${LAB_ROOT:-@@LAB_ROOT@@}"
STATE="$LAB_ROOT/state"
PIDFILE="$STATE/mock.pid"
PLANS="basic developer business enterprise-on-ramp enterprise"

start() {
  if is_up; then echo "control plane already running on 127.0.0.1:4599"; return 0; fi
  LAB_STATE="$STATE" nohup python3 "$LAB_ROOT/mock/server.py" >>"$LAB_ROOT/logs/mock.log" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 40); do is_up && { echo "control plane up on 127.0.0.1:4599"; return 0; }; sleep 0.1; done
  echo "control plane failed to start; see $LAB_ROOT/logs/mock.log" >&2; return 1
}
stop() { [[ -f "$PIDFILE" ]] && kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; echo "stopped"; }
is_up() { (exec 3<>/dev/tcp/127.0.0.1/4599) 2>/dev/null; }

plan_get() { python3 -c "import json;print(json.load(open('$STATE/account.json'))['supportPlan'])"; }
plan_set() {
  local want="${1:-}"
  [[ " $PLANS " == *" $want "* ]] || { echo "unknown plan '$want'. valid: $PLANS" >&2; exit 2; }
  python3 - "$want" <<'PY'
import json, os, sys
path = os.path.join(os.environ["LAB_STATE"], "account.json")
data = json.load(open(path))
data["supportPlan"] = sys.argv[1]
json.dump(data, open(path, "w"), indent=2)
PY
  echo "[simulated Billing console] support plan changed to: $want"
  cat <<'NOTE'
  In a real account this is Billing and Cost Management -> Support plans, and it
  needs root or an IAM principal allowed to call supportplans:*. Published list
  prices (confirm at https://aws.amazon.com/premiumsupport/pricing/):
    Basic               free: docs, whitepapers, re:Post, core Trusted Advisor
                        checks, AWS Health Dashboard, service quota increases,
                        24x7 access to account and billing support only
    Developer           greater of USD 29/month or 3% of monthly AWS usage
                        business-hours email access to Cloud Support Associates
    Business            greater of USD 100/month or a tiered % of usage
                        24x7 phone/chat/email, full Trusted Advisor, Support API,
                        AWS Health API, third-party software support
    Enterprise On-Ramp  greater of USD 5,500/month or 10% of usage
                        pool of Technical Account Managers, 30-min response for
                        business-critical, Concierge, Well-Architected reviews
    Enterprise          greater of USD 15,000/month or a tiered % of usage
                        designated TAM, 15-min response for business-critical,
                        Incident Detection and Response, IEM, Concierge
NOTE
}

ta_console() {
  local plan; plan="$(plan_get)"
  echo "[simulated Trusted Advisor console] plan=$plan"
  case "$plan" in
    basic|developer)
      echo "  core checks only (service quota usage and basic security):"
      printf '    - %s\n' "Service Limits" "Security Groups - Specific Ports Unrestricted" \
        "IAM Use" "MFA on Root Account" "Amazon S3 Bucket Permissions" \
        "Amazon EBS Public Snapshots" "Amazon RDS Public Snapshots"
      echo "  the Trusted Advisor API is part of the AWS Support API, so it is unavailable here." ;;
    *)
      echo "  all categories available: cost optimizing, performance, security," \
           "fault tolerance, service limits (and operational excellence in the console)."
      echo "  programmatic access: aws support describe-trusted-advisor-checks --language en" ;;
  esac
}

docs() {
  cat <<'MAP'
AWS technical resources and support options - the map exam task 4.3 tests
  Self-service, free
    AWS Documentation .............. https://docs.aws.amazon.com/
    AWS Whitepapers and guides ..... https://aws.amazon.com/whitepapers/
    AWS Prescriptive Guidance ...... https://aws.amazon.com/prescriptive-guidance/
    AWS re:Post (community Q&A) .... https://repost.aws/
    AWS Knowledge Center ........... https://repost.aws/knowledge-center
    AWS Health Dashboard ........... https://health.aws.amazon.com/health/status
    AWS Well-Architected Tool ...... https://docs.aws.amazon.com/wellarchitected/latest/userguide/intro.html
    AWS Skill Builder / Training ... https://aws.amazon.com/training/
    Report abuse (Trust & Safety) .. https://support.aws.amazon.com/#/contacts/report-abuse
  Paid or engagement-based
    AWS Support plans .............. https://aws.amazon.com/premiumsupport/plans/
    AWS Support case management .... https://docs.aws.amazon.com/awssupport/latest/user/case-management.html
    AWS Support API ................ https://docs.aws.amazon.com/awssupport/latest/APIReference/Welcome.html
    Technical Account Manager ...... included with Enterprise On-Ramp (pooled) and Enterprise (designated)
    AWS Professional Services ...... https://aws.amazon.com/professional-services/
    AWS Managed Services (AMS) ..... https://aws.amazon.com/managed-services/
    AWS IQ (short-term experts) .... https://aws.amazon.com/iq/
    AWS Partner Network ............ https://aws.amazon.com/partners/
    AWS Marketplace ................ https://aws.amazon.com/marketplace/
  Operational limits
    Service Quotas ................. https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
MAP
}

status() {
  echo "lab root .......... $LAB_ROOT"
  echo "control plane ..... $(is_up && echo 'up (127.0.0.1:4599)' || echo 'DOWN - run: support-lab start')"
  echo "support plan ...... $(plan_get)"
  echo "configured region . $("$LAB_ROOT/bin/aws" configure get region 2>/dev/null || echo '(unset)')"
  echo "open cases ........ $(python3 -c "import json;print(len(json.load(open('$STATE/cases.json'))))" 2>/dev/null || echo 0)"
  echo "quota requests .... $(python3 -c "import json;print(len(json.load(open('$STATE/quota_requests.json'))))" 2>/dev/null || echo 0)"
}

export LAB_STATE="$STATE"
case "${1:-help}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  plan) shift; case "${1:-get}" in get) plan_get ;; set) shift; plan_set "${1:-}" ;; *) echo "usage: support-lab plan get|set <plan>" >&2; exit 2 ;; esac ;;
  ta-console) ta_console ;;
  docs) docs ;;
  verify) start >/dev/null; exec python3 "$LAB_ROOT/bin/lab-verify.py" ;;
  reset) exec bash "$LAB_ROOT/bin/reseed.sh" ;;
  *) cat <<'USAGE'
usage: support-lab <command>
  start | stop | status      offline control plane lifecycle
  plan get | plan set <p>    simulated Billing -> Support plans page
  ta-console                 simulated Trusted Advisor console view
  docs                       the task 4.3 resource map, with official URLs
  verify                     grade your fix
  reset                      re-break everything and start over
USAGE
     ;;
esac
CTL_EOF

# =============================================================================
# 5. Fault seeding (re-runnable)
# =============================================================================
cat > "$LAB_ROOT/bin/reseed.sh" <<'SEED_EOF'
#!/usr/bin/env bash
set -euo pipefail
LAB_ROOT="${LAB_ROOT:-@@LAB_ROOT@@}"
STATE="$LAB_ROOT/state"

# FAULT 1 - no region configured: every API call dies before it reaches the wire.
mkdir -p "$HOME/.aws"
cat > "$HOME/.aws/config" <<'CFG'
[default]
output = json
# region =
CFG
cat > "$HOME/.aws/credentials" <<'CRED'
[default]
aws_access_key_id = LABFAKEACCESSKEY0000
aws_secret_access_key = labFakeSecretKeyNeverUsedOffline0000000
CRED
chmod 600 "$HOME/.aws/credentials"

# FAULT 2 - the account sits on Basic Support: no Support API, no Health API,
#           core Trusted Advisor checks only.
cat > "$STATE/account.json" <<'ACC'
{
  "accountId": "000000000000",
  "supportPlan": "basic"
}
ACC
echo '[]' > "$STATE/cases.json"
echo '[]' > "$STATE/quota_requests.json"

# FAULT 3 - the on-call runbook opens the case at a severity the plan does not have.
cat > "$LAB_ROOT/drafts/10-open-case.sh" <<'DRAFT1'
#!/usr/bin/env bash
# On-call runbook snippet. It used to work on the old account. It no longer does.
# Keep the [LAB4.3] tag in the subject: the grader looks for it.
set -euo pipefail
aws support create-case \
  --subject "[LAB4.3] Auto Scaling cannot launch: EC2 On-Demand quota exhausted in us-east-1" \
  --service-code "amazon-elastic-compute-cloud-linux" \
  --category-code "instance-issue" \
  --severity-code "critical" \
  --language "en" \
  --communication-body "Production checkout fleet is down. The Auto Scaling group cannot launch instances: the Running On-Demand Standard instances quota in us-east-1 is 5 and we need 20. Requesting a quota increase and an engineer on the case."
DRAFT1

# FAULT 4 - the quota runbook targets a quota that cannot be raised.
cat > "$LAB_ROOT/drafts/20-raise-quota.sh" <<'DRAFT2'
#!/usr/bin/env bash
# On-call runbook snippet. Somebody copied the quota code from a chat message.
set -euo pipefail
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-LABF1XED \
  --desired-value 20
DRAFT2

chmod +x "$LAB_ROOT/drafts/"*.sh
echo "faults re-seeded."
SEED_EOF

# -----------------------------------------------------------------------------
# Materialise paths, permissions, environment
# -----------------------------------------------------------------------------
for f in "$LAB_ROOT/mock/server.py" "$LAB_ROOT/bin/aws" "$LAB_ROOT/bin/lab-verify.py" \
         "$LAB_ROOT/bin/support-lab" "$LAB_ROOT/bin/reseed.sh"; do
  sed -i "s|@@LAB_ROOT@@|$LAB_ROOT|g" "$f"
  chmod +x "$f"
done

cat > "$LAB_ROOT/env.sh" <<ENV_EOF
# source this file to enter the lab shell
export LAB_ROOT="$LAB_ROOT"
export LAB_STATE="$LAB_ROOT/state"
export PATH="$LAB_ROOT/bin:\$PATH"
# fake, syntactically valid credentials: nothing is signed, nothing leaves the VM
export AWS_ACCESS_KEY_ID="LABFAKEACCESSKEY0000"
export AWS_SECRET_ACCESS_KEY="labFakeSecretKeyNeverUsedOffline0000000"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE
ENV_EOF

if [[ -d "$HOME/.aws" && ! -e "$LAB_ROOT/backup/aws-$TS" ]]; then
  cp -a "$HOME/.aws" "$LAB_ROOT/backup/aws-$TS"
  info "backed up ~/.aws to $LAB_ROOT/backup/aws-$TS"
fi

LAB_ROOT="$LAB_ROOT" bash "$LAB_ROOT/bin/reseed.sh" >/dev/null
LAB_ROOT="$LAB_ROOT" "$LAB_ROOT/bin/support-lab" start >/dev/null
ok "lab installed and broken on purpose."

# =============================================================================
# 6. Student briefing
# =============================================================================
cat <<BRIEF

${c_bold}================================================================${c_reset}
${c_bold} BREAK & FIX — CLF-C02 task 4.3
 Identify AWS technical resources and AWS Support options${c_reset}
${c_bold}================================================================${c_reset}

${c_bold}Enter the lab${c_reset}
    source $LAB_ROOT/env.sh
    support-lab status

${c_bold}The scenario${c_reset}
  03:40. The checkout fleet in us-east-1 is down. The Auto Scaling group
  cannot launch instances: the "Running On-Demand Standard instances" quota
  is 5 and the fleet needs 20. You are on call on a VM that was rebuilt
  yesterday, and the on-call runbook under $LAB_ROOT/drafts/
  no longer works.

${c_bold}The symptoms you will see${c_reset}
  1) Any command fails before it reaches AWS:
       ${c_yel}You must specify a region. You can also configure your region by
       running "aws configure".${c_reset}
  2) Once that is fixed, Support and Health calls fail with:
       ${c_yel}An error occurred (SubscriptionRequiredException) when calling the
       DescribeSeverityLevels operation: Amazon Web Services Premium Support
       Subscription is required to use this service.${c_reset}
     and \`support-lab ta-console\` shows only a handful of checks.
  3) drafts/10-open-case.sh is rejected:
       ${c_yel}InvalidParameterValueException: severityCode 'critical' is not
       available for support plan ...${c_reset}
  4) drafts/20-raise-quota.sh is rejected:
       ${c_yel}InvalidParameterValueException: The quota 'L-LABF1XED' ... is not
       adjustable and cannot be increased.${c_reset}

${c_bold}What you must achieve — all six graded checks green${c_reset}
  1. \`aws sts get-caller-identity\` resolves (region configured, us-east-1).
  2. \`aws support describe-severity-levels\` succeeds: the account has a plan
     that grants programmatic access to AWS Support.
  3. The full Trusted Advisor check set is visible (> 7 checks, all categories).
  4. A support case exists whose subject contains ${c_bold}[LAB4.3]${c_reset}, classified at the
     severity that means "production system down" — the highest severity your
     chosen plan actually offers, not the highest severity that exists.
  5. \`aws health describe-events\` returns ACCOUNT_SPECIFIC events, not just the
     public ones you could have read on the AWS Health Dashboard for free.
  6. A PENDING Service Quotas increase to >= 20 on the ${c_bold}adjustable${c_reset} EC2
     On-Demand Standard instances quota, in us-east-1.

${c_bold}Tools on your side${c_reset}
    aws <service> <operation>     offline AWS CLI v2 look-alike
    support-lab status            plan, region, control-plane health
    support-lab plan get|set      simulated Billing -> Support plans page
    support-lab ta-console        simulated Trusted Advisor console
    support-lab docs              the task 4.3 resource map, with official URLs
    support-lab verify            grade yourself
    support-lab reset             re-break it and try again

${c_bold}Questions to answer out loud before you call it done${c_reset}
  · Which support plans give you the AWS Support API, and which give you a
    Technical Account Manager?
  · What is the first-response target for each severity on your plan, and what
    changes on Enterprise On-Ramp versus Enterprise?
  · Which of these did you NOT need a paid plan for: quota increases, the
    public AWS Health Dashboard, the AWS Health API, re:Post, the Knowledge
    Center, the core Trusted Advisor checks?
  · Who would you engage for a six-month migration: Professional Services,
    AWS IQ, an APN partner, or AMS — and why?

${c_bold}Undo everything${c_reset}
    $0 --restore

BRIEF

exit 0

# =============================================================================
# ============================  SOLUTION  =====================================
#  Stop here unless you have already tried. Everything below is the answer.
# =============================================================================
#
# STEP 0 — enter the lab and take stock
#   source /opt/support-lab/env.sh
#   support-lab status
#     control plane ..... up (127.0.0.1:4599)
#     support plan ...... basic
#     configured region . (unset)
#   Reading a status line before touching anything is the whole discipline:
#   two of the four faults are already visible here.
#
# ---------------------------------------------------------------------------
# FAULT 1 — no region configured
# ---------------------------------------------------------------------------
#   Symptom:
#     $ aws sts get-caller-identity
#     You must specify a region. You can also configure your region by running "aws configure".
#
#   Diagnosis: the CLI resolves the region in a fixed order — --region flag,
#   then AWS_REGION, then AWS_DEFAULT_REGION, then the `region` key of the
#   active profile in ~/.aws/config. All four are empty. The rebuild dropped
#   the config file.
#
#   Fix (the workload is in us-east-1, so that is the region):
#     aws configure set region us-east-1
#     aws configure get region          # -> us-east-1
#     aws sts get-caller-identity       # -> arn:aws:iam::000000000000:user/lab-student
#
#   Worth knowing for the exam: AWS Support and AWS Health are global services
#   whose API endpoint lives in US East (N. Virginia); Service Quotas is
#   regional — a quota raised in us-east-1 does nothing for eu-west-1.
#
# ---------------------------------------------------------------------------
# FAULT 2 — the account is on Basic Support
# ---------------------------------------------------------------------------
#   Symptom:
#     $ aws support describe-severity-levels
#     An error occurred (SubscriptionRequiredException) when calling the
#     DescribeSeverityLevels operation: Amazon Web Services Premium Support
#     Subscription is required to use this service.
#     $ aws health describe-events        # same error
#     $ support-lab ta-console            # core checks only
#
#   Diagnosis: Basic Support gives you documentation, whitepapers, re:Post, the
#   Knowledge Center, the AWS Health Dashboard, service quota increases, the
#   core Trusted Advisor checks, and 24x7 access to account and billing support
#   only. It does NOT give you technical support cases, the AWS Support API,
#   the AWS Health API, or the full Trusted Advisor check set. Developer adds
#   business-hours technical cases but still no API access. The Support API and
#   the Health API start at Business.
#     https://aws.amazon.com/premiumsupport/plans/
#     https://docs.aws.amazon.com/awssupport/latest/APIReference/Welcome.html
#     https://docs.aws.amazon.com/health/latest/ug/health-api.html
#
#   Fix (in a real account: Billing and Cost Management -> Support plans, as
#   root or an IAM principal with supportplans permissions):
#     support-lab plan get              # basic
#     support-lab plan set business
#     aws support describe-severity-levels
#       low     General guidance            24 hours
#       normal  System impaired             12 hours
#       high    Production system impaired   4 hours
#       urgent  Production system down       1 hour
#
#   Note what did NOT appear: `critical` (business-critical system down). That
#   severity exists only on Enterprise On-Ramp (30-minute target) and
#   Enterprise (15-minute target). This is fault 3, and you have just diagnosed
#   it without seeing the error yet.
#
# ---------------------------------------------------------------------------
# FAULT 3 — the runbook opens the case at a severity the plan does not have
# ---------------------------------------------------------------------------
#   Symptom:
#     $ bash /opt/support-lab/drafts/10-open-case.sh
#     An error occurred (InvalidParameterValueException) when calling the
#     CreateCase operation: severityCode 'critical' is not available for support
#     plan 'business'. Available: low, normal, high, urgent.
#
#   Diagnosis: the runbook was written for an Enterprise account. Severity is
#   not a mood, it is a contract: each code maps to a documented first-response
#   target, and the available codes are a function of the plan.
#     https://docs.aws.amazon.com/awssupport/latest/user/case-management.html
#
#   Fix — classify the case honestly. Production is down, so `urgent`:
#     sed -i 's/--severity-code "critical"/--severity-code "urgent"/' \
#       /opt/support-lab/drafts/10-open-case.sh
#     bash /opt/support-lab/drafts/10-open-case.sh
#     # -> {"caseId": "case-000000000000-lab-2026-00000001"}
#     aws support describe-cases
#
#   Equivalent single command, if you prefer not to touch the runbook:
#     aws support create-case \
#       --subject "[LAB4.3] Auto Scaling cannot launch: EC2 On-Demand quota exhausted in us-east-1" \
#       --service-code "amazon-elastic-compute-cloud-linux" \
#       --category-code "instance-issue" \
#       --severity-code "urgent" \
#       --language "en" \
#       --communication-body "Production checkout fleet is down..."
#
#   Discover valid classification codes instead of guessing:
#     aws support describe-services
#
# ---------------------------------------------------------------------------
# FAULT 4 — the quota request targets a non-adjustable quota
# ---------------------------------------------------------------------------
#   Symptom:
#     $ bash /opt/support-lab/drafts/20-raise-quota.sh
#     An error occurred (InvalidParameterValueException) when calling the
#     RequestServiceQuotaIncrease operation: The quota 'L-LABF1XED' (Lab
#     simulated hard limit (NOT adjustable)) is not adjustable and cannot be
#     increased.
#
#   Diagnosis: Service Quotas marks every quota as adjustable or not. A
#   non-adjustable quota is an architectural constraint — you design around it,
#   you do not file a case about it. Somebody pasted the wrong code from chat.
#     https://docs.aws.amazon.com/servicequotas/latest/userguide/intro.html
#
#   Fix — list the quotas and pick the adjustable one that matches the failure:
#     aws service-quotas list-service-quotas --service-code ec2
#       L-1216C47A  Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances  5.0  Adjustable: true
#       L-0263D0A3  EC2-VPC Elastic IPs                                               5.0  Adjustable: true
#       L-LABF1XED  Lab simulated hard limit (NOT adjustable)                         5.0  Adjustable: false
#
#     aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
#     aws service-quotas request-service-quota-increase \
#       --service-code ec2 --quota-code L-1216C47A --desired-value 20
#     aws service-quotas list-requested-service-quota-change-history --service-code ec2
#       # Status: PENDING
#
#   Two exam-relevant facts hiding in this step: quota increases are available
#   on every plan, Basic included — you never need to buy support to raise a
#   limit; and the Trusted Advisor "Service Limits" check is one of the core
#   free checks precisely because it warns you at ~80% usage, before 03:40.
#
# ---------------------------------------------------------------------------
# STEP 5 — read the account-specific health signal
# ---------------------------------------------------------------------------
#     aws health describe-events
#   PUBLIC events are what anyone can read on the AWS Health Dashboard without
#   a plan. ACCOUNT_SPECIFIC events — the degraded instance store on
#   i-0lab00000000000a1, the scheduled RDS maintenance — are yours, and reaching
#   them programmatically is what the Business plan bought you. This is the
#   distinction between "Service health" and "Your account health".
#     https://docs.aws.amazon.com/health/latest/ug/what-is-aws-health.html
#
# ---------------------------------------------------------------------------
# STEP 6 — grade
# ---------------------------------------------------------------------------
#     support-lab verify
#     # score: 6/6
#
# ---------------------------------------------------------------------------
# THE CONCEPTUAL ANSWERS
# ---------------------------------------------------------------------------
#   Plan capability ladder (each tier includes the one below it):
#     Basic               docs, whitepapers, re:Post, Knowledge Center, AWS
#                         Health Dashboard, quota increases, core Trusted
#                         Advisor checks, account and billing support 24x7
#     Developer           technical cases in business hours, general guidance
#                         (24h) and system impaired (12h)
#     Business            24x7 phone/chat/email, ALL Trusted Advisor checks,
#                         AWS Support API, AWS Health API, third-party software
#                         support, IAM-controlled case access, high (4h) and
#                         urgent (1h)
#     Enterprise On-Ramp  pooled Technical Account Managers, Concierge for
#                         billing, Well-Architected reviews, critical (30 min)
#     Enterprise          designated TAM, Incident Detection and Response,
#                         Infrastructure Event Management, training, critical
#                         (15 min)
#
#   Free versus paid, from this lab: quota increases FREE, public AWS Health
#   Dashboard FREE, re:Post FREE, Knowledge Center FREE, core Trusted Advisor
#   checks FREE — the AWS Health API, the Support API, the full Trusted Advisor
#   set and technical cases are the paid part.
#
#   Who to engage for a six-month migration:
#     AWS Professional Services  AWS's own consultants, joint engagement
#     APN partner                a vetted third party, often the right answer
#     AWS IQ                     short, scoped tasks with independent experts
#     AMS                        ongoing operation of your infrastructure,
#                                not a migration project
#     A TAM                      guidance and advocacy, not delivery capacity
#
#   Run `support-lab docs` for the full resource map with official URLs.
#
#   Cleanup:  ./break-fix-4.3-support.sh --restore
# =============================================================================