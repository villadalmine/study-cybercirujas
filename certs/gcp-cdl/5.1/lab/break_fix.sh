#!/usr/bin/env bash
# =============================================================================
#  Google Cloud Digital Leader (gcp-cdl) — exam version 2026-08-12
#  Domain 5 · Topic 5.1 — Describe fundamental cloud security concepts (9.0%)
#
#  BREAK & FIX LAB — "The Friday deploy that turned a private bucket public"
#
#  What this script does
#  ---------------------
#  It builds a self-contained, teaching-grade stand-in for a Cloud Storage
#  bucket fronted by a JSON API: a TLS listener, an IAM allow-policy engine
#  (bindings -> roles -> permissions), envelope-style encryption at rest with a
#  key held in a "key ring", and an audit log in the shape of a Cloud Audit
#  Logs entry. Then it BREAKS four things that map one-to-one to the four
#  security concepts this exam objective is built on:
#
#     Fault 1  IAM / least privilege        -> public data exposure
#     Fault 2  Encryption in transit        -> credentials and payload on the wire
#     Fault 3  Encryption at rest / KMS     -> plaintext blobs + key next to data
#     Fault 4  Auditability / defence in depth -> no traceability of access
#
#  Everything lives under one disposable directory ($LAB_ROOT). The script
#  never touches system packages, system services, /etc, firewall rules, users,
#  or anything outside that directory. It refuses to run as root, and it binds
#  its listener to 127.0.0.1 on an unprivileged port. It is still intended for
#  a THROWAWAY lab VM: treat every file it creates as compromised by design.
#
#  Usage
#  -----
#     ./break-fix-5.1.sh              # build the lab, break it, print briefing
#     ./break-fix-5.1.sh verify       # score yourself (exit 0 == fully fixed)
#     ./break-fix-5.1.sh status       # current posture of the environment
#     ./break-fix-5.1.sh hint [1-4]   # progressive hints, one fault at a time
#     ./break-fix-5.1.sh logs         # server log + audit log
#     ./break-fix-5.1.sh start|stop|restart
#     ./break-fix-5.1.sh reset        # roll back to the known-good state
#     ./break-fix-5.1.sh break        # re-inject the faults
#     ./break-fix-5.1.sh destroy      # delete the lab directory
#
#  Environment overrides: LAB_ROOT, LAB_PORT
#
#  Official sources
#  ----------------
#   - Cloud Digital Leader exam guide:
#     https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#   - Shared responsibility / shared fate:
#     https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
#   - IAM overview: https://cloud.google.com/iam/docs/overview
#   - Using IAM securely (least privilege):
#     https://cloud.google.com/iam/docs/using-iam-securely
#   - Public access prevention:
#     https://cloud.google.com/storage/docs/public-access-prevention
#   - Default encryption at rest:
#     https://cloud.google.com/docs/security/encryption/default-encryption
#   - Encryption in transit:
#     https://cloud.google.com/docs/security/encryption-in-transit
#   - Cloud KMS key rotation: https://cloud.google.com/kms/docs/key-rotation
#   - Cloud Audit Logs: https://cloud.google.com/logging/docs/audit
#   - Zero trust / BeyondCorp: https://cloud.google.com/beyondcorp
#
#  The step-by-step solution is at the END of this file, commented out.
#  Do not read it until `verify` has beaten you at least twice.
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Lab constants                                                               #
# --------------------------------------------------------------------------- #
LAB_ID="gcp-cdl-5.1"
LAB_ROOT="${LAB_ROOT:-$HOME/labs/${LAB_ID}}"
LAB_PORT="${LAB_PORT:-18443}"
LAB_MARKER=".disposable-lab-do-not-use-in-production"

PROJECT="lab-fin-prod-01"
BUCKET="lab-finance-prod"
OBJECT="q3-payroll.csv"

SRE="sre-oncall@lab.example.com"
INTERN="data-intern@lab.example.com"
ETL="etl-writer@${PROJECT}.iam.gserviceaccount.com"

SELF="$(basename "$0")"

# --------------------------------------------------------------------------- #
# Output helpers                                                              #
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
  C_Y=$'\033[33m'; C_C=$'\033[36m'; C_D=$'\033[2m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_D=""
fi

