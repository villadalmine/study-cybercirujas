#!/usr/bin/env bash
#===============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) -- exam guide version 1.0
#  Domain 3: Cloud Technology and Services
#  Topic 3.1 -- Define methods of deploying and operating in the AWS Cloud
#  Exam weight of the parent domain item: 4.25
#
#  BREAK & FIX LABORATORY  --  "the console is not the only way in"
#
#  WHAT THIS TOPIC ACTUALLY ASKS OF YOU
#  ------------------------------------
#  Task statement 3.1 is about the *ways* you provision, deploy and operate:
#    * AWS Management Console  (interactive, human, not scriptable, not auditable
#      as code)
#    * AWS CLI                 (programmatic, scriptable, credential + config
#      resolution chain, region and endpoint resolution)
#    * AWS SDKs                (same resolution chain as the CLI: both are
#      botocore/aws-sdk on top of the same shared config files)
#    * Infrastructure as Code  (AWS CloudFormation templates, AWS CDK which
#      synthesizes CloudFormation, third-party IaC)
#    * Deployment models       (all-in cloud, hybrid, on-premises/VMware Cloud
#      on AWS) and connectivity (public internet, AWS Site-to-Site VPN,
#      AWS Direct Connect, VPC endpoints)
#    * One-time operations vs managed operations
#
#  Nearly every real "AWS is down for me" ticket at practitioner level is none
#  of those things: it is the *access method* being misconfigured -- a stale
#  environment variable, a profile that does not exist, a region that is not a
#  region, an endpoint the request never reaches, or a template that never
#  validated. This lab breaks exactly those, in that order.
#
#  SAFETY MODEL  (read this before running)
#  ----------------------------------------
#   * Everything lives under $LAB_ROOT (default ~/aws-clf-3.1-lab).
#   * Your real ~/.aws/config and ~/.aws/credentials are NEVER read, written,
#     moved or backed up. The lab exports AWS_CONFIG_FILE and
#     AWS_SHARED_CREDENTIALS_FILE to point somewhere else entirely.
#   * No real AWS account is contacted and no real credentials are needed. A
#     local mock control-plane endpoint on 127.0.0.1 answers just enough AWS
#     Query protocol for `sts get-caller-identity` and a handful of
#     `cloudformation` verbs. Nothing costs money.
#   * No system service, no package install, no root, no changes outside
#     $LAB_ROOT.
#   * Still: RUN ONLY ON A DISPOSABLE LAB VM. Break & fix habits should be
#     built where the blast radius is zero.
#
#  USAGE
#    ./break-fix-3.1.sh            # preflight, build lab, prove it healthy, break it
#    ./break-fix-3.1.sh verify     # grade your repair (run it from your lab shell)
#    ./break-fix-3.1.sh hint       # one more hint each time you ask
#    ./break-fix-3.1.sh status     # what is running, what the CLI currently sees
#    ./break-fix-3.1.sh clean      # stop the mock and delete $LAB_ROOT
#
#  ENV OVERRIDES
#    LAB_ROOT=/path        where the lab is built      (default ~/aws-clf-3.1-lab)
#    LAB_PORT=4566         mock endpoint port          (default 4566)
#    I_KNOW_THIS_IS_A_DISPOSABLE_LAB_VM=yes            skip the interactive guard
#
#  OFFICIAL SOURCES
#    AWS Certified Cloud Practitioner (CLF-C02) Exam Guide
#      https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#    Configuration and credential file settings (AWS CLI User Guide)
#      https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html
#    Configuration settings and precedence
#      https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html
#    Service-specific and global endpoint configuration
#      https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html
#    AWS CloudFormation template anatomy
#      https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/template-anatomy.html
#    ValidateTemplate API reference
#      https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/API_ValidateTemplate.html
#    Signature Version 4 credential scope
#      https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html
#===============================================================================

set -euo pipefail

LAB_ROOT="${LAB_ROOT:-$HOME/aws-clf-3.1-lab}"
LAB_PORT="${LAB_PORT:-4566}"
DECOY_PORT=4599
LAB_PROFILE="clf-lab"
LAB_REGION="us-east-1"
LAB_ACCOUNT="123456789012"
STACK_NAME="clf-lab-net"
TEMPLATE_REL="iac/vpc-lab.yaml"
MOCK_PY="$LAB_ROOT/mock/awslab_mock.py"
PID_FILE="$LAB_ROOT/run/mock.pid"
HINT_FILE="$LAB_ROOT/run/hint.level"
FAILS=0

if [[ -t 1 ]]; then
    B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YEL=$'\033[33m'; CYA=$'\033[36m'; N=$'\033[0m'
else
    B=""; DIM=""; RED=""; GRN=""; YEL=""; CYA=""; N=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$CYA" "$N" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$N" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$N" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$DIM" "-------------------------------------------------------------------------------" "$N"; }

pass_check() { printf '  %s[ PASS ]%s %s\n' "$GRN" "$N" "$1"; return 0; }
fail_check() {
    printf '  %s[ FAIL ]%s %s\n' "$RED" "$N" "$1"
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2" | sed 's/^/           /'
    fi
    FAILS=$((FAILS + 1))
    return 0
}

#------------------------------------------------------------------------------
# Guards and preflight
#------------------------------------------------------------------------------

require_disposable_vm() {
    if [[ "${I_KNOW_THIS_IS_A_DISPOSABLE_LAB_VM:-no}" == "yes" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Non-interactive run. Re-run with I_KNOW_THIS_IS_A_DISPOSABLE_LAB_VM=yes if this really is a throwaway VM."
    fi
    rule
    say "${B}This script writes only under:${N} $LAB_ROOT"
    say "It does not touch ~/.aws, does not need root, and contacts no real AWS account."
    say "Even so, run break & fix drills only on a machine you can delete."
    rule
    local answer=""
    read -r -p "Type 'disposable' to confirm this is a lab VM: " answer
    [[ "$answer" == "disposable" ]] || die "Not confirmed. Nothing was created."
    return 0
}

version_ge() { # version_ge FOUND MINIMUM
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

port_is_open() {
    python3 - "$1" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(0.4)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
}

preflight() {
    info "Preflight"

    command -v python3 >/dev/null 2>&1 || die "python3 not found. The mock endpoint and the template linter need it."
    python3 -c 'import yaml' 2>/dev/null || die \
"PyYAML not found. CloudFormation templates are YAML, so the lab needs a YAML parser.
    Fedora/RHEL : sudo dnf install -y python3-pyyaml
    Debian/Ubuntu: sudo apt-get install -y python3-yaml
    Amazon Linux: sudo dnf install -y python3-pyyaml
    venv/pip    : pip install pyyaml"
    ok "python3 $(python3 -c 'import sys;print(".".join(map(str,sys.version_info[:3])))') with PyYAML"

    command -v aws >/dev/null 2>&1 || die \
"AWS CLI not found. Install AWS CLI v2 (the topic-3.1 'programmatic access' method):
    curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install
  Docs: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"

    local raw major_minor
    raw="$(aws --version 2>&1 | head -n1)"
    major_minor="$(printf '%s' "$raw" | sed -n 's#^aws-cli/\([0-9.]*\).*#\1#p')"
    [[ -n "$major_minor" ]] || die "Could not parse 'aws --version' output: $raw"
    case "$major_minor" in
        2.*) version_ge "$major_minor" "2.13.0" || die \
"AWS CLI $major_minor is too old for this lab. It needs >= 2.13.0, the first release
  that honours 'endpoint_url' inside the shared config file. Upgrade the CLI." ;;
        1.*) version_ge "$major_minor" "1.29.0" || die \
"AWS CLI $major_minor is too old for this lab. It needs >= 1.29.0 (botocore 1.31+)
  for 'endpoint_url' support in the shared config file. Upgrade the CLI." ;;
        *) die "Unrecognised AWS CLI version: $raw" ;;
    esac
    ok "AWS CLI $major_minor  ($raw)"

    if [[ "$(id -u)" == "0" ]]; then
        warn "Running as root. Nothing here needs root; a non-privileged user is the better habit."
    fi

    if port_is_open "$LAB_PORT" && [[ ! -f "$PID_FILE" ]]; then
        die "TCP 127.0.0.1:$LAB_PORT is already in use by something that is not this lab.
  Free it, or re-run with LAB_PORT=<free port>."
    fi
    ok "TCP 127.0.0.1:$LAB_PORT available for the mock endpoint"
    return 0
}

