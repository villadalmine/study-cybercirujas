#!/usr/bin/env bash
#
# ============================================================================
#  gcp-cdl :: Topic 4.1 -- Describe how Google Cloud helps organizations
#                          transition to the cloud
#  Break & Fix Lab :: "The Migration That Went Dark"
# ============================================================================
#
#  Exam guide reference (2026-08-12):
#    https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#    Section 4.1 -- weight 6.0
#
#  WHAT THIS LAB IS ABOUT
#  ----------------------
#  A Cloud Digital Leader is expected to reason about the *operational
#  consequences* of migration decisions, not just name the phases. Google's
#  own migration framework (Assess -> Plan -> Deploy -> Optimize, documented at
#  https://cloud.google.com/architecture/migration-to-gcp-getting-started)
#  insists that the ASSESS phase produce a complete workload inventory and a
#  dependency map BEFORE anything is cut over. The most common real-world
#  failure in a lift-and-shift is not a broken VM: it is a *forgotten
#  dependency*. Something the inventory never captured -- a hard-coded IP, an
#  on-prem DNS resolver, a shared NFS mount, a cron job that nobody owned --
#  keeps working right up to the moment the legacy environment is
#  decommissioned, and then the migrated service goes dark.
#
#  This script simulates exactly that on a throwaway VM. It stands up a small
#  "migrated" application, then decommissions the "on-prem" piece it silently
#  depended on. Your job is to perform the assessment that should have happened
#  first: discover the dependency, map it, and remediate it the way a
#  cloud-native design would.
#
#  SAFETY CONTRACT
#  ---------------
#  Everything this script touches lives under /opt/cdl-lab41 plus three
#  clearly-namespaced system objects (one systemd unit, one hosts entry, one
#  local user). Nothing outside that set is modified. It refuses to run unless
#  you confirm the host is disposable. `--restore` undoes 100% of it.
#  No external network access, no billable Google Cloud API calls, no gcloud
#  mutations -- this is a *conceptual* lab about migration methodology,
#  deliberately runnable on any scratch Debian/Ubuntu VM (including a free
#  e2-micro) without spending a cent.
#
#  USAGE
#  -----
#    sudo ./cdl-4.1-break-and-fix.sh --break     # set up, then break it
#    sudo ./cdl-4.1-break-and-fix.sh --verify    # did the student fix it?
#    sudo ./cdl-4.1-break-and-fix.sh --restore   # remove every artifact
#    sudo ./cdl-4.1-break-and-fix.sh --hint      # progressive hints
#
# ============================================================================

set -Eeuo pipefail

readonly LAB_ID="cdl-4.1"
readonly LAB_ROOT="/opt/cdl-lab41"
readonly APP_DIR="${LAB_ROOT}/app"
readonly LEGACY_DIR="${LAB_ROOT}/onprem-datacenter"
readonly STATE_DIR="${LAB_ROOT}/.state"
readonly APP_UNIT="cdl41-catalog.service"
readonly APP_PORT="8141"
readonly LEGACY_HOSTNAME="inventory-db.corp.internal"
readonly LEGACY_IP="127.0.41.10"
readonly HOSTS_MARKER="# ${LAB_ID} lab entry -- safe to delete"
readonly APP_USER="cdl41app"
readonly BACKUP_DIR="${STATE_DIR}/backups"

C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'

log()  { printf '%s[%s]%s %s\n' "${C_BLU}" "${LAB_ID}" "${C_OFF}" "$*"; }
warn() { printf '%s[%s]%s %s\n' "${C_YEL}" "${LAB_ID}" "${C_OFF}" "$*"; }
err()  { printf '%s[%s]%s %s\n' "${C_RED}" "${LAB_ID}" "${C_OFF}" "$*" >&2; }
ok()   { printf '%s[%s]%s %s\n' "${C_GRN}" "${LAB_ID}" "${C_OFF}" "$*"; }
rule() { printf '%s%s%s\n' "${C_DIM}" "$(printf '=%.0s' {1..76})" "${C_OFF}"; }

trap 'err "Aborted at line ${LINENO} (exit $?). Run --restore to clean up."' ERR

# ---------------------------------------------------------------------------
# Guard rails
# ---------------------------------------------------------------------------

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "This lab modifies systemd units and /etc/hosts. Run it with sudo."
    exit 1
  fi
}

require_disposable_host() {
  rule
  warn "This VM will be modified. Only run this on a DISPOSABLE lab instance."
  warn "Artifacts created: ${LAB_ROOT}, /etc/systemd/system/${APP_UNIT},"
  warn "one ${HOSTS_MARKER%% --*} line in /etc/hosts, and local user '${APP_USER}'."
  warn "'--restore' removes all of them."
  rule
  if [[ "${LAB_FORCE:-0}" == "1" ]]; then
    log "LAB_FORCE=1 -- skipping interactive confirmation."
    return 0
  fi
  read -r -p "Type 'disposable' to continue: " answer
  if [[ "${answer}" != "disposable" ]]; then
    err "Not confirmed. Nothing was changed."
    exit 1
  fi
}