hdr()  { printf '\n%s%s%s\n' "$C_B$C_C" "$*" "$C_RST"; }
say()  { printf '%s\n' "$*"; }
info() { printf '%s[info]%s %s\n' "$C_D" "$C_RST" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_G" "$C_RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()  { printf '%s[fail]%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$C_D" "----------------------------------------------------------------------" "$C_RST"; }

# --------------------------------------------------------------------------- #
# Guardrails — this is destructive by design, so bound the blast radius        #
# --------------------------------------------------------------------------- #
guard() {
  [ "${EUID:-$(id -u)}" -ne 0 ] || die "refusing to run as root: this lab needs no privilege, and a root-owned break is a bad habit to teach."

  case "$LAB_ROOT" in
    ""|"/"|"$HOME"|"/etc"|"/usr"|"/var"|"/opt"|"/home")
      die "LAB_ROOT='$LAB_ROOT' is not a disposable directory. Point LAB_ROOT somewhere throwaway." ;;
  esac

  if [ -e "$LAB_ROOT" ] && [ ! -e "$LAB_ROOT/$LAB_MARKER" ]; then
    die "'$LAB_ROOT' exists and is not a lab directory (missing $LAB_MARKER). Refusing to touch it."
  fi

  for bin in python3 openssl curl awk sed tar find; do
    command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"
  done
  python3 -c 'import ssl, http.server, json' 2>/dev/null || die "python3 lacks ssl/http.server/json support"
}

require_lab() {
  [ -e "$LAB_ROOT/$LAB_MARKER" ] || die "lab not built yet. Run: ./$SELF"
}

# --------------------------------------------------------------------------- #
# Small utilities                                                             #
# --------------------------------------------------------------------------- #
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "???"; }
sha256_of() { openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'; }
obj_path()  { printf '%s/data/objects/%s/%s' "$LAB_ROOT" "$BUCKET" "$OBJECT"; }
key_path()  { printf '%s/kms/keyring/prod-key.b64' "$LAB_ROOT"; }
api_url()   { printf '%s://127.0.0.1:%s/v1/b/%s/o/%s' "$1" "$LAB_PORT" "$BUCKET" "$OBJECT"; }

conf_get() {
  awk -F= -v k="$1" '$1==k {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; found=1}
                     END{ if(!found) print "" }' "$LAB_ROOT/etc/server.conf" 2>/dev/null | head -1
}

conf_set() {
  local k="$1" v="$2" f="$LAB_ROOT/etc/server.conf"
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    sed -i.bak "s|^${k}=.*|${k}=${v}|" "$f" && rm -f "${f}.bak"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

# HTTPS GET as a principal. $1 = email or "" for anonymous. $2 = body sink.
# Prints the HTTP status code, or 000 when the transport itself failed.
get_as() {
  local principal="${1:-}" sink="${2:-/dev/null}" code=""
  local args=(-s -m 6 -o "$sink" -w '%{http_code}' --cacert "$LAB_ROOT/tls/server.crt")
  [ -n "$principal" ] && args+=(-H "Authorization: Bearer ${principal}")
  code="$(curl "${args[@]}" "$(api_url https)" 2>/dev/null)" || code=""
  [ -n "$code" ] || code="000"
  printf '%s' "$code"
}

# Same request over cleartext HTTP. Used to prove whether a plaintext listener
# is answering — on a correctly configured endpoint this must fail outright.
get_cleartext() {
  local sink="${1:-/dev/null}" code=""
  code="$(curl -s -m 6 -o "$sink" -w '%{http_code}' "$(api_url http)" 2>/dev/null)" || code=""
  [ -n "$code" ] || code="000"
  printf '%s' "$code"
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/${LAB_PORT}") >/dev/null 2>&1; }

# --------------------------------------------------------------------------- #
# Server lifecycle                                                            #
# --------------------------------------------------------------------------- #
server_pid() {
  local f="$LAB_ROOT/var/run/object-api.pid"
  [ -f "$f" ] || return 1
  local pid; pid="$(cat "$f" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

start_server() {
  if server_pid >/dev/null 2>&1; then info "object API already running (pid $(server_pid))"; return 0; fi
  mkdir -p "$LAB_ROOT/var/run" "$LAB_ROOT/var/log"
  nohup python3 "$LAB_ROOT/bin/object-api.py" >>"$LAB_ROOT/var/log/server.log" 2>&1 &
  echo $! > "$LAB_ROOT/var/run/object-api.pid"
  local i=0
  while [ $i -lt 40 ]; do
    port_open && break
    sleep 0.25; i=$((i+1))
  done
  if port_open; then
    ok "object API listening on 127.0.0.1:${LAB_PORT} (tls=$(conf_get tls))"
  else
    warn "object API did not open port ${LAB_PORT}; see: ./$SELF logs"
  fi
}

stop_server() {
  local pid
  if pid="$(server_pid 2>/dev/null)"; then
    kill "$pid" 2>/dev/null || true
    local i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 20 ]; do sleep 0.2; i=$((i+1)); done
    kill -9 "$pid" 2>/dev/null || true
    ok "object API stopped"
  else
    info "object API was not running"
  fi
  rm -f "$LAB_ROOT/var/run/object-api.pid"
}

# --------------------------------------------------------------------------- #
# SETUP — build the known-good environment                                     #
# --------------------------------------------------------------------------- #
write_server() {
  cat > "$LAB_ROOT/bin/object-api.py" <<'PY'
#!/usr/bin/env python3
"""object-api.py

A deliberately small stand-in for a Cloud Storage JSON API endpoint, used by
the gcp-cdl 5.1 break & fix lab. It models four production controls:

  * TLS termination            -> encryption in transit
  * IAM allow policy evaluation -> authorization / least privilege
  * envelope encryption on read -> encryption at rest (AES-256-CBC via openssl)
  * append-only access log      -> Cloud Audit Logs (DATA_READ)

Config is re-read per request for policy and audit (IAM changes propagate
without a restart, exactly as they do on Google Cloud), while the TLS listener
is bound once at startup (changing it requires a restart, also as in reality).
"""
from __future__ import annotations

import http.server
import json
import os
import ssl
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONF_F = os.path.join(ROOT, "etc", "server.conf")
POLICY_F = os.path.join(ROOT, "iam", "policy.json")
KEY_F = os.path.join(ROOT, "kms", "keyring", "prod-key.b64")
OBJ_D = os.path.join(ROOT, "data", "objects")
AUDIT_F = os.path.join(ROOT, "var", "log", "audit.log")
TLS_CRT = os.path.join(ROOT, "tls", "server.crt")
TLS_KEY = os.path.join(ROOT, "tls", "server.key")

# A cut-down copy of the predefined-role -> permission mapping. The exam only
# asks you to reason about it; production asks you to keep it minimal.
ROLE_PERMISSIONS = {
    "roles/owner": {
        "storage.objects.get", "storage.objects.create",
        "storage.buckets.setIamPolicy", "resourcemanager.projects.setIamPolicy",
    },
    "roles/editor": {"storage.objects.get", "storage.objects.create"},
    "roles/viewer": {"storage.objects.get"},
    "roles/storage.admin": {
        "storage.objects.get", "storage.objects.create", "storage.buckets.setIamPolicy",
    },
    "roles/storage.objectAdmin": {"storage.objects.get", "storage.objects.create"},
    "roles/storage.objectViewer": {"storage.objects.get"},
}

TRUTHY = {"on", "true", "1", "yes", "enabled"}

DEFAULTS = {
    "bind": "127.0.0.1",
    "port": "18443",
    "tls": "on",
    "encryption_at_rest": "on",
    "audit_logging": "on",
}


def load_conf():
    conf = dict(DEFAULTS)
    try:
        with open(CONF_F, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                key, _, value = line.partition("=")
                conf[key.strip()] = value.strip()
    except FileNotFoundError:
        pass
    return conf


def load_policy():
    try:
        with open(POLICY_F, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:  # a malformed policy must fail closed, never open
        sys.stderr.write("[policy] unreadable (%s) -> failing closed\n" % exc)
        return {"bindings": []}


def evaluate(principal: str, permission: str, policy: dict):
    """Return (granted, role, matched_member). Fail-closed by default."""
    for binding in policy.get("bindings", []):
        role = binding.get("role", "")
        if permission not in ROLE_PERMISSIONS.get(role, set()):
            continue
        for member in binding.get("members", []):
            if member == principal:
                return True, role, member
            if member == "allUsers":
                return True, role, member
            if member == "allAuthenticatedUsers" and principal != "allUsers":
                return True, role, member
    return False, None, None


def read_object(path: str):
    """Return (bytes, at_rest_state). 'Salted__' is the openssl enc header."""
    with open(path, "rb") as fh:
        blob = fh.read()
    if blob[:8] != b"Salted__":
        return blob, "PLAINTEXT_AT_REST"
    proc = subprocess.run(
        ["openssl", "enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", "100000",
         "-pass", "file:" + KEY_F],
        input=blob, capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", "replace")[:200].strip())
    return proc.stdout, "CMEK_AES_256_CBC"


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "lab-object-api/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s - %s\n" % (
            datetime.now(timezone.utc).isoformat(timespec="seconds"),
            self.address_string(), fmt % args))

    # ---------------------------------------------------------------- audit
    def audit(self, principal, resource, permission, granted, role, status):
        conf = load_conf()
        if conf.get("audit_logging", "on").lower() not in TRUTHY:
            return  # the fault: access happens, nothing is recorded
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "logName": "projects/lab-fin-prod-01/logs/cloudaudit.googleapis.com%2Fdata_access",
            "severity": "INFO",
            "protoPayload": {
                "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
                "methodName": "storage.objects.get",
                "resourceName": resource,
                "authenticationInfo": {"principalEmail": principal},
                "authorizationInfo": [
                    {"permission": permission, "granted": granted, "role": role}
                ],
                "requestMetadata": {
                    "callerIp": self.client_address[0],
                    "callerSuppliedUserAgent": self.headers.get("User-Agent", "-"),
                    "requestAttributes": {"scheme": "https" if self.is_tls() else "http"},
                },
                "status": {"code": 0 if granted else 7, "httpStatus": status},
            },
        }
        try:
            with open(AUDIT_F, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(entry, separators=(",", ":")) + "\n")
        except Exception as exc:
            sys.stderr.write("[audit] write failed: %s\n" % exc)

    def is_tls(self):
        return isinstance(self.connection, ssl.SSLSocket)

    # ----------------------------------------------------------------- send
    def send_body(self, code, body: bytes, ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, code, payload, extra=None):
        body = (json.dumps(payload, indent=2) + "\n").encode("utf-8")
        self.send_body(code, body, "application/json; charset=utf-8", extra)

    # ------------------------------------------------------------------ GET
    def do_GET(self):
        conf = load_conf()
        path = urllib.parse.urlparse(self.path).path

        if path in ("/healthz", "/"):
            self.send_json(200, {
                "status": "SERVING",
                "tls": self.is_tls(),
                "encryption_at_rest": conf.get("encryption_at_rest"),
                "audit_logging": conf.get("audit_logging"),
            })
            return

        parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
        if len(parts) != 5 or parts[0] != "v1" or parts[1] != "b" or parts[3] != "o":
            self.send_json(404, {"error": {"code": 404, "message": "no such route"}})
            return

        bucket, name = parts[2], parts[4]
        resource = "//storage.googleapis.com/projects/_/buckets/%s/objects/%s" % (bucket, name)

        auth = self.headers.get("Authorization", "")
        principal = "user:" + auth[7:].strip() if auth.lower().startswith("bearer ") else "allUsers"

        granted, role, member = evaluate(principal, "storage.objects.get", load_policy())
        if not granted:
            self.audit(principal, resource, "storage.objects.get", False, None, 403)
            self.send_json(403, {"error": {
                "code": 403, "status": "PERMISSION_DENIED",
                "message": "%s does not have storage.objects.get access to the object." % principal,
            }})
            return

        target = os.path.join(OBJ_D, bucket, name)
        if not os.path.isfile(target):
            self.audit(principal, resource, "storage.objects.get", True, role, 404)
            self.send_json(404, {"error": {"code": 404, "message": "No such object: %s/%s" % (bucket, name)}})
            return

        try:
            payload, at_rest = read_object(target)
        except Exception as exc:
            self.audit(principal, resource, "storage.objects.get", True, role, 500)
            self.send_json(500, {"error": {"code": 500, "message": "decrypt failed: %s" % exc}})
            return

        self.audit(principal, resource, "storage.objects.get", True, role, 200)
        self.send_body(200, payload, "text/csv; charset=utf-8", {
            "x-goog-lab-principal": principal,
            "x-goog-lab-granted-by": "%s via %s" % (role or "-", member or "-"),
            "x-goog-lab-encryption-at-rest": at_rest,
            "x-goog-lab-transport": "TLS" if self.is_tls() else "CLEARTEXT",
        })


def main():
    conf = load_conf()
    bind = conf.get("bind", "127.0.0.1")
    port = int(conf.get("port", "18443"))
    tls_on = conf.get("tls", "on").lower() in TRUTHY

    httpd = http.server.ThreadingHTTPServer((bind, port), Handler)
    if tls_on:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(TLS_CRT, TLS_KEY)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    sys.stderr.write("[startup] %s://%s:%d tls=%s at_rest=%s audit=%s\n" % (
        "https" if tls_on else "http", bind, port, tls_on,
        conf.get("encryption_at_rest"), conf.get("audit_logging")))
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
PY
  chmod 0755 "$LAB_ROOT/bin/object-api.py"
}

write_good_policy() {
  cat > "$LAB_ROOT/iam/policy.json" <<EOF
{
  "version": 3,
  "etag": "BwXlabPolicyEtag=",
  "resource": "//storage.googleapis.com/projects/_/buckets/${BUCKET}",
  "bindings": [
    {
      "role": "roles/storage.objectViewer",
      "members": [
        "user:${SRE}",
        "user:${INTERN}"
      ]
    },
    {
      "role": "roles/storage.objectAdmin",
      "members": [
        "serviceAccount:${ETL}"
      ]
    }
  ]
}
EOF
  chmod 0640 "$LAB_ROOT/iam/policy.json"
}

write_good_conf() {
  cat > "$LAB_ROOT/etc/server.conf" <<EOF
# Object API runtime configuration (${PROJECT} / ${BUCKET})
# tls                 : terminate TLS on the listener (read at STARTUP -> restart to apply)
# encryption_at_rest  : encrypt object payloads with the key ring DEK on write
# audit_logging       : emit a Cloud-Audit-Logs-shaped DATA_READ entry per access
bind=127.0.0.1
port=${LAB_PORT}
tls=on
encryption_at_rest=on
audit_logging=on
EOF
  chmod 0640 "$LAB_ROOT/etc/server.conf"
}

setup() {
  if [ -e "$LAB_ROOT/$LAB_MARKER" ]; then
    info "lab already present at $LAB_ROOT (use 'reset' to roll back, 'destroy' to remove)"
    return 0
  fi

  hdr "[1/6] Provisioning the lab environment at ${LAB_ROOT}"
  mkdir -p "$LAB_ROOT"/{bin,etc,iam,tls,kms/keyring,data/objects/"$BUCKET",var/log,var/run,state,.golden}
  : > "$LAB_ROOT/$LAB_MARKER"
  printf 'Disposable lab for %s. Everything here is intentionally insecure at some point.\n' "$LAB_ID" \
    > "$LAB_ROOT/$LAB_MARKER"
  chmod 0700 "$LAB_ROOT"

  write_server
  write_good_conf
  write_good_policy

  hdr "[2/6] Issuing the TLS serving certificate (encryption in transit)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
    -keyout "$LAB_ROOT/tls/server.key" -out "$LAB_ROOT/tls/server.crt" \
    -subj "/CN=localhost/O=Lab Finance/OU=${PROJECT}" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 \
    || openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
         -keyout "$LAB_ROOT/tls/server.key" -out "$LAB_ROOT/tls/server.crt" \
         -subj "/CN=localhost" >/dev/null 2>&1 \
    || die "openssl could not issue the serving certificate"
  chmod 0600 "$LAB_ROOT/tls/server.key"
  chmod 0644 "$LAB_ROOT/tls/server.crt"
  ok "self-signed cert issued (private key 0600, public cert 0644)"

  hdr "[3/6] Creating the data encryption key in the key ring"
  openssl rand -base64 32 > "$(key_path)"
  chmod 0600 "$(key_path)"
  chmod 0700 "$LAB_ROOT/kms" "$LAB_ROOT/kms/keyring"
  ok "DEK created: kms/keyring/prod-key.b64 (mode $(file_mode "$(key_path)"))"

  hdr "[4/6] Writing the confidential object, encrypted at rest"
  local plain="$LAB_ROOT/state/.plain.$$"
  cat > "$plain" <<'CSV'
employee_id,full_name,role,base_salary_usd,bonus_usd,bank_account_iban
E-1041,Ada Reyes,Staff SRE,182000,24000,ES91 2100 0418 4502 0005 1332
E-1077,Kenji Alvarez,Principal Architect,214000,41000,ES79 2100 0813 6101 2345 6789
E-1108,Noor Haddad,Security Engineer,171500,19500,ES15 0049 1500 0512 3456 7892
E-1150,Sam Okonkwo,Data Engineer,148000,12000,ES68 0075 0300 3406 0123 4567
CSV
  sha256_of "$plain" > "$LAB_ROOT/state/expected.sha256"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
    -pass file:"$(key_path)" -in "$plain" -out "$(obj_path)" \
    || die "encryption of the lab object failed"
  rm -f "$plain"
  chmod 0640 "$(obj_path)"
  ok "gs://${BUCKET}/${OBJECT} stored with AES-256 (header: $(head -c 8 "$(obj_path)"))"

  hdr "[5/6] Enabling audit logging"
  : > "$LAB_ROOT/var/log/audit.log"
  chmod 0640 "$LAB_ROOT/var/log/audit.log"
  ok "var/log/audit.log ready (mode 0640, append-only by convention)"

  hdr "[6/6] Starting the object API and snapshotting the known-good state"
  start_server
  tar -C "$LAB_ROOT" --exclude=./.golden --exclude=./var/run -czf "$LAB_ROOT/.golden/known-good.tgz" . 2>/dev/null
  ok "golden snapshot saved (./$SELF reset restores it)"
}

# --------------------------------------------------------------------------- #
# BREAK — four controlled, reversible faults                                   #
# --------------------------------------------------------------------------- #
break_lab() {
  hdr "Injecting faults (controlled, reversible, confined to ${LAB_ROOT})"

  # ---- Fault 1: IAM. A "temporary" grant that made it to production. -------
  cat > "$LAB_ROOT/iam/policy.json" <<EOF
{
  "version": 3,
  "etag": "BwXlabPolicyEtag=",
  "resource": "//storage.googleapis.com/projects/_/buckets/${BUCKET}",
  "bindings": [
    {
      "role": "roles/storage.objectViewer",
      "members": [
        "user:${SRE}",
        "user:${INTERN}",
        "allUsers"
      ]
    },
    {
      "role": "roles/owner",
      "members": [
        "user:${INTERN}"
      ]
    },
    {
      "role": "roles/storage.objectAdmin",
      "members": [
        "serviceAccount:${ETL}"
      ]
    }
  ]
}
EOF
  ok "fault 1 injected — IAM allow policy rewritten"

  # ---- Fault 2: TLS termination disabled on the listener. ------------------
  conf_set tls off
  ok "fault 2 injected — listener configuration changed"

  # ---- Fault 3: key handling and encryption at rest. -----------------------
  chmod 0644 "$(key_path)"
  cp "$(key_path)" "$LAB_ROOT/data/objects/${BUCKET}/prod-key.b64.bak"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass file:"$(key_path)" \
    -in "$(obj_path)" -out "$(obj_path).tmp" 2>/dev/null \
    && mv "$(obj_path).tmp" "$(obj_path)"
  chmod 0644 "$(obj_path)"
  conf_set encryption_at_rest off
  ok "fault 3 injected — key ring and object storage state changed"

  # ---- Fault 4: audit trail. ----------------------------------------------
  conf_set audit_logging off
  : > "$LAB_ROOT/var/log/audit.log"
  chmod 0666 "$LAB_ROOT/var/log/audit.log"
  ok "fault 4 injected — logging pipeline changed"

  stop_server
  start_server
}

# --------------------------------------------------------------------------- #
# BRIEFING                                                                     #
# --------------------------------------------------------------------------- #
briefing() {
  local crt="$LAB_ROOT/tls/server.crt"
  cat <<EOF

${C_B}${C_C}================================================================================
 INCIDENT BRIEFING — gcp-cdl 5.1 · fundamental cloud security concepts
================================================================================${C_RST}

${C_B}Context${C_RST}
  You are the on-call engineer for project ${C_B}${PROJECT}${C_RST}. A payroll export
  lives in ${C_B}gs://${BUCKET}/${OBJECT}${C_RST}, served by a small object API on
  127.0.0.1:${LAB_PORT}. Last Friday somebody "unblocked an intern" at 18:40 and
  pushed a config change with it. Nothing alerted, because the thing that would
  have alerted was part of the change.

  The provider secures the underlying infrastructure. Everything you are about
  to fix — identity and access, key handling, transport configuration, logging —
  is on ${C_B}your${C_RST} side of the shared responsibility model. That division is the
  single most tested idea in this exam objective.

${C_B}Lab root${C_RST}   ${LAB_ROOT}
${C_B}Endpoint${C_RST}   https://127.0.0.1:${LAB_PORT}/v1/b/${BUCKET}/o/${OBJECT}
${C_B}CA cert${C_RST}    ${crt}   (self-signed: pass it with --cacert)
${C_B}Principals${C_RST} ${SRE} (on-call), ${INTERN} (needs read-only), ${ETL} (writer SA)

${C_B}${C_Y}SYMPTOM 1 — anyone on the internet can read payroll${C_RST}
  Reproduce (note: no credential at all):
    ${C_D}curl -sk https://127.0.0.1:${LAB_PORT}/v1/b/${BUCKET}/o/${OBJECT}${C_RST}
  Expected symptom: HTTP 200 and the CSV, including IBANs, for an anonymous
  caller. Inspect ${C_B}iam/policy.json${C_RST} — one binding member turns a private
  bucket into a public website, and one role turns a read-only intern into a
  project owner.
  ${C_D}You must end with: anonymous -> 403, ${INTERN} -> 200.${C_RST}

${C_B}${C_Y}SYMPTOM 2 — TLS handshake fails, cleartext works${C_RST}
  Reproduce:
    ${C_D}curl -v --cacert ${crt} https://127.0.0.1:${LAB_PORT}/healthz${C_RST}
    ${C_D}curl -v http://127.0.0.1:${LAB_PORT}/healthz${C_RST}
  Expected symptom: the HTTPS call dies with an SSL error ("wrong version
  number"), while plain HTTP answers happily — the bearer token and the payroll
  rows are travelling in the clear. Check ${C_B}etc/server.conf${C_RST}.
  ${C_D}The TLS setting is read at startup only: config alone will not fix it.${C_RST}

${C_B}${C_Y}SYMPTOM 3 — the blob on disk is readable, and the key is next to it${C_RST}
  Reproduce:
    ${C_D}head -c 200 ${LAB_ROOT}/data/objects/${BUCKET}/${OBJECT}${C_RST}
    ${C_D}ls -l ${LAB_ROOT}/kms/keyring/ ${LAB_ROOT}/data/objects/${BUCKET}/${C_RST}
  Expected symptom: the object is plaintext CSV instead of an openssl
  "Salted__" ciphertext; the DEK is world-readable; and a copy of that key was
  backed up ${C_B}inside the bucket it protects${C_RST}, which is the same as no encryption.
  ${C_D}You must re-encrypt the object without changing its contents.${C_RST}

${C_B}${C_Y}SYMPTOM 4 — access leaves no trace${C_RST}
  Reproduce:
    ${C_D}wc -l ${LAB_ROOT}/var/log/audit.log${C_RST}   ${C_D}# after making the requests above${C_RST}
  Expected symptom: zero entries. Reads happen and nothing records who, when,
  from where, or under which role. The log file is also mode 0666, so anyone
  could rewrite history. Detective controls are the last layer of defence in
  depth; without them you cannot answer "what did the attacker take?".

${C_B}Your objective${C_RST}
  Bring every control back up so that:
    ${C_D}./$SELF verify${C_RST}
  reports 11/11 PASS and exits 0. Rules of engagement:
    * do ${C_B}not${C_RST} delete or truncate the object — its SHA-256 is checked
    * do ${C_B}not${C_RST} stop the service to "pass" the checks
    * ${INTERN} must keep read access to this one object
    * fix causes in the files, not symptoms in the checks

${C_B}Tools${C_RST}
  ${C_D}./$SELF verify | status | logs | hint 1..4 | reset | destroy${C_RST}

EOF
}

# --------------------------------------------------------------------------- #
# STATUS                                                                       #
# --------------------------------------------------------------------------- #
status() {
  hdr "Environment posture — ${LAB_ROOT}"
  if server_pid >/dev/null 2>&1; then
    ok "object API running (pid $(server_pid), port ${LAB_PORT})"
  else
    warn "object API not running"
  fi
  rule
  printf '  %-26s %s\n' "tls"                "$(conf_get tls)"
  printf '  %-26s %s\n' "encryption_at_rest" "$(conf_get encryption_at_rest)"
  printf '  %-26s %s\n' "audit_logging"      "$(conf_get audit_logging)"
  rule
  printf '  %-26s %s\n' "DEK mode"           "$(file_mode "$(key_path)")"
  printf '  %-26s %s\n' "object mode"        "$(file_mode "$(obj_path)")"
  printf '  %-26s %s\n' "audit.log mode"     "$(file_mode "$LAB_ROOT/var/log/audit.log")"
  printf '  %-26s %s\n' "object at rest"     "$( [ "$(head -c 8 "$(obj_path)" 2>/dev/null)" = "Salted__" ] && echo "ENCRYPTED" || echo "PLAINTEXT" )"
  printf '  %-26s %s\n' "audit entries"      "$(wc -l < "$LAB_ROOT/var/log/audit.log" 2>/dev/null || echo 0)"
  rule
  say "  IAM bindings currently in effect:"
  sed -n 's/^/    /p' "$LAB_ROOT/iam/policy.json"
  printf '\n'
}

logs() {
  hdr "var/log/server.log (last 20)"
  tail -n 20 "$LAB_ROOT/var/log/server.log" 2>/dev/null || say "  (empty)"
  hdr "var/log/audit.log (last 10)"
  tail -n 10 "$LAB_ROOT/var/log/audit.log" 2>/dev/null || say "  (empty)"
  printf '\n'
}

# --------------------------------------------------------------------------- #
# VERIFY — the scoreboard                                                      #
# --------------------------------------------------------------------------- #
PASS_N=0; FAIL_N=0

run_check() {
  local title="$1" fn="$2" hint="$3"
  if "$fn" >/dev/null 2>&1; then
    printf '  %s[PASS]%s %s\n' "$C_G" "$C_RST" "$title"
    PASS_N=$((PASS_N+1))
  else
    printf '  %s[FAIL]%s %s\n' "$C_R" "$C_RST" "$title"
    printf '         %s-> %s%s\n' "$C_D" "$hint" "$C_RST"
    FAIL_N=$((FAIL_N+1))
  fi
}

chk_service_up()      { server_pid >/dev/null 2>&1 && port_open; }

chk_tls_enforced()    { [ "$(get_as "$SRE" /dev/null)" = "200" ] && [ "$(conf_get tls)" = "on" ]; }

chk_no_cleartext()    { [ "$(get_cleartext /dev/null)" = "000" ]; }

chk_anon_denied()     { [ "$(get_as "" /dev/null)" = "403" ]; }

chk_no_public_member() {
  ! grep -Eq '"(allUsers|allAuthenticatedUsers)"' "$LAB_ROOT/iam/policy.json"
}

chk_least_privilege() {
  python3 - "$LAB_ROOT/iam/policy.json" "user:${INTERN}" <<'PY'
import json, sys
policy_file, member = sys.argv[1], sys.argv[2]
privileged = {"roles/owner", "roles/editor", "roles/storage.admin",
              "roles/storage.objectAdmin", "roles/viewer"}
with open(policy_file) as fh:
    policy = json.load(fh)
for binding in policy.get("bindings", []):
    if binding.get("role") in privileged and member in binding.get("members", []):
        sys.exit(1)
sys.exit(0)
PY
}

chk_intern_can_read() { [ "$(get_as "$INTERN" /dev/null)" = "200" ]; }

chk_key_locked()      { case "$(file_mode "$(key_path)")" in 600|400) return 0;; *) return 1;; esac; }

chk_no_key_in_bucket() {
  local dir="$LAB_ROOT/data" secret
  find "$dir" -type f -name '*key*' 2>/dev/null | grep -q . && return 1
  secret="$(head -1 "$(key_path)" 2>/dev/null || true)"
  [ -n "$secret" ] || return 1
  grep -RqF -- "$secret" "$dir" 2>/dev/null && return 1
  return 0
}

chk_encrypted_at_rest() {
  [ "$(head -c 8 "$(obj_path)" 2>/dev/null)" = "Salted__" ] && [ "$(conf_get encryption_at_rest)" = "on" ]
}

chk_audit_working() {
  local before after
  case "$(file_mode "$LAB_ROOT/var/log/audit.log")" in 600|640|400|440) : ;; *) return 1;; esac
  before="$(wc -l < "$LAB_ROOT/var/log/audit.log" 2>/dev/null || echo 0)"
  get_as "$SRE" /dev/null >/dev/null 2>&1
  after="$(wc -l < "$LAB_ROOT/var/log/audit.log" 2>/dev/null || echo 0)"
  [ "$after" -gt "$before" ]
}

chk_data_integrity() {
  local body expected actual
  body="$(mktemp)"; trap 'rm -f "$body"' RETURN
  [ "$(get_as "$SRE" "$body")" = "200" ] || return 1
  expected="$(cat "$LAB_ROOT/state/expected.sha256" 2>/dev/null || echo x)"
  actual="$(sha256_of "$body")"
  [ "$expected" = "$actual" ]
}

verify() {
  PASS_N=0; FAIL_N=0
  hdr "Verification — gcp-cdl 5.1 break & fix"
  rule
  run_check "service is up and answering on 127.0.0.1:${LAB_PORT}" \
            chk_service_up "the endpoint must stay in service; ./$SELF start"
  run_check "encryption in transit: TLS terminated and authorized read works" \
            chk_tls_enforced "etc/server.conf tls=on, then restart the listener"
  run_check "no cleartext listener answering on the same port" \
            chk_no_cleartext "an HTTP request must not be served; only TLS should bind"
  run_check "anonymous caller is denied (403) on the payroll object" \
            chk_anon_denied "remove the public member from the allow policy"
  run_check "allow policy contains no allUsers / allAuthenticatedUsers" \
            chk_no_public_member "public access prevention: no public members on a private bucket"
  run_check "least privilege: intern holds no owner/editor/admin role" \
            chk_least_privilege "grant the narrowest predefined role that still works"
  run_check "intern retains the read access the job requires" \
            chk_intern_can_read "least privilege is not zero privilege: keep objectViewer"
  run_check "DEK is not world-readable (mode 600 or stricter)" \
            chk_key_locked "chmod 600 kms/keyring/prod-key.b64"
  run_check "no key material stored inside the bucket it protects" \
            chk_no_key_in_bucket "delete the key backup under data/objects/"
  run_check "encryption at rest: object is ciphertext and the control is on" \
            chk_encrypted_at_rest "re-encrypt with openssl enc, set encryption_at_rest=on"
  run_check "audit logging records reads and the log is not world-writable" \
            chk_audit_working "audit_logging=on and chmod 640 var/log/audit.log"
  rule
  if [ "$FAIL_N" -eq 0 ]; then
    printf '  %sSCORE %d/%d — environment restored.%s\n' "$C_G$C_B" "$PASS_N" "$((PASS_N+FAIL_N))" "$C_RST"
    say ""
    say "  Now say it in exam language: which of those four faults were the"
    say "  provider's responsibility? None. Identity, key handling, transport"
    say "  configuration and logging all sit on the customer's side of the"
    say "  shared responsibility model — that is the whole point of 5.1."
    printf '\n'
    return 0
  fi
  printf '  %sSCORE %d/%d — %d control(s) still broken.%s\n' \
         "$C_Y$C_B" "$PASS_N" "$((PASS_N+FAIL_N))" "$FAIL_N" "$C_RST"
  say "  Hints: ./$SELF hint 1 (IAM) · 2 (transit) · 3 (at rest) · 4 (audit)"
  printf '\n'
  return 1
}

# --------------------------------------------------------------------------- #
# HINTS                                                                        #
# --------------------------------------------------------------------------- #
hint() {
  case "${1:-}" in
    1) hdr "Hint 1 — IAM and least privilege"
       say "  * Open iam/policy.json. A binding member that is not an identity at"
       say "    all makes the object public; on Cloud Storage the same member is"
       say "    what Public Access Prevention exists to block."
       say "  * A second binding gives a read-only person a role that can rewrite"
       say "    the policy itself. Ask what the intern actually needs: one verb,"
       say "    storage.objects.get, on one bucket."
       say "  * The policy is re-read per request. No restart needed — that is"
       say "    also true of real IAM changes (propagation, not restart)."
       say "  * Docs: https://cloud.google.com/iam/docs/using-iam-securely" ;;
    2) hdr "Hint 2 — encryption in transit"
       say "  * etc/server.conf decides whether the listener terminates TLS."
       say "  * The certificate and key were never damaged: look at tls/ and"
       say "    confirm server.key is 0600 and server.crt is readable."
       say "  * The listener binds its socket once, at startup. Changing config"
       say "    without restarting leaves the cleartext socket in place."
       say "  * Docs: https://cloud.google.com/docs/security/encryption-in-transit" ;;
    3) hdr "Hint 3 — encryption at rest and key management"
       say "  * An openssl-encrypted file starts with the 8 bytes 'Salted__'."
       say "    head -c 8 the object and compare."
       say "  * Re-encrypt in place with the same parameters used to create it:"
       say "      openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \\"
       say "        -pass file:kms/keyring/prod-key.b64 -in IN -out OUT"
       say "  * A key stored inside the resource it protects is not a key, it is"
       say "    a comment. Find it with: find data/ -name '*key*'"
       say "  * Docs: https://cloud.google.com/docs/security/encryption/default-encryption" ;;
    4) hdr "Hint 4 — auditability and defence in depth"
       say "  * audit_logging in etc/server.conf is read per request, so this one"
       say "    takes effect immediately — but the file mode still matters: a"
       say "    world-writable log is a log an attacker edits."
       say "  * Generate traffic after fixing it, then tail var/log/audit.log and"
       say "    read one entry: principalEmail, authorizationInfo.granted, role,"
       say "    callerIp. That is the shape of a real Cloud Audit Logs DATA_READ."
       say "  * Docs: https://cloud.google.com/logging/docs/audit" ;;
    *) say "Usage: ./$SELF hint <1|2|3|4>   (1 IAM · 2 transit · 3 at rest · 4 audit)" ;;
  esac
  printf '\n'
}

