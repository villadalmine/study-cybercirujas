#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) - Lab: BREAK & FIX
#  Domain 2: Security and Compliance
#  Task Statement 2.3: Identify AWS access management capabilities
#
#  "The build pipeline can no longer publish" - a failing deployment role,
#  diagnosed with the same tools you would use against a real account.
#
#  WHAT THIS IS
#  ------------
#  A self-contained, offline lab. It builds a simulated AWS account (profiles,
#  an IAM role with a trust policy, a permissions boundary, a bucket and a
#  credentials file) as plain files under $LAB_ROOT, breaks it in four places
#  and plants one audit finding. Nothing outside $LAB_ROOT is ever written and
#  no real AWS endpoint is ever called: a small `aws` command on the lab PATH
#  answers the real CLI subcommands used here (sts, iam, s3, configure) with
#  the real response shapes, and enforces the real evaluation logic
#  (explicit Deny > boundary/identity Allow > implicit Deny).
#
#  RUN IT ONLY ON A DISPOSABLE LAB VM. The account id 123456789012 and every
#  credential-shaped string below are fictitious.
#
#  USAGE
#  -----
#    ./break_fix.sh start [DIR]   # build the sandbox and print the brief (default)
#    ./break_fix.sh shell         # a shell with the lab PATH and AWS_* variables
#    ./break_fix.sh verify        # grade your repair
#    ./break_fix.sh hint N        # hint 1..5, gentlest first
#    ./break_fix.sh brief         # print the brief again
#    ./break_fix.sh reset         # rebuild the sandbox, faults back in place
#    ./break_fix.sh clean         # delete the sandbox
#
#  ENVIRONMENT
#  -----------
#    LAB_ROOT=<path>                 default: $HOME/aws-clf-lab-2.3
#    LAB_ASSUME_YES=1                skip the interactive confirmation
#    AWS_LAB_MFA_CODE=123456         answers the MFA prompt unattended
#
#  REQUIREMENTS: bash >= 4, python3 (stdlib only), coreutils.
#
#  OFFICIAL SOURCES
#  ----------------
#   - CLF-C02 Exam Guide:
#     https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#   - IAM roles and temporary credentials:
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html
#   - Policy evaluation logic:
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
#   - Permissions boundaries:
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
#   - IAM role trust policies and MFA conditions:
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa_configure-api-require.html
#   - AWS CLI role profiles (source_profile, mfa_serial):
#     https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html
#   - IAM policy simulator API:
#     https://docs.aws.amazon.com/IAM/latest/APIReference/API_SimulatePrincipalPolicy.html
#   - The root user and its access keys:
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html
# ==============================================================================

set -euo pipefail

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  echo "This lab needs bash >= 4. Found: ${BASH_VERSION:-unknown}" >&2
  exit 1
fi

LAB_ID="aws-clf-2.3"
LAB_ROOT="${LAB_ROOT:-$HOME/aws-clf-lab-2.3}"
MARKER=".aws-clf-lab-2.3"
ACCOUNT_ID="123456789012"
BUCKET="lab-artifacts-${ACCOUNT_ID}"

if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''
fi

PASS=0
FAILED=0

say()  { printf '%s\n' "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

# Everything the lab touches hangs off $LAB_ROOT; derive the paths in one place
# so `start DIR` can move the whole sandbox.
set_paths() {
  case "$LAB_ROOT" in
    ""|"/"|"$HOME"|"$HOME/") fail "LAB_ROOT ($LAB_ROOT) is unsafe: point it at a dedicated directory."; exit 1 ;;
  esac
  BIN="$LAB_ROOT/bin"
  AWS_CONFIG_FILE="$LAB_ROOT/aws/config"
  AWS_SHARED_CREDENTIALS_FILE="$LAB_ROOT/aws/credentials"
}
set_paths

require_tools() {
  local t
  for t in python3 grep sed mktemp; do
    command -v "$t" >/dev/null 2>&1 || { fail "missing required tool: $t"; exit 1; }
  done
}

confirm_destructive() {
  [ "${LAB_ASSUME_YES:-0}" = "1" ] && return 0
  [ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM:-}" = "yes" ] && return 0
  printf '\n%sThis script builds a deliberately misconfigured lab sandbox.%s\n' "$C_YELLOW$C_BOLD" "$C_RESET"
  printf 'It writes ONLY under %s and never calls a real AWS endpoint.\n' "$LAB_ROOT"
  local answer
  read -r -p "Type 'yes' to continue: " answer || answer=""
  [ "$answer" = "yes" ] || { fail "cancelled."; exit 1; }
}

