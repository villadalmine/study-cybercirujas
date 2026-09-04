#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) - Lab: BREAK & FIX
#  Domain 2: Security and Compliance
#  Task Statement 2.2: Understand AWS Cloud security, governance, and compliance
#                      concepts  (exam weight for this topic: 7.5)
# ==============================================================================
#
#  WHAT THIS IS
#  ------------
#  A self-contained, offline, destructive-free lab. It builds a *simulated AWS
#  account control plane* as a JSON tree under $LAB_ROOT and then misconfigures
#  it the way real accounts get misconfigured. Nothing outside $LAB_ROOT is ever
#  written, and no real AWS API is ever called: the script installs a read-only
#  `aws` shim on the lab PATH that answers real CLI subcommands with the real
#  API response shapes, so every inspection command you type here is the exact
#  command you would type against a real account.
#
#  The graded controls are the real Security Hub control IDs from the AWS
#  Foundational Security Best Practices (FSBP) standard and the CIS AWS
#  Foundations Benchmark, because that is what an auditor actually reads.
#
#  RUN IT ONLY ON A DISPOSABLE LAB VM.
#
#  USAGE
#  -----
#    ./22-break-fix-security-governance.sh break     # arm the lab (default)
#    ./22-break-fix-security-governance.sh verify    # the grader / audit report
#    ./22-break-fix-security-governance.sh hint      # guidance for failing controls
#    ./22-break-fix-security-governance.sh shell     # subshell with the lab PATH
#    ./22-break-fix-security-governance.sh reset     # delete the lab tree
#
#  ENVIRONMENT
#  -----------
#    LAB_ROOT=<path>     default: $HOME/labs/aws-clf-2.2
#    LAB_ASSUME_YES=1    skip the interactive confirmation
#
#  REQUIREMENTS: bash >= 4, jq >= 1.6, coreutils.
#
#  OFFICIAL SOURCES
#  ----------------
#   - CLF-C02 Exam Guide:
#     https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#   - Security Hub controls reference:
#     https://docs.aws.amazon.com/securityhub/latest/userguide/securityhub-controls-reference.html
#   - IAM security best practices:
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
#   - S3 Block Public Access:
#     https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
#   - S3 bucket policy examples (aws:SecureTransport):
#     https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-bucket-policies.html
#   - CloudTrail log file integrity validation:
#     https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
#   - CloudTrail encryption with SSE-KMS:
#     https://docs.aws.amazon.com/awscloudtrail/latest/userguide/encrypting-cloudtrail-log-files-with-aws-kms.html
#   - What is AWS Config:
#     https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html
#   - Rotating AWS KMS keys:
#     https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
#   - Amazon GuardDuty:
#     https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
#   - Amazon Macie:
#     https://docs.aws.amazon.com/macie/latest/user/what-is-macie.html
#   - Amazon Inspector:
#     https://docs.aws.amazon.com/inspector/latest/user/what-is-inspector.html
#   - AWS Artifact:
#     https://docs.aws.amazon.com/artifact/latest/ug/what-is-aws-artifact.html
#   - Amazon EBS encryption by default:
#     https://docs.aws.amazon.com/ebs/latest/userguide/work-with-ebs-encr.html
# ==============================================================================

set -euo pipefail

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
    echo "This lab needs bash >= 4 (associative arrays). Found: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Constants. The account id 000000000000 is deliberately fictitious, and every
# credential-shaped string in this lab is defanged so no secret scanner, and no
# student, ever mistakes it for real key material.
# ------------------------------------------------------------------------------
LAB_ID="aws-clf-2.2"
LAB_ROOT="${LAB_ROOT:-$HOME/labs/${LAB_ID}}"
ACC="${LAB_ROOT}/account"
BIN="${LAB_ROOT}/bin"
ACCOUNT_ID="000000000000"
REGION="us-east-1"
BUCKET="clf-lab-reports-${ACCOUNT_ID}"
TRAIL="clf-lab-trail"
CMK_ARN="arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/1b2c3d4e-5f60-4a71-8b92-0c3d4e5f6a7b"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/DataTeamAccess"
SG_ID="sg-0a1b2c3d4e5f67890"
TOTAL_CONTROLS=19

if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; W=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
    R=''; G=''; Y=''; C=''; W=''; D=''; N=''
fi

PASSED=0
FAILED=0
FAILED_IDS=()
declare -A HINTS=()

die()  { echo "${R}error:${N} $*" >&2; exit 1; }
info() { echo "${C}==>${N} $*"; }
rule() { printf '%s\n' "${D}------------------------------------------------------------------------------${N}"; }

