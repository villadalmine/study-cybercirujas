#!/usr/bin/env bash
# =============================================================================
#  AWS Certified Cloud Practitioner — CLF-C02 (exam guide v1.0)
#  Domain 2 (Security and Compliance) · Task Statement 2.1
#  "Understand the AWS shared responsibility model"  · domain weight: 7.5%
#
#  LAB TYPE : break & fix, offline, self-contained
#  RUN ON   : a DISPOSABLE virtual machine you can destroy afterwards.
#             It creates a system user, systemd units, a firewall table and a
#             loopback alias. Do NOT run it on a workstation you care about.
#
#  WHY A LOCAL SIMULATION AND NOT A REAL AWS ACCOUNT
#  -------------------------------------------------
#  The shared responsibility model is a *boundary*, not a service. To feel the
#  boundary you must be able to touch both sides of it, and on real AWS you
#  physically cannot touch the AWS side (that is the whole point). This lab
#  therefore reproduces, on one VM and with zero cost:
#
#    * an EC2-like guest OS you own end to end          -> CUSTOMER side
#    * a security-group-like stateless packet filter    -> CUSTOMER side
#    * an IMDSv2-compatible instance metadata service   -> boundary (AWS runs
#      the endpoint; you own what you attach to it and who can reach it)
#    * an S3-like object store with bucket policy, Block Public Access and
#      SSE at rest                                      -> CUSTOMER side
#    * an "aws-managed" tree (hypervisor firmware, physical access controls,
#      managed-service patch level)                     -> AWS side, READ ONLY
#
#  Every fix you will perform maps 1:1 to a real AWS CLI call, and the real
#  call is printed next to the lab call in the solution block at the end.
#
#  OFFICIAL SOURCES
#    - Exam guide (CLF-C02):
#      https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#    - Shared Responsibility Model:
#      https://aws.amazon.com/compliance/shared-responsibility-model/
#    - EC2 security groups:
#      https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html
#    - Instance metadata and IMDSv2:
#      https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
#    - Credential resolution chain (SDKs and CLI):
#      https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
#    - IAM policy evaluation logic:
#      https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
#    - S3 Block Public Access:
#      https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
#    - S3 server-side encryption:
#      https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html
#
#  USAGE
#    sudo ./srm-lab.sh run       # setup + break + student briefing (default)
#    sudo ./srm-lab.sh verify    # graded scorecard, exit 0 only when all pass
#    sudo ./srm-lab.sh hint      # progressive hints, no answers
#    sudo ./srm-lab.sh rebreak   # re-apply the damage without rebuilding
#    sudo ./srm-lab.sh clean     # remove every artifact this script created
#
#  Confirmation is mandatory: pass --force or export SRM_LAB_I_UNDERSTAND=yes
# =============================================================================

set -euo pipefail

LAB_ROOT="${SRM_LAB_ROOT:-/opt/srm-lab}"
BIN="$LAB_ROOT/bin"
STATE="$LAB_ROOT/state"
IAM="$LAB_ROOT/iam"
S3="$LAB_ROOT/s3"
BUCKET_NAME="srm-lab-customer-data"
BUCKET="$S3/buckets/$BUCKET_NAME"
WWW="$LAB_ROOT/www"
KMS="$LAB_ROOT/kms"
TEMPLATES="$LAB_ROOT/templates"
AWS_MANAGED="$LAB_ROOT/aws-managed"
AGENT="$LAB_ROOT/agent"
APP_USER="srmapp"
APP_HOME="$LAB_ROOT/home/$APP_USER"
APP_PORT=8080
ACCOUNT_ID="123456789012"
ROLE_NAME="srm-lab-app-role"
INSTANCE_ID="i-0abc1234lab5678de"

# Deliberately fake, non-canonical example credentials. Nothing here is valid
# anywhere; the strings only have to satisfy the AKID/secret shape checks.
LEGACY_AKID="AKIAEXAMPLELABKEY000"
LEGACY_SECRET="EXAMPLEonlyLABsecret0000000000000000AAAA"
ROLE_AKID="ASIAEXAMPLELABROLE00"
ROLE_SECRET="EXAMPLEonlyLABrolesecret000000000000BBBB"

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
C_BLU=$'\033[34m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s%s%s\n' "$C_BLD$C_BLU" "$*" "$C_OFF"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Preflight. Refuses to run anywhere it could do harm.
# -----------------------------------------------------------------------------
preflight() {
  [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 ${1:-run}"

  if [ "${SRM_LAB_I_UNDERSTAND:-no}" != "yes" ] && [ "${FORCE:-0}" != "1" ]; then
    cat <<EOF
${C_YEL}This script modifies the machine it runs on:${C_OFF}
  - creates the system user '$APP_USER' and the tree $LAB_ROOT
  - installs and starts two systemd units (srm-imds, srm-webapp)
  - adds an nftables/iptables table that DROPs inbound tcp/$APP_PORT
  - may add 169.254.169.254/32 to the loopback interface
Run it only on a disposable lab VM.

Re-run with:  sudo SRM_LAB_I_UNDERSTAND=yes $0 ${1:-run}
        or :  sudo $0 --force ${1:-run}
EOF
    exit 2
  fi

  [ -d /run/systemd/system ] || die "systemd is required (the lab uses systemctl/journalctl as diagnostic tools)"
  for t in python3 openssl curl ss ip; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
  done
  if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
    die "need nft or iptables to simulate the security group"
  fi
}

fw_backend() { command -v nft >/dev/null 2>&1 && echo nft || echo iptables; }

# Real EC2 detection: if a genuine IMDS answers, we must NOT steal
# 169.254.169.254 — hijacking it would break the instance's real credentials.
pick_imds_endpoint() {
  if curl -fsS -m 1 -X PUT "http://169.254.169.254/latest/api/token" \
       -H "X-aws-ec2-metadata-token-ttl-seconds: 60" >/dev/null 2>&1; then
    warn "a real IMDS answered on 169.254.169.254 — this VM looks like a real EC2 instance."
    warn "the lab will NOT touch the link-local address; the mock IMDS binds 127.0.0.169 instead."
    echo "127.0.0.169"
  else
    echo "169.254.169.254"
  fi
}

# -----------------------------------------------------------------------------
# setup — build a HEALTHY environment first. A break & fix lab is only honest
#         if the target state provably existed before the break.
# -----------------------------------------------------------------------------
setup() {
  head1 "[setup] building the lab environment under $LAB_ROOT"

  mkdir -p "$BIN" "$STATE" "$IAM/policies" "$BUCKET/objects" "$WWW/public" \
           "$KMS" "$TEMPLATES" "$AWS_MANAGED" "$AGENT" "$APP_HOME/.aws" "$LAB_ROOT/log"

  local shell_nologin=/bin/false
  [ -x /usr/sbin/nologin ] && shell_nologin=/usr/sbin/nologin
  [ -x /sbin/nologin ] && shell_nologin=/sbin/nologin
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$APP_HOME" --shell "$shell_nologin" "$APP_USER"
  fi
  chown -R "$APP_USER":"$APP_USER" "$APP_HOME"

  local imds_ep; imds_ep="$(pick_imds_endpoint)"
  printf '%s\n' "$imds_ep" > "$STATE/imds-endpoint"
  printf '%s\n' "$ROLE_NAME" > "$STATE/instance-profile"
  printf '%s\n' "$INSTANCE_ID" > "$STATE/instance-id"
  if [ "$imds_ep" = "169.254.169.254" ]; then
    ip addr replace 169.254.169.254/32 dev lo
  else
    ip addr replace 127.0.0.169/32 dev lo
  fi

  # ---- KMS stand-in ---------------------------------------------------------
  # In real AWS this key material never leaves the KMS HSM boundary; a file on
  # the instance is exactly what KMS exists to avoid. It is here only so the
  # ciphertext is verifiable offline.
  [ -s "$KMS/lab-cmk.key" ] || openssl rand -hex 32 > "$KMS/lab-cmk.key"
  chmod 0640 "$KMS/lab-cmk.key"; chgrp "$APP_USER" "$KMS/lab-cmk.key"

  # ---- IAM: credential database and identity policies -----------------------
  cat > "$IAM/keys.json" <<EOF
{
  "$LEGACY_AKID": {
    "principal": "arn:aws:iam::$ACCOUNT_ID:user/legacy-deploy-user",
    "status": "Inactive",
    "policy": null,
    "note": "long-lived key of a decommissioned IAM user; rotated out and deactivated"
  },
  "$ROLE_AKID": {
    "principal": "arn:aws:sts::$ACCOUNT_ID:assumed-role/$ROLE_NAME/$INSTANCE_ID",
    "status": "Active",
    "policy": "$ROLE_NAME",
    "note": "temporary credentials vended by the instance profile through IMDSv2"
  }
}
EOF

  cat > "$IAM/policies/$ROLE_NAME.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadCustomerObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::$BUCKET_NAME",
        "arn:aws:s3:::$BUCKET_NAME/*"
      ]
    },
    {
      "Sid": "DecryptWithLabKey",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:DescribeKey"],
      "Resource": "arn:aws:kms:us-east-1:$ACCOUNT_ID:key/lab-cmk"
    },
    {
      "Sid": "NeverDeleteCustomerData",
      "Effect": "Deny",
      "Action": ["s3:DeleteObject", "s3:DeleteBucket"],
      "Resource": "arn:aws:s3:::$BUCKET_NAME/*"
    }
  ]
}
EOF

  cat > "$IAM/instance-profile-credentials.json" <<EOF
{
  "Code": "Success",
  "Type": "AWS-HMAC",
  "AccessKeyId": "$ROLE_AKID",
  "SecretAccessKey": "$ROLE_SECRET",
  "Token": "IQoJb3JpZ2luX2VjEXAMPLElabSessionTokenNotValidAnywhere",
  "Expiration": "2026-12-31T23:59:59Z"
}
EOF
  chmod 0644 "$IAM/keys.json" "$IAM/policies/$ROLE_NAME.json" "$IAM/instance-profile-credentials.json"

  # ---- S3 stand-in: bucket, config, policy, one object ----------------------
  cat > "$BUCKET/bucket-config.json" <<EOF
{
  "Bucket": "$BUCKET_NAME",
  "Region": "us-east-1",
  "PublicAccessBlockConfiguration": {
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  },
  "ACL": "private",
  "ServerSideEncryptionConfiguration": {
    "SSEAlgorithm": "aws:kms",
    "KMSMasterKeyID": "arn:aws:kms:us-east-1:$ACCOUNT_ID:key/lab-cmk"
  }
}
EOF

  cat > "$TEMPLATES/bucket-policy-tls-only.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::$BUCKET_NAME",
        "arn:aws:s3:::$BUCKET_NAME/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