# ------------------------------------------------------------------------------
# The simulated `aws` command. Stdlib python, read-only except for `s3 cp`.
# ------------------------------------------------------------------------------
write_aws_shim() {
  mkdir -p "$BIN"
  cat > "$BIN/aws" <<'PYEOF'
#!/usr/bin/env python3
"""Lab-only stand-in for the AWS CLI. Answers sts / iam / s3 / configure from
the files under $AWS_LAB_ROOT and applies real policy-evaluation rules."""
import base64
import configparser
import fnmatch
import json
import os
import sys

ROOT = os.environ["AWS_LAB_ROOT"]
ACC = "123456789012"
BUCKET = "lab-artifacts-" + ACC
BUCKET_ARN = "arn:aws:s3:::" + BUCKET
ROLE = "LabDeployRole"
ROLE_ARN = "arn:aws:iam::%s:role/%s" % (ACC, ROLE)


def load(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
        return json.load(handle)


def out(obj):
    print(json.dumps(obj, indent=4))


def die(message, code=254):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def lst(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def read_ini(path, is_config):
    parser = configparser.RawConfigParser(delimiters=("=",))
    parser.read(path, encoding="utf-8")
    data = {}
    for section in parser.sections():
        name = section[len("profile "):] if is_config and section.startswith("profile ") else section
        data[name.strip()] = {k.strip(): v.strip() for k, v in parser.items(section)}
    return data


CONFIG = read_ini(os.environ["AWS_CONFIG_FILE"], True)
CREDS = read_ini(os.environ["AWS_SHARED_CREDENTIALS_FILE"], False)

# ---- argument parsing ---------------------------------------------------------
argv = sys.argv[1:]
profile = os.environ.get("AWS_PROFILE", "default")
output = "json"
query = None
rest = []
i = 0
while i < len(argv):
    a = argv[i]
    if a == "--profile":
        profile = argv[i + 1]; i += 2
    elif a == "--output":
        output = argv[i + 1]; i += 2
    elif a == "--query":
        query = argv[i + 1]; i += 2
    elif a in ("--region", "--cli-connect-timeout", "--cli-read-timeout"):
        i += 2
    elif a in ("--no-cli-pager", "--no-paginate", "--debug"):
        i += 1
    else:
        rest.append(a); i += 1
if len(rest) < 2:
    die("usage: aws <service> <command> [options]", 252)
service, command = rest[0], rest[1]
flags = {}
positional = []
current = None
for token in rest[2:]:
    if token.startswith("--"):
        current = token[2:]
        flags[current] = []
    elif current is not None:
        flags[current].append(token)
    else:
        positional.append(token)


# ---- policy evaluation --------------------------------------------------------
def match_statement(statement, action, resource):
    actions = lst(statement.get("Action"))
    resources = lst(statement.get("Resource", "*"))
    return (any(fnmatch.fnmatchcase(action.lower(), x.lower()) for x in actions)
            and any(fnmatch.fnmatchcase(resource, r) for r in resources))


def policies_for(kind, name):
    if kind == "user" and name == "ci":
        return [("CiBaselinePolicy", "IAM Policy", load("iam/policies/CiBaselinePolicy.json"))]
    if kind == "user" and name == "auditor":
        return [("AuditorPolicy", "IAM Policy", load("iam/policies/AuditorPolicy.json"))]
    if kind == "role" and name == ROLE:
        return [("DeployArtifactsPolicy", "IAM Policy", load("iam/policies/DeployArtifactsPolicy.json"))]
    return []


def evaluate(kind, name, action, resource):
    """explicit Deny anywhere > SCP must allow > boundary AND identity must allow > implicit Deny."""
    if kind == "root":
        return {"decision": "allowed", "matched": [], "boundary": None, "scp": True}
    docs = policies_for(kind, name)
    boundary = load("iam/boundaries/DeployBoundary.json") if kind == "role" else None
    if boundary is not None:
        docs = [("DeployBoundary", "Permissions Boundary", boundary)] + docs
    if resource.startswith(BUCKET_ARN):
        docs = docs + [("BucketPolicy", "Resource Policy", load("s3/bucket-policy.json"))]
    scp = any(s.get("Effect") == "Allow" and "*" in lst(s.get("Action"))
              for s in load("org/scp.json")["Statement"])
    identity_allow = boundary_allow = False
    for pname, ptype, doc in docs:
        for st in lst(doc.get("Statement")):
            if not match_statement(st, action, resource):
                continue
            if st.get("Effect") == "Deny":
                return {"decision": "explicitDeny", "scp": scp,
                        "boundary": False if boundary is not None else None,
                        "matched": [{"SourcePolicyId": pname, "SourcePolicyType": ptype,
                                     "Sid": st.get("Sid", "")}]}
            if ptype == "Permissions Boundary":
                boundary_allow = True
            elif ptype == "IAM Policy":
                identity_allow = True
    ok = scp and identity_allow and (boundary is None or boundary_allow)
    return {"decision": "allowed" if ok else "implicitDeny", "matched": [], "scp": scp,
            "boundary": (boundary_allow if boundary is not None else None)}


# ---- identity resolution (the credential chain) -------------------------------
def mfa_code(serial):
    code = os.environ.get("AWS_LAB_MFA_CODE", "")
    if not code:
        sys.stderr.write("Enter MFA code for %s: " % serial)
        sys.stderr.flush()
        code = sys.stdin.readline().strip()
    return code


def trust_allows(caller_arn, caller_name, prof):
    trust = load("iam/trust/LabDeployRole.json")
    for st in lst(trust.get("Statement")):
        if st.get("Effect") != "Allow":
            continue
        principal = st.get("Principal")
        principals = lst(principal.get("AWS")) if isinstance(principal, dict) else lst(principal)
        if not any(p in ("*", caller_arn, "arn:aws:iam::%s:root" % ACC) for p in principals):
            continue
        condition = st.get("Condition") or {}
        needs_mfa = any("multifactorauth" in k.lower() for block in condition.values() for k in block)
        if needs_mfa:
            serial = prof.get("mfa_serial")
            if not serial or serial != "arn:aws:iam::%s:mfa/%s" % (ACC, caller_name):
                continue
            code = mfa_code(serial)
            if not (len(code) == 6 and code.isdigit()):
                continue
        return True
    return False


def identity(name):
    prof = {}
    prof.update(CONFIG.get(name, {}))
    prof.update(CREDS.get(name, {}))
    if name not in CONFIG and name not in CREDS:
        die("\nThe config profile (%s) could not be found" % name, 255)
    if "role_arn" in prof:
        source = prof.get("source_profile")
        if not source or (source not in CONFIG and source not in CREDS):
            die("\nThe config profile (%s) could not be found" % (source or "source_profile"), 255)
        caller = identity(source)
        if not trust_allows(caller["Arn"], caller["name"], prof):
            die("\nAn error occurred (AccessDenied) when calling the AssumeRole operation: "
                "User: %s is not authorized to perform: sts:AssumeRole on resource: %s"
                % (caller["Arn"], prof["role_arn"]))
        role_name = prof["role_arn"].rsplit("/", 1)[1]
        return {"kind": "role", "name": role_name, "Account": ACC,
                "Arn": "arn:aws:sts::%s:assumed-role/%s/ci-pipeline" % (ACC, role_name),
                "UserId": "AROAJ2EXAMPLEROLEID1:ci-pipeline"}
    if "aws_access_key_id" not in prof:
        die('Unable to locate credentials. You can configure credentials by running "aws configure".', 253)
    if name == "root":
        return {"kind": "root", "name": "root", "Account": ACC,
                "Arn": "arn:aws:iam::%s:root" % ACC, "UserId": ACC}
    return {"kind": "user", "name": name, "Account": ACC,
            "Arn": "arn:aws:iam::%s:user/%s" % (ACC, name), "UserId": "AIDAJ2EXAMPLEUSERID-" + name}


def denied(who, operation, action, code=254):
    die("\nAn error occurred (AccessDenied) when calling the %s operation: User: %s is not "
        "authorized to perform: %s" % (operation, who["Arn"], action), code)


def authorize(who, operation, action, resource="*"):
    if evaluate(who["kind"], who["name"], action, resource)["decision"] != "allowed":
        denied(who, operation, action)


# ---- commands -----------------------------------------------------------------
if service == "configure" and command == "list-profiles":
    for n in sorted(set(CONFIG) | set(CREDS)):
        print(n)
    sys.exit(0)

who = identity(profile)

if service == "sts" and command == "get-caller-identity":
    out({"UserId": who["UserId"], "Account": ACC, "Arn": who["Arn"]})

elif service == "iam":
    op = {"get-role": "GetRole", "list-mfa-devices": "ListMFADevices",
          "simulate-principal-policy": "SimulatePrincipalPolicy",
          "generate-credential-report": "GenerateCredentialReport",
          "get-credential-report": "GetCredentialReport",
          "get-account-password-policy": "GetAccountPasswordPolicy"}.get(command)
    if op is None:
        die("aws: error: '%s' is not supported by this lab simulator" % command, 252)
    authorize(who, op, "iam:" + op)
    if op == "GetRole":
        name = (flags.get("role-name") or [""])[0]
        if name != ROLE:
            die("\nAn error occurred (NoSuchEntity) when calling the GetRole operation: "
                "The role with name %s cannot be found." % name, 254)
        out({"Role": {"Path": "/", "RoleName": ROLE, "Arn": ROLE_ARN,
                      "AssumeRolePolicyDocument": load("iam/trust/LabDeployRole.json"),
                      "PermissionsBoundary": {"PermissionsBoundaryType": "Policy",
                                              "PermissionsBoundaryArn":
                                              "arn:aws:iam::%s:policy/DeployBoundary" % ACC}}})
    elif op == "ListMFADevices":
        user = (flags.get("user-name") or [who["name"]])[0]
        devices = [{"UserName": "ci", "SerialNumber": "arn:aws:iam::%s:mfa/ci" % ACC}] if user == "ci" else []
        out({"MFADevices": devices})
    elif op == "SimulatePrincipalPolicy":
        source = (flags.get("policy-source-arn") or [""])[0]
        kind, name = ("role", source.rsplit("/", 1)[-1]) if ":role/" in source else \
                     ("user", source.rsplit("/", 1)[-1])
        results = []
        for action in flags.get("action-names", []):
            for resource in (flags.get("resource-arns") or ["*"]):
                r = evaluate(kind, name, action, resource)
                item = {"EvalActionName": action, "EvalResourceName": resource,
                        "EvalDecision": r["decision"], "MatchedStatements": r["matched"],
                        "MissingContextValues": [],
                        "OrganizationsDecisionDetail": {"AllowedByOrganizations": r["scp"]}}
                if r["boundary"] is not None:
                    item["PermissionsBoundaryDecisionDetail"] = {"AllowedByPermissionsBoundary": r["boundary"]}
                results.append(item)
        out({"EvaluationResults": results})
    elif op == "GenerateCredentialReport":
        out({"State": "COMPLETE", "Description": "No report exists. Starting a new report generation task"})
    elif op == "GetCredentialReport":
        rows = ["user,arn,password_enabled,mfa_active,access_key_1_active,access_key_2_active",
                "<root_account>,arn:aws:iam::%s:root,not_supported,false,true,false" % ACC,
                "ci,arn:aws:iam::%s:user/ci,false,true,true,false" % ACC,
                "auditor,arn:aws:iam::%s:user/auditor,true,true,true,false" % ACC]
        content = base64.b64encode(("\n".join(rows) + "\n").encode()).decode()
        if query == "Content" and output == "text":
            print(content)
        else:
            out({"Content": content, "ReportFormat": "text/csv"})
    elif op == "GetAccountPasswordPolicy":
        out({"PasswordPolicy": {"MinimumPasswordLength": 6, "RequireSymbols": False,
                                "RequireNumbers": False, "RequireUppercaseCharacters": False,
                                "RequireLowercaseCharacters": True, "AllowUsersToChangePassword": True,
                                "ExpirePasswords": False}})

elif service == "s3" and command in ("ls", "cp"):
    store = os.path.join(ROOT, "s3", BUCKET)
    if command == "ls":
        target = positional[0] if positional else ""
        if not target.startswith("s3://" + BUCKET):
            die("\nAn error occurred (NoSuchBucket) when calling the ListBuckets operation", 254)
        authorize(who, "ListObjectsV2", "s3:ListBucket", BUCKET_ARN)
        for dirpath, _, files in sorted(os.walk(store)):
            for f in sorted(files):
                full = os.path.join(dirpath, f)
                key = os.path.relpath(full, store).replace(os.sep, "/")
                print("2026-01-01 00:00:00 %10d %s" % (os.path.getsize(full), key))
    else:
        if len(positional) != 2:
            die("usage: aws s3 cp <src> <dst>", 252)
        src, dst = positional
        if dst.startswith("s3://" + BUCKET + "/"):
            key = dst[len("s3://" + BUCKET + "/"):]
            r = evaluate(who["kind"], who["name"], "s3:PutObject", BUCKET_ARN + "/" + key)
            if r["decision"] != "allowed":
                sys.stderr.write("upload failed: %s to %s An error occurred (AccessDenied) when calling "
                                 "the PutObject operation: Access Denied\n" % (src, dst))
                sys.exit(1)
            target = os.path.join(store, key)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(src, "rb") as s, open(target, "wb") as d:
                d.write(s.read())
            print("upload: %s to %s" % (src, dst))
        else:
            die("aws: error: this lab simulator only supports uploads to s3://%s/" % BUCKET, 252)
else:
    die("aws: error: '%s %s' is not supported by this lab simulator" % (service, command), 252)
PYEOF
  chmod +x "$BIN/aws"
}

# ------------------------------------------------------------------------------
# The sandbox: files only, then the four faults.
# ------------------------------------------------------------------------------
build_lab() {
  mkdir -p "$LAB_ROOT"/{aws,iam/trust,iam/boundaries,iam/policies,org,s3/"$BUCKET"/builds,s3/"$BUCKET"/releases,state,bin}
  write_aws_shim

  # Long-lived access keys are assembled at run time so no key-shaped literal
  # sits in this file (secret scanners, and students, must not mistake them
  # for real key material).
  local akid="AK""IA"
  cat > "$AWS_SHARED_CREDENTIALS_FILE" <<EOF
[ci]
aws_access_key_id = ${akid}LABCI00000000001
aws_secret_access_key = lab-only-not-a-real-secret-ci

[auditor]
aws_access_key_id = ${akid}LABAUDIT00000001
aws_secret_access_key = lab-only-not-a-real-secret-auditor

[root]
aws_access_key_id = ${akid}LABROOT00000001
aws_secret_access_key = lab-only-not-a-real-secret-root
EOF
  chmod 600 "$AWS_SHARED_CREDENTIALS_FILE"

  # FAULT 1: source_profile names a profile that does not exist (ci-runner).
  cat > "$AWS_CONFIG_FILE" <<EOF
[default]
region = us-east-1

[profile ci]
region = us-east-1
output = json

[profile auditor]
region = us-east-1
output = json

[profile deploy]
role_arn = arn:aws:iam::${ACCOUNT_ID}:role/LabDeployRole
source_profile = ci-runner
region = us-east-1
output = json
EOF

  # FAULTS 2 and 3: the trust policy names a deleted user and demands MFA the
  # profile does not supply.
  cat > "$LAB_ROOT/iam/trust/LabDeployRole.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPipelineUserToAssume",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_ID}:user/ci-runner-legacy" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "Bool": { "aws:MultiFactorAuthPresent": "true" },
        "NumericLessThan": { "aws:MultiFactorAuthAge": "3600" }
      }
    }
  ]
}
EOF

  # FAULT 4: the boundary meant to freeze releases/ freezes the whole bucket.
  cat > "$LAB_ROOT/iam/boundaries/DeployBoundary.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowArtifactDataPlane",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"]
    },
    {
      "Sid": "ProtectImmutableArtifacts",
      "Effect": "Deny",
      "Action": "s3:*",
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    }
  ]
}
EOF

  cat > "$LAB_ROOT/iam/policies/CiBaselinePolicy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeTheDeploymentRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/LabDeployRole"
    },
    {
      "Sid": "InspectIamForDebugging",
      "Effect": "Allow",
      "Action": ["iam:GetRole", "iam:ListMFADevices", "iam:SimulatePrincipalPolicy"],
      "Resource": "*"
    }
  ]
}
EOF

  cat > "$LAB_ROOT/iam/policies/AuditorPolicy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadCredentialHygiene",
      "Effect": "Allow",
      "Action": ["iam:GenerateCredentialReport", "iam:GetCredentialReport", "iam:GetAccountPasswordPolicy"],
      "Resource": "*"
    }
  ]
}
EOF

  cat > "$LAB_ROOT/iam/policies/DeployArtifactsPolicy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteBuildArtifacts",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    },
    {
      "Sid": "ListArtifactBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET}"
    }
  ]
}
EOF

  cat > "$LAB_ROOT/s3/bucket-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDeploymentRole",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_ID}:role/LabDeployRole" },
      "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"]
    }
  ]
}
EOF

  cat > "$LAB_ROOT/org/scp.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "FullAWSAccess", "Effect": "Allow", "Action": "*", "Resource": "*" }
  ]
}
EOF

  echo "release 1.0" > "$LAB_ROOT/s3/$BUCKET/releases/app-1.0.txt"

  cat > "$LAB_ROOT/env.sh" <<EOF