require_tools() {
    local missing=()
    for t in jq stat grep sed mktemp; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if (( ${#missing[@]} )); then
        echo "${R}Missing required tools:${N} ${missing[*]}" >&2
        echo "  Fedora/RHEL : sudo dnf install -y ${missing[*]}" >&2
        echo "  Debian/Ubuntu: sudo apt-get install -y ${missing[*]}" >&2
        exit 1
    fi
}

# Refuse to operate on anything that is not clearly the lab directory.
sanity_lab_root() {
    case "$LAB_ROOT" in
        ""|"/"|"$HOME"|"$HOME/") die "LAB_ROOT ($LAB_ROOT) is unsafe. Point it at a dedicated directory." ;;
    esac
    [[ "$LAB_ROOT" == *"$LAB_ID"* ]] || die "LAB_ROOT must contain '${LAB_ID}' in its path (got: $LAB_ROOT)."
}

confirm() {
    [[ "${LAB_ASSUME_YES:-0}" == "1" ]] && return 0
    echo
    echo "${Y}${W}This script arms a deliberately misconfigured lab.${N}"
    echo "It writes ONLY under: ${W}${LAB_ROOT}${N}"
    echo "It installs a fake read-only 'aws' command in ${W}${BIN}${N} which shadows a real"
    echo "AWS CLI while the lab PATH is active. It never calls a real AWS endpoint."
    echo
    read -r -p "Type 'lab' to continue: " answer
    [[ "$answer" == "lab" ]] || die "Aborted by the user."
}

write_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path"
}

# ==============================================================================
# BREAK
# ==============================================================================
cmd_break() {
    sanity_lab_root
    require_tools
    confirm

    rm -rf "${ACC}"
    mkdir -p "${ACC}" "${BIN}" "${LAB_ROOT}/answers" "${LAB_ROOT}/app" "${LAB_ROOT}/.aws" "${LAB_ROOT}/work"

    # --- STS -------------------------------------------------------------------
    write_file "${ACC}/sts/get-caller-identity.json" <<JSON
{
    "UserId": "AIDAEXAMPLEUSERIDLAB",
    "Account": "${ACCOUNT_ID}",
    "Arn": "arn:aws:iam::${ACCOUNT_ID}:user/lab-operator"
}
JSON

    # --- IAM: root hygiene -----------------------------------------------------
    # AccountMFAEnabled=0 and AccountAccessKeysPresent=1 are exactly what the
    # real GetAccountSummary returns for an account whose root user still has
    # long-term keys and no MFA. Two of the oldest findings in the benchmark.
    write_file "${ACC}/iam/get-account-summary.json" <<'JSON'
{
    "SummaryMap": {
        "AccountMFAEnabled": 0,
        "AccountAccessKeysPresent": 1,
        "Users": 9,
        "UsersQuota": 5000,
        "MFADevices": 3,
        "MFADevicesInUse": 3,
        "Policies": 14,
        "PolicyVersionsInUse": 27,
        "GroupsPerUserQuota": 10
    }
}
JSON

    # --- IAM: password policy --------------------------------------------------
    # Note the shape: the real API OMITS PasswordReusePrevention when it has
    # never been set. Your jq must handle the absent key, not assume a zero.
    write_file "${ACC}/iam/get-account-password-policy.json" <<'JSON'
{
    "PasswordPolicy": {
        "MinimumPasswordLength": 6,
        "RequireSymbols": false,
        "RequireNumbers": false,
        "RequireUppercaseCharacters": false,
        "RequireLowercaseCharacters": false,
        "AllowUsersToChangePassword": false,
        "ExpirePasswords": false
    }
}
JSON

    # --- IAM: the classic star-star policy -------------------------------------
    write_file "${ACC}/iam/list-policies.json" <<JSON
{
    "Policies": [
        {
            "PolicyName": "DataTeamAccess",
            "PolicyId": "ANPAEXAMPLEPOLICYIDLAB",
            "Arn": "${POLICY_ARN}",
            "Path": "/",
            "DefaultVersionId": "v3",
            "AttachmentCount": 4,
            "IsAttachable": true,
            "CreateDate": "2026-05-02T14:21:03+00:00",
            "UpdateDate": "2026-08-30T12:00:00+00:00"
        }
    ]
}
JSON

    write_file "${ACC}/iam/get-policy-version.json" <<'JSON'
{
    "PolicyVersion": {
        "Document": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Sid": "DataTeamEverything",
                    "Effect": "Allow",
                    "Action": "*",
                    "Resource": "*"
                }
            ]
        },
        "VersionId": "v3",
        "IsDefaultVersion": true,
        "CreateDate": "2026-08-30T12:00:00+00:00"
    }
}
JSON

    # --- S3: account-level Block Public Access ---------------------------------
    # Account level lives in the s3control API, bucket level in s3api. Knowing
    # which one an auditor asks for is half the exam question.
    write_file "${ACC}/s3control/get-public-access-block.json" <<'JSON'
{
    "PublicAccessBlockConfiguration": {
        "BlockPublicAcls": false,
        "IgnorePublicAcls": false,
        "BlockPublicPolicy": false,
        "RestrictPublicBuckets": false
    }
}
JSON

    write_file "${ACC}/s3api/list-buckets.json" <<JSON
{
    "Buckets": [
        { "Name": "${BUCKET}", "CreationDate": "2026-04-11T09:02:44+00:00" },
        { "Name": "clf-lab-trail-logs-${ACCOUNT_ID}", "CreationDate": "2026-04-11T09:03:10+00:00" },
        { "Name": "clf-lab-config-${ACCOUNT_ID}", "CreationDate": "2026-04-11T09:03:31+00:00" }
    ],
    "Owner": { "DisplayName": "clf-lab", "ID": "b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9" }
}
JSON

    # GetBucketPolicy returns the document as an ESCAPED STRING, not as JSON.
    # That is why every real audit one-liner pipes it through `fromjson`.
    write_file "${ACC}/s3api/get-bucket-policy.json" <<'JSON'
{
    "Policy": "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PublicReadGetObject\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::clf-lab-reports-000000000000/*\"}]}"
}
JSON

    # --- CloudTrail ------------------------------------------------------------
    write_file "${ACC}/cloudtrail/describe-trails.json" <<JSON
{
    "trailList": [
        {
            "Name": "${TRAIL}",
            "S3BucketName": "clf-lab-trail-logs-${ACCOUNT_ID}",
            "IncludeGlobalServiceEvents": false,
            "IsMultiRegionTrail": false,
            "HomeRegion": "${REGION}",
            "TrailARN": "arn:aws:cloudtrail:${REGION}:${ACCOUNT_ID}:trail/${TRAIL}",
            "LogFileValidationEnabled": false,
            "HasCustomEventSelectors": false,
            "HasInsightSelectors": false,
            "IsOrganizationTrail": false
        }
    ]
}
JSON

    write_file "${ACC}/cloudtrail/get-trail-status.json" <<'JSON'
{
    "IsLogging": false,
    "LatestDeliveryTime": "2026-08-28T03:09:12+00:00",
    "StartLoggingTime": "2026-04-11T09:10:00+00:00",
    "StopLoggingTime": "2026-08-28T03:11:52+00:00",
    "TimeLoggingStarted": "2026-04-11T09:10:00Z",
    "TimeLoggingStopped": "2026-08-28T03:11:52Z"
}
JSON

    # --- AWS Config ------------------------------------------------------------
    # A recorder with no delivery channel cannot record. The error code below is
    # the one the service actually returns, and it is the whole diagnosis.
    write_file "${ACC}/configservice/describe-configuration-recorder-status.json" <<'JSON'
{
    "ConfigurationRecordersStatus": [
        {
            "name": "default",
            "lastStartTime": "2026-04-11T09:15:02+00:00",
            "lastStopTime": "2026-08-28T03:12:40+00:00",
            "recording": false,
            "lastStatus": "FAILURE",
            "lastErrorCode": "NoAvailableDeliveryChannel",
            "lastErrorMessage": "The configuration recorder cannot start because no delivery channel is configured.",
            "lastStatusChangeTime": "2026-08-28T03:12:40+00:00"
        }
    ]
}
JSON

    write_file "${ACC}/configservice/describe-delivery-channels.json" <<'JSON'
{
    "DeliveryChannels": []
}
JSON

    # --- GuardDuty -------------------------------------------------------------
    write_file "${ACC}/guardduty/list-detectors.json" <<'JSON'
{
    "DetectorIds": []
}
JSON

    # --- KMS -------------------------------------------------------------------
    write_file "${ACC}/kms/list-aliases.json" <<JSON
{
    "Aliases": [
        {
            "AliasName": "alias/clf-lab-cmk",
            "AliasArn": "arn:aws:kms:${REGION}:${ACCOUNT_ID}:alias/clf-lab-cmk",
            "TargetKeyId": "1b2c3d4e-5f60-4a71-8b92-0c3d4e5f6a7b"
        },
        {
            "AliasName": "alias/aws/s3",
            "AliasArn": "arn:aws:kms:${REGION}:${ACCOUNT_ID}:alias/aws/s3",
            "TargetKeyId": "9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"
        }
    ]
}
JSON

    write_file "${ACC}/kms/get-key-rotation-status.json" <<'JSON'
{
    "KeyRotationEnabled": false
}
JSON

    # --- EC2 -------------------------------------------------------------------
    write_file "${ACC}/ec2/describe-security-groups.json" <<JSON
{
    "SecurityGroups": [
        {
            "GroupId": "${SG_ID}",
            "GroupName": "lab-bastion-sg",
            "Description": "bastion access",
            "VpcId": "vpc-0f1e2d3c4b5a69788",
            "IpPermissions": [
                {
                    "IpProtocol": "tcp",
                    "FromPort": 22,
                    "ToPort": 22,
                    "IpRanges": [ { "CidrIp": "0.0.0.0/0", "Description": "temporary - remove after migration" } ],
                    "Ipv6Ranges": [ { "CidrIpv6": "::/0" } ],
                    "PrefixListIds": [],
                    "UserIdGroupPairs": []
                },
                {
                    "IpProtocol": "tcp",
                    "FromPort": 3389,
                    "ToPort": 3389,
                    "IpRanges": [ { "CidrIp": "0.0.0.0/0" } ],
                    "Ipv6Ranges": [],
                    "PrefixListIds": [],
                    "UserIdGroupPairs": []
                }
            ],
            "IpPermissionsEgress": [
                { "IpProtocol": "-1", "IpRanges": [ { "CidrIp": "0.0.0.0/0" } ], "Ipv6Ranges": [], "PrefixListIds": [], "UserIdGroupPairs": [] }
            ]
        }
    ]
}
JSON

    write_file "${ACC}/ec2/get-ebs-encryption-by-default.json" <<'JSON'
{
    "EbsEncryptionByDefault": false
}
JSON

    # --- Local credential hygiene (the customer side of the responsibility line)
    # Every key-shaped string here is intentionally malformed: it carries hyphens
    # so it can never match the real AKIA[0-9A-Z]{16} shape.
    write_file "${LAB_ROOT}/.aws/credentials" <<'CRED'
