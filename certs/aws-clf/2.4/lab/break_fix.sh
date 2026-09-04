#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) - Exam version 1.0
#  Domain 2: Security and Compliance
#  Task statement 2.4: Identify components and resources for security
#  Domain weight: 7.5
#
#  BREAK & FIX LAB - "The Friday change window"
#
#  Official reference for the objectives covered here:
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
#  WHAT THIS SCRIPT DOES
#    It materialises a *simulated* AWS account (account id 111122223333) as a
#    tree of real, syntactically valid AWS JSON documents - IAM policies, a
#    permissions boundary, a Service Control Policy, security groups, an S3
#    bucket policy + Block Public Access + default encryption, a KMS customer
#    managed key with its key policy, a Secrets Manager secret, a CloudTrail
#    trail and the detective services (GuardDuty, Security Hub, AWS Config,
#    Amazon Inspector) - then injects eight controlled misconfigurations into
#    them and hands you an offline evaluator (`awslab`) that implements the
#    real IAM policy evaluation order and the real security-group semantics.
#
#  SAFETY - read this before running
#    * Everything happens inside ONE directory ($LAB_ROOT, default
#      ~/aws-clf-lab-2.4). Nothing outside it is created, modified or deleted.
#    * There is NO network access, NO `aws` CLI call, NO AWS credential read,
#      NO package installation, NO systemd/firewall/sshd change. The lab cannot
#      touch a real AWS account even if one is configured on this machine.
#    * Requirements: bash 4+, python3 (standard library only).
#    * Still: run it on a disposable lab VM. `--reset` rebuilds from scratch.
#
#  Usage:
#    ./2.4-break-fix-security-components.sh            # build lab + break it
#    ./2.4-break-fix-security-components.sh --reset    # wipe and start over
#    ./2.4-break-fix-security-components.sh --help
# ==============================================================================

set -euo pipefail

LAB="${LAB_ROOT:-$HOME/aws-clf-lab-2.4}"
export LAB