# --------------------------------------------------------------------------- #
# RESET / DESTROY                                                              #
# --------------------------------------------------------------------------- #
reset_lab() {
  [ -f "$LAB_ROOT/.golden/known-good.tgz" ] || die "no golden snapshot found; use 'destroy' then rebuild"
  hdr "Rolling back to the known-good state"
  stop_server
  find "$LAB_ROOT" -mindepth 1 -maxdepth 1 \
       ! -name '.golden' ! -name "$LAB_MARKER" -exec rm -rf {} + 2>/dev/null || true
  tar -C "$LAB_ROOT" -xzf "$LAB_ROOT/.golden/known-good.tgz"
  mkdir -p "$LAB_ROOT/var/run"
  start_server
  ok "environment restored. Re-inject the faults with: ./$SELF break"
}

destroy_lab() {
  [ -e "$LAB_ROOT/$LAB_MARKER" ] || die "'$LAB_ROOT' is not a lab directory; refusing to delete anything"
  stop_server 2>/dev/null || true
  rm -rf "$LAB_ROOT"
  ok "removed $LAB_ROOT"
}

usage() {
  cat <<EOF
${C_B}gcp-cdl 5.1 — break & fix lab${C_RST}

  ./$SELF                 build the lab, inject the faults, print the briefing
  ./$SELF verify          score the environment (exit 0 when fully repaired)
  ./$SELF status          current security posture
  ./$SELF hint <1-4>      progressive hints per fault
  ./$SELF logs            server log and audit log
  ./$SELF start|stop|restart
  ./$SELF break           re-inject the faults
  ./$SELF reset           roll back to the known-good state
  ./$SELF destroy         delete ${LAB_ROOT}

Environment: LAB_ROOT (default ${LAB_ROOT}), LAB_PORT (default ${LAB_PORT})
EOF
}