EOF
  cp "$TEMPLATES/bucket-policy-tls-only.json" "$BUCKET/bucket-policy.json"

  # Synthetic records. No real personal data is used anywhere in this lab.
  cat > "$STATE/plaintext-seed.csv" <<'EOF'
record_id,customer_ref,tier,monthly_spend_usd,contact_hash
1001,ACME-NORTH,enterprise,4820.00,3f1a9c7de2
1002,GLOBEX-EU,standard,310.50,9b02ee41ac
1003,INITECH-APAC,enterprise,7735.25,c47da10b8f
1004,UMBRELLA-LATAM,standard,188.75,20e6fb9d33
EOF
  chmod 0600 "$STATE/plaintext-seed.csv"

  # ---- the AWS side of the line: read-only, out of scope --------------------
  cat > "$AWS_MANAGED/README.txt" <<'EOF'
EVERYTHING UNDER THIS DIRECTORY IS "SECURITY OF THE CLOUD".

In a real account you have no shell, no API and no ticket that lets you change
any of it. It is listed here so you can see it, reason about it, and leave it
alone. Touching these files is a graded failure in this lab, because in
production the equivalent action does not exist.
EOF
  cat > "$AWS_MANAGED/hypervisor-nitro-firmware.txt" <<'EOF'
component: AWS Nitro System (hypervisor + Nitro Card + Nitro Security Chip)
firmware: managed and patched by AWS, live, with no instance downtime
customer action required: none. There is no API to read or write this.
EOF
  cat > "$AWS_MANAGED/datacenter-physical-controls.txt" <<'EOF'
component: physical and environmental security of the AWS Region / AZ
controls: perimeter, multi-factor badge + biometric access, CCTV, media
          destruction, power/HVAC redundancy
evidence available to the customer: AWS Artifact (SOC 1/2/3, ISO 27001, PCI DSS)
customer action required: download the report, do not attempt the audit yourself
EOF
  cat > "$AWS_MANAGED/managed-service-patch-level.txt" <<'EOF'
service: Amazon RDS for PostgreSQL (managed database)
engine patch level: 16.4-R3 — applied by AWS during the maintenance window
guest OS under the engine: patched by AWS; no SSH, no sudo, no package manager
CONTRAST: on Amazon EC2 the guest OS patch level is 100% the customer's job.
          Same company, same datacenter, different side of the line, because
          the service model changed (IaaS vs managed/PaaS).