#------------------------------------------------------------------------------
# Lab construction
#------------------------------------------------------------------------------

write_mock() {
    mkdir -p "$LAB_ROOT/mock"
    cat > "$MOCK_PY" <<'PY'
#!/usr/bin/env python3
"""Offline stand-in for two AWS control-plane endpoints: STS and CloudFormation.

It speaks just enough of the AWS Query protocol for the commands this lab uses
(and falls back to JSON if a future botocore migrates these services), so the
student sees real AWS CLI behaviour -- real error codes, real error wording --
without an AWS account, credentials, network access or spend.

Deliberate design notes, because they are the teaching point:

  * SigV4 signatures are NOT verified. What IS verified is the *credential
    scope* in the Authorization header: `Credential=<AKID>/<date>/<region>/
    <service>/aws4_request`. A request signed for a region that does not exist
    is rejected exactly the way AWS rejects it. That is why a bogus region is a
    hard failure and not a cosmetic one.

  * ValidateTemplate / CreateStack really parse the template and reproduce
    CloudFormation's own error strings ("Template format error: ...",
    "Template error: Unresolved resource dependencies [...] in the Resources
    block of the template"), so what you learn here transfers verbatim.

Not a general-purpose AWS emulator. For that, see LocalStack. This is a prop.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from xml.sax.saxutils import escape

try:
    import yaml
except ImportError:  # pragma: no cover - preflight already checked this
    raise SystemExit("PyYAML is required: pip install pyyaml")

ACCOUNT = "123456789012"
USER_ID = "AIDACKCEVSQ6C2EXAMPLE"
PRINCIPAL_ARN = f"arn:aws:iam::{ACCOUNT}:user/clf-lab-student"
PARTITION = "aws"

# The lab pretends the AWS partition has three regions. Anything else is not a
# region, and the endpoint says so the way the real one does.
VALID_REGIONS = {"us-east-1", "us-west-2", "eu-west-1"}

NAMESPACES = {
    "sts": "https://sts.amazonaws.com/doc/2011-06-15/",
    "cloudformation": "http://cloudformation.amazonaws.com/doc/2010-05-15/",
}

CREDENTIAL_RE = re.compile(
    r"Credential=(?P<akid>[^/\s]+)/(?P<date>\d{8})/(?P<region>[^/\s]+)/"
    r"(?P<service>[^/\s]+)/aws4_request"
)

PHYSICAL_ID_PREFIX = {
    "AWS::EC2::VPC": "vpc",
    "AWS::EC2::Subnet": "subnet",
    "AWS::EC2::SecurityGroup": "sg",
    "AWS::EC2::RouteTable": "rtb",
    "AWS::EC2::InternetGateway": "igw",
}

PSEUDO_PARAMETERS = {
    "AWS::AccountId",
    "AWS::NoValue",
    "AWS::NotificationARNs",
    "AWS::Partition",
    "AWS::Region",
    "AWS::StackId",
    "AWS::StackName",
    "AWS::URLSuffix",
}

# The shape the graded exercise must keep. Fixing the template by deleting the
# hard parts is not fixing the template.
REQUIRED_RESOURCES = {
    "LabVpc": "AWS::EC2::VPC",
    "LabSubnet": "AWS::EC2::Subnet",
    "LabSecurityGroup": "AWS::EC2::SecurityGroup",
}

STATE_LOCK = threading.Lock()
STACKS: dict = {}
STATE_PATH = None
LOG_PATH = None


# --------------------------------------------------------------------------- #
# YAML with CloudFormation short-form intrinsic functions
# --------------------------------------------------------------------------- #

class CfnLoader(yaml.SafeLoader):
    """SafeLoader refuses unknown tags, and every CloudFormation short form
    (!Ref, !GetAtt, !Sub, !Join ...) is a YAML tag. Map them to the long form
    the way the real parser does: `!Ref Foo` -> {"Ref": "Foo"}."""


def _intrinsic(loader, tag_suffix, node):
    key = "Ref" if tag_suffix == "Ref" else "Fn::" + tag_suffix
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    else:
        value = loader.construct_mapping(node, deep=True)
    if key == "Fn::GetAtt" and isinstance(value, str):
        value = value.split(".", 1)
    return {key: value}


CfnLoader.add_multi_constructor("!", _intrinsic)


class AwsError(Exception):
    def __init__(self, code, message, status=400, err_type="Sender"):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status
        self.err_type = err_type


# --------------------------------------------------------------------------- #
# Template validation -- mirrors CloudFormation's own messages
# --------------------------------------------------------------------------- #

def parse_template(body: str) -> dict:
    if not body or not body.strip():
        raise AwsError("ValidationError", "Template format error: unsupported structure.")
    try:
        doc = yaml.load(body, Loader=CfnLoader)
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        where = f" (line {mark.line + 1}, column {mark.column + 1})" if mark else ""
        problem = getattr(exc, "problem", None) or "invalid document"
        raise AwsError(
            "ValidationError",
            f"Template format error: YAML not well-formed.{where}: {problem}",
        )
    if not isinstance(doc, dict):
        raise AwsError("ValidationError", "Template format error: unsupported structure.")
    return doc


def _collect_refs(node, block, found):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "Ref" and isinstance(value, str):
                found.append((value, block))
            elif key == "Fn::GetAtt":
                if isinstance(value, list) and value and isinstance(value[0], str):
                    found.append((value[0], block))
                elif isinstance(value, str):
                    found.append((value.split(".", 1)[0], block))
            else:
                _collect_refs(value, block, found)
    elif isinstance(node, list):
        for item in node:
            _collect_refs(item, block, found)


def validate_template(body: str) -> dict:
    """Returns the parsed template. Raises AwsError with CloudFormation wording."""
    doc = parse_template(body)

    resources = doc.get("Resources")
    if not isinstance(resources, dict) or not resources:
        raise AwsError(
            "ValidationError",
            "Template format error: At least one Resources member must be defined.",
        )

    for logical_id, definition in resources.items():
        if not isinstance(definition, dict):
            raise AwsError(
                "ValidationError",
                f"Template format error: [/Resources/{logical_id}] resource definition is malformed.",
            )
        if "Type" not in definition:
            raise AwsError(
                "ValidationError",
                "Template format error: Every Resources object must contain a Type member.",
            )
        rtype = definition["Type"]
        if not isinstance(rtype, str) or rtype.count("::") < 2:
            raise AwsError(
                "ValidationError",
                f"Template format error: Unrecognized resource types: [{rtype}]",
            )

    parameters = doc.get("Parameters") or {}
    if not isinstance(parameters, dict):
        raise AwsError("ValidationError", "Template format error: unsupported structure.")

    known = set(resources) | set(parameters) | PSEUDO_PARAMETERS
    found: list = []
    _collect_refs(resources, "Resources", found)
    _collect_refs(doc.get("Outputs") or {}, "Outputs", found)

    for block in ("Resources", "Outputs"):
        missing = sorted({name for name, blk in found if blk == block and name not in known})
        if missing:
            raise AwsError(
                "ValidationError",
                "Template error: Unresolved resource dependencies ["
                + ", ".join(missing)
                + f"] in the {block} block of the template",
            )
    return doc


def physical_id(stack_name: str, logical_id: str, rtype: str) -> str:
    digest = hashlib.sha1(f"{stack_name}/{logical_id}".encode()).hexdigest()[:16]
    return f"{PHYSICAL_ID_PREFIX.get(rtype, 'res')}-0{digest}"


# --------------------------------------------------------------------------- #
# Operations
# --------------------------------------------------------------------------- #

def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def _save_state():
    if not STATE_PATH:
        return
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(STACKS, handle)
    os.replace(tmp, STATE_PATH)


def _load_state():
    global STACKS
    if STATE_PATH and os.path.exists(STATE_PATH):
        try:
            with open(STATE_PATH, encoding="utf-8") as handle:
                STACKS = json.load(handle)
        except (OSError, ValueError):
            STACKS = {}


def op_get_caller_identity(params, ctx):
    return {"UserId": USER_ID, "Account": ACCOUNT, "Arn": PRINCIPAL_ARN}


def op_validate_template(params, ctx):
    doc = validate_template(params.get("TemplateBody", ""))
    parameters = []
    for key, spec in (doc.get("Parameters") or {}).items():
        spec = spec if isinstance(spec, dict) else {}
        parameters.append(
            {
                "ParameterKey": key,
                "DefaultValue": str(spec.get("Default", "")),
                "NoEcho": bool(spec.get("NoEcho", False)),
                "Description": str(spec.get("Description", "")),
            }
        )
    return {
        "Description": str(doc.get("Description", "")),
        "Parameters": parameters,
        "Capabilities": [],
    }


def op_create_stack(params, ctx):
    name = params.get("StackName", "")
    if not name:
        raise AwsError("ValidationError", "1 validation error detected: Value null at 'stackName' failed to satisfy constraint: Member must not be null")
    doc = validate_template(params.get("TemplateBody", ""))
    with STATE_LOCK:
        if name in STACKS:
            raise AwsError("AlreadyExistsException", f"Stack [{name}] already exists")
        stack_id = (
            f"arn:{PARTITION}:cloudformation:{ctx['region']}:{ACCOUNT}:stack/{name}/"
            + hashlib.sha1(name.encode()).hexdigest()[:12]
        )
        resources = []
        for logical_id, definition in doc["Resources"].items():
            rtype = definition["Type"]
            resources.append(
                {
                    "StackName": name,
                    "StackId": stack_id,
                    "LogicalResourceId": logical_id,
                    "PhysicalResourceId": physical_id(name, logical_id, rtype),
                    "ResourceType": rtype,
                    "Timestamp": _now(),
                    "ResourceStatus": "CREATE_COMPLETE",
                }
            )
        by_logical = {r["LogicalResourceId"]: r["PhysicalResourceId"] for r in resources}
        outputs = []
        for key, spec in (doc.get("Outputs") or {}).items():
            spec = spec if isinstance(spec, dict) else {}
            value = spec.get("Value")
            if isinstance(value, dict) and "Ref" in value:
                value = by_logical.get(value["Ref"], str(value["Ref"]))
            outputs.append(
                {
                    "OutputKey": key,
                    "OutputValue": str(value),
                    "Description": str(spec.get("Description", "")),
                }
            )
        STACKS[name] = {
            "StackId": stack_id,
            "StackName": name,
            "Description": str(doc.get("Description", "")),
            "CreationTime": _now(),
            "StackStatus": "CREATE_COMPLETE",
            "DisableRollback": False,
            "EnableTerminationProtection": False,
            "Outputs": outputs,
            "Tags": [],
            "_resources": resources,
        }
        _save_state()
    return {"StackId": stack_id}


def _public_stack(stack):
    return {k: v for k, v in stack.items() if not k.startswith("_")}


def op_describe_stacks(params, ctx):
    name = params.get("StackName")
    with STATE_LOCK:
        if name:
            if name not in STACKS:
                raise AwsError("ValidationError", f"Stack with id {name} does not exist")
            return {"Stacks": [_public_stack(STACKS[name])]}
        return {"Stacks": [_public_stack(s) for s in STACKS.values()]}


def op_describe_stack_resources(params, ctx):
    name = params.get("StackName")
    with STATE_LOCK:
        if not name or name not in STACKS:
            raise AwsError("ValidationError", f"Stack with id {name} does not exist")
        return {"StackResources": list(STACKS[name]["_resources"])}


def op_list_stacks(params, ctx):
    with STATE_LOCK:
        return {
            "StackSummaries": [
                {
                    "StackId": s["StackId"],
                    "StackName": s["StackName"],
                    "CreationTime": s["CreationTime"],
                    "StackStatus": s["StackStatus"],
                }
                for s in STACKS.values()
            ]
        }


def op_delete_stack(params, ctx):
    name = params.get("StackName", "")
    with STATE_LOCK:
        STACKS.pop(name, None)  # DeleteStack is idempotent in the real API too
        _save_state()
    return {}


OPERATIONS = {
    "GetCallerIdentity": (op_get_caller_identity, "sts"),
    "ValidateTemplate": (op_validate_template, "cloudformation"),
    "CreateStack": (op_create_stack, "cloudformation"),
    "DescribeStacks": (op_describe_stacks, "cloudformation"),
    "DescribeStackResources": (op_describe_stack_resources, "cloudformation"),
    "ListStacks": (op_list_stacks, "cloudformation"),
    "DeleteStack": (op_delete_stack, "cloudformation"),
}


# --------------------------------------------------------------------------- #
# Serialization: AWS Query XML, with a JSON fallback
# --------------------------------------------------------------------------- #

def to_xml(value, name):
    if isinstance(value, dict):
        inner = "".join(to_xml(v, k) for k, v in value.items())
        return f"<{name}>{inner}</{name}>"
    if isinstance(value, list):
        inner = "".join(to_xml(item, "member") for item in value)
        return f"<{name}>{inner}</{name}>"
    if isinstance(value, bool):
        return f"<{name}>{'true' if value else 'false'}</{name}>"
    return f"<{name}>{escape(str(value))}</{name}>"


def query_response(action, service, result):
    body = "".join(to_xml(v, k) for k, v in result.items())
    result_element = f"<{action}Result>{body}</{action}Result>" if result else ""
    request_id = hashlib.sha1(f"{action}{_now()}".encode()).hexdigest()[:32]
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f'<{action}Response xmlns="{NAMESPACES[service]}">'
        f"{result_element}"
        f"<ResponseMetadata><RequestId>{request_id}</RequestId></ResponseMetadata>"
        f"</{action}Response>"
    )


def query_error(err: AwsError, service):
    request_id = hashlib.sha1(f"{err.code}{_now()}".encode()).hexdigest()[:32]
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f'<ErrorResponse xmlns="{NAMESPACES.get(service, NAMESPACES["sts"])}">'
        f"<Error><Type>{err.err_type}</Type><Code>{escape(err.code)}</Code>"
        f"<Message>{escape(err.message)}</Message></Error>"
        f"<RequestId>{request_id}</RequestId></ErrorResponse>"
    )


def _log(line):
    if not LOG_PATH:
        return
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(f"{_now()} {line}\n")
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "AwsLabMock/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep stdout clean; we log ourselves
        return

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def _send(self, status, payload, content_type):
        raw = payload.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("x-amzn-RequestId", hashlib.sha1(raw).hexdigest()[:32])
        self.end_headers()
        self.wfile.write(raw)

    def _handle(self):
        parsed = urlparse(self.path)
        if parsed.path.rstrip("/") == "/ping":
            self._send(200, "pong", "text/plain")
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        content_type = self.headers.get("Content-Type", "")
        target = self.headers.get("X-Amz-Target", "")
        json_mode = bool(target) or "json" in content_type

        if json_mode:
            try:
                params = json.loads(raw or "{}")
            except ValueError:
                params = {}
            action = target.split(".")[-1] if target else str(params.get("Action", ""))
        else:
            source = raw if raw else parsed.query
            params = {
                k: v[-1]
                for k, v in parse_qs(source, keep_blank_values=True).items()
            }
            action = params.get("Action", "")

        service = "sts"
        region = None
        match = CREDENTIAL_RE.search(self.headers.get("Authorization", ""))
        if match:
            region = match.group("region")
            service = match.group("service")

        try:
            if region is not None and region not in VALID_REGIONS:
                # Real AWS wording. A region string is part of the signature,
                # so an invalid one is an authentication failure, not a typo.
                raise AwsError(
                    "InvalidSignatureException",
                    f"Credential should be scoped to a valid region, not '{region}'.",
                    status=403,
                )
            if action not in OPERATIONS:
                raise AwsError(
                    "InvalidAction",
                    f"Could not find operation {action or '<none>'} for version 2011-06-15",
                )
            handler, service = OPERATIONS[action]
            result = handler(params, {"region": region or "us-east-1"})
            _log(f"OK   action={action} region={region} service={service}")
            if json_mode:
                self._send(200, json.dumps(result), "application/x-amz-json-1.1")
            else:
                self._send(200, query_response(action, service, result), "text/xml")
        except AwsError as err:
            _log(f"ERR  action={action} region={region} code={err.code} msg={err.message}")
            if json_mode:
                payload = json.dumps({"__type": err.code, "message": err.message})
                self._send(err.status, payload, "application/x-amz-json-1.1")
            else:
                self._send(err.status, query_error(err, service), "text/xml")
        except Exception as exc:  # pragma: no cover - defensive
            _log(f"BUG  action={action} {exc!r}")
            err = AwsError("InternalFailure", str(exc), status=500, err_type="Receiver")
            self._send(500, query_error(err, "sts"), "text/xml")


# --------------------------------------------------------------------------- #
# Offline template linter (used by the grader)
# --------------------------------------------------------------------------- #

def check_template(path) -> int:
    try:
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
    except OSError as exc:
        print(f"unreadable template: {exc}")
        return 2
    try:
        doc = validate_template(body)
    except AwsError as err:
        print(f"{err.code}: {err.message}")
        return 1

    problems = []
    resources = doc.get("Resources", {})
    for logical_id, expected_type in REQUIRED_RESOURCES.items():
        if logical_id not in resources:
            problems.append(f"required resource '{logical_id}' is missing")
        elif resources[logical_id].get("Type") != expected_type:
            problems.append(
                f"resource '{logical_id}' must be of type {expected_type}, found "
                f"{resources[logical_id].get('Type')!r}"
            )
    subnet = resources.get("LabSubnet", {})
    vpc_ref = (subnet.get("Properties") or {}).get("VpcId")
    if vpc_ref != {"Ref": "LabVpc"}:
        problems.append(
            "LabSubnet.Properties.VpcId must be '!Ref LabVpc' (a real dependency, "
            f"not a hardcoded id); found {vpc_ref!r}"
        )
    if problems:
        for problem in problems:
            print(f"shape: {problem}")
        return 1
    print("template is valid and keeps the required shape")
    return 0


def main():
    global STATE_PATH, LOG_PATH
    parser = argparse.ArgumentParser(description="Offline AWS control-plane prop for the CLF-C02 3.1 lab")
    parser.add_argument("--port", type=int, default=4566)
    parser.add_argument("--state", default=None)
    parser.add_argument("--log", default=None)
    parser.add_argument("--check-template", default=None, metavar="PATH")
    args = parser.parse_args()

    if args.check_template:
        sys.exit(check_template(args.check_template))

    STATE_PATH = args.state
    LOG_PATH = args.log
    _load_state()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    _log(f"listening on 127.0.0.1:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
PY
    chmod 0755 "$MOCK_PY"
    return 0
}

write_good_template() {
    mkdir -p "$LAB_ROOT/iac"
    cat > "$LAB_ROOT/$TEMPLATE_REL" <<'YAML'
AWSTemplateFormatVersion: '2010-09-09'
Description: CLF-C02 3.1 lab - minimal network stack, deployed as code

Parameters:
  VpcCidr:
    Type: String
    Default: 10.20.0.0/16
    Description: CIDR block for the lab VPC

Resources:
  LabVpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - Key: Name
          Value: clf-lab-vpc

  LabSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref LabVpc
      CidrBlock: 10.20.1.0/24
      Tags:
        - Key: Name
          Value: clf-lab-subnet

  LabSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Lab security group with no ingress
      VpcId: !Ref LabVpc
      Tags:
        - Key: Name
          Value: clf-lab-sg

Outputs:
  VpcId:
    Description: Physical id of the VPC created by this stack
    Value: !Ref LabVpc
  SubnetId:
    Description: Physical id of the subnet created by this stack
    Value: !Ref LabSubnet
YAML
    return 0
}

write_broken_template() {
    # Three defects, discovered in this order because that is the order the
    # template engine processes them: lexical -> structural -> referential.
    cat > "$LAB_ROOT/$TEMPLATE_REL" <<'YAML'
AWSTemplateFormatVersion: '2010-09-09'
Description: CLF-C02 3.1 lab - minimal network stack, deployed as code

Parameters:
  VpcCidr:
    Type: String
    Default: 10.20.0.0/16
    Description: CIDR block for the lab VPC

Resources:
  LabVpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsSupport: true
      EnableDnsHostnames: true
       Tags:
        - Key: Name
          Value: clf-lab-vpc

  LabSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref LabVPC
      CidrBlock: 10.20.1.0/24
      Tags:
        - Key: Name
          Value: clf-lab-subnet

  LabSecurityGroup:
    Properties:
      GroupDescription: Lab security group with no ingress
      VpcId: !Ref LabVpc
      Tags:
        - Key: Name
          Value: clf-lab-sg

Outputs:
  VpcId:
    Description: Physical id of the VPC created by this stack
    Value: !Ref LabVpc
  SubnetId:
    Description: Physical id of the subnet created by this stack
    Value: !Ref LabSubnet
YAML
    return 0
}

write_config_healthy() {
    mkdir -p "$LAB_ROOT/aws"
    cat > "$LAB_ROOT/aws/config" <<EOF
# Shared config file for the lab -- this is NOT ~/.aws/config.
# Docs: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html
[profile $LAB_PROFILE]
region = $LAB_REGION
output = json
endpoint_url = http://127.0.0.1:$LAB_PORT
EOF

    cat > "$LAB_ROOT/aws/credentials" <<'EOF'
# Fake, inert, local-only. No AKIA prefix on purpose so secret scanners do not
# have to think about it. The mock endpoint never checks the secret.
[clf-lab]
aws_access_key_id = LABKEYIDEXAMPLE00001
aws_secret_access_key = labSecretExampleValueNotUsableAnywhere000
EOF
    chmod 0600 "$LAB_ROOT/aws/credentials"

    cat > "$LAB_ROOT/lab.env" <<EOF
# Source this in every shell you use for the lab:  source $LAB_ROOT/lab.env
# It redirects the AWS CLI and every AWS SDK away from ~/.aws and towards the
# lab's own files, so nothing you do here can touch a real account.
export LAB_ROOT="$LAB_ROOT"
export AWS_CONFIG_FILE="\$LAB_ROOT/aws/config"
export AWS_SHARED_CREDENTIALS_FILE="\$LAB_ROOT/aws/credentials"
export AWS_PROFILE="$LAB_PROFILE"
export AWS_PAGER=""
EOF
    return 0
}

#------------------------------------------------------------------------------
# Mock endpoint lifecycle
#------------------------------------------------------------------------------

stop_mock() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.2
            done
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
    return 0
}

start_mock() {
    stop_mock
    mkdir -p "$LAB_ROOT/run" "$LAB_ROOT/logs"
    nohup python3 "$MOCK_PY" \
        --port "$LAB_PORT" \
        --state "$LAB_ROOT/run/stacks.json" \
        --log "$LAB_ROOT/logs/requests.log" \
        >>"$LAB_ROOT/logs/mock.out" 2>&1 &
    echo $! > "$PID_FILE"
    disown 2>/dev/null || true

    local tries=0
    until port_is_open "$LAB_PORT"; do
        tries=$((tries + 1))
        if [[ $tries -gt 40 ]]; then
            die "Mock endpoint failed to start. See $LAB_ROOT/logs/mock.out"
        fi
        sleep 0.25
    done
    return 0
}

in_lab_env() { # run a command with the pristine lab environment
    (
        set +u
        # shellcheck disable=SC1090
        . "$LAB_ROOT/lab.env"
        set -u
        "$@"
    )
}

#------------------------------------------------------------------------------
# break: build, prove healthy, then break
#------------------------------------------------------------------------------

prove_healthy() {
    info "Baseline: proving the lab works before breaking it"
    local out account

    if ! out="$(in_lab_env aws sts get-caller-identity --output json 2>&1)"; then
        say "$out"
        die "Baseline failed at sts:GetCallerIdentity. Not breaking a system that is already broken."
    fi
    account="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' 2>/dev/null || true)"
    [[ "$account" == "$LAB_ACCOUNT" ]] || die "Baseline identity mismatch (got '${account:-none}')."
    ok "aws sts get-caller-identity -> account $account, arn arn:aws:iam::$LAB_ACCOUNT:user/clf-lab-student"

    if ! out="$(in_lab_env aws cloudformation validate-template \
            --template-body "file://$LAB_ROOT/$TEMPLATE_REL" --output json 2>&1)"; then
        say "$out"
        die "Baseline failed at cloudformation:ValidateTemplate."
    fi
    ok "aws cloudformation validate-template -> valid (2 parameters resolved, 3 resources)"

    if ! out="$(in_lab_env aws cloudformation create-stack --stack-name clf-lab-preflight \
            --template-body "file://$LAB_ROOT/$TEMPLATE_REL" --output json 2>&1)"; then
        say "$out"
        die "Baseline failed at cloudformation:CreateStack."
    fi
    in_lab_env aws cloudformation delete-stack --stack-name clf-lab-preflight >/dev/null 2>&1 || true
    ok "aws cloudformation create-stack / delete-stack -> round trip OK"
    rule
    return 0
}

apply_breakage() {
    info "Introducing the faults"

    # FAULT FAMILY 1 -- the environment layer wins, and it is wrong.
    # This is what a stale CI job, a copy-pasted onboarding snippet or a
    # half-finished `aws configure export-credentials` leaves behind.
    cat >> "$LAB_ROOT/lab.env" <<'EOF'

# --- appended by "platform automation" during onboarding -----------------
export AWS_PROFILE="ghost-admin"
export AWS_ACCESS_KEY_ID="LEFTOVERKEYFROMCI001"
export AWS_DEFAULT_REGION="us-east-99"
# ------------------------------------------------------------------------
EOF

    # FAULT FAMILY 2 -- the request is well formed and goes nowhere.
    # Same class of failure as a VPC endpoint pointing at the wrong service, a
    # Direct Connect / VPN route that never came up, or a proxy on the wrong
    # port: the client is fine, the path is not.
    sed -i "s#^endpoint_url = .*#endpoint_url = http://127.0.0.1:$DECOY_PORT#" "$LAB_ROOT/aws/config"

    # FAULT FAMILY 3 -- infrastructure as code that was never validated.
    write_broken_template

    ok "faults in place"
    return 0
}

briefing() {
    local out="$LAB_ROOT/BRIEFING.txt"
    {
        rule
        say "${B}CLF-C02 3.1 -- BREAK & FIX: methods of deploying and operating in the AWS Cloud${N}"
        rule
        say ""
        say "${B}SCENARIO${N}"
        say "  You inherited a workstation that is supposed to drive AWS three ways:"
        say "  the CLI for ad-hoc operations, the SDK/CLI credential chain shared with"
        say "  every automation on the box, and CloudFormation for anything that must"
        say "  be reproducible. This morning nothing works, and the AWS Management"
        say "  Console is not an option -- you are on a headless VM, and the point of"
        say "  the exercise is that every console click has a programmatic equivalent."
        say ""
        say "  Nobody knows what changed. There is no ticket. There is a shell profile"
        say "  someone appended to, a config file someone edited, and a template someone"
        say "  committed without validating."
        say ""
        say "${B}FIRST, OPEN YOUR LAB SHELL${N}"
        say "    ${CYA}source $LAB_ROOT/lab.env${N}"
        say "    ${CYA}cd $LAB_ROOT${N}"
        say ""
        say "${B}SYMPTOMS YOU WILL SEE (in this order -- each fix reveals the next)${N}"
        say ""
        say "  1. Any aws command, even ${CYA}aws configure list${N}, dies before it starts:"
        say "     ${DIM}The config profile (ghost-admin) could not be found${N}"
        say ""
        say "  2. Then the CLI finds a profile but refuses to sign:"
        say "     ${DIM}Partial credentials found in env, missing: AWS_SECRET_ACCESS_KEY${N}"
        say ""
        say "  3. Then the request is built correctly and never arrives:"
        say "     ${DIM}Could not connect to the endpoint URL: \"http://127.0.0.1:$DECOY_PORT/\"${N}"
        say ""
        say "  4. Then it arrives and is rejected at the door:"
        say "     ${DIM}An error occurred (InvalidSignatureException) when calling the${N}"
        say "     ${DIM}GetCallerIdentity operation: Credential should be scoped to a valid${N}"
        say "     ${DIM}region, not 'us-east-99'.${N}"
        say ""
        say "  5. And when identity finally works, the deployment method does not:"
        say "     ${DIM}An error occurred (ValidationError) when calling the ValidateTemplate${N}"
        say "     ${DIM}operation: Template format error: YAML not well-formed. (line ..)${N}"
        say "     followed by two more template errors behind it."
        say ""
        say "${B}YOUR MISSION${N}"
        say "  Make all five of these true, without passing --profile, --region or"
        say "  --endpoint-url on the command line (the grader runs bare commands, and"
        say "  a flag you type every time is not a fix -- it is a workaround):"
        say ""
        say "   [1] No AWS credential or region setting comes from the environment."
        say "       ${CYA}aws configure list${N} must show access_key and region sourced from"
        say "       the config/credentials files, not from 'env'."
        say "   [2] ${CYA}aws sts get-caller-identity${N} returns account $LAB_ACCOUNT."
        say "   [3] The effective region is $LAB_REGION and the effective endpoint is"
        say "       http://127.0.0.1:$LAB_PORT."
        say "   [4] ${CYA}aws cloudformation validate-template --template-body file://$TEMPLATE_REL${N}"
        say "       succeeds, with LabVpc / LabSubnet / LabSecurityGroup still present"
        say "       and LabSubnet still depending on the VPC via !Ref."
        say "   [5] Stack ${B}$STACK_NAME${N} exists in CREATE_COMPLETE, created from that template."
        say ""
        say "${B}RULES${N}"
        say "  * Do not edit mock/awslab_mock.py. It is the AWS side of the wire; you do"
        say "    not get to patch AWS."
        say "  * Do not delete resources from the template to make it validate."
        say "  * Everything you need is in \$LAB_ROOT plus the AWS docs."
        say ""
        say "${B}TOOLS OF THE TRADE${N}"
        say "    ${CYA}aws configure list${N}              which setting came from where"
        say "    ${CYA}aws configure list-profiles${N}     which profiles actually exist"
        say "    ${CYA}env | grep -i '^AWS_'${N}           the layer that overrides everything"
        say "    ${CYA}aws sts get-caller-identity --debug 2>&1 | grep -i endpoint${N}"
        say "    ${CYA}tail -f $LAB_ROOT/logs/requests.log${N}   what the endpoint actually received"
        say ""
        say "${B}COMMANDS${N}"
        say "    ${CYA}$0 verify${N}   grade yourself (run it from your lab shell)"
        say "    ${CYA}$0 hint${N}     one more hint each time"
        say "    ${CYA}$0 status${N}   what is running and what the CLI currently sees"
        say "    ${CYA}$0 clean${N}    stop the mock and delete $LAB_ROOT"
        say ""
        say "  Target time: 25 minutes. The step-by-step solution is in the comments at"
        say "  the end of this script -- read it after you have finished, or after you"
        say "  have genuinely stalled."
        rule
    } | tee "$LAB_ROOT/BRIEFING.txt" >/dev/null
    cat "$LAB_ROOT/BRIEFING.txt"
    return 0
}

cmd_break() {
    require_disposable_vm
    preflight
    stop_mock
    rm -rf "$LAB_ROOT"
    mkdir -p "$LAB_ROOT"/{aws,iac,mock,logs,run}
    write_mock
    write_good_template
    write_config_healthy
    start_mock
    ok "mock AWS control plane listening on http://127.0.0.1:$LAB_PORT (pid $(cat "$PID_FILE"))"
    rule
    prove_healthy
    apply_breakage
    rm -f "$HINT_FILE"
    say ""
    briefing
    return 0
}

#------------------------------------------------------------------------------
# verify
#------------------------------------------------------------------------------

cmd_verify() {
    [[ -d "$LAB_ROOT" ]] || die "No lab at $LAB_ROOT. Run '$0' first."
    FAILS=0
    rule
    say "${B}GRADING -- CLF-C02 3.1 break & fix${N}"
    rule

    if [[ -z "${AWS_CONFIG_FILE:-}" ]]; then
        warn "AWS_CONFIG_FILE is not set in this shell. Run 'source $LAB_ROOT/lab.env'"
        warn "in the shell where you are working, then run '$0 verify' from that same shell."
    fi

    if ! port_is_open "$LAB_PORT"; then
        warn "The mock endpoint is not listening on 127.0.0.1:$LAB_PORT. Starting it."
        write_mock
        start_mock
    fi

    # --- objective 1: nothing leaks from the environment layer ---------------
    local leaked="" v
    for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
             AWS_DEFAULT_REGION AWS_REGION AWS_ENDPOINT_URL; do
        if [[ -n "${!v:-}" ]]; then leaked="$leaked $v"; fi
    done
    if [[ -z "$leaked" ]]; then
        pass_check "no credential/region/endpoint override in the environment"
    else
        fail_check "environment still overrides the config files" \
"still exported:$leaked
NOTE: removing a line from lab.env does NOT unexport it from a shell that
already sourced it. Use 'unset <VAR>' or open a fresh shell."
    fi

    if [[ "${AWS_PROFILE:-}" == "$LAB_PROFILE" ]]; then
        pass_check "AWS_PROFILE resolves to an existing profile ($LAB_PROFILE)"
    else
        fail_check "AWS_PROFILE should be '$LAB_PROFILE'" "current value: '${AWS_PROFILE:-<unset>}'"
    fi

    # --- objective 2: identity ----------------------------------------------
    local out account
    if out="$(aws sts get-caller-identity --output json 2>&1)"; then
        account="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Account",""))' 2>/dev/null || true)"
        if [[ "$account" == "$LAB_ACCOUNT" ]]; then
            pass_check "aws sts get-caller-identity -> account $account"
        else
            fail_check "unexpected identity" "$out"
        fi
    else
        fail_check "aws sts get-caller-identity still fails" "$out"
    fi

    # --- objective 3: region and endpoint -----------------------------------
    local listing region_value region_source
    listing="$(aws configure list 2>&1 || true)"
    region_value="$(printf '%s\n' "$listing" | awk '$1=="region"{print $2}')"
    region_source="$(printf '%s\n' "$listing" | awk '$1=="region"{print $3}')"
    if [[ "$region_value" == "$LAB_REGION" && "$region_source" != "env" ]]; then
        pass_check "effective region is $LAB_REGION, sourced from $region_source"
    else
        fail_check "effective region must be $LAB_REGION and must not come from the environment" \
                   "aws configure list says: region='${region_value:-?}' source='${region_source:-?}'"
    fi

    local endpoint
    endpoint="$(aws configure get endpoint_url 2>/dev/null || true)"
    if [[ -z "$endpoint" ]]; then
        endpoint="$(sed -n 's/^[[:space:]]*endpoint_url[[:space:]]*=[[:space:]]*//p' "$LAB_ROOT/aws/config" | head -n1)"
    fi
    if [[ "$endpoint" == "http://127.0.0.1:$LAB_PORT" ]]; then
        pass_check "endpoint_url points at the reachable endpoint ($endpoint)"
    else
        fail_check "endpoint_url must be http://127.0.0.1:$LAB_PORT" "found: '${endpoint:-<unset>}'"
    fi

    # --- objective 4: the template ------------------------------------------
    local lint
    if lint="$(python3 "$MOCK_PY" --check-template "$LAB_ROOT/$TEMPLATE_REL" 2>&1)"; then
        pass_check "template parses, validates and keeps the required shape"
    else
        fail_check "template still rejected" "$lint"
    fi

    if out="$(aws cloudformation validate-template --template-body "file://$LAB_ROOT/$TEMPLATE_REL" --output json 2>&1)"; then
        pass_check "aws cloudformation validate-template accepted the template"
    else
        fail_check "aws cloudformation validate-template still fails" "$out"
    fi

    # --- objective 5: the deployment ----------------------------------------
    local status
    if out="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --output json 2>&1)"; then
        status="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Stacks"][0]["StackStatus"])' 2>/dev/null || true)"
        if [[ "$status" == "CREATE_COMPLETE" ]]; then
            pass_check "stack $STACK_NAME is CREATE_COMPLETE"
        else
            fail_check "stack $STACK_NAME is in state '${status:-unknown}'" "$out"
        fi
    else
        fail_check "stack $STACK_NAME does not exist yet" \
"deploy it as code once the template validates:
  aws cloudformation create-stack --stack-name $STACK_NAME \\
      --template-body file://$LAB_ROOT/$TEMPLATE_REL
  aws cloudformation wait stack-create-complete --stack-name $STACK_NAME"
    fi

    rule
    if [[ $FAILS -eq 0 ]]; then
        say "${GRN}${B}ALL OBJECTIVES MET.${N}"
        say ""
        say "What you just practised, in CLF-C02 3.1 vocabulary:"
        say "  * The Console is one method; the CLI, the SDKs and IaC are the others,"
        say "    and all of them resolve credentials, region and endpoint through the"
        say "    same chain -- so a broken chain breaks every programmatic method at once."
        say "  * Configuration precedence, highest first: command-line flags, then"
        say "    environment variables, then the CLI credentials/config files, then"
        say "    container/EC2 instance-profile metadata (IMDS). Debug top-down."
        say "  * Region is not decoration: it selects the endpoint AND it is baked into"
        say "    the SigV4 credential scope, so a wrong region fails as an auth error."
        say "  * Reachability is its own layer: public internet, VPN, Direct Connect or"
        say "    VPC endpoint -- 'Could not connect to the endpoint URL' is a network"
        say "    statement, never a permissions one."
        say "  * IaC is a deployment method with its own failure ladder: lexical, then"
        say "    structural, then referential. validate-template is free; a failed"
        say "    stack in production is not."
        say ""
        say "Inspect what you built:"
        say "  aws cloudformation describe-stack-resources --stack-name $STACK_NAME --output table"
        say "  aws cloudformation describe-stacks --stack-name $STACK_NAME --query 'Stacks[0].Outputs'"
        say ""
        say "Tear down when finished:  $0 clean"
        rule
        return 0
    fi
    say "${RED}${B}$FAILS objective(s) still failing.${N}  Fix, then re-run '$0 verify'."
    say "Stuck? '$0 hint' gives you one more clue each time."
    rule
    return 1
}

#------------------------------------------------------------------------------
# hint / status / clean
#------------------------------------------------------------------------------

cmd_hint() {
    [[ -d "$LAB_ROOT" ]] || die "No lab at $LAB_ROOT. Run '$0' first."
    mkdir -p "$LAB_ROOT/run"
    local level=0
    [[ -f "$HINT_FILE" ]] && level="$(cat "$HINT_FILE")"
    level=$((level + 1))
    printf '%s' "$level" > "$HINT_FILE"
    rule
    case "$level" in
        1)
            say "${B}Hint 1/4 -- find the layer, not the symptom.${N}"
            say "Every AWS SDK and the CLI resolve settings in a fixed precedence:"
            say "  1. command-line flags   2. environment variables"
            say "  3. the CLI credentials file   4. the CLI config file"
            say "  5. container credentials   6. EC2 instance profile (IMDS)"
            say "Two commands tell you the whole story before you edit anything:"
            say "  ${CYA}env | grep -i '^AWS_'${N}"
            say "  ${CYA}aws configure list${N}   (read the 'Type' and 'Location' columns)"
            ;;
        2)
            say "${B}Hint 2/4 -- the export trap.${N}"
            say "The environment poison lives at the bottom of ${CYA}$LAB_ROOT/lab.env${N}."
            say "Deleting those lines is necessary but NOT sufficient: a variable already"
            say "exported into your current shell survives re-sourcing the file. Either"
            say "${CYA}unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_DEFAULT_REGION${N} and re-source, or"
            say "open a brand-new shell. This is exactly why 'it works on my machine'"
            say "and 'it works in a fresh terminal' are different claims."
            ;;
        3)
            say "${B}Hint 3/4 -- reachability vs. authorization.${N}"
            say "'Could not connect to the endpoint URL' means no HTTP response ever came"
            say "back: nothing to do with IAM. Compare what the client is aiming at with"
            say "what is actually listening:"
            say "  ${CYA}grep endpoint_url $LAB_ROOT/aws/config${N}"
            say "  ${CYA}ss -lntp 2>/dev/null | grep 45${N}"
            say "Once the request lands, ${CYA}tail $LAB_ROOT/logs/requests.log${N} shows the"
            say "region the endpoint saw in your signature."
            ;;
        4)
            say "${B}Hint 4/4 -- read the template errors in order.${N}"
            say "CloudFormation reports one class of error at a time:"
            say "  1. 'YAML not well-formed. (line N, column M)' -> indentation. Go to that"
            say "     line; one key sits one space deeper than its siblings."
            say "  2. 'Every Resources object must contain a Type member.' -> one resource"
            say "     has Properties but no Type."
            say "  3. 'Unresolved resource dependencies [X] in the Resources block' -> a"
            say "     !Ref names a logical id that does not exist. Logical ids are"
            say "     case-sensitive: LabVPC is not LabVpc."
            say "Loop until it validates: ${CYA}aws cloudformation validate-template --template-body file://$TEMPLATE_REL${N}"
            ;;
        *)
            say "${B}No hints left.${N} The full step-by-step solution is in the comment block"
            say "at the end of this script:"
            say "  ${CYA}sed -n '/^# *SOLUTION/,\$p' $0 | less${N}"
            ;;
    esac
    rule
    return 0
}

cmd_status() {
    [[ -d "$LAB_ROOT" ]] || die "No lab at $LAB_ROOT. Run '$0' first."
    rule
    say "${B}LAB STATUS${N}"
    rule
    say "lab root      : $LAB_ROOT"
    if port_is_open "$LAB_PORT"; then
        say "mock endpoint : ${GRN}listening${N} on http://127.0.0.1:$LAB_PORT (pid $(cat "$PID_FILE" 2>/dev/null || echo '?'))"
    else
        say "mock endpoint : ${RED}not listening${N} on 127.0.0.1:$LAB_PORT  (run '$0 verify' to restart it)"
    fi
    say ""
    say "${B}AWS_* in this shell${N}"
    env | grep -E '^AWS_' | sed 's/^/  /' || say "  (none)"
    say ""
    say "${B}aws configure list${N}"
    aws configure list 2>&1 | sed 's/^/  /' || true
    say ""
    say "${B}last endpoint activity${N}"
    tail -n 8 "$LAB_ROOT/logs/requests.log" 2>/dev/null | sed 's/^/  /' || say "  (no requests yet)"
    rule
    return 0
}

cmd_clean() {
    case "$LAB_ROOT" in
        "" | "/" | "$HOME") die "Refusing to delete '$LAB_ROOT'." ;;
    esac
    [[ -d "$LAB_ROOT" ]] || { info "Nothing to clean at $LAB_ROOT"; return 0; }
    stop_mock
    if [[ "${I_KNOW_THIS_IS_A_DISPOSABLE_LAB_VM:-no}" != "yes" && -t 0 ]]; then
        local answer=""
        read -r -p "Delete $LAB_ROOT and everything in it? [y/N] " answer
        [[ "$answer" == "y" || "$answer" == "Y" ]] || { info "Kept."; return 0; }
    fi
    rm -rf "$LAB_ROOT"
    ok "Lab removed. Your ~/.aws was never touched; unset AWS_CONFIG_FILE,"
    ok "AWS_SHARED_CREDENTIALS_FILE and AWS_PROFILE (or close the lab shell)."
    return 0
}

usage() {
    sed -n '2,60p' "$0" | sed 's/^#//; s/^ //'
    return 0
}

case "${1:-break}" in
    break|start|setup) cmd_break ;;
    verify|check|grade) cmd_verify ;;
    hint) cmd_hint ;;
    status) cmd_status ;;
    clean|destroy|teardown) cmd_clean ;;
    help|-h|--help) usage ;;
    *) die "Unknown command '$1'. Try: break | verify | hint | status | clean" ;;
esac

exit 0

#===============================================================================
# SOLUTION -- step by step
#===============================================================================
# Do not read this until `./break-fix-3.1.sh verify` passes, or until you have
# genuinely stalled. The value of a break & fix is in the diagnosis, and the
# diagnosis is the part the exam actually tests.
#
# The five faults, and why each one belongs to task statement 3.1:
#
#   F1  AWS_PROFILE="ghost-admin"        env layer  -> profile resolution
#   F2  AWS_ACCESS_KEY_ID with no secret env layer  -> credential resolution
#   F3  AWS_DEFAULT_REGION="us-east-99"  env layer  -> region + SigV4 scope
#   F4  endpoint_url on port 4599        config     -> reachability/connectivity
#   F5  three defects in vpc-lab.yaml    IaC        -> deployment as code
#
# -----------------------------------------------------------------------------
# STEP 0 -- reproduce, then look at the layers before editing anything
# -----------------------------------------------------------------------------
#   $ source ~/aws-clf-3.1-lab/lab.env
#   $ cd ~/aws-clf-3.1-lab
#   $ aws sts get-caller-identity
#   The config profile (ghost-admin) could not be found
#
#   The CLI failed before it built a request, so this is a configuration
#   problem, not a network or IAM problem. Enumerate the layers, highest
#   precedence first:
#
#   $ env | grep -i '^AWS_'
#   AWS_CONFIG_FILE=/home/you/aws-clf-3.1-lab/aws/config
#   AWS_SHARED_CREDENTIALS_FILE=/home/you/aws-clf-3.1-lab/aws/credentials
#   AWS_PROFILE=ghost-admin
#   AWS_PAGER=
#   AWS_ACCESS_KEY_ID=LEFTOVERKEYFROMCI001
#   AWS_DEFAULT_REGION=us-east-99
#
#   $ aws configure list-profiles
#   clf-lab
#
#   'ghost-admin' does not exist. 'clf-lab' does. Three of those variables are
#   junk. Note that AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE are the lab's
#   own isolation and must stay.
#
# -----------------------------------------------------------------------------
# STEP 1 -- remove the environment overrides (F1, F2, F3)
# -----------------------------------------------------------------------------
#   Edit ~/aws-clf-3.1-lab/lab.env and delete the appended block:
#
#       export AWS_PROFILE="ghost-admin"
#       export AWS_ACCESS_KEY_ID="LEFTOVERKEYFROMCI001"
#       export AWS_DEFAULT_REGION="us-east-99"
#
#   Keep the original `export AWS_PROFILE="clf-lab"` line above it.
#   One-liner if you prefer:
#
#   $ sed -i '/^# --- appended by "platform automation"/,/^# ----*$/d' lab.env
#
#   THE TRAP: editing the file does not change the shell you are already in.
#   An exported variable lives in the process environment until you unset it.
#
#   $ unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_DEFAULT_REGION
#   $ source ~/aws-clf-3.1-lab/lab.env
#
#   (Equivalent and cleaner in real life: exec a fresh shell and source once.)
#
#   $ aws configure list
#         Name                    Value             Type    Location
#         ----                    -----             ----    --------
#      profile                   clf-lab              env    AWS_PROFILE
#   access_key     ****************0001 shared-credentials-file
#   secret_key     ****************0000 shared-credentials-file
#       region                 us-east-1      config-file    .../aws/config
#
#   Read the Type column. That column is the whole lesson: it tells you which
#   layer won. If access_key still says 'env', the unset did not happen.
#
# -----------------------------------------------------------------------------
# STEP 2 -- fix reachability (F4)
# -----------------------------------------------------------------------------
#   $ aws sts get-caller-identity
#   Could not connect to the endpoint URL: "http://127.0.0.1:4599/"
#
#   No HTTP response came back at all. This is never an IAM error. In a real
#   account the same message means: wrong region in the endpoint name, a VPC
#   endpoint that does not exist for that service, a security group or NACL
#   blocking 443, a proxy variable, or a Direct Connect / Site-to-Site VPN
#   path that is down. Here it is simply the wrong port.
#
#   $ grep -n endpoint_url aws/config
#   4:endpoint_url = http://127.0.0.1:4599
#   $ ss -lntp | grep 45
#   LISTEN 0 5 127.0.0.1:4566 0.0.0.0:*  users:(("python3",pid=...))
#
#   4566 is listening; 4599 is not. Fix the config file:
#
#   $ sed -i 's#^endpoint_url = .*#endpoint_url = http://127.0.0.1:4566#' aws/config
#
#   $ aws sts get-caller-identity
#   {
#       "UserId": "AIDACKCEVSQ6C2EXAMPLE",
#       "Account": "123456789012",
#       "Arn": "arn:aws:iam::123456789012:user/clf-lab-student"
#   }
#
#   If instead you see:
#     An error occurred (InvalidSignatureException) when calling the
#     GetCallerIdentity operation: Credential should be scoped to a valid
#     region, not 'us-east-99'.
#   then AWS_DEFAULT_REGION is still exported in this shell -- go back to
#   STEP 1 and unset it. That message is worth memorising: the region is part
#   of the SigV4 credential scope, so a bad region surfaces as an
#   authentication failure, not as "no such region".
#
# -----------------------------------------------------------------------------
# STEP 3 -- fix the infrastructure as code (F5), one error class at a time
# -----------------------------------------------------------------------------
#   $ aws cloudformation validate-template --template-body file://iac/vpc-lab.yaml
#   An error occurred (ValidationError) when calling the ValidateTemplate
#   operation: Template format error: YAML not well-formed. (line 17, column 12):
#   mapping values are not allowed here
#
#   3a. LEXICAL. Line 17 is `Tags:` indented 7 spaces while its siblings
#       (CidrBlock, EnableDnsSupport, EnableDnsHostnames) are at 6. YAML is
#       whitespace-significant; one extra space is a syntax error. Align it:
#
#           Properties:
#             CidrBlock: !Ref VpcCidr
#             EnableDnsSupport: true
#             EnableDnsHostnames: true
#             Tags:
#               - Key: Name
#                 Value: clf-lab-vpc
#
#   $ aws cloudformation validate-template --template-body file://iac/vpc-lab.yaml
#   ... Template format error: Every Resources object must contain a Type member.
#
#   3b. STRUCTURAL. LabSecurityGroup has Properties but no Type. Every entry
#       under Resources needs `Type: AWS::Service::ResourceType`:
#
#         LabSecurityGroup:
#           Type: AWS::EC2::SecurityGroup
#           Properties:
#             GroupDescription: Lab security group with no ingress
#             VpcId: !Ref LabVpc
#
#   $ aws cloudformation validate-template --template-body file://iac/vpc-lab.yaml
#   ... Template error: Unresolved resource dependencies [LabVPC] in the
#       Resources block of the template
#
#   3c. REFERENTIAL. LabSubnet does `VpcId: !Ref LabVPC`, but the logical id is
#       `LabVpc`. Logical ids are case-sensitive. Fix the reference (do NOT
#       hardcode a vpc-id -- the !Ref is what creates the dependency edge that
#       makes CloudFormation build the VPC first and delete it last):
#
#         LabSubnet:
#           Type: AWS::EC2::Subnet
#           Properties:
#             VpcId: !Ref LabVpc
#             CidrBlock: 10.20.1.0/24
#
#   $ aws cloudformation validate-template --template-body file://iac/vpc-lab.yaml
#   {
#       "Parameters": [
#           {
#               "ParameterKey": "VpcCidr",
#               "DefaultValue": "10.20.0.0/16",
#               "NoEcho": false,
#               "Description": "CIDR block for the lab VPC"
#           }
#       ],
#       "Description": "CLF-C02 3.1 lab - minimal network stack, deployed as code",
#       "Capabilities": []
#   }
#
# -----------------------------------------------------------------------------
# STEP 4 -- deploy it the IaC way
# -----------------------------------------------------------------------------
#   $ aws cloudformation create-stack --stack-name clf-lab-net \
#         --template-body file://iac/vpc-lab.yaml
#   {
#       "StackId": "arn:aws:cloudformation:us-east-1:123456789012:stack/clf-lab-net/1f0e3dad9932"
#   }
#
#   $ aws cloudformation wait stack-create-complete --stack-name clf-lab-net
#   $ aws cloudformation describe-stacks --stack-name clf-lab-net \
#         --query 'Stacks[0].StackStatus' --output text
#   CREATE_COMPLETE
#
#   $ aws cloudformation describe-stack-resources --stack-name clf-lab-net \
#         --query 'StackResources[].[LogicalResourceId,ResourceType,PhysicalResourceId]' \
#         --output table
#   -----------------------------------------------------------------------------
#   |  LabVpc            |  AWS::EC2::VPC            |  vpc-0<...>              |
#   |  LabSubnet         |  AWS::EC2::Subnet         |  subnet-0<...>           |
#   |  LabSecurityGroup  |  AWS::EC2::SecurityGroup  |  sg-0<...>               |
#   -----------------------------------------------------------------------------
#
# -----------------------------------------------------------------------------
# STEP 5 -- grade and tear down
# -----------------------------------------------------------------------------
#   $ ./break-fix-3.1.sh verify      # all objectives PASS
#   $ ./break-fix-3.1.sh clean       # stop the mock, delete the lab tree
#
# -----------------------------------------------------------------------------
# EXAM-LEVEL TAKEAWAYS (task statement 3.1)
# -----------------------------------------------------------------------------
# * Ways to provision and operate: AWS Management Console (interactive, good for
#   learning and one-off inspection, bad for repeatability), AWS CLI (scriptable,
#   the same API the Console calls), AWS SDKs (same credential chain as the CLI),
#   Infrastructure as Code -- CloudFormation templates, or AWS CDK which
#   synthesizes CloudFormation from a general-purpose language. Anything you can
#   click, you can call; anything you can call, you can declare.
#
# * A CloudFormation stack is the unit of lifecycle: create, update (with change
#   sets), delete. Resources declared in one template are created in dependency
#   order derived from !Ref / !GetAtt, and deleted in reverse. That is why
#   replacing a !Ref with a hardcoded id is a real defect, not a style choice.
#
# * Configuration precedence for every programmatic method, highest first:
#   command-line flags > environment variables > CLI credentials file >
#   CLI config file > container credentials > EC2 instance profile (IMDS).
#   Debug from the top down; `aws configure list` prints the winner per setting.
#
# * Region selects the endpoint and is embedded in the SigV4 credential scope --
#   which is why an invalid region can present itself as a signature error.
#
# * Connectivity is a separate layer from identity and from authorization:
#   public internet, AWS Site-to-Site VPN, AWS Direct Connect, or VPC endpoints
#   (interface/gateway) for private access. "Could not connect to the endpoint
#   URL" is always a path problem; "AccessDenied" is always a policy problem.
#   Never fix the second by editing the first.
#
# * Deployment models you may be asked to distinguish: all-in cloud, hybrid
#   (VPN / Direct Connect / AWS Outposts / Storage Gateway bridging an existing
#   data centre), and on-premises or "private cloud" workloads. Orthogonal to
#   that: one-time operations versus managed, repeatable operations -- which is
#   exactly the difference between STEP 0's clicking and STEP 4's stack.
#
# Sources used to build this lab:
#   https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#   https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html
#   https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html
#   https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html
#   https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/template-anatomy.html
#   https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference-ref.html
#   https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/API_ValidateTemplate.html
#   https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html
#===============================================================================