# source this file: it points the AWS CLI variables and PATH at the lab sandbox
export AWS_LAB_ROOT="$LAB_ROOT"
export AWS_CONFIG_FILE="$AWS_CONFIG_FILE"
export AWS_SHARED_CREDENTIALS_FILE="$AWS_SHARED_CREDENTIALS_FILE"
export AWS_PAGER=""
export PATH="$BIN:\$PATH"
EOF

  cat > "$LAB_ROOT/BRIEF.txt" <<EOF
================================================================================
 AWS CLF-C02 - Task 2.3 - "The build pipeline can no longer publish"
================================================================================
Wattle Co.'s CI pipeline publishes build artifacts to s3://${BUCKET}/builds/
by assuming the role LabDeployRole through the AWS CLI profile "deploy".
Since last night every publish fails. An audit also found something on this
build host that is not an outage but must not survive.

Enter the lab:
    source ${LAB_ROOT}/env.sh
    aws --profile deploy sts get-caller-identity

Your objectives:
  1. The deploy profile can assume LabDeployRole (and MFA is still required).
  2. The role can upload to builds/ and list the artifact bucket.
  3. Least privilege survives: the role still cannot write to releases/, call
     iam:CreateUser or delete the bucket, and the trust policy is not opened to
     every principal. A fix that widens a policy is not a fix.
  4. No long-lived root credentials remain on this host.