require_tooling() {
  local missing=()
  for bin in systemctl python3 curl getent; do
    command -v "${bin}" >/dev/null 2>&1 || missing+=("${bin}")
  done
  if ((${#missing[@]})); then
    err "Missing required tools: ${missing[*]}"
    err "On Debian/Ubuntu: apt-get install -y python3 curl systemd"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Phase 1 -- Build the "already migrated" workload
# ---------------------------------------------------------------------------
#
# The story: a retail company ran a catalog service on-prem. The service reads
# its product inventory from a database host called inventory-db.corp.internal.
# The migration team lifted the *application tier* into a Google Cloud VM and
# declared the migration complete. The database tier was scheduled for a later
# wave. Nobody wrote the dependency down.
#
build_workload() {
  log "Provisioning the migrated application tier..."

  install -d -m 0755 "${LAB_ROOT}" "${APP_DIR}" "${LEGACY_DIR}" "${STATE_DIR}" "${BACKUP_DIR}"

  if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${APP_USER}"
    touch "${STATE_DIR}/user_created_by_lab"
  fi

  # --- the "on-prem datacenter" side: a tiny inventory API -----------------
  cat > "${LEGACY_DIR}/inventory_db.py" <<'PYEOF'
#!/usr/bin/env python3
"""Stand-in for the on-premises inventory database tier.

Binds to a loopback alias so it is unreachable from outside this VM.
Speaks the smallest possible HTTP dialect the catalog service expects.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

ROWS = [
    {"sku": "SKU-1001", "name": "Cold brew concentrate", "on_hand": 412},
    {"sku": "SKU-1002", "name": "Ceramic pour-over cone", "on_hand": 87},
    {"sku": "SKU-1003", "name": "Burr grinder, manual", "on_hand": 5},
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (stdlib naming)
        if self.path != "/inventory":
            self.send_error(404, "no such table")
            return
        body = json.dumps({"source": "on-prem", "rows": ROWS}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


if __name__ == "__main__":
    HTTPServer(("127.0.41.10", 9141), Handler).serve_forever()
PYEOF

  # --- the "migrated" side: the catalog service ---------------------------
  # Note the dependency: a hostname, resolved at request time. This is the
  # thing the assessment phase was supposed to catch.
  cat > "${APP_DIR}/catalog_service.py" <<'PYEOF'
#!/usr/bin/env python3
"""Catalog service -- the tier that was lifted and shifted into the cloud.

Reads its upstream from /opt/cdl-lab41/app/config.env so that the fix can be
made through configuration rather than by editing code, which is how you would
do it in a real migration (config as data, not as source).
"""
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

CONFIG_PATH = "/opt/cdl-lab41/app/config.env"


def load_config():
    conf = {}
    try:
        with open(CONFIG_PATH, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                conf[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return conf


def fetch_inventory():
    conf = load_config()
    upstream = conf.get("INVENTORY_UPSTREAM", "http://inventory-db.corp.internal:9141")
    timeout = float(conf.get("INVENTORY_TIMEOUT_SECONDS", "3"))
    url = upstream.rstrip("/") + "/inventory"
    with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310
        return json.loads(resp.read().decode()), url


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            # Liveness only: the process is up. Deliberately does NOT check the
            # upstream -- that is precisely why the outage was invisible to
            # the dashboard for the first eleven minutes.
            self._respond(200, {"status": "ok", "check": "liveness"})
            return
        if self.path == "/readyz":
            try:
                fetch_inventory()
            except Exception as exc:  # noqa: BLE001
                self._respond(503, {"status": "not-ready", "reason": str(exc)})
                return
            self._respond(200, {"status": "ready"})
            return
        if self.path == "/catalog":
            try:
                payload, url = fetch_inventory()
            except urllib.error.URLError as exc:
                self._respond(502, {
                    "error": "upstream_unreachable",
                    "detail": str(exc.reason),
                    "hint": "catalog service could not reach its inventory tier",
                })
                return
            except Exception as exc:  # noqa: BLE001
                self._respond(502, {"error": "upstream_error", "detail": str(exc)})
                return
            payload["served_by"] = "migrated-catalog-service"
            payload["upstream"] = url
            self._respond(200, payload)
            return
        self.send_error(404)

    def _respond(self, code, obj):
        body = json.dumps(obj, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Structured-ish line so `journalctl -u` is actually readable.
        print("catalog %s" % (fmt % args), flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("CATALOG_PORT", "8141"))
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF

  # The dependency, written as configuration. The hostname -- not an IP --
  # is what makes this fixable without touching code.
  cat > "${APP_DIR}/config.env" <<EOF
# Catalog service configuration -- migrated wave 1
# Upstream inventory tier. Still pointing at the on-prem datacenter.
INVENTORY_UPSTREAM=http://${LEGACY_HOSTNAME}:9141
INVENTORY_TIMEOUT_SECONDS=3
EOF

  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
  chmod 0644 "${APP_DIR}/config.env"

  # /etc/hosts stands in for the on-prem DNS resolver the VM inherited.
  cp -a /etc/hosts "${BACKUP_DIR}/hosts.before" 2>/dev/null || true
  if ! grep -q "${LEGACY_HOSTNAME}" /etc/hosts; then
    printf '%s %s  %s\n' "${LEGACY_IP}" "${LEGACY_HOSTNAME}" "${HOSTS_MARKER}" >> /etc/hosts
  fi

  # Loopback alias so the legacy tier has an address of its own to bind to.
  ip address add "${LEGACY_IP}/32" dev lo 2>/dev/null || true

  cat > "/etc/systemd/system/${APP_UNIT}" <<EOF
[Unit]
Description=${LAB_ID} migrated catalog service
After=network.target

[Service]
Type=simple
User=${APP_USER}
Environment=CATALOG_PORT=${APP_PORT}
ExecStart=/usr/bin/python3 ${APP_DIR}/catalog_service.py
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${APP_UNIT}" >/dev/null 2>&1

  # Start the on-prem tier in the foreground of a detached process. It is
  # intentionally NOT a systemd unit -- it represents infrastructure that
  # lives outside this VM's control plane, which is the whole point.
  start_legacy_tier

  sleep 1
  log "Workload is up. Sanity check:"
  curl -sS --max-time 5 "http://127.0.0.1:${APP_PORT}/catalog" || true
  echo
}

start_legacy_tier() {
  if pgrep -f "${LEGACY_DIR}/inventory_db.py" >/dev/null 2>&1; then
    return 0
  fi
  setsid nohup /usr/bin/python3 "${LEGACY_DIR}/inventory_db.py" \
    >"${STATE_DIR}/legacy.log" 2>&1 < /dev/null &
  echo $! > "${STATE_DIR}/legacy.pid"
  sleep 1
}

# ---------------------------------------------------------------------------
# Phase 2 -- The break
# ---------------------------------------------------------------------------
#
# The "decommission the datacenter" event, compressed into three actions:
#   1. The legacy inventory process is stopped   -> the tier is gone.
#   2. The /etc/hosts entry is removed           -> the on-prem resolver is gone.
#   3. The loopback alias is withdrawn           -> the address itself is gone.
#
# This is deliberately a *layered* failure: the student who only restarts the
# app sees nothing improve, and the student who only re-adds DNS gets a
# connection refused instead of a name-resolution error. Reading the actual
# error text is the skill being trained.
#
apply_break() {
  log "Simulating the datacenter decommission window..."

  if [[ -f "${STATE_DIR}/legacy.pid" ]]; then
    kill "$(cat "${STATE_DIR}/legacy.pid")" 2>/dev/null || true
  fi
  pkill -f "${LEGACY_DIR}/inventory_db.py" 2>/dev/null || true

  # Remove the resolver entry, keeping a backup for --restore.
  cp -a /etc/hosts "${BACKUP_DIR}/hosts.after-build"
  sed -i "\|${LEGACY_HOSTNAME}|d" /etc/hosts

  ip address del "${LEGACY_IP}/32" dev lo 2>/dev/null || true

  # Hide the legacy source so the student cannot simply restart it and call
  # it a fix -- the datacenter is *gone*, that is the premise. The bytes are
  # preserved for --restore only.
  if [[ -f "${LEGACY_DIR}/inventory_db.py" ]]; then
    mv "${LEGACY_DIR}/inventory_db.py" "${BACKUP_DIR}/inventory_db.py.decommissioned"
  fi

  date -u +%FT%TZ > "${STATE_DIR}/broken_at"
  systemctl restart "${APP_UNIT}" >/dev/null 2>&1 || true
  sleep 1
}

# ---------------------------------------------------------------------------
# The student-facing briefing
# ---------------------------------------------------------------------------

print_briefing() {
  rule
  cat <<'BRIEF'
INCIDENT BRIEFING -- gcp-cdl 4.1 -- "The Migration That Went Dark"
BRIEF
  rule
  cat <<BRIEF

CONTEXT
  Northwind Coffee ran a two-tier retail catalog on-premises: an application
  tier and an inventory database tier. Six weeks ago the migration team lifted
  the application tier into Google Cloud as wave 1 and reported the workload
  "migrated". The inventory tier was scheduled for wave 3.

  Last night the on-premises datacenter contract ended. The rack was powered
  down on schedule. Nobody objected, because the workload inventory produced
  during the ASSESS phase listed the catalog service as "fully migrated, no
  remaining on-prem dependencies".

  It had one.

WHAT IS RUNNING ON THIS VM
  * ${APP_UNIT}  -- the migrated catalog service, listening on
    http://127.0.0.1:${APP_PORT}. It is UP. systemd reports it healthy.
  * Its configuration lives at ${APP_DIR}/config.env
  * The inventory tier that used to answer it: gone, along with the DNS that
    resolved its name.

THE SYMPTOM YOU WILL SEE
  1) systemctl says everything is fine -- this is the trap:

       \$ systemctl is-active ${APP_UNIT}
       active

  2) The liveness probe is green, because it only proves the process exists:

       \$ curl -s http://127.0.0.1:${APP_PORT}/healthz
       {"status": "ok", "check": "liveness"}

  3) But every real request fails with a 502 and an upstream error:

       \$ curl -s http://127.0.0.1:${APP_PORT}/catalog
       {
         "error": "upstream_unreachable",
         "detail": "[Errno -2] Name or service not known",
         "hint": "catalog service could not reach its inventory tier"
       }

  4) And the readiness probe -- the one that actually tests the dependency --
     returns 503:

       \$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:${APP_PORT}/readyz
       503

  Customers see an empty product catalog. Monitoring saw nothing for eleven
  minutes, because the dashboard was wired to /healthz.

WHAT YOU MUST ACHIEVE
  Restore a 200 response with real inventory rows from:

       curl -s http://127.0.0.1:${APP_PORT}/catalog

  and a 200 from /readyz -- WITHOUT resurrecting the on-premises datacenter.
  It is gone. That is the premise of the exercise and the premise of every
  real migration cutover: you cannot roll back to a rack that no longer draws
  power.

  Concretely, you must:
    (a) Diagnose the failure from the evidence, not from this briefing --
        practise reading the error text and the journal.
    (b) Identify the undocumented dependency and write it down. Create
        ${LAB_ROOT}/dependency-map.md and record, at minimum: the dependent
        component, the dependency it needs, the protocol and port, and which
        migration wave it should have been in. This file is graded. It is the
        artifact the ASSESS phase failed to produce.
    (c) Provide the missing capability *in the cloud environment* -- stand up
        a replacement inventory endpoint on this VM and repoint the catalog
        service at it through configuration, not by editing source.
    (d) Leave the service passing both /healthz and /readyz.

  Then run:  sudo \$0 --verify

RULES OF ENGAGEMENT
  * Do not edit ${APP_DIR}/catalog_service.py. In a real migration you often
    cannot rebuild the application; configuration is your lever.
  * Do not restore anything from ${BACKUP_DIR}. That directory is the lab's
    undo tape, not a solution.
  * Everything you need is already installed: python3, curl, systemd,
    getent, ss, journalctl.

CONCEPTS THIS EXERCISES (exam guide section 4.1)
  * Why the ASSESS phase of Google's migration path exists, and what a
    workload inventory plus dependency map is actually for.
  * The difference between lift-and-shift, improve-and-move, and
    rip-and-replace -- and why a partially-migrated two-tier app is the
    worst of all three until the last wave lands.
  * Migration waves, cutover windows, and why the decommission decision must
    be gated on evidence rather than on a contract end date.
  * Liveness versus readiness: an availability signal that does not test the
    dependency chain is a signal that will lie to you.

DIAGNOSTIC STARTING POINTS
    systemctl status ${APP_UNIT}
    journalctl -u ${APP_UNIT} -n 50 --no-pager
    curl -s http://127.0.0.1:${APP_PORT}/catalog | python3 -m json.tool
    cat ${APP_DIR}/config.env
    getent hosts ${LEGACY_HOSTNAME}
    ss -lntp | head -n 20

REFERENCES
  * Cloud Digital Leader exam guide (2026-08-12), section 4.1:
    https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
  * Migration to Google Cloud: getting started (the four phases):
    https://cloud.google.com/architecture/migration-to-gcp-getting-started
  * Migration to Google Cloud: assessing and discovering your workloads:
    https://cloud.google.com/architecture/migration-to-gcp-assessing-and-discovering-your-workloads
  * Migration to Google Cloud: transferring your large datasets:
    https://cloud.google.com/architecture/migration-to-google-cloud-transferring-your-large-datasets
  * Migration Center (workload discovery and TCO assessment):
    https://cloud.google.com/migration-center/docs/migration-center-overview
  * Google Cloud Adoption Framework (the readiness themes behind "how Google
    Cloud helps organizations transition"):
    https://cloud.google.com/adoption-framework

BRIEF
  rule
}

# ---------------------------------------------------------------------------
# Hints -- progressive, so the student can choose how much to spend
# ---------------------------------------------------------------------------

show_hint() {
  local level="${1:-1}"
  case "${level}" in
    1)
      cat <<'H'
HINT 1 of 3 -- read the error, do not guess.
  "Name or service not known" is errno -2: DNS resolution failed. That is a
  different failure from "Connection refused" (the name resolved, nothing is
  listening) and different again from a timeout (packets went nowhere).
  Ask yourself: what name is it trying to resolve, and who told it to?
    cat /opt/cdl-lab41/app/config.env
    getent hosts inventory-db.corp.internal
H
      ;;
    2)
      cat <<'H'
HINT 2 of 3 -- the dependency is not coming back.
  The on-prem host is decommissioned. You are not being asked to restore it.
  You are being asked to do what wave 3 should have done: provide that
  capability inside the cloud environment. In production that means Cloud SQL,
  AlloyDB, Spanner, or a container on GKE -- something Google Cloud operates
  so there is no rack left to power down. In this lab, any local process that
  serves the same contract on any port is a valid stand-in.

  The contract the catalog service expects:
    GET <upstream>/inventory  ->  200 application/json
    {"source": "...", "rows": [{"sku": "...", "name": "...", "on_hand": 0}, ...]}
H
      ;;
    3)
      cat <<'H'
HINT 3 of 3 -- the two halves of the fix.
  1. Serve the contract locally. A ten-line python3 http.server handler is
     enough; make it survive a reboot with a systemd unit if you want full
     marks on the "cloud-native" spirit of the exercise.
  2. Repoint the consumer through configuration only:
       INVENTORY_UPSTREAM=http://127.0.0.1:<your-port>
     in /opt/cdl-lab41/app/config.env, then restart the catalog service.
  3. Write /opt/cdl-lab41/dependency-map.md. The grader checks for it, and it
     is the artifact whose absence caused the outage in the first place.
H
      ;;
    *)
      err "Hint levels are 1, 2 or 3."
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Grading
# ---------------------------------------------------------------------------

verify() {
  local score=0 total=6
  rule
  log "Grading ${LAB_ID}..."
  rule

  # 1 -- the service answers /catalog with 200
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
          "http://127.0.0.1:${APP_PORT}/catalog" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok  "PASS  /catalog returns 200"; ((score++))
  else
    err "FAIL  /catalog returned ${code} (want 200)"
  fi

  # 2 -- the payload actually carries inventory rows
  local body
  body="$(curl -s --max-time 8 "http://127.0.0.1:${APP_PORT}/catalog" || echo '{}')"
  if printf '%s' "${body}" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
rows = d.get("rows")
sys.exit(0 if isinstance(rows, list) and len(rows) >= 1
         and all(isinstance(r, dict) and "sku" in r for r in rows) else 1)
'; then
    ok  "PASS  payload contains well-formed inventory rows"; ((score++))
  else
    err "FAIL  payload has no usable 'rows' array"
  fi

  # 3 -- readiness, the probe that tests the dependency
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
          "http://127.0.0.1:${APP_PORT}/readyz" || echo 000)"
  if [[ "${code}" == "200" ]]; then
    ok  "PASS  /readyz returns 200"; ((score++))
  else
    err "FAIL  /readyz returned ${code} (want 200)"
  fi

  # 4 -- fixed through configuration, not by editing the application
  if grep -q '^INVENTORY_UPSTREAM=' "${APP_DIR}/config.env" 2>/dev/null &&
     ! grep -q "${LEGACY_HOSTNAME}" "${APP_DIR}/config.env" 2>/dev/null; then
    ok  "PASS  config.env repointed away from the decommissioned host"; ((score++))
  else
    err "FAIL  config.env still references ${LEGACY_HOSTNAME} (or is malformed)"
  fi

  # 5 -- the application source was not modified
  if grep -q 'CONFIG_PATH = "/opt/cdl-lab41/app/config.env"' \
       "${APP_DIR}/catalog_service.py" 2>/dev/null; then
    ok  "PASS  catalog_service.py left intact"; ((score++))
  else
    err "FAIL  catalog_service.py was edited -- the rule was config-only"
  fi

  # 6 -- the missing ASSESS-phase artifact exists and says something
  local map="${LAB_ROOT}/dependency-map.md"
  if [[ -s "${map}" ]] &&
     grep -qi 'catalog'   "${map}" &&
     grep -qi 'inventory' "${map}" &&
     grep -qiE 'port|9141|8141|[0-9]{4}' "${map}"; then
    ok  "PASS  dependency-map.md exists and documents the dependency"; ((score++))
  else
    err "FAIL  ${map} missing or incomplete"
    err "      It must name the dependent component, the dependency,"
    err "      and the protocol/port."
  fi

  rule
  if (( score == total )); then
    ok "SCORE ${score}/${total} -- lab complete."
    ok "You did what the ASSESS phase should have done, only under pressure."
  else
    warn "SCORE ${score}/${total} -- keep going. '--hint 1' if you are stuck."
  fi
  rule
  (( score == total ))
}

# ---------------------------------------------------------------------------
# Restore -- must undo everything, unconditionally
# ---------------------------------------------------------------------------

restore() {
  log "Restoring the VM..."

  systemctl disable --now "${APP_UNIT}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${APP_UNIT}"
  systemctl daemon-reload || true
  systemctl reset-failed "${APP_UNIT}" >/dev/null 2>&1 || true

  pkill -f "${LEGACY_DIR}/inventory_db.py" 2>/dev/null || true
  pkill -f "${APP_DIR}/catalog_service.py" 2>/dev/null || true

  sed -i "\|${LEGACY_HOSTNAME}|d" /etc/hosts 2>/dev/null || true
  ip address del "${LEGACY_IP}/32" dev lo 2>/dev/null || true

  if [[ -f "${STATE_DIR}/user_created_by_lab" ]] && id -u "${APP_USER}" >/dev/null 2>&1; then
    userdel "${APP_USER}" 2>/dev/null || true
  fi

  rm -rf "${LAB_ROOT}"
  ok "Clean. No ${LAB_ID} artifacts remain."
  warn "Any replacement unit YOU created during the fix is still yours to remove:"
  warn "  systemctl list-units --all | grep -i inventory"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${LAB_ID} -- break & fix lab for gcp-cdl topic 4.1

  --break            Provision the workload and then break it (default)
  --verify           Grade the student's fix
  --hint [1|2|3]     Progressive hints
  --restore          Remove every artifact this lab created
  --help             This text

Environment:
  LAB_FORCE=1        Skip the interactive disposable-host confirmation
EOF
}

main() {
  local action="${1:---break}"
  case "${action}" in
    --break)
      require_root; require_tooling; require_disposable_host
      build_workload
      apply_break
      print_briefing
      ;;
    --verify)
      require_root; verify
      ;;
    --hint)
      show_hint "${2:-1}"
      ;;
    --restore)
      require_root; restore
      ;;
    --help|-h)
      usage
      ;;
    *)
      err "Unknown option: ${action}"
      usage
      exit 1
      ;;
  esac
}

main "$@"

# ===========================================================================
#
#                        S O L U T I O N   ( spoiler )
#
#  Do not read this until you have spent real time on --hint 1 through 3.
#
# ===========================================================================
#
# STEP 0 -- Establish what is actually broken, and at which layer.
# ---------------------------------------------------------------------------
#   $ systemctl is-active cdl41-catalog.service
#   active
#
#   The unit is green. That already tells you something important: this is not
#   a crashed process, it is a broken dependency. Confirm with the two probes,
#   which disagree on purpose:
#
#   $ curl -s http://127.0.0.1:8141/healthz
#   {"status": "ok", "check": "liveness"}
#
#   $ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8141/readyz
#   503
#
#   Liveness green + readiness red = "the process is fine, the thing it needs
#   is not". In GKE this is exactly why you configure both probes; a Deployment
#   with only a livenessProbe will keep a Pod in Ready state while it serves
#   nothing but errors, and the Service will happily route traffic to it.
#
# STEP 1 -- Read the error text. It names the layer.
# ---------------------------------------------------------------------------
#   $ curl -s http://127.0.0.1:8141/catalog | python3 -m json.tool
#   {
#       "error": "upstream_unreachable",
#       "detail": "[Errno -2] Name or service not known",
#       "hint": "catalog service could not reach its inventory tier"
#   }
#
#   Errno -2 is EAI_NONAME from getaddrinfo(3): name resolution failed. Not a
#   firewall, not a refused connection, not a timeout. Distinguishing these
#   three is the single highest-value triage skill in a migration cutover:
#     * "Name or service not known"  -> DNS / resolver / hosts file
#     * "Connection refused"         -> resolved fine, nothing listening
#     * "Connection timed out"       -> resolved fine, packets dropped (firewall,
#                                       VPC route, missing Cloud Interconnect /
#                                       Cloud VPN back to the peer network)
#
# STEP 2 -- Find the name and who supplied it.
# ---------------------------------------------------------------------------
#   $ cat /opt/cdl-lab41/app/config.env
#   INVENTORY_UPSTREAM=http://inventory-db.corp.internal:9141
#   INVENTORY_TIMEOUT_SECONDS=3
#
#   $ getent hosts inventory-db.corp.internal
#   (no output, exit status 2)
#
#   $ journalctl -u cdl41-catalog.service -n 30 --no-pager
#   ... catalog "GET /catalog HTTP/1.1" 502 -
#
#   The .corp.internal suffix is the tell: that is a private, on-premises zone.
#   A workload in Google Cloud resolving a .corp.internal name is, by
#   definition, still reaching back into the old environment -- over Cloud VPN,
#   Cloud Interconnect, or a Cloud DNS forwarding zone. That is a legitimate
#   architecture *during* a migration, and a defect *after* it.
#
# STEP 3 -- Write the artifact whose absence caused the outage.
# ---------------------------------------------------------------------------
#   Do this BEFORE fixing anything. Under incident pressure the documentation
#   never gets written afterwards, which is how the same gap survives into the
#   next wave.
#
#   $ sudo tee /opt/cdl-lab41/dependency-map.md > /dev/null <<'MD'
#   # Dependency map -- Northwind catalog service
#
#   Produced during incident response 2026-09-08. This should have been an
#   output of the ASSESS phase, before wave 1 cutover.
#
#   | Dependent | Depends on | Protocol / port | Direction | Migration wave |
#   |---|---|---|---|---|
#   | catalog service (migrated, wave 1) | inventory-db.corp.internal | HTTP/TCP 9141 | egress, synchronous, per-request | should have been wave 1, was scheduled wave 3 |
#
#   Details
#   - Discovered at runtime, not at assessment time. Failure surfaced as
#     EAI_NONAME once the on-prem resolver was withdrawn.
#   - Coupling: synchronous and on the read path. Every /catalog request
#     blocks on it, so there is no degraded mode -- the tier is hard-required.
#   - Blast radius: 100% of catalog reads; customer-visible as an empty store.
#   - Detection gap: the availability dashboard polled /healthz (liveness),
#     which never exercises the dependency. Repoint it at /readyz.
#   - Remediation: replacement inventory endpoint provided inside Google Cloud;
#     consumer repointed via configuration.
#   - Target end state: managed data tier (Cloud SQL / AlloyDB / Spanner) so
#     there is no self-operated host left to decommission. Private Service
#     Connect or a private IP on the VPC; no .corp.internal names in config.
#
#   Rule adopted: no environment is decommissioned until every workload that
#   named it has been re-pointed and observed green on a readiness probe for
#   one full business cycle.
#   MD
#
# STEP 4 -- Provide the capability in the cloud environment.
# ---------------------------------------------------------------------------
#   The datacenter is gone; you replace the tier, you do not revive it. In
#   production this is a managed service -- Cloud SQL, AlloyDB or Spanner --
#   chosen precisely because Google operates the substrate and there is no
#   rack to power down. Here, a local stand-in that honours the same contract:
#
#   $ sudo install -d -m 0755 /opt/cdl-lab41/replacement
#   $ sudo tee /opt/cdl-lab41/replacement/inventory_api.py > /dev/null <<'PY'
#   #!/usr/bin/env python3
#   """Replacement inventory tier, running inside the cloud environment.
#
#   Stands in for a managed data service. Serves the identical contract the
#   catalog service already speaks, so the consumer needs no code change.
#   """
#   import json
#   from http.server import BaseHTTPRequestHandler, HTTPServer
#
#   ROWS = [
#       {"sku": "SKU-1001", "name": "Cold brew concentrate", "on_hand": 412},
#       {"sku": "SKU-1002", "name": "Ceramic pour-over cone", "on_hand": 87},
#       {"sku": "SKU-1003", "name": "Burr grinder, manual", "on_hand": 5},
#   ]
#
#
#   class Handler(BaseHTTPRequestHandler):
#       def do_GET(self):
#           if self.path != "/inventory":
#               self.send_error(404)
#               return
#           body = json.dumps({"source": "google-cloud", "rows": ROWS}).encode()
#           self.send_response(200)
#           self.send_header("Content-Type", "application/json")
#           self.send_header("Content-Length", str(len(body)))
#           self.end_headers()
#           self.wfile.write(body)
#
#       def log_message(self, *_a):
#           return
#
#
#   if __name__ == "__main__":
#       HTTPServer(("127.0.0.1", 9142), Handler).serve_forever()
#   PY
#
#   Make it survive a reboot -- a stand-in that dies with your SSH session has
#   reproduced the original defect in a new place:
#
#   $ sudo tee /etc/systemd/system/cdl41-inventory.service > /dev/null <<'UNIT'
#   [Unit]
#   Description=cdl-4.1 replacement inventory tier
#   After=network.target
#
#   [Service]
#   Type=simple
#   ExecStart=/usr/bin/python3 /opt/cdl-lab41/replacement/inventory_api.py
#   Restart=always
#   RestartSec=2
#   NoNewPrivileges=true
#
#   [Install]
#   WantedBy=multi-user.target
#   UNIT
#
#   $ sudo systemctl daemon-reload
#   $ sudo systemctl enable --now cdl41-inventory.service
#   $ curl -s http://127.0.0.1:9142/inventory
#   {"source": "google-cloud", "rows": [{"sku": "SKU-1001", ...}]}
#
# STEP 5 -- Repoint the consumer. Configuration only.
# ---------------------------------------------------------------------------
#   $ sudo sed -i \
#       's|^INVENTORY_UPSTREAM=.*|INVENTORY_UPSTREAM=http://127.0.0.1:9142|' \
#       /opt/cdl-lab41/app/config.env
#   $ sudo systemctl restart cdl41-catalog.service
#
#   The application binary is untouched. That is the point: in a real
#   lift-and-shift you frequently cannot rebuild the artifact -- the toolchain
#   is gone, the vendor is gone, the source is a tarball on a share that was in
#   the same rack. Everything that might need to change after a cutover should
#   be data the process reads, not a constant it was compiled with.
#
# STEP 6 -- Verify, and verify the *right* signal.
# ---------------------------------------------------------------------------
#   $ curl -s http://127.0.0.1:8141/catalog | python3 -m json.tool
#   {
#       "source": "google-cloud",
#       "rows": [
#           {"sku": "SKU-1001", "name": "Cold brew concentrate", "on_hand": 412},
#           {"sku": "SKU-1002", "name": "Ceramic pour-over cone", "on_hand": 87},
#           {"sku": "SKU-1003", "name": "Burr grinder, manual", "on_hand": 5}
#       ],
#       "served_by": "migrated-catalog-service",
#       "upstream": "http://127.0.0.1:9142/inventory"
#   }
#
#   $ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8141/readyz
#   200
#
#   $ sudo ./cdl-4.1-break-and-fix.sh --verify
#   [cdl-4.1] PASS  /catalog returns 200
#   [cdl-4.1] PASS  payload contains well-formed inventory rows
#   [cdl-4.1] PASS  /readyz returns 200
#   [cdl-4.1] PASS  config.env repointed away from the decommissioned host
#   [cdl-4.1] PASS  catalog_service.py left intact
#   [cdl-4.1] PASS  dependency-map.md exists and documents the dependency
#   [cdl-4.1] SCORE 6/6 -- lab complete.
#
#   Note the "source" field flipped from "on-prem" to "google-cloud". In a real
#   migration that flag is worth having: a field in the response, a label on
#   the resource, a tag in Cloud Monitoring, that tells you unambiguously which
#   side of the cutover served a given request.
#
# ---------------------------------------------------------------------------
# WHY THIS IS THE 4.1 MATERIAL, NOT JUST A SHELL EXERCISE
# ---------------------------------------------------------------------------
#
# 1. ASSESS is not paperwork. Google's migration path is Assess -> Plan ->
#    Deploy -> Optimize
#    (https://cloud.google.com/architecture/migration-to-gcp-getting-started),
#    and the ASSESS deliverable is a workload inventory *with dependencies*
#    (https://cloud.google.com/architecture/migration-to-gcp-assessing-and-discovering-your-workloads).
#    Migration Center exists to produce that automatically -- discovery of
#    running workloads, dependency mapping, and TCO
#    (https://cloud.google.com/migration-center/docs/migration-center-overview).
#    The outage in this lab is what a missing row in that inventory costs.
#
# 2. The three migration types, and which one this was.
#    * Lift and shift -- move as-is. Fastest, cheapest to execute, inherits
#      every operational burden you had. That is what wave 1 did.
#    * Improve and move -- modernise while migrating; e.g. the data tier lands
#      on Cloud SQL instead of a self-managed VM.
#    * Rip and replace -- decommission and rebuild, typically toward managed
#      or serverless services.
#    A two-tier application split across waves is temporarily the worst of all
#    three: it carries lift-and-shift's operational debt AND a cross-environment
#    network dependency on the critical path. That state is acceptable only
#    while it is explicitly tracked with an end date.
#
# 3. Decommissioning is a phase, not an afterthought. The correct gate is
#    evidence -- every workload re-pointed, every readiness probe green through
#    a full business cycle -- not a contract expiry. "The rack was powered down
#    on schedule" is the root cause sentence in this postmortem.
#
# 4. Managed services shrink the surface that can be decommissioned out from
#    under you. Had the data tier landed on Cloud SQL, AlloyDB or Spanner in
#    wave 1, there would have been no host to switch off; Google operates the
#    substrate, and the migration would have ended at the point the CDL exam
#    guide calls the transition to cloud operations. This is the concrete
#    meaning of "how Google Cloud helps organizations transition": not that the
#    VMs move, but that the number of things you must personally keep alive
#    goes down.
#
# 5. Observability must test the dependency chain. /healthz proved a process
#    existed. /readyz proved the system could do its job. Wire alerting to the
#    second one. In GKE that is readinessProbe versus livenessProbe; in
#    Cloud Run it is the startup and liveness probe configuration; in Compute
#    Engine it is the health check attached to the backend service, which
#    should hit a path that exercises the dependency, not a static 200.
#
# 6. The organizational half. The Google Cloud Adoption Framework
#    (https://cloud.google.com/adoption-framework) scores readiness on Learn,
#    Lead, Scale and Secure. This incident is a Lead failure before it is a
#    technical one: the team that owned the app and the team that owned the
#    datacenter contract never reconciled their views of "migrated". No amount
#    of tooling fixes that; a single shared dependency map does.
#
# ---------------------------------------------------------------------------
# CLEANUP
# ---------------------------------------------------------------------------
#   $ sudo systemctl disable --now cdl41-inventory.service
#   $ sudo rm -f /etc/systemd/system/cdl41-inventory.service
#   $ sudo systemctl daemon-reload
#   $ sudo ./cdl-4.1-break-and-fix.sh --restore
#
# ===========================================================================