[default]
aws_access_key_id = AKIA-EXAMPLE-DO-NOT-USE
aws_secret_access_key = EXAMPLE-SECRET-NOT-REAL-DO-NOT-USE
CRED
    chmod 0644 "${LAB_ROOT}/.aws/credentials"

    write_file "${LAB_ROOT}/.aws/config" <<CFG
[default]
region = ${REGION}
output = json
CFG

    write_file "${LAB_ROOT}/app/.env" <<'ENVF'
APP_ENV=production
REPORTS_BUCKET=clf-lab-reports-000000000000
AWS_ACCESS_KEY_ID=AKIA-EXAMPLE-DO-NOT-USE
AWS_SECRET_ACCESS_KEY=EXAMPLE-SECRET-NOT-REAL-DO-NOT-USE
ENVF

    # --- The concepts answer sheet ---------------------------------------------
    write_file "${LAB_ROOT}/answers/governance.env" <<'ANS'
# Task 2.2 - governance and compliance concepts.
# Fill in the AWS service that answers each question. One service per line.
# Free form is fine: "AWS CloudTrail", "cloudtrail" and "CloudTrail" all grade
# the same. Leave nothing blank.

# Where does an auditor download the SOC 2, ISO 27001 and PCI DSS reports
# for the AWS side of the shared responsibility model, on demand?
COMPLIANCE_REPORTS_SERVICE=

# Which service records WHO made WHICH API call, from WHERE and WHEN?
API_ACTIVITY_AUDIT_SERVICE=

# Which service records the CONFIGURATION of a resource over time and can
# evaluate it against rules (a configuration history and compliance timeline)?
RESOURCE_CONFIGURATION_HISTORY_SERVICE=

# Which service aggregates security findings from other services and scores
# the account against CIS / AWS Foundational Security Best Practices?
CENTRAL_FINDINGS_SERVICE=

# Which service discovers and classifies sensitive data (PII, credentials)
# inside Amazon S3?
S3_SENSITIVE_DATA_DISCOVERY_SERVICE=

# Which service continuously scans EC2 instances, container images in ECR and
# Lambda functions for software vulnerabilities and unintended network exposure?
WORKLOAD_VULNERABILITY_SCAN_SERVICE=

# Which service creates, stores and controls the encryption keys used for
# encryption at rest across AWS services?
KEY_STORAGE_SERVICE=
ANS

    install_shims
    print_briefing
}

# ------------------------------------------------------------------------------
# The read-only `aws` shim: real subcommands, real response shapes, no network.
# ------------------------------------------------------------------------------
install_shims() {
    write_file "${BIN}/aws" <<'SHIM'
#!/usr/bin/env bash
# Offline read-only AWS CLI simulator for the CLF-C02 2.2 lab.
# It resolves `aws <service> <operation>` to account/<service>/<operation>.json.
# Mutating operations are intentionally NOT implemented: in this lab the control
# plane is the JSON tree, and you remediate it with jq (see `hint`).
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACC="${LAB_ROOT}/account"
LAB_BUCKET="clf-lab-reports-000000000000"

# Drop global flags that may precede the service name (--region, --profile...).
while [[ $# -gt 0 && "$1" == --* ]]; do
    case "$1" in
        --region|--profile|--output|--endpoint-url|--query) shift 2 ;;
        *) shift ;;
    esac
done

service="${1:-}"; operation="${2:-}"
[[ -n "$service" && -n "$operation" ]] && shift 2

if [[ -z "$service" || -z "$operation" ]]; then
    echo "usage: aws <service> <operation> [parameters]" >&2
    echo "lab note: this is the offline lab shim (read-only)." >&2
    exit 252
fi

# Validate --bucket the way the real service would.
bucket=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[$i]}" == "--bucket" ]] && bucket="${args[$((i + 1))]:-}"
done
if [[ -n "$bucket" && "$bucket" != "$LAB_BUCKET" ]]; then
    echo "An error occurred (NoSuchBucket) when calling the ${operation} operation: The specified bucket does not exist" >&2
    exit 254
fi

file="${ACC}/${service}/${operation}.json"
if [[ -f "$file" ]]; then
    jq . "$file"
    exit 0
fi

cat >&2 <<EOF
Invalid choice or unimplemented in this lab: 'aws ${service} ${operation}'.
The lab shim answers read-only inspection calls only. Available:
$(cd "$ACC" 2>/dev/null && for d in */; do for f in "$d"*.json; do echo "  aws ${d%/} $(basename "$f" .json)"; done; done)
EOF
exit 252
SHIM
    chmod +x "${BIN}/aws"

    # jq in-place helper. This is how you "apply" a change in this lab.
    write_file "${BIN}/jqi" <<'JQI'
#!/usr/bin/env bash
# jqi <file> <jq-filter> [jq-args...]  -- edit a JSON file in place.
set -euo pipefail
file="$1"; shift
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
jq "$@" "$file" > "$tmp"
mv "$tmp" "$file"
JQI
    chmod +x "${BIN}/jqi"
}

print_briefing() {
    echo
    rule
    echo "${W}  CLF-C02 / Domain 2 / Task 2.2 - BREAK & FIX ARMED${N}"
    rule
    cat <<EOF

${W}SCENARIO${N}
  You have inherited AWS account ${ACCOUNT_ID}. A SOC 2 Type II readiness
  review starts on Monday and the auditor has asked for one thing: evidence.
  Not opinions - evidence that the account is governed, logged, encrypted and
  least-privileged, and that the evidence itself cannot be tampered with.

  The previous operator "made things work" during an incident window and never
  rolled anything back. Governance guardrails are off, logging is stopped, data
  is public, and long-term credentials are sitting in a world-readable file.

${W}THE SYMPTOM YOU WILL SEE${N}
  Run the audit:

      ${C}${LAB_ROOT}/../$(basename "$0") verify${N}   (or: $0 verify)

  It renders a Security Hub-style report. Right now ${R}every one of the
  ${TOTAL_CONTROLS} controls fails${N} and the compliance score is 0%. Each failing line
  gives you the real control ID (IAM.9, S3.1, CloudTrail.4, Config.1, KMS.4,
  EC2.13 ...) and nothing else. Diagnosis is your job.

  You will also see, if you look:
    - ${D}aws cloudtrail get-trail-status${N} reports ${R}"IsLogging": false${N} - the account
      has been blind since 2026-08-28. There is no record of what happened after
      that timestamp, and no way to create one retroactively.
    - ${D}aws s3api get-bucket-policy --bucket ${BUCKET}${N} returns a
      policy whose Principal is ${R}"*"${N}.
    - ${D}ls -l ${LAB_ROOT}/.aws/credentials${N} shows mode ${R}0644${N} with static keys in it.

${W}YOUR OBJECTIVE${N}
  Get the audit to print ${G}${TOTAL_CONTROLS}/${TOTAL_CONTROLS} - AUDIT PASSED${N}, and be able to say out loud,
  for each control, ${W}which AWS service enforces it and what an attacker or an
  auditor does when it is off${N}. Two of the controls are not configuration at
  all: one is credential hygiene on the customer side of the shared
  responsibility line, and one is the concepts answer sheet at
  ${C}${LAB_ROOT}/answers/governance.env${N} - a control you cannot pass by guessing
  the syntax, only by knowing what each service is for.

${W}YOUR TOOLBOX${N}
  Enter the lab shell (adds ${BIN} to PATH):

      ${C}$0 shell${N}

  Inside it, ${W}aws${N} is an offline read-only simulator that speaks the real CLI:

      ${D}aws sts get-caller-identity${N}
      ${D}aws iam get-account-summary${N}
      ${D}aws iam get-account-password-policy${N}
      ${D}aws iam list-policies${N}
      ${D}aws iam get-policy-version --policy-arn ${POLICY_ARN} --version-id v3${N}
      ${D}aws s3control get-public-access-block --account-id ${ACCOUNT_ID}${N}
      ${D}aws s3api get-bucket-policy --bucket ${BUCKET}${N}
      ${D}aws cloudtrail describe-trails${N}
      ${D}aws cloudtrail get-trail-status --name ${TRAIL}${N}
      ${D}aws configservice describe-configuration-recorder-status${N}
      ${D}aws configservice describe-delivery-channels${N}
      ${D}aws guardduty list-detectors${N}
      ${D}aws kms get-key-rotation-status --key-id alias/clf-lab-cmk${N}
      ${D}aws ec2 describe-security-groups${N}
      ${D}aws ec2 get-ebs-encryption-by-default${N}

  Writes are not implemented on purpose. ${W}The lab control plane is the JSON tree
  under ${ACC}${N}; you remediate by editing it, and the helper
  ${W}jqi <file> '<filter>'${N} does an in-place jq edit. For every fix, work out the
  real production command too - ${C}$0 hint${N} names the service and the doc page.

${W}RULES${N}
  - Do not edit this script or the verifier. Fix the account, not the exam.
  - ${C}$0 hint${N}  gives guidance for the controls that are still failing.
  - ${C}$0 reset${N} deletes ${LAB_ROOT} and discards all your progress.

EOF
    rule
}