Everything lives under ${LAB_ROOT} (aws/, iam/, s3/, org/). Edit the files there.
Commands:  $0 verify | hint N | reset | clean
================================================================================
EOF
  : > "$LAB_ROOT/$MARKER"
}

require_lab() {
  [ -f "$LAB_ROOT/$MARKER" ] || { fail "no lab at $LAB_ROOT - run: $0 start"; exit 1; }
}

cmd_start() {
  if [ -n "${1:-}" ]; then LAB_ROOT="$1"; fi
  set_paths
  require_tools
  if [ -f "$LAB_ROOT/$MARKER" ]; then
    say "lab: sandbox already built at $LAB_ROOT (use '$0 reset' to put the faults back)."
  else
    confirm_destructive
    build_lab
    say "lab: sandbox built at $LAB_ROOT"
  fi
  cat "$LAB_ROOT/BRIEF.txt"
}

cmd_shell() {
  require_lab
  say "lab: entering the sandbox shell (exit to leave)."
  exec bash --rcfile <(printf '[ -f ~/.bashrc ] && . ~/.bashrc\n. "%s/env.sh"\n' "$LAB_ROOT") -i
}

cmd_hint() {
  require_lab
  case "${1:-1}" in
    1) say "Hint 1: read the error literally. Is it a CLIENT-side error (the call never left your machine) or a service AccessDenied? 'aws configure list-profiles' shows what the CLI can see." ;;
    2) say "Hint 2: a role profile is a two-link chain (source_profile -> role_arn). Compare 'source_profile' in $AWS_CONFIG_FILE with the profiles that exist." ;;
    3) say "Hint 3: an AssumeRole is decided by the role's TRUST policy. 'aws --profile ci iam get-role --role-name LabDeployRole' shows who it trusts and under which Condition. A condition key with no value never matches." ;;
    4) say "Hint 4: S3 will not say why it denied you. Ask IAM: 'aws --profile ci iam simulate-principal-policy' (the role cannot run it itself). Look at MatchedStatements and which policy TYPE owns the Deny." ;;
    5) say "Hint 5: an explicit Deny beats every Allow. Narrow what it covers (releases/ only); do not delete it and do not widen an Allow. For the audit finding use the credential report: 'aws --profile auditor iam get-credential-report'." ;;
    *) say "usage: $0 hint N   (N = 1..5)"; exit 1 ;;
  esac
}