EOF
  chmod 0444 "$AWS_MANAGED"/*
  command -v chattr >/dev/null 2>&1 && chattr +i "$AWS_MANAGED"/* 2>/dev/null || true
  ( cd "$AWS_MANAGED" && find . -type f | LC_ALL=C sort | xargs sha256sum ) > "$STATE/aws-managed.sha256"

  # ---- guest OS agent (customer-patched component) --------------------------
  printf '1.0.3\n' > "$AGENT/VERSION"
  cat > "$AGENT/advisories.json" <<'EOF'
{
  "LAB-2026-0001": {
    "component": "srm-agent",
    "severity": "HIGH",
    "summary": "fictional lab advisory: unauthenticated local privilege escalation in srm-agent < 1.0.3",
    "fixed_in": "1.0.3",
    "remediation": "srm-patch  (real world: dnf/apt update, or AWS Systems Manager Patch Manager)"
  }
}
EOF

  write_python_components
  write_units
  install_symlinks

  chown -R root:"$APP_USER" "$LAB_ROOT"
  chmod -R g+rX "$LAB_ROOT"
  chmod 0750 "$STATE"; chmod 0640 "$STATE/plaintext-seed.csv"

  systemctl daemon-reload
  systemctl enable --now srm-imds.service >/dev/null 2>&1
  systemctl enable --now srm-webapp.service >/dev/null 2>&1
  sleep 1

  # Healthy baseline: encrypt the object at rest through the lab tooling.
  "$BIN/s3ctl" encrypt-bucket "$BUCKET_NAME" --seed "$STATE/plaintext-seed.csv" >/dev/null
  ok "lab is up and HEALTHY (this is the state you must restore)"
  "$BIN/srm-audit" --quiet || warn "baseline audit reported findings — inspect with: srm-audit"
}

# -----------------------------------------------------------------------------
# Embedded components
# -----------------------------------------------------------------------------
write_python_components() {

  cat > "$BIN/srmlib.py" <<'PY'
"""Shared library: credential chain, policy evaluation, object I/O.

Deliberately small and readable — it exists so the student can open it and see
that IAM's evaluation logic (explicit Deny > Allow > implicit Deny) is not
magic, and that the credential chain has a fixed, documented precedence.
"""
import fnmatch, json, os, socket, subprocess, urllib.error, urllib.request

LAB = os.environ.get("SRM_LAB_ROOT", "/opt/srm-lab")
IAM = os.path.join(LAB, "iam")
S3 = os.path.join(LAB, "s3", "buckets")
STATE = os.path.join(LAB, "state")
KMS_KEY = os.path.join(LAB, "kms", "lab-cmk.key")
ENC_MAGIC = b"Salted__"


class AwsError(Exception):
    def __init__(self, code, op, msg):
        self.code = code
        super().__init__(
            "An error occurred (%s) when calling the %s operation: %s" % (code, op, msg))


def _read(path, default=""):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default


def jload(path):
    with open(path) as fh:
        return json.load(fh)


def primary_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))          # TEST-NET-1, no packet is sent
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def imds_endpoint():
    return _read(os.path.join(STATE, "imds-endpoint"), "169.254.169.254")


def imds_credentials(timeout=2):
    """IMDSv2: PUT a token first, then present it on every GET."""
    base = "http://%s" % imds_endpoint()
    req = urllib.request.Request(base + "/latest/api/token", method="PUT",
                                 headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"})
    token = urllib.request.urlopen(req, timeout=timeout).read().decode()
    hdr = {"X-aws-ec2-metadata-token": token}
    role = urllib.request.urlopen(
        urllib.request.Request(base + "/latest/meta-data/iam/security-credentials/", headers=hdr),
        timeout=timeout).read().decode().strip()
    if not role:
        raise AwsError("NoCredentialProviders", "GetCredentials", "no IAM role attached to the instance profile")
    body = urllib.request.urlopen(
        urllib.request.Request(base + "/latest/meta-data/iam/security-credentials/" + role, headers=hdr),
        timeout=timeout).read().decode()
    return role, json.loads(body)


def resolve_credentials():
    """Standard AWS credential resolution order (abbreviated to what matters here):
       1. environment variables
       2. shared credentials file ($HOME/.aws/credentials)
       3. EC2 instance profile via IMDS
    The first provider that returns anything WINS. It is never asked whether
    what it returned still works."""
    if os.environ.get("AWS_ACCESS_KEY_ID"):
        return {"source": "environment-variables",
                "access_key_id": os.environ["AWS_ACCESS_KEY_ID"], "role": None}

    shared = os.path.join(os.path.expanduser("~"), ".aws", "credentials")
    if os.path.exists(shared):
        akid = None
        for line in open(shared):
            line = line.strip()
            if line.lower().startswith("aws_access_key_id"):
                akid = line.split("=", 1)[1].strip()
        if akid:
            return {"source": "shared-credentials-file", "access_key_id": akid,
                    "role": None, "path": shared}

    try:
        role, creds = imds_credentials()
    except AwsError:
        raise
    except Exception as exc:
        raise AwsError("NoCredentialProviders", "GetCredentials",
                       "unable to reach the instance metadata service: %s" % exc)
    return {"source": "instance-profile", "access_key_id": creds["AccessKeyId"],
            "role": role, "expiration": creds.get("Expiration")}


def identify(op="GetCallerIdentity"):
    creds = resolve_credentials()
    keys = jload(os.path.join(IAM, "keys.json"))
    entry = keys.get(creds["access_key_id"])
    if entry is None:
        raise AwsError("InvalidClientTokenId", op,
                       "The security token included in the request is invalid.")
    if entry.get("status") != "Active":
        raise AwsError("InvalidClientTokenId", op,
                       "The security token included in the request is invalid. "
                       "(access key %s is %s)" % (creds["access_key_id"], entry.get("status")))
    creds.update(principal=entry["principal"], policy=entry.get("policy"),
                 status=entry["status"])
    return creds


def _matches(pattern, value):
    return fnmatch.fnmatchcase(value, pattern)


def _as_list(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def _condition_hit(cond, ctx):
    """Only the operators this lab needs. Absent condition == always matches."""
    if not cond:
        return True
    for key, val in cond.get("Bool", {}).items():
        want = str(val).lower() == "true"
        if bool(ctx.get(key)) != want:
            return False
    return True


def evaluate(policy, action, resource, ctx):
    decision = "ImplicitDeny"
    for st in policy.get("Statement", []):
        if not any(_matches(a, action) for a in _as_list(st.get("Action"))):
            continue
        if not any(_matches(r, resource) for r in _as_list(st.get("Resource"))):
            continue
        if not _condition_hit(st.get("Condition"), ctx):
            continue
        if st.get("Effect") == "Deny":
            return "ExplicitDeny", st.get("Sid", "-")
        decision = "Allow"
    return decision, "-"


def bucket_dir(bucket):
    return os.path.join(S3, bucket)


def bucket_config(bucket):
    return jload(os.path.join(bucket_dir(bucket), "bucket-config.json"))


def bucket_policy(bucket):
    path = os.path.join(bucket_dir(bucket), "bucket-policy.json")
    return jload(path) if os.path.exists(path) else {"Statement": []}


def object_path(bucket, key):
    return os.path.join(bucket_dir(bucket), "objects", key)


def is_encrypted(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(8) == ENC_MAGIC
    except OSError:
        return False


def _openssl(args, data):
    p = subprocess.run(["openssl"] + args, input=data,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise AwsError("KMSInvalidStateException", "Decrypt", p.stderr.decode().strip())
    return p.stdout


def encrypt_bytes(data):
    return _openssl(["enc", "-aes-256-cbc", "-pbkdf2", "-salt",
                     "-pass", "file:" + KMS_KEY], data)


def decrypt_bytes(data):
    return _openssl(["enc", "-d", "-aes-256-cbc", "-pbkdf2",
                     "-pass", "file:" + KMS_KEY], data)


def get_object(bucket, key, secure_transport=True):
    """The full request path: authenticate -> authorize -> read -> decrypt."""
    who = identify("GetObject")
    arn = "arn:aws:s3:::%s/%s" % (bucket, key)
    ctx = {"aws:SecureTransport": secure_transport}

    verdict, sid = evaluate(bucket_policy(bucket), "s3:GetObject", arn, ctx)
    if verdict == "ExplicitDeny":
        raise AwsError("AccessDenied", "GetObject",
                       "Access Denied — explicit Deny in the bucket policy (Sid: %s)" % sid)

    if not who.get("policy"):
        raise AwsError("AccessDenied", "GetObject",
                       "Access Denied — %s has no identity policy attached" % who["principal"])
    ipol = jload(os.path.join(IAM, "policies", who["policy"] + ".json"))
    verdict, sid = evaluate(ipol, "s3:GetObject", arn, ctx)
    if verdict == "ExplicitDeny":
        raise AwsError("AccessDenied", "GetObject",
                       "Access Denied — explicit Deny in the identity policy (Sid: %s)" % sid)
    if verdict != "Allow":
        raise AwsError("AccessDenied", "GetObject",
                       "Access Denied — no Allow matched for %s on %s" % ("s3:GetObject", arn))

    path = object_path(bucket, key)
    if not os.path.exists(path):
        raise AwsError("NoSuchKey", "GetObject", "The specified key does not exist.")
    with open(path, "rb") as fh:
        blob = fh.read()
    if blob[:8] == ENC_MAGIC:
        verdict, _ = evaluate(ipol, "kms:Decrypt",
                              bucket_config(bucket)["ServerSideEncryptionConfiguration"]["KMSMasterKeyID"], ctx)
        if verdict != "Allow":
            raise AwsError("AccessDenied", "GetObject",
                           "the ciphertext refers to a KMS key that %s is not allowed to use"
                           % who["principal"])
        blob = decrypt_bytes(blob)
        who["sse"] = "aws:kms"
    else:
        who["sse"] = None
    return who, blob
PY

  cat > "$BIN/imds.py" <<'PY'
#!/usr/bin/env python3
"""IMDSv2-compatible mock of the EC2 Instance Metadata Service.

Session-oriented requests only: a GET without a valid token is rejected with
401, exactly like an instance configured with HttpTokens=required. This is the
customer-side hardening that neutralises SSRF against 169.254.169.254.
"""
import json, os, secrets, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LAB = os.environ.get("SRM_LAB_ROOT", "/opt/srm-lab")
STATE = os.path.join(LAB, "state")
IAM = os.path.join(LAB, "iam")
TOKENS = set()


def read(path, default=""):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default


class Handler(BaseHTTPRequestHandler):
    server_version = "EC2ws"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("imds %s %s\n" % (self.address_string(), fmt % args))

    def _reply(self, code, body):
        blob = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Server", "EC2ws")
        self.end_headers()
        self.wfile.write(blob)

    def do_PUT(self):
        if self.path != "/latest/api/token":
            return self._reply(404, "Not Found")
        if not self.headers.get("X-aws-ec2-metadata-token-ttl-seconds"):
            return self._reply(400, "missing X-aws-ec2-metadata-token-ttl-seconds")
        token = "AQAE" + secrets.token_hex(16)
        TOKENS.add(token)
        self._reply(200, token)

    def do_GET(self):
        if self.headers.get("X-aws-ec2-metadata-token") not in TOKENS:
            return self._reply(401, "Unauthorized — IMDSv2 token required")
        role = read(os.path.join(STATE, "instance-profile"))
        if self.path == "/latest/meta-data/instance-id":
            return self._reply(200, read(os.path.join(STATE, "instance-id"), "i-unknown"))
        if self.path == "/latest/meta-data/iam/security-credentials/":
            return self._reply(200, role) if role else self._reply(404, "Not Found")
        if role and self.path == "/latest/meta-data/iam/security-credentials/" + role:
            return self._reply(200, read(os.path.join(IAM, "instance-profile-credentials.json")))
        self._reply(404, "Not Found")


if __name__ == "__main__":
    host = read(os.path.join(STATE, "imds-endpoint"), "169.254.169.254")
    ThreadingHTTPServer((host, 80), Handler).serve_forever()
PY

  cat > "$BIN/webapp.py" <<'PY'
#!/usr/bin/env python3
"""The customer workload. Reads one object from the lab bucket per request.

It never caches credentials, so every request re-walks the credential chain —
that is what makes the IAM failure visible in real time with curl.
"""
import os, sys, traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LAB = os.environ.get("SRM_LAB_ROOT", "/opt/srm-lab")
sys.path.insert(0, os.path.join(LAB, "bin"))
import srmlib  # noqa: E402

BUCKET = "srm-lab-customer-data"
KEY = "customer-records.csv"
WWW = os.path.join(LAB, "www")


class Handler(BaseHTTPRequestHandler):
    server_version = "srm-webapp/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("webapp %s %s\n" % (self.address_string(), fmt % args))

    def _reply(self, code, body, ctype="text/plain"):
        blob = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)

    def do_GET(self):
        if self.path.startswith("/healthz"):
            return self._reply(200, "ok\n")

        if self.path.startswith("/public/"):
            # Anything reachable here is served with NO authentication at all.
            name = os.path.basename(self.path)
            path = os.path.join(WWW, "public", name)
            if os.path.isfile(path):
                with open(path, "rb") as fh:
                    return self._reply(200, fh.read(), "text/csv")
            return self._reply(404, "not found\n")

        try:
            who, blob = srmlib.get_object(BUCKET, KEY)
        except srmlib.AwsError as exc:
            return self._reply(500, "workload error:\n  %s\n" % exc)
        except Exception:
            return self._reply(500, "unhandled error:\n%s\n" % traceback.format_exc())

        head = ("srm-webapp OK\n"
                "  credential source : %s\n"
                "  principal         : %s\n"
                "  object            : s3://%s/%s\n"
                "  encryption        : %s\n\n" %
                (who["source"], who["principal"], BUCKET, KEY, who["sse"] or "NONE"))
        return self._reply(200, head.encode() + blob)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("SRM_APP_PORT", "8080"))),
                        Handler).serve_forever()
PY

  cat > "$BIN/s3ctl" <<'PY'
#!/usr/bin/env python3
"""Lab stand-in for the AWS CLI. Every subcommand prints its real equivalent."""
import argparse, json, os, shutil, sys

LAB = os.environ.get("SRM_LAB_ROOT", "/opt/srm-lab")
sys.path.insert(0, os.path.join(LAB, "bin"))
import srmlib  # noqa: E402


def save_config(bucket, cfg):
    path = os.path.join(srmlib.bucket_dir(bucket), "bucket-config.json")
    with open(path, "w") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")


def cmd_whoami(_):
    who = srmlib.identify()
    print("credential source : %s" % who["source"])
    if who.get("path"):
        print("credential file   : %s" % who["path"])
    print("access key id     : %s" % who["access_key_id"])
    print("principal         : %s" % who["principal"])
    print("key status        : %s" % who["status"])
    print("# real equivalent : aws sts get-caller-identity")


def cmd_get(a):
    who, blob = srmlib.get_object(a.bucket, a.key, secure_transport=not a.no_tls)
    sys.stderr.write("# fetched as %s (sse=%s)\n" % (who["principal"], who["sse"] or "NONE"))
    sys.stdout.write(blob.decode())


def cmd_encrypt_bucket(a):
    cfg = srmlib.bucket_config(a.bucket)
    cfg["ServerSideEncryptionConfiguration"] = {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "arn:aws:kms:us-east-1:123456789012:key/lab-cmk"}
    save_config(a.bucket, cfg)
    objdir = os.path.join(srmlib.bucket_dir(a.bucket), "objects")
    os.makedirs(objdir, exist_ok=True)
    if a.seed and not os.listdir(objdir):
        shutil.copyfile(a.seed, os.path.join(objdir, "customer-records.csv"))
    for name in os.listdir(objdir):
        path = os.path.join(objdir, name)
        if srmlib.is_encrypted(path):
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        with open(path, "wb") as fh:
            fh.write(srmlib.encrypt_bytes(data))
        os.chmod(path, 0o640)
        print("re-encrypted with SSE-KMS: s3://%s/%s" % (a.bucket, name))
    print("default encryption : aws:kms")
    print("# real equivalent  : aws s3api put-bucket-encryption --bucket %s \\" % a.bucket)
    print("#                      --server-side-encryption-configuration file://sse.json")


def cmd_block_public_access(a):
    cfg = srmlib.bucket_config(a.bucket)
    cfg["PublicAccessBlockConfiguration"] = {k: True for k in
        ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")}
    save_config(a.bucket, cfg)
    print("Block Public Access: all four settings = true")
    print("# real equivalent  : aws s3api put-public-access-block --bucket %s \\" % a.bucket)
    print("#   --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,"
          "BlockPublicPolicy=true,RestrictPublicBuckets=true")


def cmd_set_acl(a):
    cfg = srmlib.bucket_config(a.bucket)
    cfg["ACL"] = a.acl
    save_config(a.bucket, cfg)
    print("bucket ACL: %s" % a.acl)
    print("# real equivalent : aws s3api put-bucket-acl --bucket %s --acl %s" % (a.bucket, a.acl))


def cmd_put_policy(a):
    with open(a.policy_file) as fh:
        doc = json.load(fh)          # parse first: never install a broken policy
    with open(os.path.join(srmlib.bucket_dir(a.bucket), "bucket-policy.json"), "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    print("bucket policy installed (%d statement(s))" % len(doc.get("Statement", [])))
    print("# real equivalent : aws s3api put-bucket-policy --bucket %s --policy file://%s"
          % (a.bucket, a.policy_file))


def cmd_describe(a):
    print(json.dumps(srmlib.bucket_config(a.bucket), indent=2))
    print(json.dumps(srmlib.bucket_policy(a.bucket), indent=2))


def main():
    p = argparse.ArgumentParser(prog="s3ctl", description="lab stand-in for the AWS CLI")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("whoami").set_defaults(func=cmd_whoami)

    g = sub.add_parser("get"); g.add_argument("bucket"); g.add_argument("key")
    g.add_argument("--no-tls", action="store_true",
                   help="simulate a plain-HTTP request (aws:SecureTransport=false)")
    g.set_defaults(func=cmd_get)

    e = sub.add_parser("encrypt-bucket"); e.add_argument("bucket")
    e.add_argument("--seed", default=None); e.set_defaults(func=cmd_encrypt_bucket)

    b = sub.add_parser("block-public-access"); b.add_argument("bucket")
    b.set_defaults(func=cmd_block_public_access)

    c = sub.add_parser("set-acl"); c.add_argument("bucket")
    c.add_argument("acl", choices=["private", "public-read"]); c.set_defaults(func=cmd_set_acl)

    d = sub.add_parser("put-policy"); d.add_argument("bucket"); d.add_argument("policy_file")
    d.set_defaults(func=cmd_put_policy)

    f = sub.add_parser("describe"); f.add_argument("bucket"); f.set_defaults(func=cmd_describe)

    args = p.parse_args()
    try:
        args.func(args)
    except srmlib.AwsError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
PY

  cat > "$BIN/srm-patch" <<'SH'
#!/usr/bin/env bash
# Guest OS package patching — on EC2 this is 100% the customer's responsibility.
# Real world: dnf/apt upgrade, an AMI rebuild, or AWS Systems Manager Patch Manager.
set -euo pipefail
LAB_ROOT="${SRM_LAB_ROOT:-/opt/srm-lab}"
cur="$(cat "$LAB_ROOT/agent/VERSION")"
fixed="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["LAB-2026-0001"]["fixed_in"])' "$LAB_ROOT/agent/advisories.json")"
if [ "$cur" = "$fixed" ]; then
  echo "srm-agent $cur — already at the fixed version, nothing to do"
  exit 0
fi
echo "srm-agent $cur -> $fixed  (advisory LAB-2026-0001, HIGH)"
printf '%s\n' "$fixed" > "$LAB_ROOT/agent/VERSION"
echo "patched. Real equivalent:"
echo "  sudo dnf -y update srm-agent        # or apt-get install --only-upgrade"
echo "  aws ssm send-command --document-name AWS-RunPatchBaseline --parameters Operation=Install"
SH
  chmod 0755 "$BIN/srm-patch"

  cat > "$BIN/srm-audit" <<'PY'
#!/usr/bin/env python3
"""Config/Trusted-Advisor style scorecard for the lab.

Each check is tagged with the side of the shared responsibility model it lives
on. The one AWS-side check is the trap: it must PASS untouched.
"""
import hashlib, json, os, subprocess, sys

LAB = os.environ.get("SRM_LAB_ROOT", "/opt/srm-lab")
sys.path.insert(0, os.path.join(LAB, "bin"))
import srmlib  # noqa: E402

BUCKET = "srm-lab-customer-data"
KEY = "customer-records.csv"
APP_USER = "srmapp"
APP_HOME = os.path.join(LAB, "home", APP_USER)
PORT = os.environ.get("SRM_APP_PORT", "8080")
QUIET = "--quiet" in sys.argv
RESULTS = []


def record(cid, owner, title, passed, detail):
    RESULTS.append((cid, owner, title, passed, detail))


def run(cmd, timeout=8):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout)
        return p.returncode, p.stdout.decode(errors="replace")
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except FileNotFoundError:
        return 127, "command not found"


def as_app(argv):
    runner = "runuser" if os.path.exists("/usr/sbin/runuser") or shutil_which("runuser") else "sudo"
    if runner == "runuser":
        return run(["runuser", "-u", APP_USER, "--", "env", "HOME=" + APP_HOME] + argv)
    return run(["sudo", "-u", APP_USER, "env", "HOME=" + APP_HOME] + argv)


def shutil_which(name):
    from shutil import which
    return which(name)


# 1 — inbound reachability (security group analogue)
ip = srmlib.primary_ip()
rc, out = run(["curl", "-fsS", "-m", "4", "http://%s:%s/healthz" % (ip, PORT)])
record("EC2-SG-INGRESS", "CUSTOMER", "tcp/%s reachable on %s" % (PORT, ip),
       rc == 0 and "ok" in out,
       "curl rc=%d (%s)" % (rc, "timeout => packets dropped by the filter"
                            if rc == 28 or "timeout" in out else out.strip()[:60]))

# 2 — the workload's effective identity
rc, out = as_app(["/usr/local/bin/s3ctl", "whoami"])
src = ""
for line in out.splitlines():
    if line.startswith("credential source"):
        src = line.split(":", 1)[1].strip()
record("IAM-CRED-CHAIN", "CUSTOMER", "workload authenticates with its instance profile",
       rc == 0 and src == "instance-profile",
       "resolved source: %s" % (src or out.strip().splitlines()[0] if out.strip() else "none"))

# 3 — end-to-end read through the app
rc, out = run(["curl", "-fsS", "-m", "6", "http://127.0.0.1:%s/" % PORT])
record("S3-GETOBJECT", "CUSTOMER", "application can read s3://%s/%s" % (BUCKET, KEY),
       rc == 0 and "srm-webapp OK" in out,
       out.strip().splitlines()[-1][:90] if out.strip() else "no response")

# 4 — public exposure
cfg = srmlib.bucket_config(BUCKET)
bpa = cfg.get("PublicAccessBlockConfiguration", {})
leak = os.path.join(LAB, "www", "public", KEY)
record("S3-PUBLIC-ACCESS", "CUSTOMER", "bucket is not publicly readable",
       all(bpa.get(k) for k in ("BlockPublicAcls", "IgnorePublicAcls",
                                "BlockPublicPolicy", "RestrictPublicBuckets"))
       and cfg.get("ACL") == "private" and not os.path.exists(leak),
       "BPA=%s ACL=%s unauthenticated_copy=%s"
       % (all(bpa.values()) if bpa else False, cfg.get("ACL"), os.path.exists(leak)))

# 5 — encryption at rest
record("S3-SSE-AT-REST", "CUSTOMER", "object is encrypted at rest with SSE-KMS",
       srmlib.is_encrypted(srmlib.object_path(BUCKET, KEY))
       and bool(cfg.get("ServerSideEncryptionConfiguration")),
       "ciphertext=%s default_sse=%s"
       % (srmlib.is_encrypted(srmlib.object_path(BUCKET, KEY)),
          (cfg.get("ServerSideEncryptionConfiguration") or {}).get("SSEAlgorithm")))

# 6 — encryption in transit, enforced by the bucket policy
try:
    srmlib.get_object(BUCKET, KEY, secure_transport=False)
    denied, why = False, "a plain-HTTP request was SERVED"
except srmlib.AwsError as exc:
    denied, why = exc.code == "AccessDenied", str(exc)[:90]
record("S3-TLS-ONLY", "CUSTOMER", "bucket policy denies non-TLS requests", denied, why)

# 7 — guest OS patch level
ver = open(os.path.join(LAB, "agent", "VERSION")).read().strip()
adv = json.load(open(os.path.join(LAB, "agent", "advisories.json")))["LAB-2026-0001"]
record("EC2-GUEST-PATCH", "CUSTOMER", "guest OS package free of LAB-2026-0001",
       tuple(map(int, ver.split("."))) >= tuple(map(int, adv["fixed_in"].split("."))),
       "srm-agent %s (fixed in %s)" % (ver, adv["fixed_in"]))

# 8 — the AWS side must be untouched
expected = open(os.path.join(LAB, "state", "aws-managed.sha256")).read().strip().splitlines()
intact, drift = True, ""
for line in expected:
    digest, rel = line.split(None, 1)
    path = os.path.join(LAB, "aws-managed", rel.strip().lstrip("./"))
    try:
        actual = hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        intact, drift = False, "%s is missing" % rel.strip()
        break
    if actual != digest:
        intact, drift = False, "%s was modified" % rel.strip()
        break
record("AWS-SIDE-INTEGRITY", "AWS", "AWS-managed components untouched by the customer",
       intact, drift or "all hashes match")

failed = [r for r in RESULTS if not r[3]]
if not QUIET:
    print()
    print("  %-20s %-9s %-46s %s" % ("CHECK", "OWNER", "CONTROL", "RESULT"))
    print("  " + "-" * 96)
    for cid, owner, title, passed, detail in RESULTS:
        mark = "\033[32mPASS\033[0m" if passed else "\033[31mFAIL\033[0m"
        print("  %-20s %-9s %-46s %s" % (cid, owner, title[:46], mark))
        if not passed:
            print("  %-20s %-9s   -> %s" % ("", "", detail))
    print()
    print("  score: %d/%d" % (len(RESULTS) - len(failed), len(RESULTS)))
    if failed:
        print("  still broken: %s" % ", ".join(r[0] for r in failed))
    else:
        print("  \033[32mall controls restored — the customer side of the line is clean\033[0m")
    print()
sys.exit(1 if failed else 0)
PY
  chmod 0755 "$BIN/srm-audit" "$BIN/s3ctl" "$BIN/imds.py" "$BIN/webapp.py"
}

write_units() {
  cat > /etc/systemd/system/srm-imds.service <<EOF
[Unit]
Description=SRM Lab mock EC2 Instance Metadata Service (IMDSv2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=SRM_LAB_ROOT=$LAB_ROOT
ExecStart=/usr/bin/env python3 $BIN/imds.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/srm-webapp.service <<EOF
[Unit]
Description=SRM Lab customer workload (reads one object per request)
After=srm-imds.service
Wants=srm-imds.service

[Service]
Type=simple
User=$APP_USER
Environment=SRM_LAB_ROOT=$LAB_ROOT
Environment=HOME=$APP_HOME
Environment=SRM_APP_PORT=$APP_PORT
ExecStart=/usr/bin/env python3 $BIN/webapp.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

install_symlinks() {
  ln -sf "$BIN/s3ctl"     /usr/local/bin/s3ctl
  ln -sf "$BIN/srm-audit" /usr/local/bin/srm-audit
  ln -sf "$BIN/srm-patch" /usr/local/bin/srm-patch
}

# -----------------------------------------------------------------------------
# break — four independent customer-side misconfigurations
# -----------------------------------------------------------------------------
do_break() {
  head1 "[break] injecting four customer-side misconfigurations"

  # BREAK 1 — the "security group" has no inbound rule for the app port.
  # DROP, not REJECT: that is why a real SG denial times out instead of
  # returning connection refused.
  if [ "$(fw_backend)" = "nft" ]; then
    nft delete table inet srm_sg 2>/dev/null || true
    nft add table inet srm_sg
    nft add chain inet srm_sg input '{ type filter hook input priority 0; policy accept; }'
    nft add rule inet srm_sg input tcp dport "$APP_PORT" counter drop \
      comment "sg-srm-lab-web: no ingress rule for tcp/$APP_PORT"
  else
    iptables -N SRM_SG 2>/dev/null || iptables -F SRM_SG
    iptables -C INPUT -j SRM_SG 2>/dev/null || iptables -I INPUT 1 -j SRM_SG
    iptables -A SRM_SG -p tcp --dport "$APP_PORT" -j DROP
  fi
  ok "break 1/4 applied (network ingress)"

  # BREAK 2 — a stale long-lived key shadows the instance profile. The
  # credential chain stops at the first provider that answers.
  install -d -o "$APP_USER" -g "$APP_USER" -m 0700 "$APP_HOME/.aws"
  cat > "$APP_HOME/.aws/credentials" <<EOF
[default]
aws_access_key_id = $LEGACY_AKID
aws_secret_access_key = $LEGACY_SECRET
EOF
  chown "$APP_USER":"$APP_USER" "$APP_HOME/.aws/credentials"
  chmod 0600 "$APP_HOME/.aws/credentials"
  ok "break 2/4 applied (identity and access management)"

  # BREAK 3 — data protection stripped: public, unencrypted, TLS not enforced.
  python3 - "$BUCKET/bucket-config.json" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["PublicAccessBlockConfiguration"] = {k: False for k in cfg["PublicAccessBlockConfiguration"]}
cfg["ACL"] = "public-read"
cfg["ServerSideEncryptionConfiguration"] = None
json.dump(cfg, open(path, "w"), indent=2)
PY
  printf '{\n  "Version": "2012-10-17",\n  "Statement": []\n}\n' > "$BUCKET/bucket-policy.json"
  python3 - "$LAB_ROOT" <<'PY'
import os, sys
LAB = sys.argv[1]
sys.path.insert(0, os.path.join(LAB, "bin"))
import srmlib
path = srmlib.object_path("srm-lab-customer-data", "customer-records.csv")
blob = open(path, "rb").read()
if blob[:8] == srmlib.ENC_MAGIC:
    blob = srmlib.decrypt_bytes(blob)
open(path, "wb").write(blob)                     # stored in the clear
os.chmod(path, 0o644)
leak = os.path.join(LAB, "www", "public", "customer-records.csv")
open(leak, "wb").write(blob)                     # served with no credentials
os.chmod(leak, 0o644)
PY
  ok "break 3/4 applied (data protection: at rest, in transit, exposure)"

  # BREAK 4 — guest OS rolled back below the fixed version.
  printf '1.0.2\n' > "$AGENT/VERSION"
  ok "break 4/4 applied (guest OS patch level)"

  systemctl restart srm-webapp.service
  sleep 1
}

# -----------------------------------------------------------------------------
# brief — what the student sees, what they must achieve
# -----------------------------------------------------------------------------
brief() {
  local ip; ip="$(python3 -c "import sys;sys.path.insert(0,'$BIN');import srmlib;print(srmlib.primary_ip())")"
  cat <<EOF

${C_BLD}${C_BLU}================================================================================
 CLF-C02 · Task 2.1 — Shared responsibility model · BREAK & FIX
================================================================================${C_OFF}

${C_BLD}THE SCENARIO${C_OFF}
You inherited one EC2 instance ($INSTANCE_ID) running a small internal
application. It reads a single object from s3://$BUCKET_NAME/ and
serves it on tcp/$APP_PORT. It worked yesterday. This morning it does not,
and a compliance scan is scheduled for this afternoon.

Four things are wrong. Every one of them is on ${C_BLD}your${C_OFF} side of the shared
responsibility model — "security ${C_BLD}IN${C_OFF} the cloud". Nothing that AWS is
responsible for has failed, and nothing you can do to the AWS side would help.

${C_BLD}SYMPTOMS YOU WILL SEE${C_OFF}

 1) From the network, the app is a black hole:
      curl -m 5 http://$ip:$APP_PORT/healthz
    ${C_YEL}hangs for the full timeout and then fails${C_OFF} — no "connection refused",
    no TCP reset, no reply at all. Meanwhile the process is alive:
      systemctl is-active srm-webapp   ->  active
      ss -ltnp | grep :$APP_PORT           ->  it IS listening
    A timeout with a healthy listener is the signature of a packet filter that
    ${C_BLD}drops${C_OFF} rather than rejects. That is exactly how a security group behaves
    when no inbound rule matches.

 2) Once you can reach it, the application answers HTTP 500:
      curl -s http://127.0.0.1:$APP_PORT/
      ${C_YEL}workload error:
        An error occurred (InvalidClientTokenId) when calling the GetObject
        operation: The security token included in the request is invalid.${C_OFF}
    The instance profile is attached and healthy — verify it yourself against
    IMDSv2. So why is the workload not using it? Compare:
      runuser -u $APP_USER -- env HOME=$APP_HOME s3ctl whoami
      s3ctl whoami        # as root, same machine, different answer
    Two identities on one instance. Explain the difference before you fix it.

 3) The compliance scan will find the data itself:
      srm-audit
    ${C_YEL}S3-PUBLIC-ACCESS FAIL · S3-SSE-AT-REST FAIL · S3-TLS-ONLY FAIL${C_OFF}
    and worse, this returns customer records to anyone, unauthenticated:
      curl -s http://$ip:$APP_PORT/public/customer-records.csv

 4) The guest OS carries an open HIGH advisory:
      srm-audit    ->  ${C_YEL}EC2-GUEST-PATCH FAIL — srm-agent 1.0.2 (fixed in 1.0.3)${C_OFF}
    Note the file $AWS_MANAGED/managed-service-patch-level.txt:
    a managed database in the same account is already patched, by AWS, with no
    action from you. Same account, same region, opposite side of the line.

${C_BLD}WHAT YOU MUST ACHIEVE${C_OFF}
  * ${C_GRN}srm-audit${C_OFF} exits 0 with 8/8 PASS.
  * The application answers HTTP 200 on http://$ip:$APP_PORT/ and reports
    "credential source : instance-profile".
  * The object is unreadable without credentials and unreadable at rest.
  * A non-TLS request to the bucket is denied by the bucket policy, not by luck.

${C_BLD}THE ONE RULE${C_OFF}
  ${C_RED}Do not modify anything under $AWS_MANAGED/.${C_OFF}
  Those files stand for the hypervisor, the physical datacenter and a managed
  service's patch level: "security ${C_BLD}OF${C_OFF} the cloud". Check AWS-SIDE-INTEGRITY
  is the trap — if you change a byte there, you fail the lab, because in a real
  account that action has no API, no console button and no support case.

${C_BLD}TOOLS ON THE BOX${C_OFF}
  s3ctl whoami | get | describe | encrypt-bucket | block-public-access |
        set-acl | put-policy         (each prints its real 'aws' equivalent)
  srm-audit          graded scorecard, exit 0 when clean
  srm-patch          guest OS package update
  systemctl / journalctl -u srm-webapp -n 50 / ss -ltnp / nft list ruleset
  curl -sv -X PUT http://\$(cat $STATE/imds-endpoint)/latest/api/token \\
       -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'      # IMDSv2 by hand

  Hints without answers:  sudo $0 hint
  Re-break to practise:   sudo $0 rebreak
  Remove the lab:         sudo $0 clean

EOF
}

hint() {
  cat <<EOF

${C_BLD}HINT 1 — ingress${C_OFF}
  A security group is stateful and allow-only: absent rule == dropped packet,
  which is why you see a timeout and not a reset. Find the equivalent rule:
    nft -a list ruleset            # note the 'handle N' on the drop rule
    iptables -L SRM_SG -n -v --line-numbers
  You need the accept to be evaluated BEFORE the drop, or the drop gone.

${C_BLD}HINT 2 — identity${C_OFF}
  Read $BIN/srmlib.py, function resolve_credentials().
  The chain returns the FIRST provider that yields anything. It does not
  validate it, and it does not fall through on failure. Now ask: what file
  exists in $APP_HOME that did not exist yesterday?
  Real-world rule this teaches: on EC2, use the instance role. A long-lived
  key on an instance is a credential you must rotate, protect and eventually
  explain in an incident report.

${C_BLD}HINT 3 — data${C_OFF}
    s3ctl describe $BUCKET_NAME
  Compare what you see with the four Block Public Access settings, the bucket
  ACL, the default encryption configuration, and the number of statements in
  the bucket policy. A template of the missing policy is already on disk:
    ls $TEMPLATES/
  Also: an object copy escaped the bucket. Where does the app serve /public/ from?

${C_BLD}HINT 4 — patching${C_OFF}
    cat $AGENT/VERSION ; cat $AGENT/advisories.json
  Then ask who patches an EC2 guest OS, and who patches an RDS engine.

EOF
}

clean() {
  head1 "[clean] removing every artifact created by this lab"
  systemctl disable --now srm-webapp.service srm-imds.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/srm-webapp.service /etc/systemd/system/srm-imds.service
  systemctl daemon-reload
  nft delete table inet srm_sg 2>/dev/null || true
  if command -v iptables >/dev/null 2>&1; then
    iptables -D INPUT -j SRM_SG 2>/dev/null || true
    iptables -F SRM_SG 2>/dev/null || true
    iptables -X SRM_SG 2>/dev/null || true
  fi
  ip addr del 169.254.169.254/32 dev lo 2>/dev/null || true
  ip addr del 127.0.0.169/32 dev lo 2>/dev/null || true
  rm -f /usr/local/bin/s3ctl /usr/local/bin/srm-audit /usr/local/bin/srm-patch
  command -v chattr >/dev/null 2>&1 && chattr -i "$AWS_MANAGED"/* 2>/dev/null || true
  rm -rf "$LAB_ROOT"
  id -u "$APP_USER" >/dev/null 2>&1 && userdel "$APP_USER" 2>/dev/null || true
  ok "clean. Nothing of this lab remains on the VM."
}

# -----------------------------------------------------------------------------
main() {
  local action="run"
  for arg in "$@"; do
    case "$arg" in
      --force) FORCE=1 ;;
      run|verify|hint|rebreak|clean|setup|break) action="$arg" ;;
      -h|--help) sed -n '1,60p' "$0"; exit 0 ;;
      *) die "unknown argument: $arg" ;;
    esac
  done

  case "$action" in
    run)     preflight run;    setup; do_break; brief ;;
    setup)   preflight setup;  setup ;;
    break|rebreak)
             preflight rebreak
             [ -d "$LAB_ROOT" ] || die "lab not built yet — run: sudo $0 run"
             "$BIN/s3ctl" encrypt-bucket "$BUCKET_NAME" --seed "$STATE/plaintext-seed.csv" >/dev/null
             cp "$TEMPLATES/bucket-policy-tls-only.json" "$BUCKET/bucket-policy.json"
             "$BIN/s3ctl" block-public-access "$BUCKET_NAME" >/dev/null
             "$BIN/s3ctl" set-acl "$BUCKET_NAME" private >/dev/null
             rm -f "$WWW/public/customer-records.csv"
             do_break; brief ;;
    verify)  [ -x "$BIN/srm-audit" ] || die "lab not built yet — run: sudo $0 run"
             "$BIN/srm-audit" ;;
    hint)    hint ;;
    clean)   preflight clean; clean ;;
  esac
}

main "$@"

# =============================================================================
#  S O L U T I O N   —   step by step
#  Do not read past this line until srm-audit gives you 8/8, or until you have
#  genuinely stalled. Each step gives the lab command, the real AWS command it
#  stands for, and the sentence that matters for the exam.
# =============================================================================
#
# -----------------------------------------------------------------------------
# STEP 0 — Diagnose before touching anything
# -----------------------------------------------------------------------------
#   srm-audit                                  # 8 checks, owner column included
#   systemctl status srm-webapp --no-pager
#   journalctl -u srm-webapp -n 30 --no-pager
#   ss -ltnp | grep :8080
#
#   Reading the scorecard: seven checks are owned by CUSTOMER and one by AWS.
#   Only the seven are yours to fix, and all seven are failing or downstream of
#   a failure. That asymmetry IS the shared responsibility model: in a real
#   outage on IaaS, the overwhelming majority of what you can fix is on your
#   side of the line, and the fastest triage question is "which side is this?".
#
# -----------------------------------------------------------------------------
# STEP 1 — Network ingress (customer: firewall / security group configuration)
# -----------------------------------------------------------------------------
#   Diagnosis:
#     curl -m 5 http://<primary-ip>:8080/healthz   -> hangs, then exit 28
#     curl -m 5 http://127.0.0.1:8080/healthz      -> also hangs (rule is on
#                                                     dport, not on source)
#     ss -ltnp | grep :8080                        -> the listener is fine
#     nft -a list ruleset | sed -n '/srm_sg/,/}/p'
#
#   A DROP produces a timeout; nothing listening produces "connection refused"
#   (TCP RST). Distinguishing those two is the single most useful reflex when
#   an EC2 workload is "unreachable":
#     timeout            -> security group / NACL / route table / host firewall
#     connection refused -> the process is not listening where you think
#
#   Fix (nftables):
#     nft insert rule inet srm_sg input tcp dport 8080 accept
#     # or remove the offending rule outright:
#     nft -a list chain inet srm_sg input          # read the 'handle N'
#     nft delete rule inet srm_sg input handle N
#
#   Fix (iptables):
#     iptables -I SRM_SG 1 -p tcp --dport 8080 -j ACCEPT
#
#   Verify:
#     curl -sf http://<primary-ip>:8080/healthz     -> ok
#
#   Real AWS equivalent:
#     aws ec2 authorize-security-group-ingress \
#       --group-id sg-0123456789abcdef0 \
#       --protocol tcp --port 8080 --cidr 10.0.0.0/16
#
#   Exam sentence: AWS operates the VPC infrastructure and enforces the rules;
#   WHICH rules exist is the customer's decision, every time. A permissive
#   0.0.0.0/0 security group is never an AWS failure.
#
# -----------------------------------------------------------------------------
# STEP 2 — Identity (customer: IAM, credential hygiene)
# -----------------------------------------------------------------------------
#   Diagnosis:
#     curl -s http://127.0.0.1:8080/
#       -> InvalidClientTokenId ... The security token included in the request
#          is invalid.
#
#     # the instance profile itself is healthy — prove it with IMDSv2 by hand:
#     IMDS=$(cat /opt/srm-lab/state/imds-endpoint)
#     TOKEN=$(curl -sX PUT "http://$IMDS/latest/api/token" \
#                  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
#     curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
#          "http://$IMDS/latest/meta-data/iam/security-credentials/"
#       -> srm-lab-app-role
#     # note: without the token header you get 401. That is IMDSv2 doing its
#     #       job, and enabling it (HttpTokens=required) is a customer setting.
#
#     # two identities on one box:
#     s3ctl whoami                                     # root -> instance-profile
#     runuser -u srmapp -- env HOME=/opt/srm-lab/home/srmapp s3ctl whoami
#       -> credential source : shared-credentials-file
#       -> access key id     : AKIAEXAMPLELABKEY000
#       -> key status        : Inactive
#
#   Root cause: the credential chain is ordered, and the first provider that
#   returns a value wins — environment variables, then the shared credentials
#   file, then the instance profile. A stale ~/.aws/credentials silently
#   shadows a perfectly good role. The SDK does not "fall back" when those
#   credentials turn out to be invalid; there is nothing to fall back to,
#   because resolution already finished.
#
#   Fix:
#     mv /opt/srm-lab/home/srmapp/.aws/credentials \
#        /opt/srm-lab/home/srmapp/.aws/credentials.revoked-$(date +%F)
#     # in the real world you would also do the part that actually matters:
#     #   aws iam update-access-key --access-key-id AKIA... --status Inactive \
#     #       --user-name legacy-deploy-user
#     #   aws iam delete-access-key --access-key-id AKIA... --user-name legacy-deploy-user
#     systemctl restart srm-webapp
#
#   Verify:
#     curl -s http://127.0.0.1:8080/ | head -4
#       -> credential source : instance-profile
#       -> principal         : arn:aws:sts::123456789012:assumed-role/srm-lab-app-role/i-0abc1234lab5678de
#
#   Real AWS equivalent of the whole remediation:
#     aws ec2 associate-iam-instance-profile --instance-id i-... \
#         --iam-instance-profile Name=srm-lab-app-role
#     aws ec2 modify-instance-metadata-options --instance-id i-... \
#         --http-tokens required --http-put-response-hop-limit 1
#
#   Exam sentence: AWS runs IAM and guarantees it evaluates policies correctly.
#   WHO your principals are, what they may do, whether you use short-lived role
#   credentials or leave a 3-year-old access key on a disk — all customer.
#
# -----------------------------------------------------------------------------
# STEP 3 — Data protection (customer: exposure, encryption at rest and in transit)
# -----------------------------------------------------------------------------
#   Diagnosis:
#     s3ctl describe srm-lab-customer-data
#       -> PublicAccessBlockConfiguration: all four false
#       -> ACL: public-read
#       -> ServerSideEncryptionConfiguration: null
#       -> bucket policy: 0 statements
#     head -c 16 /opt/srm-lab/s3/buckets/srm-lab-customer-data/objects/customer-records.csv
#       -> readable CSV, i.e. no ciphertext, no "Salted__" envelope
#     curl -s http://<primary-ip>:8080/public/customer-records.csv
#       -> the records, to anybody, with no credentials
#
#   Fix, in this order (close the exposure first, then harden):
#     rm -f /opt/srm-lab/www/public/customer-records.csv
#     s3ctl block-public-access srm-lab-customer-data
#     s3ctl set-acl srm-lab-customer-data private
#     s3ctl encrypt-bucket srm-lab-customer-data
#     s3ctl put-policy srm-lab-customer-data \
#           /opt/srm-lab/templates/bucket-policy-tls-only.json
#
#   Verify:
#     s3ctl get srm-lab-customer-data customer-records.csv            # works
#     s3ctl get srm-lab-customer-data customer-records.csv --no-tls   # AccessDenied
#     curl -s http://<primary-ip>:8080/public/customer-records.csv    # 404
#
#   Real AWS equivalents:
#     aws s3api put-public-access-block --bucket <b> \
#       --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,\
#     BlockPublicPolicy=true,RestrictPublicBuckets=true
#     aws s3api put-bucket-acl --bucket <b> --acl private
#     aws s3api put-bucket-encryption --bucket <b> \
#       --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":
#         {"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"arn:aws:kms:...:key/..."},
#         "BucketKeyEnabled":true}]}'
#     aws s3api put-bucket-policy --bucket <b> --policy file://tls-only.json
#
#   The TLS-only statement, verbatim (this is the one to memorise):
#     {"Version":"2012-10-17","Statement":[{
#       "Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*",
#       "Action":"s3:*",
#       "Resource":["arn:aws:s3:::<b>","arn:aws:s3:::<b>/*"],
#       "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
#
#   Exam sentence: AWS gives you the durability, the KMS HSMs, the TLS
#   endpoints and Block Public Access. Whether the bucket is public, whether
#   encryption is on, and WHAT you put in the object are the customer's — the
#   customer always owns the data itself and its classification.
#
# -----------------------------------------------------------------------------
# STEP 4 — Guest OS patching (customer on EC2; AWS on managed services)
# -----------------------------------------------------------------------------
#   Diagnosis:
#     cat /opt/srm-lab/agent/VERSION            -> 1.0.2
#     cat /opt/srm-lab/agent/advisories.json    -> LAB-2026-0001 fixed in 1.0.3
#
#   Fix:
#     srm-patch
#
#   Real AWS equivalents:
#     sudo dnf -y update                                  # or apt-get upgrade
#     aws ssm send-command --document-name AWS-RunPatchBaseline \
#         --targets Key=instanceids,Values=i-... --parameters Operation=Install
#     # or bake a new AMI with EC2 Image Builder and replace the instance
#
#   Then read, and do NOT modify:
#     cat /opt/srm-lab/aws-managed/managed-service-patch-level.txt
#
#   Exam sentence: the same task changes owner with the service model.
#   EC2 (IaaS): guest OS, kernel, packages, agents -> CUSTOMER.
#   RDS / ElastiCache / OpenSearch (managed): engine and underlying OS -> AWS.
#   Lambda / S3 / DynamoDB (serverless): the entire runtime -> AWS, and the
#   customer's surface shrinks to IAM, data and configuration.
#   This is why the model is sometimes drawn as a dial rather than a wall:
#   "inherited controls" grow as you move from EC2 toward serverless.
#
# -----------------------------------------------------------------------------
# STEP 5 — The trap: leave the AWS side alone
# -----------------------------------------------------------------------------
#   Nothing to do. If AWS-SIDE-INTEGRITY fails, you edited a file under
#   /opt/srm-lab/aws-managed/ — hypervisor firmware, physical datacenter
#   controls, or a managed engine's patch level. In a real account there is no
#   command that does that, and reaching for one is a diagnosis error, not a
#   permissions error. The correct customer actions on that side of the line
#   are exactly three:
#     1. rely on the SLA and the AWS Health Dashboard for availability events,
#     2. download the third-party attestations from AWS Artifact for auditors,
#     3. open a support case — you do not remediate, you escalate.
#   If you did modify a file, restore it and re-baseline honestly:
#     sudo /path/to/srm-lab.sh clean && sudo /path/to/srm-lab.sh run
#
# -----------------------------------------------------------------------------
# STEP 6 — Final verification
# -----------------------------------------------------------------------------
#   srm-audit ; echo "exit=$?"          # expect 8/8 PASS and exit=0
#   curl -s http://<primary-ip>:8080/ | head -5
#
#   Then tear the VM down:
#     sudo /path/to/srm-lab.sh clean
#
# -----------------------------------------------------------------------------
#  THE ONE-PARAGRAPH TAKEAWAY (this is what Task 2.1 actually tests)
# -----------------------------------------------------------------------------
#  AWS is responsible for security OF the cloud: the hardware, the global
#  infrastructure (Regions, AZs, edge locations), the hypervisor and the
#  software of managed services. The customer is responsible for security IN
#  the cloud: guest OS and patching on EC2, network and firewall configuration,
#  IAM principals and policies, client- and server-side encryption choices,
#  and the data itself, always. Some controls are shared (patch management,
#  configuration management, awareness and training), and the boundary moves
#  with the service model — never with the vendor. Four failures in this lab,
#  four customer-side root causes, zero AWS-side actions available. That ratio
#  is the point.
#
#  SOURCES
#   - CLF-C02 exam guide:
#     https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#   - https://aws.amazon.com/compliance/shared-responsibility-model/
#   - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html
#   - https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
#   - https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html
#   - https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
#   - https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html
#   - https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html
# =============================================================================