# ==============================================================================
# VERIFY - the graded audit report
# ==============================================================================
record() {
    local ok="$1" id="$2" ref="$3" title="$4"
    if [[ "$ok" == "0" ]]; then
        printf '  %s%-12s%s %-14s %-52s %sPASS%s\n' "$D" "$id" "$N" "$ref" "$title" "$G" "$N"
        PASSED=$((PASSED + 1))
    else
        printf '  %s%-12s%s %-14s %-52s %sFAIL%s\n' "$W" "$id" "$N" "$ref" "$title" "$R" "$N"
        FAILED=$((FAILED + 1))
        FAILED_IDS+=("$id")
    fi
}

# jcheck <id> <ref> <title> <relative-json-path> <jq-filter>
jcheck() {
    local id="$1" ref="$2" title="$3" rel="$4" filter="$5"
    local file="${ACC}/${rel}" ok=1
    if [[ -f "$file" ]] && jq -e "$filter" "$file" >/dev/null 2>&1; then
        ok=0
    fi
    record "$ok" "$id" "$ref" "$title"
}

# scheck <id> <ref> <title> <shell-expression>
scheck() {
    local id="$1" ref="$2" title="$3" expr="$4" ok=1
    if eval "$expr" >/dev/null 2>&1; then
        ok=0
    fi
    record "$ok" "$id" "$ref" "$title"
}

norm() {
    tr '[:upper:]' '[:lower:]' <<<"${1:-}" | sed -e 's/[^a-z0-9]//g' -e 's/^aws//' -e 's/^amazon//'
}