# ------------------------------------------------------------------------------
# Grader helpers
# ------------------------------------------------------------------------------
aws_lab() {
  (
    export AWS_LAB_ROOT="$LAB_ROOT" AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
    export AWS_LAB_MFA_CODE="${AWS_LAB_MFA_CODE:-123456}" AWS_PAGER=""
    python3 "$BIN/aws" "$@" </dev/null
  )
}

head1() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); printf '  %s[ PASS ]%s %s\n' "$C_GREEN" "$C_RESET" "$desc"
  else
    FAILED=$((FAILED + 1)); printf '  %s[ FAIL ]%s %s\n' "$C_RED" "$C_RESET" "$desc"
  fi
}

check_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    FAILED=$((FAILED + 1)); printf '  %s[ FAIL ]%s %s\n' "$C_RED" "$C_RESET" "$desc"
  else
    PASS=$((PASS + 1)); printf '  %s[ PASS ]%s %s\n' "$C_GREEN" "$C_RESET" "$desc"
  fi
}

# Read one key with the same INI parser the aws shim uses, so any valid spacing
# (`key = v`, `key=v`) grades the same way it works.
ini_get() {
  python3 -c 'import configparser, sys
p = configparser.RawConfigParser(delimiters=("=",)); p.read(sys.argv[1], encoding="utf-8")
print(p.get(sys.argv[2], sys.argv[3], fallback=""))' "$1" "$2" "$3"
}

source_profile_exists() {
  local src
  src=$(ini_get "$AWS_CONFIG_FILE" "profile deploy" source_profile)
  [ -n "$src" ] && aws_lab configure list-profiles | grep -qx "$src"
}

trust_names_ci() { grep -q "\"arn:aws:iam::${ACCOUNT_ID}:user/ci\"" "$LAB_ROOT/iam/trust/LabDeployRole.json"; }
trust_keeps_mfa() { grep -q 'aws:MultiFactorAuthPresent' "$LAB_ROOT/iam/trust/LabDeployRole.json"; }
deploy_is_role() { aws_lab --profile deploy sts get-caller-identity | grep -q 'assumed-role/LabDeployRole/'; }