# --------------------------------------------------------------------------- #
main() {
  local cmd="${1:-run}"
  shift 2>/dev/null || true
  case "$cmd" in
    run)              guard; setup; break_lab; briefing ;;
    setup)            guard; setup ;;
    break)            guard; require_lab; break_lab; briefing ;;
    briefing)         require_lab; briefing ;;
    verify|check)     require_lab; verify ;;
    status)           require_lab; status ;;
    hint)             require_lab; hint "${1:-}" ;;
    logs)             require_lab; logs ;;
    start)            require_lab; start_server ;;
    stop)             require_lab; stop_server ;;
    restart)          require_lab; stop_server; start_server ;;
    reset)            guard; require_lab; reset_lab ;;
    destroy)          destroy_lab ;;
    help|-h|--help)   usage ;;
    *)                usage; exit 2 ;;
  esac
}

main "$@"

# =============================================================================
#  SOLUTION — do not read until `verify` has beaten you at least twice
# =============================================================================
#
#  Set a shell variable first so the commands below are copy-pasteable:
#
#      LAB=~/labs/gcp-cdl-5.1        # or your LAB_ROOT
#      PORT=18443
#      cd "$LAB"
#
#  ---------------------------------------------------------------------------
#  STEP 0 — Triage before touching anything
#  ---------------------------------------------------------------------------
#      ./break-fix-5.1.sh verify      # 11 checks, see which fail
#      ./break-fix-5.1.sh status      # posture in one screen
#
#  Reproduce the headline symptom, because it is the one that ends careers:
#
#      curl -sk https://127.0.0.1:$PORT/v1/b/lab-finance-prod/o/q3-payroll.csv
#      # -> HTTP 200 + IBANs, with no Authorization header at all
#
#  ---------------------------------------------------------------------------
#  STEP 1 — Fault 1: IAM. Remove public access, restore least privilege.
#  ---------------------------------------------------------------------------
#  Edit iam/policy.json and (a) delete the "allUsers" member, (b) delete the
#  whole roles/owner binding for the intern. The intern stays in
#  roles/storage.objectViewer, which grants exactly storage.objects.get.
#
#      cat > iam/policy.json <<'JSON'
#      {
#        "version": 3,
#        "etag": "BwXlabPolicyEtag=",
#        "resource": "//storage.googleapis.com/projects/_/buckets/lab-finance-prod",
#        "bindings": [
#          {
#            "role": "roles/storage.objectViewer",
#            "members": [
#              "user:sre-oncall@lab.example.com",
#              "user:data-intern@lab.example.com"
#            ]
#          },
#          {
#            "role": "roles/storage.objectAdmin",
#            "members": [
#              "serviceAccount:etl-writer@lab-fin-prod-01.iam.gserviceaccount.com"
#            ]
#          }
#        ]
#      }
#      JSON
#      chmod 640 iam/policy.json
#
#  Verify immediately — no restart, the policy is evaluated per request:
#
#      curl -s -o /dev/null -w '%{http_code}\n' -k \
#        https://127.0.0.1:$PORT/v1/b/lab-finance-prod/o/q3-payroll.csv        # 403
#      curl -s -o /dev/null -w '%{http_code}\n' -k \
#        -H 'Authorization: Bearer data-intern@lab.example.com' \
#        https://127.0.0.1:$PORT/v1/b/lab-finance-prod/o/q3-payroll.csv        # 200
#
#  On real Google Cloud the equivalent moves are:
#      gcloud storage buckets remove-iam-policy-binding gs://BUCKET \
#          --member=allUsers --role=roles/storage.objectViewer
#      gcloud storage buckets update gs://BUCKET --public-access-prevention
#      gcloud projects remove-iam-policy-binding PROJECT \
#          --member=user:EMAIL --role=roles/owner
#  and the durable control is an org policy constraint
#  (constraints/storage.publicAccessPrevention) plus IAM Recommender to shrink
#  roles automatically.  https://cloud.google.com/storage/docs/public-access-prevention
#
#  ---------------------------------------------------------------------------
#  STEP 2 — Fault 2: encryption in transit. Re-enable TLS and RESTART.
#  ---------------------------------------------------------------------------
#      grep -n '^tls=' etc/server.conf            # tls=off
#      sed -i 's/^tls=.*/tls=on/' etc/server.conf
#      ls -l tls/                                 # server.key must be 0600
#      chmod 600 tls/server.key; chmod 644 tls/server.crt
#      ./break-fix-5.1.sh restart                 # the socket is bound at startup
#
#  Verify both directions — TLS must work, cleartext must not be served:
#
#      curl -s --cacert tls/server.crt https://127.0.0.1:$PORT/healthz
#      curl -s -m 3 http://127.0.0.1:$PORT/healthz ; echo "exit=$?"   # non-zero
#      openssl s_client -connect 127.0.0.1:$PORT -tls1_2 </dev/null 2>/dev/null \
#        | openssl x509 -noout -subject -dates
#
#  Exam framing: Google encrypts traffic between its data centres for you, but
#  the customer chooses whether the front door speaks TLS at all, which cipher
#  floor it enforces, and whether the certificate is valid. A bearer token sent
#  over cleartext is a credential you have already lost.
#  https://cloud.google.com/docs/security/encryption-in-transit
#
#  ---------------------------------------------------------------------------
#  STEP 3 — Fault 3: encryption at rest and key hygiene.
#  ---------------------------------------------------------------------------
#  3a. Lock the key and remove the copy that was backed up inside the bucket:
#
#      chmod 600 kms/keyring/prod-key.b64
#      chmod 700 kms kms/keyring
#      find data/ -name '*key*'                        # data/objects/.../prod-key.b64.bak
#      rm -f data/objects/lab-finance-prod/prod-key.b64.bak
#
#  3b. Re-encrypt the object in place, with the parameters it was created with:
#
#      openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
#        -pass file:kms/keyring/prod-key.b64 \
#        -in  data/objects/lab-finance-prod/q3-payroll.csv \
#        -out /tmp/q3.enc
#      mv /tmp/q3.enc data/objects/lab-finance-prod/q3-payroll.csv
#      chmod 640 data/objects/lab-finance-prod/q3-payroll.csv
#      head -c 8 data/objects/lab-finance-prod/q3-payroll.csv; echo   # Salted__
#
#  3c. Turn the control back on so future writes are encrypted too:
#
#      sed -i 's/^encryption_at_rest=.*/encryption_at_rest=on/' etc/server.conf
#
#  3d. OPTIONAL, and the right instinct after any key exposure — rotate. Order
#      matters: decrypt with the old key, encrypt with the new, then retire the
#      old key OUTSIDE the data path. Never delete the old key before every
#      object encrypted under it has been rewritten.
#
#      openssl rand -base64 32 > kms/keyring/prod-key-v2.b64
#      chmod 600 kms/keyring/prod-key-v2.b64
#      openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
#        -pass file:kms/keyring/prod-key.b64 \
#        -in data/objects/lab-finance-prod/q3-payroll.csv -out /tmp/q3.plain
#      openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
#        -pass file:kms/keyring/prod-key-v2.b64 -in /tmp/q3.plain -out /tmp/q3.v2
#      mv /tmp/q3.v2 data/objects/lab-finance-prod/q3-payroll.csv
#      shred -u /tmp/q3.plain 2>/dev/null || rm -f /tmp/q3.plain
#      mv kms/keyring/prod-key-v2.b64 kms/keyring/prod-key.b64      # server reads this path
#
#      (In Cloud KMS this is one call — `gcloud kms keys versions create` plus a
#      rewrite of the objects — and rotation can be scheduled:
#       https://cloud.google.com/kms/docs/key-rotation)
#
#  Exam framing: Google Cloud encrypts all customer data at rest by default with
#  Google-managed keys. CMEK (Cloud KMS) and CSEK move progressively more of the
#  key custody — and the responsibility for losing it — to the customer. The
#  only thing that never changes is that a key stored beside the data it
#  protects provides no confidentiality at all.
#
#  ---------------------------------------------------------------------------
#  STEP 4 — Fault 4: restore the audit trail.
#  ---------------------------------------------------------------------------
#      sed -i 's/^audit_logging=.*/audit_logging=on/' etc/server.conf
#      chmod 640 var/log/audit.log
#      curl -s --cacert tls/server.crt \
#        -H 'Authorization: Bearer sre-oncall@lab.example.com' \
#        https://127.0.0.1:$PORT/v1/b/lab-finance-prod/o/q3-payroll.csv >/dev/null
#      tail -1 var/log/audit.log | python3 -m json.tool
#
#  Read the entry out loud: principalEmail (who), authorizationInfo.granted and
#  role (under what authority), callerIp (from where), timestamp (when),
#  methodName + resourceName (what). Those five answers are the difference
#  between "we had an incident" and "we had an incident and here is the exact
#  blast radius". Data Access logs for storage.objects.get are NOT enabled by
#  default in Google Cloud — Admin Activity logs are — so this is a customer
#  decision, and the customer pays for the volume.
#  https://cloud.google.com/logging/docs/audit
#
#  ---------------------------------------------------------------------------
#  STEP 5 — Confirm and close
#  ---------------------------------------------------------------------------
#      ./break-fix-5.1.sh verify        # expect 11/11 and exit code 0
#      echo $?
#
#  ---------------------------------------------------------------------------
#  WHY EACH FAULT IS ON THE EXAM (topic 5.1, weight 9%)
#  ---------------------------------------------------------------------------
#   Fault 1 -> Shared responsibility + IAM + principle of least privilege.
#              The provider secures the hardware, hypervisor, storage media and
#              physical facility. Identity, roles, bindings and public exposure
#              are always the customer's. Expect scenario questions where the
#              "right answer" is the narrowest predefined role, not a custom one
#              and never a basic role (owner/editor/viewer) in production.
#   Fault 2 -> Encryption in transit. TLS at the edge is a customer control;
#              Google's internal encryption between services does not rescue an
#              endpoint the customer published over HTTP.
#   Fault 3 -> Encryption at rest, default vs CMEK vs CSEK, and key management.
#              Know the ladder and know who holds the key at each rung.
#   Fault 4 -> Defence in depth and the CIA triad's forgotten leg. Preventive
#              controls fail; detective controls tell you how badly. Cloud Audit
#              Logs, VPC Service Controls, org policy constraints and zero-trust
#              access (BeyondCorp: never trust the network, always verify the
#              identity and device) are the layers stacked behind IAM.
#
#   All four are things the customer configures. That sentence is the exam
#   objective, and this lab is that sentence with consequences attached.
# =============================================================================