answers_ok() {
    local file="${LAB_ROOT}/answers/governance.env"
    [[ -f "$file" ]] || return 1
    local -A expect=(
        [COMPLIANCE_REPORTS_SERVICE]="artifact"
        [API_ACTIVITY_AUDIT_SERVICE]="cloudtrail"
        [RESOURCE_CONFIGURATION_HISTORY_SERVICE]="config|configservice"
        [CENTRAL_FINDINGS_SERVICE]="securityhub"
        [S3_SENSITIVE_DATA_DISCOVERY_SERVICE]="macie"
        [WORKLOAD_VULNERABILITY_SCAN_SERVICE]="inspector|inspector2"
        [KEY_STORAGE_SERVICE]="kms|keymanagementservice"
    )
    local key raw value
    for key in "${!expect[@]}"; do
        raw="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
        value="$(norm "${raw//[\"\']/}")"
        [[ -n "$value" ]] || return 1
        [[ "$value" =~ ^(${expect[$key]})$ ]] || return 1
    done
    return 0
}

cmd_verify() {
    require_tools
    [[ -d "$ACC" ]] || die "No lab found at ${LAB_ROOT}. Run: $0 break"

    local star_def='def star($v): ($v|tostring) == "*" or (($v|type) == "array" and (($v|index("*")) != null));'
    local anon_def='def anon($p): ($p|tostring) == "*" or (($p|type) == "object" and ((($p.AWS)|tostring) == "*" or ((($p.AWS)|type) == "array" and (($p.AWS)|index("*")) != null)));'
    local stmts='(.PolicyVersion.Document.Statement | if type == "array" then . else [.] end)'
    local bstmts='(.Policy | fromjson | .Statement | if type == "array" then . else [.] end)'

    PASSED=0; FAILED=0; FAILED_IDS=()

    echo
    rule
    echo "${W}  AWS Security Hub - compliance summary${N}   ${D}account ${ACCOUNT_ID} / ${REGION}${N}"
    echo "${D}  Standard: AWS Foundational Security Best Practices + CIS AWS Foundations${N}"
    rule
    printf '  %-12s %-14s %-52s %s\n' "CONTROL" "STANDARD REF" "TITLE" "STATE"
    rule

    # --- Identity ---------------------------------------------------------------
    jcheck "IAM.9"  "CIS 1.5"  "MFA is enabled for the root user" \
        "iam/get-account-summary.json" '.SummaryMap.AccountMFAEnabled == 1'
    HINTS["IAM.9"]="The root user is the only identity that cannot be constrained by an IAM policy or an SCP. Its only real control is MFA. Evidence lives in iam:GetAccountSummary -> AccountMFAEnabled. https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html"

    jcheck "IAM.4"  "CIS 1.4"  "No access keys exist for the root user" \
        "iam/get-account-summary.json" '.SummaryMap.AccountAccessKeysPresent == 0'
    HINTS["IAM.4"]="A root access key is an unrevocable-by-policy, unexpiring credential to the whole account. There is no legitimate long-lived use for one. AccountAccessKeysPresent must be 0."

    jcheck "IAM.15" "CIS 1.8"  "Password policy requires at least 14 characters" \
        "iam/get-account-password-policy.json" '.PasswordPolicy.MinimumPasswordLength >= 14'
    HINTS["IAM.15"]="iam:UpdateAccountPasswordPolicy. Length is the control that survives; note that CIS v1.4+ dropped the composition and 90-day-expiry rules, aligning with NIST SP 800-63B."

    jcheck "IAM.16" "CIS 1.9"  "Password policy prevents reuse of the last 24" \
        "iam/get-account-password-policy.json" '(.PasswordPolicy.PasswordReusePrevention // 0) >= 24'
    HINTS["IAM.16"]="The real API omits PasswordReusePrevention entirely when it was never set, so an audit script that reads it without a default silently passes. Use '// 0'."

    jcheck "IAM.1"  "FSBP IAM.1" "No customer policy grants full \"*\" on \"*\"" \
        "iam/get-policy-version.json" "${star_def} [${stmts}[] | select(.Effect == \"Allow\" and star(.Action) and star(.Resource))] | length == 0"
    HINTS["IAM.1"]="Least privilege. Replace the star-star statement with the specific actions on the specific ARNs, publish it as a new default policy version, then delete the old version. Use IAM Access Analyzer policy generation from CloudTrail history to find what is really used."

    # --- Data protection --------------------------------------------------------
    jcheck "S3.1"   "FSBP S3.1"  "Account-level Block Public Access is fully on" \
        "s3control/get-public-access-block.json" '[.PublicAccessBlockConfiguration | to_entries[] | select(.value != true)] | length == 0'
    HINTS["S3.1"]="Account-level BPA (s3control) overrides every bucket, present and future. All four flags: BlockPublicAcls, IgnorePublicAcls, BlockPublicPolicy, RestrictPublicBuckets. https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html"

    jcheck "S3.2"   "FSBP S3.2"  "Bucket policy grants nothing to an anonymous principal" \
        "s3api/get-bucket-policy.json" "${anon_def} [${bstmts}[] | select(.Effect == \"Allow\" and anon(.Principal))] | length == 0"
    HINTS["S3.2"]="Principal \"*\" (or {\"AWS\":\"*\"}) with Effect Allow is public. GetBucketPolicy hands you the document as an escaped string - pipe it through fromjson before you judge it."

    jcheck "S3.5"   "FSBP S3.5"  "Bucket policy denies requests not using TLS" \
        "s3api/get-bucket-policy.json" "[${bstmts}[] | select(.Effect == \"Deny\" and ((.Condition.Bool[\"aws:SecureTransport\"] // \"\") | tostring) == \"false\")] | length >= 1"
    HINTS["S3.5"]="Encryption in transit is not automatic just because the endpoint offers HTTPS: you must deny the plaintext path with a Deny statement conditioned on aws:SecureTransport = false, covering both the bucket ARN and the /* object ARN."

    # --- Logging and audit trail ------------------------------------------------
    jcheck "CT.1"   "FSBP CloudTrail.1" "A multi-Region trail covers global service events" \
        "cloudtrail/describe-trails.json" '[.trailList[] | select(.IsMultiRegionTrail == true and .IncludeGlobalServiceEvents == true)] | length >= 1'
    HINTS["CT.1"]="A single-Region trail is blind to activity in every other Region, and IAM/STS/CloudFront are global services whose events only appear when IncludeGlobalServiceEvents is on. This is the control an attacker relies on."

    jcheck "CT.LOG" "CIS 3.1"    "The trail is actually logging right now" \
        "cloudtrail/get-trail-status.json" '.IsLogging == true'
    HINTS["CT.LOG"]="A configured trail that has been stopped still shows up in describe-trails and looks healthy. Only GetTrailStatus tells the truth. Gaps in a trail are unrecoverable - you cannot backfill history."

    jcheck "CT.4"   "FSBP CloudTrail.4" "Log file integrity validation is enabled" \
        "cloudtrail/describe-trails.json" '[.trailList[] | select(.LogFileValidationEnabled == true)] | length >= 1'
    HINTS["CT.4"]="Validation makes CloudTrail write hourly digest files with SHA-256 hashes, signed with a private key held by AWS, so 'aws cloudtrail validate-logs' can prove no log was altered or deleted. Without it your evidence is only as trustworthy as the account it lives in. https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html"

    jcheck "CT.2"   "FSBP CloudTrail.2" "Trail logs are encrypted at rest with SSE-KMS" \
        "cloudtrail/describe-trails.json" '[.trailList[] | select((.KmsKeyId // "") | length > 0)] | length >= 1'
    HINTS["CT.2"]="Default trail encryption is SSE-S3. With a customer managed KMS key, reading the logs also requires kms:Decrypt, so the key policy becomes a second, independent authorization gate on your audit evidence."

    jcheck "CFG.1"  "FSBP Config.1"     "Config recorder is recording (with a delivery channel)" \
        "configservice/describe-configuration-recorder-status.json" '.ConfigurationRecordersStatus[0].recording == true'
    HINTS["CFG.1"]="CloudTrail answers 'who called what'; AWS Config answers 'what did this resource look like at 03:00, and when did it change'. The recorder cannot start without a delivery channel - read lastErrorCode. https://docs.aws.amazon.com/config/latest/developerguide/WhatIsConfig.html"

    jcheck "CFG.2"  "CIS 3.5"           "Config has a delivery channel for its snapshots" \
        "configservice/describe-delivery-channels.json" '(.DeliveryChannels | length) >= 1'
    HINTS["CFG.2"]="The delivery channel is the S3 bucket (and optional SNS topic) Config writes configuration snapshots and history to. No channel, no recorder."

    jcheck "GD.1"   "FSBP GuardDuty.1"  "GuardDuty is enabled in the Region" \
        "guardduty/list-detectors.json" '(.DetectorIds | length) >= 1'
    HINTS["GD.1"]="GuardDuty is the detective control that consumes CloudTrail management and S3 data events, VPC Flow Logs, DNS logs and EKS audit logs, and raises findings such as credential exfiltration or crypto-mining. It needs no agent; enabling it is the whole deployment. https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html"

    # --- Encryption and network exposure ---------------------------------------
    jcheck "KMS.4"  "FSBP KMS.4"  "Customer managed KMS key rotation is enabled" \
        "kms/get-key-rotation-status.json" '.KeyRotationEnabled == true'
    HINTS["KMS.4"]="Automatic rotation creates new key material while keeping the same key ID and ARN, and retains the old material so existing ciphertext still decrypts - nothing to re-encrypt, no application change. https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html"

    jcheck "EC2.13" "FSBP EC2.13/14" "No security group allows 0.0.0.0/0 to 22 or 3389" \
        "ec2/describe-security-groups.json" '[.SecurityGroups[].IpPermissions[] | select((((.FromPort // 0) <= 22) and ((.ToPort // 65535) >= 22)) or (((.FromPort // 0) <= 3389) and ((.ToPort // 65535) >= 3389))) | select((((.IpRanges // []) | any(.CidrIp == "0.0.0.0/0")) or ((.Ipv6Ranges // []) | any(.CidrIpv6 == "::/0"))))] | length == 0'
    HINTS["EC2.13"]="Remember the IPv6 twin: ::/0 is just as open as 0.0.0.0/0 and is missed by half of the audit scripts in the wild. Also note IpProtocol \"-1\" carries no FromPort/ToPort - 'all traffic' includes 22. The strongest answer is no inbound rule at all, using SSM Session Manager."

    jcheck "EC2.7"  "FSBP EC2.7"  "EBS encryption by default is enabled in the Region" \
        "ec2/get-ebs-encryption-by-default.json" '.EbsEncryptionByDefault == true'
    HINTS["EC2.7"]="This is a per-Region, per-account setting: turning it on in us-east-1 does nothing for eu-west-1. It applies to new volumes only, so pre-existing unencrypted volumes must be snapshot-copy-encrypted."

    # --- Customer-side credential hygiene ---------------------------------------
    scheck "LAB.1"  "IAM best pr."  "No long-term keys on disk; creds file is 0600" \
        "[[ \"\$(stat -c '%a' '${LAB_ROOT}/.aws/credentials' 2>/dev/null)\" == '600' ]] \
         && ! grep -qE '^[[:space:]]*aws_secret_access_key[[:space:]]*=[[:space:]]*[^[:space:]]' '${LAB_ROOT}/.aws/credentials' \
         && ! grep -rqE 'AKIA|aws_secret_access_key|AWS_SECRET_ACCESS_KEY' '${LAB_ROOT}/app'"
    HINTS["LAB.1"]="This is the customer side of the shared responsibility model: AWS secures the credential service, you secure the credential. Static keys in a .env file are the single most common root cause of AWS account compromise. Replace them with IAM Identity Center (SSO) for humans and an IAM role for workloads - both produce short-lived credentials nobody can leak permanently."

    scheck "GOV.1"  "Task 2.2"     "Governance concepts answer sheet is correct" \
        "answers_ok"
    HINTS["GOV.1"]="Fill in ${LAB_ROOT}/answers/governance.env. Each line maps a governance question to exactly one service. If two of your answers are the same service, at least one is wrong."

    rule
    local pct=$(( PASSED * 100 / TOTAL_CONTROLS ))
    printf '  %-28s %s%d%s / %d controls   (%d%%)\n' "COMPLIANCE SCORE" \
        "$([[ $FAILED -eq 0 ]] && echo "$G" || echo "$R")" "$PASSED" "$N" "$TOTAL_CONTROLS" "$pct"
    rule

    if (( FAILED == 0 )); then
        echo
        echo "  ${G}${W}AUDIT PASSED${N} - the account is governed, logged, encrypted and least-privileged."
        echo "  ${D}Evidence pack: CloudTrail (who did what) + AWS Config (what it looked like)"
        echo "  + Security Hub (scored against a published benchmark) + AWS Artifact (the"
        echo "  AWS side of the shared responsibility model, downloadable on demand).${N}"
        echo
        return 0
    fi

    echo
    echo "  ${R}AUDIT FAILED${N} - ${FAILED} control(s) open: ${FAILED_IDS[*]}"
    echo "  Run ${C}$0 hint${N} for guidance on the failing controls."
    echo
    return 1
}

cmd_hint() {
    if cmd_verify >/dev/null 2>&1; then
        echo "${G}Nothing failing. Run '$0 verify' to see the report.${N}"
        return 0
    fi
    echo
    rule
    echo "${W}  GUIDANCE FOR OPEN CONTROLS${N}  ${D}(what and why - not the command)${N}"
    rule
    local id
    for id in "${FAILED_IDS[@]}"; do
        echo
        echo "  ${W}${id}${N}"
        printf '    %s\n' "${HINTS[$id]:-No hint recorded.}" | fold -s -w 92 | sed '2,$s/^/    /'
    done
    echo
    rule
    echo "  ${D}Remediate the JSON under ${ACC} with: jqi <file> '<filter>'${N}"
    echo "  ${D}For every fix, name the real production command before you move on.${N}"
    echo
}

cmd_shell() {
    [[ -d "$LAB_ROOT" ]] || die "No lab found at ${LAB_ROOT}. Run: $0 break"
    info "Entering the lab shell. 'exit' returns to your normal environment."
    info "PATH now prefers ${BIN} (offline 'aws' shim + 'jqi')."
    PATH="${BIN}:${PATH}" \
    AWS_CONFIG_FILE="${LAB_ROOT}/.aws/config" \
    AWS_SHARED_CREDENTIALS_FILE="${LAB_ROOT}/.aws/credentials" \
    AWS_DEFAULT_REGION="${REGION}" \
    LAB_ROOT="${LAB_ROOT}" ACC="${ACC}" \
    PS1="(${LAB_ID}) \w \$ " \
        bash --noprofile --norc -i
}

cmd_reset() {
    sanity_lab_root
    [[ -d "$LAB_ROOT" ]] || { info "Nothing to remove at ${LAB_ROOT}."; return 0; }
    if [[ "${LAB_ASSUME_YES:-0}" != "1" ]]; then
        read -r -p "Delete ${LAB_ROOT} and all progress? [y/N] " a
        [[ "$a" == "y" || "$a" == "Y" ]] || die "Aborted."
    fi
    rm -rf "${LAB_ROOT}"
    info "Removed ${LAB_ROOT}."
}

usage() {
    cat <<EOF
CLF-C02 Task 2.2 break & fix lab.

  $0 break     arm the lab (default)
  $0 verify    run the graded audit report
  $0 hint      guidance for the controls still failing
  $0 shell     subshell with the offline 'aws' shim on PATH
  $0 reset     delete ${LAB_ROOT}

Environment: LAB_ROOT=<path>  LAB_ASSUME_YES=1
EOF
}

main() {
    case "${1:-break}" in
        break)          cmd_break ;;
        verify|status)  cmd_verify ;;
        hint)           cmd_hint ;;
        shell)          cmd_shell ;;
        reset|clean)    cmd_reset ;;
        -h|--help|help) usage ;;
        *)              usage; exit 2 ;;
    esac
}