upload_to() {
  local f rc=0
  f=$(mktemp)
  echo "lab artifact $$" > "$f"
  aws_lab --profile deploy s3 cp "$f" "s3://$BUCKET/$1" || rc=$?
  rm -f "$f"
  return "$rc"
}
upload_builds()   { upload_to "builds/verify-$$.txt"; }
upload_releases() { upload_to "releases/verify-$$.txt"; }

simulate_allows() {
  aws_lab --profile ci iam simulate-principal-policy \
      --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:role/LabDeployRole" \
      --action-names "$1" --resource-arns "$2" | grep -q '"EvalDecision": "allowed"'
}

no_root_credentials() { ! grep -q '^\[root\]' "$AWS_SHARED_CREDENTIALS_FILE"; }

cmd_verify() {
  require_lab
  PASS=0
  FAILED=0
  head1 "Objective 1 - the deploy profile can assume LabDeployRole"
  check     "the deploy profile's source_profile exists" source_profile_exists
  check     "the trust policy names the ci user" trust_names_ci
  check     "the trust policy still demands MFA (the condition was kept)" trust_keeps_mfa
  check     "the deploy profile resolves to an assumed-role session" deploy_is_role

  head1 "Objective 2 - the pipeline can publish again"
  check     "the role uploads to builds/" upload_builds
  check     "the role can list the artifact bucket" \
            aws_lab --profile deploy s3 ls "s3://$BUCKET"

  head1 "Objective 3 - the guardrails you were not asked to remove"
  check_not "the role STILL cannot write to releases/ (boundary preserved)" \
            upload_releases
  check_not "the role STILL cannot call iam:CreateUser" \
            simulate_allows "iam:CreateUser" "arn:aws:iam::${ACCOUNT_ID}:user/newbie"
  check_not "the role STILL cannot delete the artifact bucket" \
            simulate_allows "s3:DeleteBucket" "arn:aws:s3:::$BUCKET"
  check_not "the trust policy was not opened to every principal" \
            grep -qE '"Principal"[[:space:]]*:[[:space:]]*"\*"' \
                 "$LAB_ROOT/iam/trust/LabDeployRole.json"

  head1 "Objective 4 - the audit finding"
  check     "no long-lived root credentials remain on this host" no_root_credentials

  printf '\n'
  if [ "$FAILED" -eq 0 ]; then
    printf '%sALL %d CHECKS PASSED.%s The pipeline is repaired and every guardrail survived.\n' \
           "$C_GREEN$C_BOLD" "$PASS" "$C_RESET"
    say "Read the commented solution at the bottom of this script and compare it with"
    say "what you actually did - the reasoning matters more than the diff."
    return 0
  fi
  printf '%s%d passed, %d still failing.%s  Try:  %s hint 1\n' \
         "$C_YELLOW$C_BOLD" "$PASS" "$FAILED" "$C_RESET" "$0"
  return 1
}

cmd_reset() {
  [ -f "$LAB_ROOT/$MARKER" ] || { fail "lab: nothing to reset at $LAB_ROOT"; exit 1; }
  rm -rf "$LAB_ROOT/aws" "$LAB_ROOT/iam" "$LAB_ROOT/org" "$LAB_ROOT/s3" "$LAB_ROOT/state"
  build_lab
  say "lab: sandbox reset - all four faults are back in place."
}

cmd_clean() {
  if [ -f "$LAB_ROOT/$MARKER" ]; then
    rm -rf "$LAB_ROOT"
    say "lab: removed $LAB_ROOT"
  else
    warn "lab: $LAB_ROOT is not a lab sandbox (no $MARKER marker) - refusing to delete."
    exit 1
  fi
}

case "${1:-start}" in
  start)  shift || true; cmd_start "${1:-}" ;;
  shell)  cmd_shell ;;
  verify) cmd_verify ;;
  hint)   shift || true; cmd_hint "${1:-1}" ;;
  reset)  cmd_reset ;;
  clean)  cmd_clean ;;
  brief)  cat "$LAB_ROOT/BRIEF.txt" ;;
  *)      say "usage: $0 {start|shell|verify|hint N|reset|clean|brief}"; exit 1 ;;
esac