C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[1;36m'
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[lab]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf '%s[fatal]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
rule() { printf '%s\n' "--------------------------------------------------------------------------"; }

usage() {
  cat <<'USAGE'
Usage: 2.4-break-fix-security-components.sh [--reset] [--help]

  (no flag)  Build the simulated account under $LAB_ROOT and inject the faults.
  --reset    Delete $LAB_ROOT and rebuild it in the broken state.
  --help     This text.

Environment:
  LAB_ROOT                Lab directory. Default: $HOME/aws-clf-lab-2.4
  AWSLAB_NONINTERACTIVE=1 Skip the confirmation prompt (for CI / kiosk images).
  NO_COLOR=1              Disable colour output.
USAGE
}

# ------------------------------------------------------------------ preflight
preflight() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required and was not found in PATH."
  case "$LAB" in
    ""|"/"|"/root"|"$HOME"|"/etc"|"/usr"|"/var"|"/home")
      die "Refusing to use '$LAB' as the lab directory. Set LAB_ROOT to a dedicated path." ;;
  esac
  [[ "$LAB" = /* ]] || die "LAB_ROOT must be an absolute path (got '$LAB')."

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    warn "Running as root. Not required - the lab only writes inside $LAB."
  fi
  if [[ -d "$HOME/.aws" ]]; then
    warn "Real AWS config found in ~/.aws - it is NOT read and NOT modified by this lab."
  fi

  if [[ "${AWSLAB_NONINTERACTIVE:-0}" != "1" && -t 0 ]]; then
    rule
    say "${C_BOLD}This lab will create and then deliberately misconfigure files under:${C_RESET}"
    say "  $LAB"
    say "It performs no network, AWS or system changes. Use a disposable VM anyway."
    rule
    read -r -p "Type LAB to continue: " answer
    [[ "$answer" == "LAB" ]] || die "Aborted by the user."
  fi
}

# ------------------------------------------------------------- file emitters
write() { # write <relative-path>   (content on stdin)
  local rel="$1" dst
  dst="$LAB/$rel"
  mkdir -p "$(dirname "$dst")"
  cat > "$dst"
}

build_identity() {
  write iam/root.json <<'JSON'
{
  "Account": "111122223333",
  "Comment": "Root user: used only for the few tasks that require it (closing the account, changing the support plan, some billing preferences). It must not have programmatic access keys.",
  "AccessKeys": [],
  "MFADevices": [
    { "SerialNumber": "arn:aws:iam::111122223333:mfa/root-hardware-token", "Type": "hardware" }
  ]
}
JSON

  write iam/users/dev-ana.json <<'JSON'
{
  "UserName": "dev-ana",
  "Arn": "arn:aws:iam::111122223333:user/dev-ana",
  "ConsoleAccess": true,
  "Groups": ["Developers"],
  "AttachedPolicies": [],
  "PermissionsBoundary": null,
  "MFADevices": [
    { "SerialNumber": "arn:aws:iam::111122223333:mfa/dev-ana", "Type": "virtual" }
  ]
}
JSON

  write iam/groups/Developers.json <<'JSON'
{
  "GroupName": "Developers",
  "AttachedPolicies": ["DeveloperReadOnly"]
}
JSON

  write iam/roles/app-backend-role.json <<'JSON'
{
  "RoleName": "app-backend-role",
  "Arn": "arn:aws:iam::111122223333:role/app-backend-role",
  "Comment": "Attached to the app tier through an EC2 instance profile. The workload uses temporary credentials from the Instance Metadata Service; there are no long-lived keys on the instance.",
  "AssumeRolePolicyDocument": {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "Ec2InstanceProfileTrust",
        "Effect": "Allow",
        "Principal": { "Service": "ec2.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }
    ]
  },
  "AttachedPolicies": ["AppBackendAccess"],
  "PermissionsBoundary": "AppBoundary"
}
JSON

  write iam/policies/AppBackendAccess.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadReleaseArtifacts",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::teach-plat-artifacts/releases/*"]
    },
    {
      "Sid": "ListReleasePrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::teach-plat-artifacts"]
    },
    {
      "Sid": "ReadDbCredential",
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": ["arn:aws:secretsmanager:us-east-1:111122223333:secret:prod/app/db-AbCdEf"]
    },
    {
      "Sid": "DecryptWithAppCmk",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:DescribeKey"],
      "Resource": ["arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"]
    },
    {
      "Sid": "WriteAppLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": ["arn:aws:logs:us-east-1:111122223333:log-group:/teach-plat/app:*"]
    }
  ]
}
JSON

  write iam/policies/AppBoundary.json <<'JSON'
{
  "Version": "2012-10-17",
  "Comment": "Permissions boundary. It grants nothing by itself: it is the MAXIMUM envelope. Effective permissions = intersection(identity policy, boundary).",
  "Statement": [
    {
      "Sid": "BoundaryEnvelope",
      "Effect": "Allow",
      "Action": [
        "s3:Get*",
        "s3:List*",
        "secretsmanager:GetSecretValue",
        "kms:Decrypt",
        "kms:DescribeKey",
        "logs:*"
      ],
      "Resource": ["*"]
    },
    {
      "Sid": "DenyIdentityEscalation",
      "Effect": "Deny",
      "Action": ["iam:*", "organizations:*", "account:*"],
      "Resource": ["*"]
    }
  ]
}
JSON

  write iam/policies/DeveloperReadOnly.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyPlatform",
      "Effect": "Allow",
      "Action": ["s3:Get*", "s3:List*", "ec2:Describe*", "cloudtrail:LookupEvents"],
      "Resource": ["*"]
    },
    {
      "Sid": "RequireMfaForSensitiveReads",
      "Effect": "Deny",
      "Action": ["secretsmanager:GetSecretValue", "kms:Decrypt"],
      "Resource": ["*"],
      "Condition": { "Bool": { "aws:MultiFactorAuthPresent": "false" } }
    }
  ]
}
JSON

  write org/scp-workloads.json <<'JSON'
{
  "Version": "2012-10-17",
  "Comment": "AWS Organizations Service Control Policy attached to the Workloads OU. An SCP is a permission FILTER: it never grants access, and it does not apply to the management account.",
  "Statement": [
    {
      "Sid": "FullAwsAccessBaseline",
      "Effect": "Allow",
      "Action": ["*"],
      "Resource": ["*"]
    },
    {
      "Sid": "DenyOutsideApprovedRegions",
      "Effect": "Deny",
      "Action": ["*"],
      "Resource": ["*"],
      "Condition": { "StringNotEquals": { "aws:RequestedRegion": ["us-east-1", "us-west-2"] } }
    },
    {
      "Sid": "DenyDisablingGuardrails",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "guardduty:DeleteDetector",
        "config:DeleteConfigurationRecorder"
      ],
      "Resource": ["*"]
    }
  ]
}
JSON
}

build_network() {
  write ec2/security-groups/sg-0web01.json <<'JSON'
{
  "GroupId": "sg-0web01",
  "GroupName": "web-tier-sg",
  "Description": "Public web tier behind the ALB. Administrative access is done with AWS Systems Manager Session Manager, so there is no inbound SSH.",
  "VpcId": "vpc-0lab",
  "IpPermissions": [
    {
      "IpProtocol": "tcp",
      "FromPort": 443,
      "ToPort": 443,
      "IpRanges": [{ "CidrIp": "0.0.0.0/0", "Description": "public HTTPS" }],
      "UserIdGroupPairs": []
    }
  ],
  "IpPermissionsEgress": [
    {
      "IpProtocol": "-1",
      "IpRanges": [{ "CidrIp": "0.0.0.0/0", "Description": "all egress" }],
      "UserIdGroupPairs": []
    }
  ]
}
JSON

  write ec2/security-groups/sg-0app01.json <<'JSON'
{
  "GroupId": "sg-0app01",
  "GroupName": "app-tier-sg",
  "Description": "Private app tier. Only the web tier security group may reach it, on 8080.",
  "VpcId": "vpc-0lab",
  "IpPermissions": [
    {
      "IpProtocol": "tcp",
      "FromPort": 8080,
      "ToPort": 8080,
      "IpRanges": [],
      "UserIdGroupPairs": [{ "GroupId": "sg-0web01", "Description": "web tier only" }]
    }
  ],
  "IpPermissionsEgress": [
    {
      "IpProtocol": "-1",
      "IpRanges": [{ "CidrIp": "0.0.0.0/0", "Description": "all egress" }],
      "UserIdGroupPairs": []
    }
  ]
}
JSON

  write ec2/network-acl-private.json <<'JSON'
{
  "NetworkAclId": "acl-0lab-private",
  "Comment": "Network ACLs are STATELESS and evaluated in rule-number order; security groups are STATEFUL and allow-only. Both are in scope for CLF-C02 task 2.4.",
  "Entries": [
    { "RuleNumber": 100, "Protocol": "-1", "RuleAction": "allow", "Egress": false, "CidrBlock": "10.0.0.0/16" },
    { "RuleNumber": 32767, "Protocol": "-1", "RuleAction": "deny", "Egress": false, "CidrBlock": "0.0.0.0/0" },
    { "RuleNumber": 100, "Protocol": "-1", "RuleAction": "allow", "Egress": true, "CidrBlock": "0.0.0.0/0" }
  ]
}
JSON
}

build_data_protection() {
  write s3/teach-plat-artifacts/public-access-block.json <<'JSON'
{
  "BlockPublicAcls": true,
  "IgnorePublicAcls": true,
  "BlockPublicPolicy": true,
  "RestrictPublicBuckets": true
}
JSON

  write s3/teach-plat-artifacts/bucket-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAppRoleRead",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::111122223333:role/app-backend-role" },
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::teach-plat-artifacts/releases/*"]
    },
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": ["s3:*"],
      "Resource": [
        "arn:aws:s3:::teach-plat-artifacts",
        "arn:aws:s3:::teach-plat-artifacts/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
JSON

  write s3/teach-plat-artifacts/encryption.json <<'JSON'
{
  "Rules": [
    {
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
      },
      "BucketKeyEnabled": true
    }
  ]
}
JSON

  write kms/key-1234abcd.json <<'JSON'
{
  "KeyId": "1234abcd-12ab-34cd-56ef-1234567890ab",
  "Arn": "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
  "Aliases": ["alias/teach-plat/app"],
  "Description": "Customer managed key (CMK) for app data and the DB secret.",
  "KeyManager": "CUSTOMER",
  "KeyState": "Enabled",
  "KeyRotationEnabled": true,
  "LabNote": "This simulator evaluates key-policy grants literally. It does not model the account-root delegation statement, so the app role needs its own explicit grant here.",
  "KeyPolicy": {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "EnableIamUserPermissions",
        "Effect": "Allow",
        "Principal": { "AWS": "arn:aws:iam::111122223333:root" },
        "Action": "kms:*",
        "Resource": "*"
      },
      {
        "Sid": "AllowAppRoleDecrypt",
        "Effect": "Allow",
        "Principal": { "AWS": "arn:aws:iam::111122223333:role/app-backend-role" },
        "Action": ["kms:Decrypt", "kms:DescribeKey"],
        "Resource": "*"
      }
    ]
  }
}
JSON

  write secretsmanager/prod-app-db.json <<'JSON'
{
  "Name": "prod/app/db",
  "ARN": "arn:aws:secretsmanager:us-east-1:111122223333:secret:prod/app/db-AbCdEf",
  "KmsKeyId": "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
  "RotationEnabled": true,
  "RotationRules": { "AutomaticallyAfterDays": 30 },
  "SecretString": "<ciphertext, decryptable only with the CMK above>"
}
JSON

  write app/app.env <<'JSON'
# Application configuration for the app tier. Secrets never live in this file:
# the workload resolves DB_SECRET_ARN at boot with its instance-profile role.
APP_ENV=production
APP_PORT=8080
DB_HOST=appdb.cluster-abc123.us-east-1.rds.amazonaws.com
DB_USER=app_rw
DB_SECRET_ARN=arn:aws:secretsmanager:us-east-1:111122223333:secret:prod/app/db-AbCdEf
AWS_REGION=us-east-1
JSON
}

build_detective() {
  write cloudtrail/org-trail.json <<'JSON'
{
  "Name": "org-trail",
  "IsOrganizationTrail": true,
  "IsMultiRegionTrail": true,
  "IsLogging": true,
  "LogFileValidationEnabled": true,
  "S3BucketName": "teach-plat-cloudtrail-logs",
  "KmsKeyId": "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab",
  "EventSelectors": [{ "ReadWriteType": "All", "IncludeManagementEvents": true }]
}
JSON

  write detective/guardduty.json <<'JSON'
{
  "DetectorId": "d-lab0001",
  "Status": "ENABLED",
  "FindingPublishingFrequency": "FIFTEEN_MINUTES",
  "DataSources": { "S3Logs": { "Status": "ENABLED" }, "Kubernetes": { "AuditLogs": { "Status": "ENABLED" } } }
}
JSON

  write detective/securityhub.json <<'JSON'
{
  "Enabled": true,
  "Standards": [
    "AWS Foundational Security Best Practices v1.0.0",
    "CIS AWS Foundations Benchmark v1.4.0"
  ]
}
JSON

  write detective/config-recorder.json <<'JSON'
{
  "Name": "default",
  "Recording": true,
  "AllSupported": true,
  "IncludeGlobalResourceTypes": true
}
JSON

  write detective/inspector.json <<'JSON'
{
  "Status": "ENABLED",
  "ScanTypes": ["EC2", "ECR", "LAMBDA"]
}
JSON
}

# ------------------------------------------------------------ the evaluator
build_tool() {
  write bin/awslab.py <<'PY'
#!/usr/bin/env python3
"""
awslab - offline control-plane simulator for the AWS security components of
CLF-C02 task statement 2.4. It performs no network I/O and calls no AWS API:
every answer below is computed from the JSON documents in the lab directory.

Implemented faithfully enough to reason about the exam objectives:
  * IAM policy evaluation order: explicit Deny > SCP > permissions boundary >
    identity policy / resource policy > implicit Deny.
  * Security groups: stateful, allow-only, referencing other groups.
  * Resource-based policies (S3 bucket policy, KMS key policy).
  * A posture audit in the style of AWS Security Hub controls.
"""

import argparse
import fnmatch
import json
import os
import re
import sys

LAB = os.environ.get("AWSLAB_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ACCOUNT = "111122223333"
REGION = "us-east-1"
BUCKET = "teach-plat-artifacts"
BUCKET_ARN = "arn:aws:s3:::teach-plat-artifacts"
OBJECT_ARN = "arn:aws:s3:::teach-plat-artifacts/releases/app-1.4.2.tar.gz"
KEY_ARN = "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
SECRET_ARN = "arn:aws:secretsmanager:us-east-1:111122223333:secret:prod/app/db-AbCdEf"
APP_ROLE = "arn:aws:iam::111122223333:role/app-backend-role"
SCP_FILE = "org/scp-workloads.json"
KEY_FILE = "kms/key-1234abcd.json"

USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def paint(code, text):
    return text if not USE_COLOR else "\033[%sm%s\033[0m" % (code, text)


def green(t):
    return paint("32", t)


def red(t):
    return paint("31", t)


def yellow(t):
    return paint("33", t)


def title(t):
    return paint("1;36", t)


class LabError(Exception):
    pass


def rel(p):
    return os.path.join(LAB, p)


def exists(p):
    return os.path.exists(rel(p))


def load(p):
    full = rel(p)
    try:
        with open(full, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        raise LabError("ResourceNotFoundException: %s does not exist" % p)
    except json.JSONDecodeError as exc:
        raise LabError("MalformedPolicyDocumentException: %s is not valid JSON (%s)" % (p, exc))


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def statements(doc):
    return as_list(doc.get("Statement", []))


def match_action(patterns, action):
    for pat in as_list(patterns):
        if fnmatch.fnmatchcase(action.lower(), str(pat).lower()):
            return str(pat)
    return None


def match_resource(patterns, resource):
    for pat in as_list(patterns):
        if fnmatch.fnmatchcase(resource, str(pat)):
            return str(pat)
    return None


def condition_ok(condition, ctx):
    if not condition:
        return True
    for operator, pairs in condition.items():
        for key, expected in pairs.items():
            actual = ctx.get(key)
            wanted = [str(v) for v in as_list(expected)]
            if operator == "Bool":
                if str(bool(actual)).lower() != wanted[0].lower():
                    return False
            elif operator == "StringEquals":
                if str(actual) not in wanted:
                    return False
            elif operator == "StringNotEquals":
                if str(actual) in wanted:
                    return False
            elif operator == "StringLike":
                if not any(fnmatch.fnmatchcase(str(actual), w) for w in wanted):
                    return False
            elif operator == "Null":
                if (actual is None) != (wanted[0].lower() == "true"):
                    return False
            else:
                return False
    return True


def principal_matches(stmt, principal_arn):
    if "Principal" not in stmt:
        return True
    principal = stmt["Principal"]
    values = []
    if isinstance(principal, dict):
        for _, val in principal.items():
            values.extend(as_list(val))
    else:
        values.extend(as_list(principal))
    for val in values:
        if val == "*" or val == principal_arn or fnmatch.fnmatchcase(principal_arn, str(val)):
            return True
    return False


def evaluate_doc(doc, action, resource, ctx, principal=None):
    """Return (effect, sid) for one policy document: Deny wins over Allow."""
    allow_sid = None
    for stmt in statements(doc):
        if principal is not None and not principal_matches(stmt, principal):
            continue
        if not match_action(stmt.get("Action", []), action):
            continue
        if not match_resource(stmt.get("Resource", ["*"]), resource):
            continue
        if not condition_ok(stmt.get("Condition"), ctx):
            continue
        if stmt.get("Effect") == "Deny":
            return ("Deny", stmt.get("Sid", "(unnamed)"))
        if allow_sid is None:
            allow_sid = stmt.get("Sid", "(unnamed)")
    return ("Allow", allow_sid) if allow_sid else (None, None)


def evaluate_docs(docs, action, resource, ctx, principal=None):
    allow_sid = None
    for name, doc in docs:
        effect, sid = evaluate_doc(doc, action, resource, ctx, principal)
        if effect == "Deny":
            return ("Deny", "%s/%s" % (name, sid))
        if effect == "Allow" and allow_sid is None:
            allow_sid = "%s/%s" % (name, sid)
    return ("Allow", allow_sid) if allow_sid else (None, None)


def resolve_principal(name):
    short = name.rstrip("/").split("/")[-1]
    role_path = "iam/roles/%s.json" % short
    user_path = "iam/users/%s.json" % short
    if exists(role_path):
        entity = load(role_path)
        docs = [(p, load("iam/policies/%s.json" % p)) for p in entity.get("AttachedPolicies", [])]
        mfa = False  # an assumed role session in this lab is not MFA-authenticated
        kind = "role"
    elif exists(user_path):
        entity = load(user_path)
        names = list(entity.get("AttachedPolicies", []))
        for group in entity.get("Groups", []):
            names.extend(load("iam/groups/%s.json" % group).get("AttachedPolicies", []))
        docs = [(p, load("iam/policies/%s.json" % p)) for p in names]
        mfa = bool(entity.get("MFADevices"))
        kind = "user"
    else:
        raise LabError("NoSuchEntity: no IAM user or role named '%s'" % short)

    boundary_name = entity.get("PermissionsBoundary")
    boundary = None
    if boundary_name:
        boundary = (boundary_name, load("iam/policies/%s.json" % boundary_name))
    return {
        "kind": kind,
        "arn": entity.get("Arn"),
        "identity": docs,
        "boundary": boundary,
        "scp": load(SCP_FILE),
        "mfa": mfa,
        "raw": entity,
    }


def resource_policy_for(resource):
    if resource.startswith(BUCKET_ARN):
        return ("s3 bucket policy", load("s3/%s/bucket-policy.json" % BUCKET), False)
    if resource.startswith("arn:aws:kms:"):
        return ("kms key policy", load(KEY_FILE)["KeyPolicy"], True)
    return (None, None, False)


def authorize(principal_name, action, resource, mfa=None, region=REGION, secure=True):
    """Full evaluation. Returns (allowed, reason, trace)."""
    principal = resolve_principal(principal_name)
    ctx = {
        "aws:MultiFactorAuthPresent": principal["mfa"] if mfa is None else mfa,
        "aws:RequestedRegion": region,
        "aws:SecureTransport": secure,
        "aws:PrincipalArn": principal["arn"],
    }
    trace = []

    effect, sid = evaluate_doc(principal["scp"], action, resource, ctx)
    trace.append(("Organizations SCP", effect or "implicit deny", sid))
    if effect == "Deny":
        return (False, "explicit Deny in the Service Control Policy (%s)" % sid, trace)
    if effect != "Allow":
        return (False, "no Service Control Policy allows %s in this OU" % action, trace)

    if principal["boundary"]:
        bname, bdoc = principal["boundary"]
        effect, sid = evaluate_doc(bdoc, action, resource, ctx)
        trace.append(("Permissions boundary (%s)" % bname, effect or "implicit deny", sid))
        if effect == "Deny":
            return (False, "explicit Deny in the permissions boundary %s (%s)" % (bname, sid), trace)
        if effect != "Allow":
            return (False, "no permissions boundary allows the %s action" % action, trace)
    else:
        trace.append(("Permissions boundary", "not attached", None))

    ident_effect, ident_sid = evaluate_docs(principal["identity"], action, resource, ctx)
    trace.append(("Identity-based policies", ident_effect or "implicit deny", ident_sid))
    if ident_effect == "Deny":
        return (False, "explicit Deny in an identity-based policy (%s)" % ident_sid, trace)

    rp_name, rp_doc, rp_required = resource_policy_for(resource)
    rp_effect, rp_sid = (None, None)
    if rp_doc is not None:
        rp_effect, rp_sid = evaluate_doc(rp_doc, action, resource, ctx, principal["arn"])
        trace.append(("Resource-based policy (%s)" % rp_name, rp_effect or "implicit deny", rp_sid))
        if rp_effect == "Deny":
            return (False, "explicit Deny in the %s (%s)" % (rp_name, rp_sid), trace)
    else:
        trace.append(("Resource-based policy", "none attached", None))

    if rp_required and rp_effect != "Allow":
        return (False, "the KMS key policy does not grant %s to this principal" % action, trace)
    if ident_effect == "Allow" or rp_effect == "Allow":
        return (True, "allowed by %s" % (ident_sid or rp_sid), trace)
    return (False, "no identity-based or resource-based policy allows %s" % action, trace)


# ------------------------------------------------------------------- network
def security_groups():
    folder = rel("ec2/security-groups")
    out = []
    for name in sorted(os.listdir(folder)):
        if name.endswith(".json"):
            out.append(load("ec2/security-groups/%s" % name))
    return out


def sg_by_id(ident):
    for group in security_groups():
        if ident in (group["GroupId"], group["GroupName"]):
            return group
    raise LabError("InvalidGroup.NotFound: %s" % ident)


def rule_covers_port(rule, port):
    proto = str(rule.get("IpProtocol", "-1"))
    if proto == "-1":
        return True
    if proto != "tcp":
        return False
    return int(rule.get("FromPort", 0)) <= port <= int(rule.get("ToPort", 65535))


def ingress_allows(group, port, src_sg=None, src_cidr=None):
    for rule in group.get("IpPermissions", []):
        if not rule_covers_port(rule, port):
            continue
        if src_sg:
            for pair in rule.get("UserIdGroupPairs", []):
                if pair.get("GroupId") == src_sg:
                    return ("security group reference %s" % src_sg, rule)
        if src_cidr:
            for block in rule.get("IpRanges", []):
                if block.get("CidrIp") in ("0.0.0.0/0", src_cidr):
                    return ("CIDR %s" % block.get("CidrIp"), rule)
    return (None, None)


def egress_allows(group, port):
    for rule in group.get("IpPermissionsEgress", []):
        if rule_covers_port(rule, port):
            return True
    return False


# ------------------------------------------------------------------ commands
def cmd_whoami(_args):
    print(title("Simulated account"))
    print("  Account id     : %s" % ACCOUNT)
    print("  Home Region    : %s" % REGION)
    print("  Lab directory  : %s" % LAB)
    print("  Principals     : role/app-backend-role, user/dev-ana, root")
    print("  Nothing here reaches a real AWS endpoint.")
    return 0


def cmd_inventory(_args):
    rows = [
        ("Identity", "IAM role", "app-backend-role (instance profile, temporary credentials)"),
        ("Identity", "IAM user + group", "dev-ana in Developers"),
        ("Identity", "IAM policy", "AppBackendAccess, DeveloperReadOnly"),
        ("Identity", "Permissions boundary", "AppBoundary"),
        ("Identity", "Organizations SCP", "scp-workloads (Workloads OU)"),
        ("Identity", "Root user", "iam/root.json"),
        ("Network", "Security group", "sg-0web01 (web), sg-0app01 (app) - stateful"),
        ("Network", "Network ACL", "acl-0lab-private - stateless, ordered"),
        ("Data", "S3 Block Public Access", "s3/%s/public-access-block.json" % BUCKET),
        ("Data", "S3 bucket policy", "s3/%s/bucket-policy.json" % BUCKET),
        ("Data", "S3 default encryption", "SSE-KMS with the CMK"),
        ("Data", "AWS KMS CMK", "alias/teach-plat/app"),
        ("Data", "Secrets Manager secret", "prod/app/db (rotating)"),
        ("Detective", "AWS CloudTrail", "org-trail (API activity)"),
        ("Detective", "Amazon GuardDuty", "threat detection"),
        ("Detective", "AWS Security Hub", "posture aggregation"),
        ("Detective", "AWS Config", "configuration recorder"),
        ("Detective", "Amazon Inspector", "workload vulnerability scanning"),
    ]
    print(title("Security components in this account"))
    for category, service, detail in rows:
        print("  %-10s %-22s %s" % (category, service, detail))
    return 0


def cmd_simulate(args):
    allowed, reason, trace = authorize(
        args.principal, args.action, args.resource,
        mfa=(True if args.mfa else None),
        region=args.region,
    )
    print(title("IAM policy evaluation"))
    print("  Principal : %s" % args.principal)
    print("  Action    : %s" % args.action)
    print("  Resource  : %s" % args.resource)
    print("")
    for layer, effect, sid in trace:
        mark = green("allow") if effect == "Allow" else (red(effect) if effect else red("implicit deny"))
        print("  %-34s %-16s %s" % (layer, mark, sid or ""))
    print("")
    print("  Decision  : %s  (%s)" % (green("Allow") if allowed else red("Deny"), reason))
    return 0 if allowed else 1


def cmd_connect(args):
    dest = sg_by_id(args.to)
    src_sg = src_cidr = None
    try:
        src = sg_by_id(getattr(args, "from"))
        src_sg = src["GroupId"]
    except LabError:
        src = None
        src_cidr = getattr(args, "from")

    matched, rule = ingress_allows(dest, args.port, src_sg=src_sg, src_cidr=src_cidr)
    print(title("Security group path check"))
    print("  Source      : %s" % (src_sg or src_cidr))
    print("  Destination : %s (%s) port %d" % (dest["GroupId"], dest["GroupName"], args.port))
    if src is not None and not egress_allows(src, args.port):
        print("  Result      : %s - no egress rule on the source group" % red("blocked"))
        return 1
    if matched:
        print("  Result      : %s via %s" % (green("reachable"), matched))
        print("  Note        : security groups are stateful, the response needs no rule.")
        return 0
    print("  Result      : %s - connection times out, no inbound rule matches" % red("blocked"))
    print("  Hint        : `awslab describe-sg %s`" % dest["GroupId"])
    return 1


def cmd_describe_sg(args):
    group = sg_by_id(args.group)
    print(json.dumps(group, indent=2))
    return 0


def cmd_healthcheck(_args):
    print(title("app-backend boot sequence (simulated)"))
    failures = 0
    steps = [
        ("secretsmanager:GetSecretValue", SECRET_ARN, "read the database credential"),
        ("kms:Decrypt", KEY_ARN, "decrypt the credential with the CMK"),
        ("s3:ListBucket", BUCKET_ARN, "list the release prefix"),
        ("s3:GetObject", OBJECT_ARN, "download the release artifact"),
    ]
    for action, resource, what in steps:
        allowed, reason, _ = authorize(APP_ROLE, action, resource)
        if allowed:
            print("  %s %-34s %s" % (green("[ ok ]"), action, what))
        else:
            failures += 1
            print("  %s %-34s %s" % (red("[fail]"), action, what))
            print("        AccessDenied: User: %s is not authorized to perform:" % APP_ROLE)
            print("        %s on resource: %s because %s" % (action, resource, reason))

    code = cmd_connect(argparse.Namespace(**{"from": "sg-0web01", "to": "sg-0app01", "port": 8080}))
    if code != 0:
        failures += 1

    print("")
    if failures:
        print("  %s the workload cannot start: %d failing step(s)." % (red("RESULT:"), failures))
        return 1
    print("  %s the workload starts cleanly." % green("RESULT:"))
    return 0


# --------------------------------------------------------------------- audit
def audit_checks():
    results = []

    def add(cid, titletext, passed, detail, hint):
        results.append({"id": cid, "title": titletext, "pass": passed, "detail": detail, "hint": hint})

    root = load("iam/root.json")
    keys = root.get("AccessKeys", [])
    add("IAM.1", "Root user has no access keys", not keys,
        "%d active root access key(s)" % len(keys) if keys else "none",
        "Delete every root access key; use IAM roles for programmatic access.")

    bad_mfa = []
    for name in sorted(os.listdir(rel("iam/users"))):
        user = load("iam/users/%s" % name)
        if user.get("ConsoleAccess") and not user.get("MFADevices"):
            bad_mfa.append(user["UserName"])
    add("IAM.2", "Console users have MFA enabled", not bad_mfa,
        ", ".join(bad_mfa) if bad_mfa else "all console users have MFA",
        "Register an MFA device for every user with console access.")

    role = load("iam/roles/app-backend-role.json")
    boundary = role.get("PermissionsBoundary")
    add("IAM.3", "Workload role carries a permissions boundary",
        bool(boundary) and exists("iam/policies/%s.json" % boundary),
        boundary or "none",
        "Attach the AppBoundary permissions boundary to app-backend-role.")

    wide = []
    for name in sorted(os.listdir(rel("iam/policies"))):
        doc = load("iam/policies/%s" % name)
        for stmt in statements(doc):
            if stmt.get("Effect") != "Allow":
                continue
            actions = [str(a) for a in as_list(stmt.get("Action"))]
            resources = [str(r) for r in as_list(stmt.get("Resource"))]
            if "*" in actions and "*" in resources:
                wide.append("%s/%s" % (name, stmt.get("Sid", "(unnamed)")))
    add("IAM.4", "No identity policy grants Action \"*\" on Resource \"*\"", not wide,
        ", ".join(wide) if wide else "least privilege respected",
        "Grant only the actions the workload needs; do not repair access with a wildcard.")

    open_admin = []
    for group in security_groups():
        for rule in group.get("IpPermissions", []):
            for port in (22, 3389):
                if not rule_covers_port(rule, port):
                    continue
                for block in rule.get("IpRanges", []):
                    if block.get("CidrIp") in ("0.0.0.0/0", "::/0"):
                        open_admin.append("%s:%d from %s" % (group["GroupId"], port, block["CidrIp"]))
    add("EC2.1", "No security group exposes 22/3389 to the internet", not open_admin,
        ", ".join(sorted(set(open_admin))) if open_admin else "no world-open admin ports",
        "Remove the rule; reach instances with AWS Systems Manager Session Manager.")

    app_sg = sg_by_id("sg-0app01")
    cidr_on_8080 = []
    for rule in app_sg.get("IpPermissions", []):
        if rule_covers_port(rule, 8080):
            for block in rule.get("IpRanges", []):
                cidr_on_8080.append(block.get("CidrIp"))
    add("EC2.2", "App tier accepts 8080 only from the web tier group", not cidr_on_8080,
        ", ".join(cidr_on_8080) if cidr_on_8080 else "security-group reference only",
        "Reference sg-0web01 in the ingress rule instead of a CIDR block.")

    pab = load("s3/%s/public-access-block.json" % BUCKET)
    off = [k for k, v in pab.items() if v is not True]
    add("S3.1", "S3 Block Public Access fully enabled", not off,
        ", ".join(sorted(off)) if off else "all four settings on",
        "Set the four Block Public Access flags back to true.")

    policy = load("s3/%s/bucket-policy.json" % BUCKET)
    anon = []
    for stmt in statements(policy):
        if stmt.get("Effect") != "Allow":
            continue
        principal = stmt.get("Principal")
        vals = []
        if isinstance(principal, dict):
            for _, val in principal.items():
                vals.extend(as_list(val))
        else:
            vals.extend(as_list(principal))
        if "*" in [str(v) for v in vals]:
            anon.append(stmt.get("Sid", "(unnamed)"))
    add("S3.2", "Bucket policy grants no anonymous access", not anon,
        ", ".join(anon) if anon else "no Principal \"*\" Allow statement",
        "Delete the public Allow statement; grant the role, not the world.")

    enc = load("s3/%s/encryption.json" % BUCKET).get("Rules", [])
    enc_ok = bool(enc) and enc[0].get("ApplyServerSideEncryptionByDefault", {}).get("SSEAlgorithm") == "aws:kms"
    add("S3.3", "Default encryption uses SSE-KMS with the CMK", enc_ok,
        "configured" if enc_ok else "no default encryption rule",
        "Re-apply default encryption with aws:kms and the customer managed key.")

    key = load(KEY_FILE)
    key_ok = key.get("KeyState") == "Enabled" and key.get("KeyRotationEnabled") is True
    add("KMS.1", "CMK enabled with automatic key rotation", key_ok,
        "state=%s rotation=%s" % (key.get("KeyState"), key.get("KeyRotationEnabled")),
        "Enable the key and turn automatic annual rotation back on.")

    secret_pattern = re.compile(r"^\s*[A-Z_]*(PASSWORD|SECRET_KEY|TOKEN|PRIVATE_KEY)\s*=\s*\S", re.I)
    leaks = []
    for name in sorted(os.listdir(rel("app"))):
        with open(rel("app/%s" % name), "r", encoding="utf-8") as fh:
            for number, line in enumerate(fh, 1):
                if line.lstrip().startswith("#"):
                    continue
                if secret_pattern.match(line) and "SECRET_ARN" not in line.upper():
                    leaks.append("app/%s:%d" % (name, number))
    add("SM.1", "No plaintext credentials in application config", not leaks,
        ", ".join(leaks) if leaks else "credentials resolved from Secrets Manager",
        "Delete the hardcoded value; the app must read DB_SECRET_ARN at runtime.")

    trail = load("cloudtrail/org-trail.json")
    trail_ok = all([trail.get("IsLogging"), trail.get("IsMultiRegionTrail"), trail.get("LogFileValidationEnabled")])
    add("CT.1", "CloudTrail logging, multi-Region, log file validation", trail_ok,
        "logging=%s multiRegion=%s validation=%s" % (
            trail.get("IsLogging"), trail.get("IsMultiRegionTrail"), trail.get("LogFileValidationEnabled")),
        "Start logging again and restore the multi-Region and validation settings.")

    gd = load("detective/guardduty.json")
    add("GD.1", "Amazon GuardDuty enabled", gd.get("Status") == "ENABLED",
        gd.get("Status", "unknown"),
        "Re-enable the GuardDuty detector in the Region.")

    cfg = load("detective/config-recorder.json")
    add("CFG.1", "AWS Config recorder running", cfg.get("Recording") is True,
        "recording=%s" % cfg.get("Recording"), "Start the configuration recorder.")

    sh = load("detective/securityhub.json")
    add("SH.1", "AWS Security Hub enabled", sh.get("Enabled") is True,
        "enabled=%s" % sh.get("Enabled"), "Enable Security Hub with the FSBP standard.")

    insp = load("detective/inspector.json")
    add("INS.1", "Amazon Inspector enabled", insp.get("Status") == "ENABLED",
        insp.get("Status", "unknown"), "Enable Inspector for EC2/ECR/Lambda scanning.")

    return results


def cmd_audit(args):
    results = audit_checks()
    failed = [r for r in results if not r["pass"]]
    print(title("Security posture audit - simulated Security Hub controls"))
    for item in results:
        if args.fail_only and item["pass"]:
            continue
        mark = green("PASS") if item["pass"] else red("FAIL")
        print("  %s  %-7s %-52s %s" % (mark, item["id"], item["title"], item["detail"]))
        if not item["pass"]:
            print("        remediation: %s" % item["hint"])
    print("")
    print("  %d control(s) checked, %s failing." % (len(results), red(str(len(failed))) if failed else green("0")))
    return 1 if failed else 0


def cmd_mission(_args):
    with open(rel("BRIEFING.md"), "r", encoding="utf-8") as fh:
        sys.stdout.write(fh.read())
    return 0


def cmd_grade(_args):
    health = cmd_healthcheck(None)
    print("")
    posture = cmd_audit(argparse.Namespace(fail_only=True))
    print("")
    if health == 0 and posture == 0:
        print(green("  LAB SOLVED: the workload boots and every control passes."))
        return 0
    print(red("  NOT SOLVED YET:") + " healthcheck=%s audit=%s" % (
        "ok" if health == 0 else "failing", "ok" if posture == 0 else "failing"))
    return 1


def main():
    parser = argparse.ArgumentParser(prog="awslab", description="Offline AWS security component simulator.")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("whoami").set_defaults(func=cmd_whoami)
    sub.add_parser("inventory").set_defaults(func=cmd_inventory)
    sub.add_parser("mission").set_defaults(func=cmd_mission)
    sub.add_parser("healthcheck").set_defaults(func=cmd_healthcheck)
    sub.add_parser("grade").set_defaults(func=cmd_grade)

    p_sim = sub.add_parser("simulate", help="evaluate one API call against every policy layer")
    p_sim.add_argument("--principal", required=True)
    p_sim.add_argument("--action", required=True)
    p_sim.add_argument("--resource", required=True)
    p_sim.add_argument("--region", default=REGION)
    p_sim.add_argument("--mfa", action="store_true")
    p_sim.set_defaults(func=cmd_simulate)

    p_con = sub.add_parser("connect", help="check a security group path")
    p_con.add_argument("--from", required=True, dest="from")
    p_con.add_argument("--to", required=True)
    p_con.add_argument("--port", type=int, required=True)
    p_con.set_defaults(func=cmd_connect)

    p_sg = sub.add_parser("describe-sg")
    p_sg.add_argument("group")
    p_sg.set_defaults(func=cmd_describe_sg)

    p_aud = sub.add_parser("audit")
    p_aud.add_argument("--fail-only", action="store_true")
    p_aud.set_defaults(func=cmd_audit)

    args = parser.parse_args()
    if not getattr(args, "func", None):
        parser.print_help()
        return 2
    try:
        return args.func(args)
    except LabError as exc:
        print(red("  %s" % exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
PY

  write bin/awslab <<'SH'
#!/usr/bin/env bash
# Thin wrapper so the student can call `awslab ...` from anywhere.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWSLAB_ROOT="$(dirname "$here")" exec python3 "$here/awslab.py" "$@"
SH
  chmod +x "$LAB/bin/awslab"
}

# --------------------------------------------------------- controlled damage
inject_faults() {
  python3 - <<'PY'
import json
import os

LAB = os.environ["LAB"]


def load(rel):
    with open(os.path.join(LAB, rel), "r", encoding="utf-8") as fh:
        return json.load(fh)


def save(rel, data):
    with open(os.path.join(LAB, rel), "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


# F1 - someone created a root access key "for the CI pipeline".
root = load("iam/root.json")
root["AccessKeys"] = [
    {"AccessKeyId": "AKIA-EXAMPLE-ROOT-0001", "Status": "Active", "CreateDate": "2026-09-03"}
]
save("iam/root.json", root)

# F2 - dev-ana's virtual MFA device was removed after a phone swap.
user = load("iam/users/dev-ana.json")
user["MFADevices"] = []
save("iam/users/dev-ana.json", user)

# F3 - a least-privilege sweep over-tightened the permissions boundary.
save("iam/policies/AppBoundary.json", {
    "Version": "2012-10-17",
    "Comment": "Tightened during the change window - reviewed by nobody.",
    "Statement": [
        {"Sid": "BoundaryEnvelope", "Effect": "Allow",
         "Action": ["s3:List*", "logs:*"], "Resource": ["*"]},
        {"Sid": "DenyIdentityEscalation", "Effect": "Deny",
         "Action": ["iam:*", "organizations:*", "account:*"], "Resource": ["*"]},
    ],
})

# F4 - the app role's grant was dropped from the key policy and rotation was
#      switched off "to stop the rotation alarms".
key = load("kms/key-1234abcd.json")
key["KeyRotationEnabled"] = False
key["KeyPolicy"]["Statement"] = [
    s for s in key["KeyPolicy"]["Statement"] if s.get("Sid") != "AllowAppRoleDecrypt"
]
save("kms/key-1234abcd.json", key)

# F5a - emergency SSH opened to the world on the web tier.
web = load("ec2/security-groups/sg-0web01.json")
web["IpPermissions"].append({
    "IpProtocol": "tcp", "FromPort": 22, "ToPort": 22,
    "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "temporary debug - never removed"}],
    "UserIdGroupPairs": [],
})
save("ec2/security-groups/sg-0web01.json", web)

# F5b - the app tier ingress rule was deleted while cleaning up the group.
app = load("ec2/security-groups/sg-0app01.json")
app["IpPermissions"] = []
save("ec2/security-groups/sg-0app01.json", app)

# F6 - the bucket was made public to "unblock a download", and default
#      encryption was removed with it.
save("s3/teach-plat-artifacts/public-access-block.json", {
    "BlockPublicAcls": False,
    "IgnorePublicAcls": False,
    "BlockPublicPolicy": False,
    "RestrictPublicBuckets": False,
})
policy = load("s3/teach-plat-artifacts/bucket-policy.json")
policy["Statement"].insert(0, {
    "Sid": "PublicReadTemporary",
    "Effect": "Allow",
    "Principal": "*",
    "Action": ["s3:GetObject"],
    "Resource": ["arn:aws:s3:::teach-plat-artifacts/*"],
})
save("s3/teach-plat-artifacts/bucket-policy.json", policy)
save("s3/teach-plat-artifacts/encryption.json", {"Rules": []})

# F7 - the trail was stopped from the management account (SCPs do not apply
#      there) and GuardDuty was suspended "because of the finding noise".
trail = load("cloudtrail/org-trail.json")
trail["IsLogging"] = False
trail["IsMultiRegionTrail"] = False
trail["LogFileValidationEnabled"] = False
save("cloudtrail/org-trail.json", trail)
gd = load("detective/guardduty.json")
gd["Status"] = "DISABLED"
save("detective/guardduty.json", gd)

# F8 - with kms:Decrypt broken, the on-call engineer hardcoded the password.
env_path = os.path.join(LAB, "app/app.env")
with open(env_path, "a", encoding="utf-8") as fh:
    fh.write("DB_PASSWORD=Pr0d-Db-Temp-Workaround\n")
PY
}

# ------------------------------------------------------------------ briefing
write_briefing() {
  write BRIEFING.md <<'MD'
==========================================================================
 CLF-C02 | Domain 2 - Security and Compliance
 Task 2.4 - Identify components and resources for security
==========================================================================

SCENARIO
  Account 111122223333 ("teach-plat production") went through an unreviewed
  Friday change window. Monday morning the app tier does not start, and the
  security team's posture report lights up.

  You are the on-call platform engineer. The account is simulated locally:
  every AWS security component is a JSON document you can read and edit with
  any text editor.

THE SYMPTOM YOU WILL SEE
  1. `awslab healthcheck` fails. The workload cannot read its database
     credential, cannot decrypt it, cannot download its release artifact,
     and the web tier cannot reach the app tier on port 8080. The errors are
     AccessDenied and a connection that times out.
  2. `awslab audit` reports several failing controls: an access key on the
     root user, a console user without MFA, SSH open to 0.0.0.0/0, a bucket
     that is public and no longer encrypted by default, a CMK with rotation
     off, a plaintext password in the app config, CloudTrail not logging and
     GuardDuty disabled.

YOUR MISSION
  Make BOTH of these exit zero:

      $LAB/bin/awslab healthcheck
      $LAB/bin/awslab audit

  or in one shot:

      $LAB/bin/awslab grade

THE CONSTRAINTS THAT MAKE IT A SECURITY EXERCISE
  * You may not repair access with a wildcard. Control IAM.4 fails if any
    identity policy allows Action "*" on Resource "*".
  * You may not open the app tier by CIDR. Control EC2.2 fails if port 8080
    accepts an IP range instead of the web tier security group.
  * You may not delete the checks. Fix the configuration, not the auditor.

TOOLS AT YOUR DISPOSAL
  awslab whoami                     what account am I in
  awslab inventory                  every security component, by category
  awslab describe-sg sg-0app01      dump one security group
  awslab simulate --principal app-backend-role \
                  --action kms:Decrypt \
                  --resource arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab
                                    shows WHICH policy layer denied the call
  awslab audit --fail-only          only the failing controls
  awslab healthcheck                simulate the workload boot
  awslab grade                      final verdict

WHERE TO LOOK
  iam/            users, groups, roles, policies, permissions boundary, root
  org/            the Service Control Policy of the Workloads OU
  ec2/            security groups (stateful) and the network ACL (stateless)
  s3/             bucket policy, Block Public Access, default encryption
  kms/            the customer managed key and its key policy
  secretsmanager/ the rotating database secret
  cloudtrail/     the organization trail
  detective/      GuardDuty, Security Hub, AWS Config, Inspector
  app/app.env     the application configuration

THE QUESTION THE EXAM IS REALLY ASKING
  Given a security requirement, which AWS component enforces it - identity
  (IAM, SCP, boundary), network (security group, NACL, WAF, Shield), data
  (KMS, Secrets Manager, S3 encryption and Block Public Access), or detection
  (CloudTrail, GuardDuty, Security Hub, Config, Inspector)? Every fault in
  this lab sits in exactly one of those four families. Name the family before
  you name the fix.

OFFICIAL DOCUMENTATION
  Exam guide      https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
  IAM evaluation  https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
  Boundaries      https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
  SCPs            https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
  Security groups https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
  S3 BPA          https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
  S3 encryption   https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-encryption.html
  KMS rotation    https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html
  KMS key policy  https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html
  Secrets Manager https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
  CloudTrail      https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
  GuardDuty       https://docs.aws.amazon.com/guardduty/latest/ug/what-is-guardduty.html
  Security Hub    https://docs.aws.amazon.com/securityhub/latest/userguide/what-is-securityhub.html
  Root user       https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html
==========================================================================
MD
}

# ---------------------------------------------------------------- main flow
main() {
  local reset=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset) reset=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
    shift
  done

  preflight

  if [[ $reset -eq 1 && -d "$LAB" ]]; then
    info "Removing the previous lab at $LAB"
    rm -rf -- "$LAB"
  fi
  if [[ -d "$LAB" && $reset -eq 0 ]]; then
    warn "$LAB already exists. Re-run with --reset to rebuild it from scratch."
    say  "Resuming with the existing lab. Run: $LAB/bin/awslab mission"
    exit 0
  fi

  info "Building the simulated account under $LAB"
  mkdir -p "$LAB"
  build_identity
  build_network
  build_data_protection
  build_detective
  build_tool
  write_briefing

  info "Injecting the controlled faults"
  inject_faults

  rule
  cat "$LAB/BRIEFING.md"
  rule
  say "${C_BOLD}Start here:${C_RESET}"
  say "  export PATH=\"$LAB/bin:\$PATH\""
  say "  awslab mission"
  say "  awslab healthcheck     ${C_YELLOW}# see the outage${C_RESET}"
  say "  awslab audit           ${C_YELLOW}# see the posture findings${C_RESET}"
  say "  awslab grade           ${C_YELLOW}# your success criteria${C_RESET}"
  rule
  say "Nothing outside $LAB was touched. Delete the lab with: rm -rf \"$LAB\""
}

main "$@"

# ==============================================================================
#  S O L U T I O N   -   do not read until you have tried the lab
# ==============================================================================
#
#  Set up first:
#      export LAB="${LAB_ROOT:-$HOME/aws-clf-lab-2.4}"
#      export PATH="$LAB/bin:$PATH"
#
#  ---------------------------------------------------------------------------
#  STEP 0 - Diagnose before you touch anything
#  ---------------------------------------------------------------------------
#      awslab healthcheck
#      awslab audit --fail-only
#      awslab simulate --principal app-backend-role \
#          --action s3:GetObject \
#          --resource arn:aws:s3:::teach-plat-artifacts/releases/app-1.4.2.tar.gz
#
#  The simulate output is the whole lesson. It prints the four layers in the
#  order AWS evaluates them, and the first one that does not say "allow" is
#  your defect:
#
#      Organizations SCP                allow            FullAwsAccessBaseline
#      Permissions boundary (AppBoundary)  implicit deny
#      ...
#
#  Read that as: "the identity policy is fine, the boundary is the ceiling and
#  the ceiling came down". Effective permissions are the INTERSECTION of the
#  identity policy and the boundary; the boundary grants nothing on its own,
#  and an action missing from it is an implicit deny.
#
#  ---------------------------------------------------------------------------
#  STEP 1 - IAM: restore the permissions boundary envelope   (identity family)
#  ---------------------------------------------------------------------------
#  Fixes: healthcheck steps secretsmanager:GetSecretValue, kms:Decrypt,
#         s3:GetObject.
#  Note it does NOT widen anything: the identity policy AppBackendAccess is
#  still the narrow grant. The boundary is only the maximum.
#
#      cat > "$LAB/iam/policies/AppBoundary.json" <<'JSON'
#      {
#        "Version": "2012-10-17",
#        "Statement": [
#          {
#            "Sid": "BoundaryEnvelope",
#            "Effect": "Allow",
#            "Action": [
#              "s3:Get*",
#              "s3:List*",
#              "secretsmanager:GetSecretValue",
#              "kms:Decrypt",
#              "kms:DescribeKey",
#              "logs:*"
#            ],
#            "Resource": ["*"]
#          },
#          {
#            "Sid": "DenyIdentityEscalation",
#            "Effect": "Deny",
#            "Action": ["iam:*", "organizations:*", "account:*"],
#            "Resource": ["*"]
#          }
#        ]
#      }
#      JSON
#
#  Why not just add Action "*" / Resource "*"? Because control IAM.4 fails on
#  it, and because that is exactly the change that turns one compromised
#  instance into a compromised account.
#
#  ---------------------------------------------------------------------------
#  STEP 2 - KMS: put the role back in the key policy, re-enable rotation
#  ---------------------------------------------------------------------------
#  Fixes: healthcheck kms:Decrypt, control KMS.1.
#  The exam point: for AWS KMS the key policy is authoritative. An identity
#  policy that allows kms:Decrypt is not enough on its own - the key policy
#  must also grant the principal. Two policies, both required.
#
#      python3 - <<'PY'
#      import json, os
#      p = os.path.join(os.environ["LAB"], "kms/key-1234abcd.json")
#      key = json.load(open(p))
#      key["KeyRotationEnabled"] = True
#      key["KeyState"] = "Enabled"
#      sids = [s.get("Sid") for s in key["KeyPolicy"]["Statement"]]
#      if "AllowAppRoleDecrypt" not in sids:
#          key["KeyPolicy"]["Statement"].append({
#              "Sid": "AllowAppRoleDecrypt",
#              "Effect": "Allow",
#              "Principal": {"AWS": "arn:aws:iam::111122223333:role/app-backend-role"},
#              "Action": ["kms:Decrypt", "kms:DescribeKey"],
#              "Resource": "*"
#          })
#      json.dump(key, open(p, "w"), indent=2)
#      PY
#
#      awslab simulate --principal app-backend-role --action kms:Decrypt \
#          --resource arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab
#
#  ---------------------------------------------------------------------------
#  STEP 3 - VPC security groups                               (network family)
#  ---------------------------------------------------------------------------
#  3a. Remove the world-open SSH rule from the web tier (control EC2.1). In a
#      real account you would keep it closed and use AWS Systems Manager
#      Session Manager, which needs no inbound port at all.
#
#      cat > "$LAB/ec2/security-groups/sg-0web01.json" <<'JSON'
#      {
#        "GroupId": "sg-0web01",
#        "GroupName": "web-tier-sg",
#        "Description": "Public web tier behind the ALB.",
#        "VpcId": "vpc-0lab",
#        "IpPermissions": [
#          {
#            "IpProtocol": "tcp",
#            "FromPort": 443,
#            "ToPort": 443,
#            "IpRanges": [{ "CidrIp": "0.0.0.0/0", "Description": "public HTTPS" }],
#            "UserIdGroupPairs": []
#          }
#        ],
#        "IpPermissionsEgress": [
#          { "IpProtocol": "-1", "IpRanges": [{ "CidrIp": "0.0.0.0/0" }], "UserIdGroupPairs": [] }
#        ]
#      }
#      JSON
#
#  3b. Restore the app tier ingress AS A GROUP REFERENCE, not a CIDR block
#      (controls EC2.2 and the healthcheck connectivity step). Referencing the
#      source security group is what keeps the rule correct when instances are
#      replaced or scaled - there is no IP address to maintain.
#
#      cat > "$LAB/ec2/security-groups/sg-0app01.json" <<'JSON'
#      {
#        "GroupId": "sg-0app01",
#        "GroupName": "app-tier-sg",
#        "Description": "Private app tier, reachable only from the web tier.",
#        "VpcId": "vpc-0lab",
#        "IpPermissions": [
#          {
#            "IpProtocol": "tcp",
#            "FromPort": 8080,
#            "ToPort": 8080,
#            "IpRanges": [],
#            "UserIdGroupPairs": [{ "GroupId": "sg-0web01", "Description": "web tier only" }]
#          }
#        ],
#        "IpPermissionsEgress": [
#          { "IpProtocol": "-1", "IpRanges": [{ "CidrIp": "0.0.0.0/0" }], "UserIdGroupPairs": [] }
#        ]
#      }
#      JSON
#
#      awslab connect --from sg-0web01 --to sg-0app01 --port 8080
#
#      Remember the pair that gets asked constantly: security groups are
#      stateful (the reply to an allowed request is always permitted) and
#      allow-only; network ACLs are stateless, ordered, and support deny rules.
#
#  ---------------------------------------------------------------------------
#  STEP 4 - Amazon S3: public access, bucket policy, encryption  (data family)
#  ---------------------------------------------------------------------------
#  Controls S3.1, S3.2, S3.3.
#
#      cat > "$LAB/s3/teach-plat-artifacts/public-access-block.json" <<'JSON'
#      {
#        "BlockPublicAcls": true,
#        "IgnorePublicAcls": true,
#        "BlockPublicPolicy": true,
#        "RestrictPublicBuckets": true
#      }
#      JSON
#
#      cat > "$LAB/s3/teach-plat-artifacts/bucket-policy.json" <<'JSON'
#      {
#        "Version": "2012-10-17",
#        "Statement": [
#          {
#            "Sid": "AllowAppRoleRead",
#            "Effect": "Allow",
#            "Principal": { "AWS": "arn:aws:iam::111122223333:role/app-backend-role" },
#            "Action": ["s3:GetObject"],
#            "Resource": ["arn:aws:s3:::teach-plat-artifacts/releases/*"]
#          },
#          {
#            "Sid": "DenyInsecureTransport",
#            "Effect": "Deny",
#            "Principal": "*",
#            "Action": ["s3:*"],
#            "Resource": [
#              "arn:aws:s3:::teach-plat-artifacts",
#              "arn:aws:s3:::teach-plat-artifacts/*"
#            ],
#            "Condition": { "Bool": { "aws:SecureTransport": "false" } }
#          }
#        ]
#      }
#      JSON
#
#      cat > "$LAB/s3/teach-plat-artifacts/encryption.json" <<'JSON'
#      {
#        "Rules": [
#          {
#            "ApplyServerSideEncryptionByDefault": {
#              "SSEAlgorithm": "aws:kms",
#              "KMSMasterKeyID": "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
#            },
#            "BucketKeyEnabled": true
#          }
#        ]
#      }
#      JSON
#
#  Note the DenyInsecureTransport statement survives every fix: an explicit
#  Deny with a condition is the standard way to enforce encryption in transit,
#  and explicit Deny always wins over any Allow, anywhere.
#
#  ---------------------------------------------------------------------------
#  STEP 5 - Secrets Manager: remove the hardcoded password
#  ---------------------------------------------------------------------------
#  Control SM.1. This one is only fixable AFTER steps 1 and 2, because the
#  password was hardcoded precisely because kms:Decrypt was failing. That
#  dependency is the real-world lesson: a broken control breeds a worse one.
#
#      sed -i '/^DB_PASSWORD=/d' "$LAB/app/app.env"
#      grep -n 'DB_' "$LAB/app/app.env"
#
#  The application keeps only DB_SECRET_ARN and resolves the credential at
#  runtime with its instance-profile role - no long-lived key on disk, and
#  rotation every 30 days does not require a redeploy.
#
#  ---------------------------------------------------------------------------
#  STEP 6 - IAM hygiene: root access key and MFA
#  ---------------------------------------------------------------------------
#  Controls IAM.1 and IAM.2. The root user has unrestricted access to every
#  resource and its actions cannot be constrained by an SCP or a boundary, so
#  it must have no programmatic access keys and must be protected with MFA.
#  Workloads use IAM roles; people use identities with MFA.
#
#      python3 - <<'PY'
#      import json, os
#      lab = os.environ["LAB"]
#      root_path = os.path.join(lab, "iam/root.json")
#      root = json.load(open(root_path))
#      root["AccessKeys"] = []
#      json.dump(root, open(root_path, "w"), indent=2)
#
#      user_path = os.path.join(lab, "iam/users/dev-ana.json")
#      user = json.load(open(user_path))
#      user["MFADevices"] = [
#          {"SerialNumber": "arn:aws:iam::111122223333:mfa/dev-ana", "Type": "virtual"}
#      ]
#      json.dump(user, open(user_path, "w"), indent=2)
#      PY
#
#  Bonus check - now that dev-ana has MFA again, the conditional Deny in
#  DeveloperReadOnly behaves as designed:
#
#      awslab simulate --principal dev-ana --action secretsmanager:GetSecretValue \
#          --resource arn:aws:secretsmanager:us-east-1:111122223333:secret:prod/app/db-AbCdEf
#      awslab simulate --principal dev-ana --action secretsmanager:GetSecretValue \
#          --resource arn:aws:secretsmanager:us-east-1:111122223333:secret:prod/app/db-AbCdEf --mfa
#
#  The first is denied, the second is not: aws:MultiFactorAuthPresent is a
#  global condition key, and this is how "require MFA for sensitive actions"
#  is actually implemented.
#
#  ---------------------------------------------------------------------------
#  STEP 7 - Detective controls: CloudTrail and GuardDuty
#  ---------------------------------------------------------------------------
#  Controls CT.1 and GD.1. CloudTrail answers "who called which API, from
#  where, when" - it is the audit trail every investigation starts from.
#  Multi-Region matters because an attacker will not use your home Region;
#  log file validation matters because an audit trail you cannot prove is
#  intact is not evidence.
#
#      python3 - <<'PY'
#      import json, os
#      lab = os.environ["LAB"]
#      t_path = os.path.join(lab, "cloudtrail/org-trail.json")
#      trail = json.load(open(t_path))
#      trail.update({"IsLogging": True, "IsMultiRegionTrail": True,
#                    "LogFileValidationEnabled": True})
#      json.dump(trail, open(t_path, "w"), indent=2)
#
#      g_path = os.path.join(lab, "detective/guardduty.json")
#      gd = json.load(open(g_path))
#      gd["Status"] = "ENABLED"
#      json.dump(gd, open(g_path, "w"), indent=2)
#      PY
#
#  Worth noticing: the SCP contains DenyDisablingGuardrails with
#  cloudtrail:StopLogging in it, and the trail was stopped anyway. That is not
#  a bug in the lab - Service Control Policies never apply to the management
#  account of an AWS Organization. It is a favourite exam distinction.
#
#  ---------------------------------------------------------------------------
#  STEP 8 - Verify
#  ---------------------------------------------------------------------------
#      awslab grade
#
#  Expected:
#      [ ok ] secretsmanager:GetSecretValue   read the database credential
#      [ ok ] kms:Decrypt                     decrypt the credential with the CMK
#      [ ok ] s3:ListBucket                   list the release prefix
#      [ ok ] s3:GetObject                    download the release artifact
#      Result      : reachable via security group reference sg-0web01
#      RESULT: the workload starts cleanly.
#      15 control(s) checked, 0 failing.
#      LAB SOLVED: the workload boots and every control passes.
#
#  ---------------------------------------------------------------------------
#  MAPPING BACK TO THE EXAM OBJECTIVE
#  ---------------------------------------------------------------------------
#  Task 2.4 asks you to identify the component that satisfies a requirement.
#  Each fault above is one row of that table:
#
#    Requirement                              Component
#    ---------------------------------------  ------------------------------
#    Who may call which API                   IAM identity-based policy
#    Ceiling on what a delegated admin can    IAM permissions boundary
#      ever grant
#    Ceiling across every account in an OU    AWS Organizations SCP
#    Who may touch this specific resource     Resource-based policy
#                                               (S3 bucket policy, KMS key policy)
#    Require MFA for a sensitive action       Policy Condition on
#                                               aws:MultiFactorAuthPresent
#    Instance-level, stateful traffic control VPC security group
#    Subnet-level, stateless, ordered rules   Network ACL
#    L7 filtering / DDoS protection           AWS WAF / AWS Shield
#    Encryption keys you control and audit    AWS KMS customer managed key
#    Credentials out of code, auto-rotated    AWS Secrets Manager
#    Stop a bucket ever becoming public       S3 Block Public Access
#    Encrypt objects at rest by default       S3 default encryption (SSE-KMS)
#    Record every API call                    AWS CloudTrail
#    Detect malicious or anomalous activity   Amazon GuardDuty
#    Track and evaluate configuration drift   AWS Config
#    Scan workloads for vulnerabilities       Amazon Inspector
#    Aggregate posture findings in one place  AWS Security Hub
#    Trusted Advisor / Artifact               Best-practice checks / compliance reports
#
#  And the frame underneath all of it - the shared responsibility model: AWS
#  secures the infrastructure OF the cloud (hardware, hypervisor, managed
#  service internals, physical security); you are responsible for security IN
#  the cloud, which is precisely every file this lab made you fix.
#      https://aws.amazon.com/compliance/shared-responsibility-model/
#
#  Clean up when you are done:
#      rm -rf "$LAB"
# ==============================================================================