main "$@"

# ==============================================================================
# ==============================================================================
#  S O L U T I O N  -  do not read until you have tried
# ==============================================================================
# ==============================================================================
#
# Enter the lab shell first, so that `aws`, `jqi` and $ACC are on hand:
#
#     ./22-break-fix-security-governance.sh shell
#
# Everything below assumes:
#     ACC=$LAB_ROOT/account
#
# ------------------------------------------------------------------------------
# STEP 0 - Triage before you touch anything. Read the report, then confirm each
#          failure against the API rather than trusting the grader.
# ------------------------------------------------------------------------------
#     ./22-break-fix-security-governance.sh verify
#     aws sts get-caller-identity
#     aws cloudtrail get-trail-status --name clf-lab-trail | jq '.IsLogging, .StopLoggingTime'
#
# The first fact worth internalising: the trail stopped on 2026-08-28. Every
# control you are about to fix has been unobserved since then, and no remediation
# recovers that history. In a real engagement, restoring logging is step one
# precisely because it is the only step whose delay causes permanent data loss.
#
# ------------------------------------------------------------------------------
# STEP 1 - CT.LOG / CT.1 / CT.4 / CT.2 : restore the audit trail, correctly.
# ------------------------------------------------------------------------------
# Four independent properties, commonly confused with each other:
#   IsMultiRegionTrail          -> the trail follows activity in every Region
#   IncludeGlobalServiceEvents  -> IAM, STS, CloudFront, Route 53 land in it
#   LogFileValidationEnabled    -> hourly digest files, SHA-256, signed by AWS
#   KmsKeyId                    -> SSE-KMS at rest, so reading logs also needs
#                                  kms:Decrypt (a second authorization gate)
#
#     jqi "$ACC/cloudtrail/describe-trails.json" \
#       '.trailList[0] |= (.IsMultiRegionTrail = true
#                          | .IncludeGlobalServiceEvents = true
#                          | .LogFileValidationEnabled = true
#                          | .KmsKeyId = "arn:aws:kms:us-east-1:000000000000:key/1b2c3d4e-5f60-4a71-8b92-0c3d4e5f6a7b")'
#
#     jqi "$ACC/cloudtrail/get-trail-status.json" \
#       --arg now "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
#       '.IsLogging = true | .StartLoggingTime = $now | .LatestDeliveryTime = $now
#        | del(.StopLoggingTime) | del(.TimeLoggingStopped)'
#
# In a real account:
#     aws cloudtrail update-trail --name clf-lab-trail \
#         --is-multi-region-trail --include-global-service-events \
#         --enable-log-file-validation --kms-key-id alias/clf-lab-cmk
#     aws cloudtrail start-logging --name clf-lab-trail
#     aws cloudtrail validate-logs --trail-arn arn:aws:cloudtrail:us-east-1:000000000000:trail/clf-lab-trail \
#         --start-time 2026-09-01T00:00:00Z          # proves nothing was tampered with
#
# Hardening beyond the control: put the log bucket in a separate account under
# AWS Organizations, enable S3 Object Lock in compliance mode, and forbid
# cloudtrail:StopLogging / DeleteTrail with a service control policy (SCP). An
# admin who can stop the trail can erase the evidence of stopping it.
#
# ------------------------------------------------------------------------------
# STEP 2 - CFG.2 / CFG.1 : AWS Config needs a delivery channel before a recorder.
# ------------------------------------------------------------------------------
# lastErrorCode said NoAvailableDeliveryChannel. Fix the cause, then the symptom.
#
#     jqi "$ACC/configservice/describe-delivery-channels.json" \
#       '.DeliveryChannels = [ { name: "default",
#                                s3BucketName: "clf-lab-config-000000000000",
#                                s3KmsKeyArn: "arn:aws:kms:us-east-1:000000000000:key/1b2c3d4e-5f60-4a71-8b92-0c3d4e5f6a7b",
#                                configSnapshotDeliveryProperties: { deliveryFrequency: "TwentyFour_Hours" } } ]'
#
#     jqi "$ACC/configservice/describe-configuration-recorder-status.json" \
#       --arg now "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
#       '.ConfigurationRecordersStatus[0] |= (.recording = true
#                                             | .lastStatus = "SUCCESS"
#                                             | .lastStartTime = $now
#                                             | del(.lastErrorCode) | del(.lastErrorMessage) | del(.lastStopTime))'
#
# In a real account:
#     aws configservice put-delivery-channel --delivery-channel file://channel.json
#     aws configservice start-configuration-recorder --configuration-recorder-name default
#     aws configservice describe-configuration-recorder-status
#
# Exam framing worth memorising: CloudTrail = API activity ("who called
# DeleteBucket at 03:14 from which IP"). Config = resource configuration over
# time ("this security group was open to 0.0.0.0/0 between Aug 28 and Sep 3"),
# plus rules and conformance packs that mark a resource COMPLIANT or not.
#
# ------------------------------------------------------------------------------
# STEP 3 - GD.1 : turn on the detective control.
# ------------------------------------------------------------------------------
#     jqi "$ACC/guardduty/list-detectors.json" \
#       '.DetectorIds = ["1ab2cd34e5f6a7b8c9d0e1f2a3b4c5d6"]'
#
# In a real account:
#     aws guardduty create-detector --enable --finding-publishing-frequency FIFTEEN_MINUTES
#
# GuardDuty reads CloudTrail events, VPC Flow Logs, DNS logs, S3 data events and
# EKS audit logs out of band - no agent, no traffic mirroring, no effect on the
# workload. Note the dependency direction: the trail you fixed in step 1 is part
# of what GuardDuty consumes.
#
# ------------------------------------------------------------------------------
# STEP 4 - IAM.9 / IAM.4 : root user hygiene.
# ------------------------------------------------------------------------------
#     jqi "$ACC/iam/get-account-summary.json" \
#       '.SummaryMap.AccountMFAEnabled = 1 | .SummaryMap.AccountAccessKeysPresent = 0'
#
# In a real account there is no CLI path for these, and that is the lesson: the
# root user is out-of-band by design. Sign in as root -> Security credentials ->
# assign an MFA device (a hardware key is the CIS-preferred form), and delete any
# root access key from the same page. Then lock root away and never use it again:
# day-to-day work happens through IAM Identity Center with short-lived
# credentials, and the handful of tasks that truly require root are documented.
#
# ------------------------------------------------------------------------------
# STEP 5 - IAM.15 / IAM.16 : password policy.
# ------------------------------------------------------------------------------
#     jqi "$ACC/iam/get-account-password-policy.json" \
#       '.PasswordPolicy.MinimumPasswordLength = 14
#        | .PasswordPolicy.PasswordReusePrevention = 24
#        | .PasswordPolicy.AllowUsersToChangePassword = true'
#
# In a real account:
#     aws iam update-account-password-policy \
#         --minimum-password-length 14 \
#         --password-reuse-prevention 24 \
#         --allow-users-to-change-password
#
# Deliberately NOT added: forced 90-day expiry and composition rules. CIS v1.4+
# removed them, following NIST SP 800-63B, because rotation pressure produces
# Summer2026! and its successors. Length plus MFA is the pair that works.
#
# ------------------------------------------------------------------------------
# STEP 6 - IAM.1 : replace the star-star policy with least privilege.
# ------------------------------------------------------------------------------
#     jqi "$ACC/iam/get-policy-version.json" \
#       '.PolicyVersion.Document.Statement =
#          [ { Sid: "DataTeamReadReports",
#              Effect: "Allow",
#              Action: [ "s3:GetObject", "s3:ListBucket" ],
#              Resource: [ "arn:aws:s3:::clf-lab-reports-000000000000",
#                          "arn:aws:s3:::clf-lab-reports-000000000000/*" ] } ]
#        | .PolicyVersion.VersionId = "v4"'
#
# In a real account (IAM policies are versioned and immutable - you publish a new
# default version, you never edit one in place):
#     aws iam create-policy-version --policy-arn arn:aws:iam::000000000000:policy/DataTeamAccess \
#         --policy-document file://least-privilege.json --set-as-default
#     aws iam delete-policy-version --policy-arn arn:aws:iam::000000000000:policy/DataTeamAccess \
#         --version-id v3
#
# How to know which actions to keep, instead of guessing: IAM Access Analyzer can
# generate a policy from the principal's CloudTrail history, and the Last Accessed
# data (aws iam get-service-last-accessed-details) shows which services the
# identity has actually touched. Guardrail above the policy: an SCP at the OU
# level, which sets the ceiling no IAM policy in the account can exceed.
#
# ------------------------------------------------------------------------------
# STEP 7 - S3.1 : account-level Block Public Access.
# ------------------------------------------------------------------------------
#     jqi "$ACC/s3control/get-public-access-block.json" \
#       '.PublicAccessBlockConfiguration |= with_entries(.value = true)'
#
# In a real account:
#     aws s3control put-public-access-block --account-id 000000000000 \
#         --public-access-block-configuration \
#         BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
#
# Account level beats bucket level and applies to buckets created tomorrow. The
# four flags are two pairs: Block* rejects new public ACLs/policies at write time,
# Ignore*/Restrict* neutralises the ones already there at evaluation time.
#
# ------------------------------------------------------------------------------
# STEP 8 - S3.2 / S3.5 : rewrite the bucket policy.
# ------------------------------------------------------------------------------
# Remove the anonymous Allow and add the TLS-only Deny, covering both the bucket
# ARN (for ListBucket-style calls) and the /* object ARN.
#
#     cat > /tmp/bucket-policy.json <<'POLICY'
#     {
#       "Version": "2012-10-17",
#       "Statement": [
#         {
#           "Sid": "DataTeamRead",
#           "Effect": "Allow",
#           "Principal": { "AWS": "arn:aws:iam::000000000000:role/DataTeamRole" },
#           "Action": [ "s3:GetObject", "s3:ListBucket" ],
#           "Resource": [ "arn:aws:s3:::clf-lab-reports-000000000000",
#                         "arn:aws:s3:::clf-lab-reports-000000000000/*" ]
#         },
#         {
#           "Sid": "DenyInsecureTransport",
#           "Effect": "Deny",
#           "Principal": "*",
#           "Action": "s3:*",
#           "Resource": [ "arn:aws:s3:::clf-lab-reports-000000000000",
#                         "arn:aws:s3:::clf-lab-reports-000000000000/*" ],
#           "Condition": { "Bool": { "aws:SecureTransport": "false" } }
#         }
#       ]
#     }
#     POLICY
#
#     jq -n --rawfile d /tmp/bucket-policy.json '{ Policy: ($d | fromjson | tojson) }' \
#       > "$ACC/s3api/get-bucket-policy.json"
#
# In a real account:
#     aws s3api put-bucket-policy --bucket clf-lab-reports-000000000000 \
#         --policy file:///tmp/bucket-policy.json
#     aws s3api get-bucket-policy --bucket clf-lab-reports-000000000000 \
#         --query Policy --output text | jq .
#
# Two mechanics behind this step. First, an explicit Deny always wins over any
# Allow, anywhere in the evaluation - that is why the TLS rule is expressed as a
# Deny rather than as a condition on the Allow. Second, encryption in transit is
# a policy decision: the HTTPS endpoint existing does not stop a client from
# using HTTP, only this Deny does.
#
# ------------------------------------------------------------------------------
# STEP 9 - KMS.4 and EC2.7 : encryption at rest.
# ------------------------------------------------------------------------------
#     jqi "$ACC/kms/get-key-rotation-status.json" \
#       '.KeyRotationEnabled = true | .RotationPeriodInDays = 365'
#     jqi "$ACC/ec2/get-ebs-encryption-by-default.json" '.EbsEncryptionByDefault = true'
#
# In a real account:
#     aws kms enable-key-rotation --key-id alias/clf-lab-cmk
#     aws kms get-key-rotation-status --key-id alias/clf-lab-cmk
#     aws ec2 enable-ebs-encryption-by-default --region us-east-1
#
# Rotation swaps the backing key material while the key ID, ARN and alias stay
# the same, and AWS keeps the previous material so old ciphertext still decrypts:
# no re-encryption, no application change. EBS default encryption is per Region
# and per account and applies to new volumes only - existing unencrypted volumes
# need snapshot -> copy with --encrypted -> replace.
#
# ------------------------------------------------------------------------------
# STEP 10 - EC2.13 : close the bastion, including the IPv6 twin.
# ------------------------------------------------------------------------------
#     jqi "$ACC/ec2/describe-security-groups.json" \
#       '.SecurityGroups[0].IpPermissions =
#          [ { IpProtocol: "tcp", FromPort: 22, ToPort: 22,
#              IpRanges: [ { CidrIp: "10.20.0.0/16", Description: "corporate VPN only" } ],
#              Ipv6Ranges: [], PrefixListIds: [], UserIdGroupPairs: [] } ]'
#
# In a real account:
#     aws ec2 revoke-security-group-ingress --group-id sg-0a1b2c3d4e5f67890 \
#         --ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}],Ipv6Ranges=[{CidrIpv6=::/0}]'
#     aws ec2 revoke-security-group-ingress --group-id sg-0a1b2c3d4e5f67890 \
#         --protocol tcp --port 3389 --cidr 0.0.0.0/0
#     aws ec2 authorize-security-group-ingress --group-id sg-0a1b2c3d4e5f67890 \
#         --protocol tcp --port 22 --cidr 10.20.0.0/16
#
# The 3389 rule is deleted outright, not narrowed: there is no Windows host here,
# and an unused rule is pure attack surface. The better answer to "how do we
# reach the instance" in 2026 is AWS Systems Manager Session Manager - the agent
# opens an outbound connection, so the security group needs no inbound rule at
# all, and every session is logged to CloudTrail and S3.
#
# ------------------------------------------------------------------------------
# STEP 11 - LAB.1 : the customer side of the shared responsibility line.
# ------------------------------------------------------------------------------
# AWS secures IAM as a service; you are responsible for the credentials it issues.
# Delete the long-term keys and move to short-lived ones.
#
#     cat > "$LAB_ROOT/.aws/credentials" <<'CRED'
#     # Long-term access keys removed 2026-09-03.
#     # Humans authenticate through IAM Identity Center (see [profile clf-lab]);
#     # workloads use an IAM role, never a key on disk.
#     CRED
#     chmod 600 "$LAB_ROOT/.aws/credentials"
#
#     cat >> "$LAB_ROOT/.aws/config" <<'CFG'
#
#     [profile clf-lab]
#     sso_session = corp
#     sso_account_id = 000000000000
#     sso_role_name = PowerUserAccess
#     region = us-east-1
#
#     [sso-session corp]
#     sso_start_url = https://d-1234567890.awsapps.com/start
#     sso_region = us-east-1
#     sso_registration_scopes = sso:account:access
#     CFG
#
#     sed -i '/^AWS_ACCESS_KEY_ID=/d; /^AWS_SECRET_ACCESS_KEY=/d' "$LAB_ROOT/app/.env"
#     echo '# Credentials come from the instance profile / task role at runtime.' >> "$LAB_ROOT/app/.env"
#
# In a real account: aws sso login --profile clf-lab, and for the application an
# EC2 instance profile, an ECS task role or an IAM Roles Anywhere trust anchor.
# All three yield credentials that expire on their own. And if a key ever did
# leak, the response is deactivate -> rotate -> review CloudTrail for the key's
# activity -> check GuardDuty for UnauthorizedAccess findings, in that order.
#
# ------------------------------------------------------------------------------
# STEP 12 - GOV.1 : the concepts, which no command can fix for you.
# ------------------------------------------------------------------------------
#     COMPLIANCE_REPORTS_SERVICE=AWS Artifact
#     API_ACTIVITY_AUDIT_SERVICE=AWS CloudTrail
#     RESOURCE_CONFIGURATION_HISTORY_SERVICE=AWS Config
#     CENTRAL_FINDINGS_SERVICE=AWS Security Hub
#     S3_SENSITIVE_DATA_DISCOVERY_SERVICE=Amazon Macie
#     WORKLOAD_VULNERABILITY_SCAN_SERVICE=Amazon Inspector
#     KEY_STORAGE_SERVICE=AWS KMS
#
# The distinctions the exam actually tests:
#   Artifact vs everything else - Artifact is where you download AWS's own
#     audit reports (SOC 1/2/3, ISO 27001, PCI DSS AOC) and accept agreements
#     such as the BAA. It is evidence about AWS, not about your account. That is
#     the shared responsibility model made downloadable.
#   CloudTrail vs Config - activity versus configuration state. "Who deleted it"
#     versus "what did it look like before".
#   Security Hub vs GuardDuty - Security Hub scores you against a published
#     standard and aggregates findings; GuardDuty produces threat findings from
#     log analysis. Security Hub is posture, GuardDuty is detection.
#   Macie vs Inspector - Macie classifies data (is there PII in this bucket);
#     Inspector scans workloads (is this AMI running a vulnerable openssl).
#   KMS vs CloudHSM - KMS is the managed, multi-tenant, FIPS 140-3 Level 3
#     validated service used by every other AWS service; CloudHSM is a
#     single-tenant HSM you operate yourself when a regulator demands it.
#   Data residency - the control is the Region. AWS never moves your data out of
#     the Region you chose; enforce it with SCPs on aws:RequestedRegion.
#
# ------------------------------------------------------------------------------
# STEP 13 - Prove it, then explain it.
# ------------------------------------------------------------------------------
#     ./22-break-fix-security-governance.sh verify     # expect 19/19 - AUDIT PASSED
#
# You are done when you can answer, without looking: for each of the nineteen
# controls, which service enforces it, what an attacker gains while it is off,
# and what evidence an auditor asks for to prove it is on. In a real account the
# same end state is built once and kept by machinery, not by hand: Control Tower
# and Organizations SCPs for the guardrails, a Config conformance pack for the
# continuous evaluation, Security Hub for the score, and a delegated security
# account that owns the logs so the account being audited cannot rewrite them.
#
# Clean up the VM with:
#     ./22-break-fix-security-governance.sh reset
# ==============================================================================