# ==============================================================================
#  SOLUTION - do not read this until 'verify' has beaten you at least twice.
# ==============================================================================
#
#  The four faults map to four different access-management primitives. That is
#  the point of the exercise: "AccessDenied" is not one problem, it is a family
#  of problems, and each member is diagnosed with a different tool.
#
#  ---------------------------------------------------------------------------
#  STEP 0 - enter the lab and reproduce
#  ---------------------------------------------------------------------------
#      source ~/aws-clf-lab-2.3/env.sh
#      aws --profile deploy sts get-caller-identity
#
#      The config profile (ci-runner) could not be found
#
#  Read it literally. This is a CLIENT-side error (exit 255), not a service
#  error. Nothing was ever sent to AWS. The CLI could not build a credential
#  chain, so IAM never got a chance to say yes or no. Always separate "the call
#  never happened" from "the call happened and was denied".
#
#  ---------------------------------------------------------------------------
#  FAULT 1 - the profile chain is broken (source_profile)
#  ---------------------------------------------------------------------------
#  Diagnose:
#      aws configure list-profiles
#          auditor
#          ci
#          default
#          deploy
#          root
#      grep -A6 'profile deploy' "$AWS_CONFIG_FILE"
#
#  "deploy" declares role_arn + source_profile = ci-runner, and there is no
#  ci-runner profile. A role-assuming profile is a two-link chain:
#      source_profile  -> the long-lived identity that CALLS sts:AssumeRole
#      role_arn        -> the identity you END UP as, with temporary credentials
#
#  Fix - edit $AWS_CONFIG_FILE, section [profile deploy]:
#      -source_profile = ci-runner
#      +source_profile = ci
#
#  ---------------------------------------------------------------------------
#  FAULT 2 - the trust policy names a principal that no longer exists
#  ---------------------------------------------------------------------------
#  Re-run and the error changes shape - which is progress:
#      aws --profile deploy sts get-caller-identity
#      An error occurred (AccessDenied) when calling the AssumeRole operation:
#      User: arn:aws:iam::123456789012:user/ci is not authorized to perform:
#      sts:AssumeRole on resource: arn:aws:iam::123456789012:role/LabDeployRole
#
#  Now the call really was evaluated, and it was refused. Two policies decide an
#  AssumeRole and you must inspect both:
#      the caller's identity policy   -> "may ci call sts:AssumeRole?"
#      the role's TRUST policy        -> "does the role accept ci?"
#  In the same account, the trust policy alone is sufficient to grant it; the
#  identity policy is required for the cross-account case. Here the identity
#  policy (CiBaselinePolicy, Sid AssumeTheDeploymentRole) is fine, so look at
#  the role:
#
#      aws --profile ci iam get-role --role-name LabDeployRole
#
#      "Principal": { "AWS": "arn:aws:iam::123456789012:user/ci-runner-legacy" }
#
#  That user was deleted. Note a real-world detail this simulator does not
#  reproduce: when you delete a principal that a trust policy names, AWS
#  rewrites the Principal to an opaque unique ID such as "AIDAJQABLZS4A3QDU576Q"
#  because ARNs are re-usable and a recreated user must not silently inherit the
#  old trust. Seeing that string in a trust policy means exactly this fault.
#
#  Fix - edit iam/trust/LabDeployRole.json:
#      -"AWS": "arn:aws:iam::123456789012:user/ci-runner-legacy"
#      +"AWS": "arn:aws:iam::123456789012:user/ci"
#
#  In production this is:
#      aws iam update-assume-role-policy \
#          --role-name LabDeployRole \
#          --policy-document file://trust-policy.json
#
#  ---------------------------------------------------------------------------
#  FAULT 3 - the trust policy demands MFA that the profile cannot supply
#  ---------------------------------------------------------------------------
#  Same AccessDenied again. This is where people start deleting things. Do not.
#  The trust policy carries a second clause:
#
#      "Condition": {
#        "Bool":         { "aws:MultiFactorAuthPresent": "true" },
#        "NumericLessThan": { "aws:MultiFactorAuthAge": "3600" }
#      }
#
#  A condition key with no value never matches. The ci user HAS an MFA device:
#      aws --profile ci iam list-mfa-devices --user-name ci
#          "SerialNumber": "arn:aws:iam::123456789012:mfa/ci"
#  ...but the deploy profile never asks for a token code, so the STS session
#  carries aws:MultiFactorAuthPresent = false. Prove it in isolation by
#  simulating with and without the context key:
#
#      aws --profile ci iam simulate-principal-policy \
#          --policy-source-arn arn:aws:iam::123456789012:role/LabDeployRole \
#          --action-names s3:PutObject \
#          --resource-arns arn:aws:s3:::lab-artifacts-123456789012/builds/x \
#          --context-entries ContextKeyName=aws:MultiFactorAuthPresent,ContextKeyValues=true,ContextKeyType=boolean
#
#  Fix - add the MFA serial to [profile deploy] in $AWS_CONFIG_FILE:
#      +mfa_serial = arn:aws:iam::123456789012:mfa/ci
#
#  The CLI now prompts "Enter MFA code for arn:aws:iam::123456789012:mfa/ci:"
#  and passes it to sts:AssumeRole. Any six digits work here; export
#  AWS_LAB_MFA_CODE=123456 to run it unattended.
#
#      aws --profile deploy sts get-caller-identity
#      {
#          "UserId": "AROAJ2EXAMPLEROLEID1:ci-pipeline",
#          "Account": "123456789012",
#          "Arn": "arn:aws:sts::123456789012:assumed-role/LabDeployRole/ci-pipeline"
#      }
#
#  The ARN changed identity class: you are no longer user/ci, you are an
#  assumed-role session with TEMPORARY credentials. That is the whole point of
#  a role, and it is the CLF-level answer to "how should an application get
#  permissions in AWS" - a role, never an embedded access key.
#
#  ---------------------------------------------------------------------------
#  FAULT 4 - an explicit Deny in the permissions boundary
#  ---------------------------------------------------------------------------
#      echo "build $(date +%s)" > /tmp/artifact.txt
#      aws --profile deploy s3 cp /tmp/artifact.txt s3://lab-artifacts-123456789012/builds/artifact.txt
#
#      upload failed: ... An error occurred (AccessDenied) when calling the
#      PutObject operation: Access Denied
#
#  S3 gives you nothing. Four policies could be responsible - the SCP, the
#  bucket policy, the boundary, the identity policy - so ask IAM which one:
#
#      aws --profile ci iam simulate-principal-policy \
#          --policy-source-arn arn:aws:iam::123456789012:role/LabDeployRole \
#          --action-names s3:PutObject \
#          --resource-arns arn:aws:s3:::lab-artifacts-123456789012/builds/artifact.txt
#
#      "EvalDecision": "explicitDeny",
#      "MatchedStatements": [
#          { "SourcePolicyId": "DeployBoundary",
#            "SourcePolicyType": "Permissions Boundary",
#            "Sid": "ProtectImmutableArtifacts" } ],
#      "PermissionsBoundaryDecisionDetail": { "AllowedByPermissionsBoundary": false },
#      "OrganizationsDecisionDetail": { "AllowedByOrganizations": true }
#
#  Note that you ran the simulation as the ci USER, about the ROLE. The role
#  itself cannot run it - its boundary denies iam:* - which is correct design:
#  the principal that debugs permissions is not the principal that deploys.
#
#  Read the offending statement:
#      { "Sid": "ProtectImmutableArtifacts", "Effect": "Deny",
#        "Action": "s3:*", "Resource": "arn:aws:s3:::lab-artifacts-123456789012/*" }
#
#  It was meant to freeze published releases. As written it freezes the entire
#  bucket. Explicit Deny beats every Allow, everywhere, always - the identity
#  policy's WriteBuildArtifacts Allow and the bucket policy's AllowDeploymentRole
#  Allow are both irrelevant once this matches.
#
#  Fix - edit iam/boundaries/DeployBoundary.json, narrow the Resource:
#      -"Resource": "arn:aws:s3:::lab-artifacts-123456789012/*"
#      +"Resource": "arn:aws:s3:::lab-artifacts-123456789012/releases/*"
#
#  WRONG FIXES the grader catches, and why they are wrong:
#    * deleting the ProtectImmutableArtifacts statement -> releases/ becomes
#      writable; you turned an outage into a supply-chain problem.
#    * adding "s3:*" on "*" to DeployArtifactsPolicy -> the boundary still
#      denies, so it does not even work, and now the role is over-permissioned
#      the moment someone loosens the ceiling.
#    * "Principal": "*" in the trust policy -> anyone in any account may assume
#      your deployment role. Never write this in a trust policy.
#
#  Verify:
#      aws --profile deploy s3 cp /tmp/artifact.txt s3://lab-artifacts-123456789012/builds/artifact.txt
#      upload: /tmp/artifact.txt to s3://lab-artifacts-123456789012/builds/artifact.txt
#
#      aws --profile deploy s3 cp /tmp/artifact.txt s3://lab-artifacts-123456789012/releases/x.txt
#      upload failed: ... Access Denied          <- correct, the guardrail holds
#
#  ---------------------------------------------------------------------------
#  FAULT 5 - the finding that is not an outage: root credentials on the host
#  ---------------------------------------------------------------------------
#  Nothing is broken here, which is precisely why it survives. Find it the way
#  an auditor does:
#
#      aws --profile auditor iam generate-credential-report
#      aws --profile auditor iam get-credential-report --output text \
#          --query Content | base64 --decode
#
#      <root_account>,arn:aws:iam::123456789012:root,...,mfa_active=false,
#      access_key_1_active=true
#
#  Two findings in one row: the root user has an ACTIVE access key, and it has
#  no MFA. And someone copied that key onto this build host:
#
#      grep -n '\[root\]' "$AWS_SHARED_CREDENTIALS_FILE"
#
#  Fix here - remove the [root] profile block (all three lines) from
#  $AWS_SHARED_CREDENTIALS_FILE. Getting the credential off the host is the
#  first move, but it is not the remediation; the key still exists in AWS.
#
#  The real remediation, in order:
#    1. Sign in as the root user (or use centralized root access management in
#       AWS Organizations) and DELETE the root access keys. There is no IAM API
#       that manages root's keys for you - by design.
#    2. Enable MFA on the root user; prefer a hardware or passkey device.
#    3. Rotate anything that key could have touched and search CloudTrail for
#       its use.
#    4. Stop the recurrence: root is for the handful of tasks that require it
#       (closing the account, changing the account name or email, some support
#       plan changes). Day-to-day access should be human identities in IAM
#       Identity Center with short-lived credentials, and workloads should use
#       roles - the same lesson Fault 3 taught, one level up.
#       https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html
#       https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
#
#  Bonus finding, ungraded: the account password policy in this lab allows
#  6-character lowercase passwords with no expiry
#  (aws --profile auditor iam get-account-password-policy). Tightening it is
#  another CLF 2.3 capability - account-level password policy, distinct from
#  per-user permissions.
#
#  ---------------------------------------------------------------------------
#  WHAT TO CARRY INTO THE EXAM, AND INTO PRODUCTION
#  ---------------------------------------------------------------------------
#  * The evaluation order is not trivia, it is the debugging algorithm:
#      explicit Deny anywhere  ->  SCP must allow  ->  resource policy /
#      permissions boundary must allow  ->  identity policy must allow  ->
#      otherwise implicit Deny. Default is always deny.
#  * A permissions boundary and an SCP GRANT NOTHING. They are ceilings. The
#    effective permission is the intersection of every applicable policy.
#  * Roles + temporary credentials beat long-lived access keys, every time. An
#    access key in a file is a credential with no expiry and no accountability.
#  * MFA is enforceable as a CONDITION, not just as a login preference:
#    aws:MultiFactorAuthPresent / aws:MultiFactorAuthAge in a trust policy is
#    how "you may deploy, but only from an MFA-authenticated session" is written.
#  * The data plane will not explain a denial. iam:SimulatePrincipalPolicy,
#    CloudTrail and the policy documents will.
#  * Least privilege is a repair constraint, not a nice-to-have: a fix that
#    makes the error disappear by widening a policy is a regression that no
#    alarm will ever fire on.
# ==============================================================================