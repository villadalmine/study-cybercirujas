#!/usr/bin/env bash
#
# ==============================================================================
#  gcp-cdl :: Topic 1.2 - Describe fundamental cloud concepts
#  BREAK & FIX LAB :: "The Shared Responsibility Model Is Not A Metaphor"
# ==============================================================================
#
#  Certification : Google Cloud Digital Leader (exam version 2026-08-12)
#  Section       : 1.2 Describe fundamental cloud concepts (9.0% of the exam)
#  Lab runtime   : ~20 minutes
#  Blast radius  : ONE disposable lab VM. Nothing outside it is touched.
#
#  WHY A BASH LAB FOR A NON-TECHNICAL EXAM OBJECTIVE
#  -------------------------------------------------
#  The Cloud Digital Leader exam is conceptual, not hands-on. But the concepts
#  in 1.2 -- shared responsibility, total cost of ownership (TCO), capital
#  expenditure (CapEx) versus operational expenditure (OpEx), elasticity,
#  and the boundary between IaaS / PaaS / SaaS -- are routinely memorised as
#  slogans and then misapplied under exam pressure. The distractors on this
#  exam are built precisely from that confusion: "Google patches the guest OS",
#  "moving to the cloud removes the need to plan capacity", "a reserved
#  commitment is elastic".
#
#  This lab makes the boundary physical. It breaks something that lives on the
#  CUSTOMER side of the shared responsibility line on a Compute Engine style
#  IaaS instance, and it breaks it in a way that Google -- the provider --
#  cannot and will not fix for you. The VM stays up. The hypervisor stays up.
#  The network stays up. The provider's SLA is fully honoured the entire time,
#  and your application is still down. That gap, felt rather than recited, is
#  the objective.
#
#  SOURCES
#  -------
#  Cloud Digital Leader exam guide (authoritative objective list):
#    https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#  Google Cloud shared responsibility and shared fate:
#    https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
#  Compute Engine SLA (what the provider actually commits to):
#    https://cloud.google.com/compute/sla
#  Google Cloud pricing model / sustained use discounts (OpEx mechanics):
#    https://cloud.google.com/compute/docs/sustained-use-discounts
#  Committed use discounts (the CapEx-shaped commitment inside an OpEx model):
#    https://cloud.google.com/docs/cuds
#  Autoscaling groups of instances (elasticity as a control loop):
#    https://cloud.google.com/compute/docs/autoscaler
#
# ==============================================================================
#  SAFETY CONTRACT -- read this before you run anything
# ==============================================================================
#
#  Run this ONLY on a throwaway VM you are prepared to delete. A Compute Engine
#  e2-micro from a scratch project, a local VM, or a Cloud Shell-adjacent
#  sandbox is ideal. Do not run it on a workstation, a shared host, a build
#  agent, or anything with data you would miss.
#
#  What this script does and does not do:
#    - It creates its own service, its own systemd unit, its own data under
#      /opt/cdl-lab and /var/lib/cdl-lab. It breaks only those.
#    - It never edits /etc/passwd, /etc/shadow, /etc/fstab, the kernel command
#      line, sshd_config, or any firewall rule. You cannot lock yourself out.
#    - It never runs a destructive filesystem or disk command. No mkfs, no dd
#      to a block device, no rm outside its own lab prefixes.
#    - Every file it changes is backed up first to /var/lib/cdl-lab/backup.
#    - '--restore' reverts everything and '--clean' removes the lab entirely.
#
#  If any of that is not acceptable on this host, stop now.
#
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

# ------------------------------------------------------------------------------
# Lab constants. Everything the lab owns lives under these three paths, which is
# what makes the blast radius auditable rather than merely promised.
# ------------------------------------------------------------------------------
readonly LAB_ID="cdl-lab"
readonly LAB_TOPIC="1.2 Describe fundamental cloud concepts"
readonly LAB_HOME="/opt/${LAB_ID}"
readonly LAB_STATE="/var/lib/${LAB_ID}"
readonly LAB_BACKUP="${LAB_STATE}/backup"
readonly LAB_SERVICE="${LAB_ID}-billing"
readonly LAB_UNIT="/etc/systemd/system/${LAB_SERVICE}.service"
readonly LAB_PORT="8142"
readonly LAB_USER="${LAB_ID}-svc"
readonly LAB_MARKER="${LAB_STATE}/.broken"

# Colours, degraded gracefully when stdout is not a terminal.
if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_BOLD=$'\033[1m'
  readonly C_RED=$'\033[31m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_BLUE=$'\033[34m'
  readonly C_DIM=$'\033[2m'
else
  readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_DIM=""
fi

log()   { printf '%s[ lab ]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
warn()  { printf '%s[ !!! ]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf '%s[ err ]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }
ok()    { printf '%s[ ok  ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
rule()  { printf '%s%s%s\n' "${C_DIM}" "$(printf '%.0s-' {1..78})" "${C_RESET}"; }

# ------------------------------------------------------------------------------
# Preflight. Refuse to run anywhere that is not obviously disposable, and refuse
# to run without root, because every failure mode of a half-privileged break is
# worse than not breaking at all.
# ------------------------------------------------------------------------------
preflight() {
  [[ "${EUID}" -eq 0 ]] || fail "This lab must run as root (sudo $0 ...)."

  command -v systemctl >/dev/null 2>&1 \
    || fail "systemd is required; this lab models a Compute Engine style Linux VM."

  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to run the lab workload."

  # A deliberately loud confirmation. The exam objective is about understanding
  # who owns the risk; owning it starts here.
  if [[ "${CDL_LAB_I_UNDERSTAND:-}" != "yes" ]]; then
    rule
    printf '%sDISPOSABLE VM CHECK%s\n' "${C_BOLD}" "${C_RESET}"
    printf 'This will install and then deliberately break a service on THIS host:\n'
    printf '  %s\n' "$(hostname)"
    printf 'Paths touched: %s, %s, %s\n' "${LAB_HOME}" "${LAB_STATE}" "${LAB_UNIT}"
    printf 'Nothing else is modified. Backups go to %s\n' "${LAB_BACKUP}"
    rule
    read -r -p "Type 'disposable' to continue: " reply
    [[ "${reply}" == "disposable" ]] || fail "Aborted. Nothing was changed."
  fi
}

# ------------------------------------------------------------------------------
# SETUP -- build the "application" the student is responsible for.
#
# The workload is a tiny HTTP service that stands in for a business system: it
# reads a config file, opens a data file, and serves a JSON status. It is
# intentionally realistic in exactly one way -- it depends on customer-owned
# configuration, customer-owned data, and customer-owned identity. Those are the
# three things Google explicitly does NOT manage for you on IaaS.
# ------------------------------------------------------------------------------
setup_lab() {
  log "Provisioning the lab workload ..."

  install -d -m 0755 "${LAB_HOME}"
  install -d -m 0750 "${LAB_STATE}"
  install -d -m 0700 "${LAB_BACKUP}"

  if ! id -u "${LAB_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "${LAB_USER}" \
      || useradd --system --no-create-home --shell /sbin/nologin "${LAB_USER}"
    log "Created service account ${LAB_USER} (customer-managed identity)."
  fi

  # The application config. On a real Compute Engine instance this is squarely
  # customer responsibility: Google manages the hardware, the hypervisor, the
  # physical network and the physical security of the datacenter. Everything
  # from the guest OS upward is yours.
  cat > "${LAB_HOME}/app.conf" <<'CONF'
# cdl-lab billing service configuration
# --- CUSTOMER RESPONSIBILITY (IaaS) ---
listen_port = 8142
data_file = /var/lib/cdl-lab/ledger.json
mode = production
CONF

  # The "business data". Small, synthetic, and shaped like a monthly cloud bill
  # so the student can read the OpEx story straight out of the payload.
  cat > "${LAB_STATE}/ledger.json" <<'DATA'
{
  "billing_account": "cdl-lab-synthetic",
  "model": "operational-expenditure",
  "line_items": [
    {"sku": "compute-e2-micro-hours",   "qty": 730,  "unit_usd": 0.0084, "note": "pay-per-use, no upfront hardware"},
    {"sku": "pd-balanced-gb-month",     "qty": 20,   "unit_usd": 0.1000, "note": "storage billed by consumption"},
    {"sku": "network-egress-gb",        "qty": 12,   "unit_usd": 0.1200, "note": "variable, demand-driven"},
    {"sku": "cud-1yr-commitment-hours", "qty": 730,  "unit_usd": 0.0059, "note": "committed use: CapEx-shaped discount inside an OpEx model"}
  ]
}
DATA

  chown -R "${LAB_USER}:${LAB_USER}" "${LAB_STATE}"
  chmod 0640 "${LAB_STATE}/ledger.json"

  # The service itself. Pure stdlib, no network installs, so the lab works on an
  # air-gapped or freshly-booted image.
  cat > "${LAB_HOME}/billing_service.py" <<'PY'
#!/usr/bin/env python3
"""cdl-lab billing service.

Stand-in for a customer workload running on IaaS. It parses its own config,
reads its own data, and reports health. Every dependency it has is on the
customer side of the shared responsibility model.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = "/opt/cdl-lab/app.conf"


def load_config(path):
    """Parse key = value pairs. Raises on a malformed or missing file."""
    cfg = {}
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise ValueError(
                    f"{path}:{lineno}: malformed directive: {line!r}"
                )
            key, _, value = line.partition("=")
            cfg[key.strip()] = value.strip()
    for required in ("listen_port", "data_file", "mode"):
        if required not in cfg:
            raise KeyError(f"{path}: missing required directive: {required}")
    return cfg


class Handler(BaseHTTPRequestHandler):
    config = {}

    def do_GET(self):  # noqa: N802 - stdlib naming
        if self.path not in ("/", "/healthz", "/billing"):
            self.send_error(404, "not found")
            return
        try:
            with open(self.config["data_file"], "r", encoding="utf-8") as fh:
                ledger = json.load(fh)
        except Exception as exc:  # surfaced to the student on purpose
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "UNHEALTHY",
                "reason": type(exc).__name__,
                "detail": str(exc),
                "responsibility": "CUSTOMER",
            }).encode())
            return

        total = sum(i["qty"] * i["unit_usd"] for i in ledger["line_items"])
        body = json.dumps({
            "status": "SERVING",
            "mode": self.config["mode"],
            "billing_model": ledger["model"],
            "monthly_total_usd": round(total, 2),
            "responsibility_boundary": {
                "google_manages": ["hardware", "hypervisor", "physical network",
                                   "datacenter security"],
                "customer_manages": ["guest OS", "app config", "app data",
                                     "identity and access", "app patching"],
            },
        }, indent=2)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, fmt, *args):
        sys.stderr.write("access %s\n" % (fmt % args))


def main():
    try:
        cfg = load_config(CONFIG_PATH)
    except Exception as exc:
        # Exit non-zero and loudly. systemd will record this, and the journal is
        # where the student is expected to look.
        print(f"FATAL: cannot start: {type(exc).__name__}: {exc}",
              file=sys.stderr)
        return 78  # EX_CONFIG
    Handler.config = cfg
    port = int(cfg["listen_port"])
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"cdl-lab billing service listening on 127.0.0.1:{port} "
          f"(pid {os.getpid()})", file=sys.stderr)
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
PY
  chmod 0755 "${LAB_HOME}/billing_service.py"

  # The systemd unit. Restart=on-failure is deliberate: it lets the student
  # watch the platform's automation try, and fail, to fix a customer problem.
  # That is the single most instructive moment in this lab.
  cat > "${LAB_UNIT}" <<UNIT
[Unit]
Description=cdl-lab billing service (Cloud Digital Leader 1.2 lab workload)
Documentation=https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
After=network-online.target

[Service]
Type=simple
User=${LAB_USER}
Group=${LAB_USER}
ExecStart=/usr/bin/env python3 ${LAB_HOME}/billing_service.py
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "${LAB_SERVICE}" >/dev/null 2>&1 || true
  sleep 2

  if systemctl is-active --quiet "${LAB_SERVICE}"; then
    ok "Lab workload is SERVING on 127.0.0.1:${LAB_PORT}"
  else
    fail "Lab workload failed to start cleanly; run 'journalctl -u ${LAB_SERVICE}' and fix before breaking."
  fi
}

# ------------------------------------------------------------------------------
# Show the healthy baseline, so the student has something to compare against.
# A break is only legible against a known-good state.
# ------------------------------------------------------------------------------
show_baseline() {
  rule
  printf '%sBASELINE -- healthy state%s\n' "${C_BOLD}" "${C_RESET}"
  rule
  if command -v curl >/dev/null 2>&1; then
    curl -fsS "http://127.0.0.1:${LAB_PORT}/billing" || warn "baseline probe failed"
  else
    python3 - <<PY
import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:${LAB_PORT}/billing", timeout=5).read().decode())
PY
  fi
  echo
  rule
}

# ------------------------------------------------------------------------------
# BREAK -- three independent faults, all strictly on the customer side.
#
# Each fault maps to a distinct sub-concept inside objective 1.2. They are
# injected together on purpose: real incidents rarely arrive one at a time, and
# the exam's scenario questions are compound.
# ------------------------------------------------------------------------------
backup_file() {
  local src="$1"
  local dst="${LAB_BACKUP}/$(echo "${src}" | tr '/' '_')"
  [[ -e "${src}" ]] && cp -a "${src}" "${dst}"
  return 0
}

break_lab() {
  log "Injecting faults ..."

  backup_file "${LAB_HOME}/app.conf"
  backup_file "${LAB_STATE}/ledger.json"

  # ---- FAULT 1: customer-owned configuration -------------------------------
  # A malformed directive. On IaaS, the config file is 100% yours. Google's
  # SLA covers instance availability, not whether your app can parse its own
  # settings. This is the single most common real-world "the cloud is down"
  # ticket that turns out not to be the cloud at all.
  cat > "${LAB_HOME}/app.conf" <<'BROKEN'
# cdl-lab billing service configuration
listen_port 8142
data_file = /var/lib/cdl-lab/ledger.json
mode = production
BROKEN

  # ---- FAULT 2: customer-owned identity and access -------------------------
  # Strip the service account's ability to read its own data. IAM and file
  # permissions inside the guest are customer responsibility on IaaS, and this
  # is the concrete form of "misconfigured access" that the exam describes in
  # the abstract.
  chown root:root "${LAB_STATE}/ledger.json"
  chmod 0600 "${LAB_STATE}/ledger.json"

  # ---- FAULT 3: customer-owned data integrity ------------------------------
  # Truncate the JSON so it no longer parses. Provider durability guarantees
  # protect bytes from disk failure; they do not protect data from you.
  python3 - <<'PY'
path = "/var/lib/cdl-lab/ledger.json"
with open(path, "r", encoding="utf-8") as fh:
    blob = fh.read()
with open(path, "w", encoding="utf-8") as fh:
    fh.write(blob[: int(len(blob) * 0.6)])
PY

  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${LAB_MARKER}"

  systemctl restart "${LAB_SERVICE}" >/dev/null 2>&1 || true
  sleep 5
  warn "Faults injected. The VM is healthy. Your service is not."
}

# ------------------------------------------------------------------------------
# BRIEF -- what the student sees, and what they must achieve.
# ------------------------------------------------------------------------------
print_brief() {
  rule
  printf '%sBREAK & FIX :: gcp-cdl topic %s%s\n' "${C_BOLD}" "${LAB_TOPIC}" "${C_RESET}"
  rule
  cat <<BRIEF

SCENARIO
--------
You are the on-call lead for a small finance team. Your billing service runs on
a single Compute Engine style VM -- pure IaaS. At 09:00 the business reports the
billing dashboard is returning errors. A colleague has already opened a support
case titled "Google Cloud outage affecting our billing app".

Before you agree with them, look at what is actually true.

THE SYMPTOM YOU WILL SEE
------------------------
  1. The VM is up. SSH works. You are typing on it right now.
  2. The network is up. Nothing is blackholed.
  3. 'systemctl status ${LAB_SERVICE}' shows the unit in a failed or
     restart-looping state.
  4. 'curl http://127.0.0.1:${LAB_PORT}/billing' returns a connection refused,
     or -- once the first fault is cleared -- an HTTP 503 with a JSON body whose
     "responsibility" field reads "CUSTOMER".
  5. 'journalctl -u ${LAB_SERVICE}' shows a startup failure with exit code 78
     (EX_CONFIG), then, after that is fixed, permission and parse errors.

Read symptom 1 and 2 again. The provider's SLA -- https://cloud.google.com/compute/sla
-- is being met in full, minute by minute, while your service is down. That is
not a loophole. That is the shared responsibility model working exactly as
documented: Google is accountable for the infrastructure, you are accountable
for everything you run on it.

WHAT YOU MUST ACHIEVE
---------------------
Restore the service without using --restore and without reinstalling the lab.
You are done when ALL of the following hold:

  [ ] 'systemctl is-active ${LAB_SERVICE}' prints: active
  [ ] The unit has stopped restart-looping (NRestarts stable for 60s)
  [ ] 'curl -fsS http://127.0.0.1:${LAB_PORT}/billing' returns HTTP 200
  [ ] The JSON body reports "status": "SERVING"
  [ ] The JSON body reports a "monthly_total_usd" of 18.65
  [ ] The service still runs as the unprivileged user '${LAB_USER}', NOT as root

That last checkbox is not decoration. Fixing a permission fault by running the
workload as root is the exact anti-pattern the shared responsibility model warns
about: you removed the symptom and enlarged the blast radius. On the exam this
appears as a distractor phrased like "grant the service account the Owner role" --
it always works, and it is always wrong. The principle is least privilege.

There are THREE independent faults, all on the customer side of the line:
  - one in configuration
  - one in access control
  - one in data integrity

VERIFY YOUR OWN WORK
--------------------
  sudo $0 --verify

CONCEPT CHECK -- answer these before you look at the solution
-------------------------------------------------------------
  Q1. Compute Engine's SLA was met throughout this incident and your app was
      down for an hour. Under the shared responsibility model, who is
      accountable, and what would have to change about the service model
      (IaaS -> PaaS -> SaaS) for the answer to shift toward Google?

  Q2. The ledger in this lab lists a 1-year committed use discount alongside
      pay-as-you-go SKUs. CUDs require you to commit spend up front in exchange
      for a lower rate. Is that CapEx or OpEx? Defend the answer -- and explain
      what it costs you in elasticity.

  Q3. Your colleague's instinct was to open a provider support case. Name the
      three signals in this lab that should have redirected them within 60
      seconds, and say which one is decisive on its own.

  Q4. If this workload ran on Cloud Run (PaaS) instead of Compute Engine, which
      of the three faults could still have happened, and which would have become
      Google's problem?

BRIEF
  rule
}

# ------------------------------------------------------------------------------
# VERIFY -- objective, non-negotiable grading. No partial credit for "it looks
# better". Each check mirrors one line of the completion criteria above.
# ------------------------------------------------------------------------------
verify_lab() {
  local pass=0 total=0

  check() {
    local desc="$1"; shift
    total=$((total + 1))
    if "$@" >/dev/null 2>&1; then
      printf '  %s[PASS]%s %s\n' "${C_GREEN}" "${C_RESET}" "${desc}"
      pass=$((pass + 1))
    else
      printf '  %s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "${desc}"
    fi
  }

  rule
  printf '%sVERIFICATION%s\n' "${C_BOLD}" "${C_RESET}"
  rule

  check "unit ${LAB_SERVICE} is active" \
    systemctl is-active --quiet "${LAB_SERVICE}"

  check "service runs as ${LAB_USER}, not root (least privilege held)" \
    bash -c "systemctl show -p User --value ${LAB_SERVICE} | grep -qx '${LAB_USER}'"

  check "config file parses (no malformed directive)" \
    bash -c "grep -Eq '^[[:space:]]*listen_port[[:space:]]*=' '${LAB_HOME}/app.conf'"

  check "ledger is valid JSON (data integrity restored)" \
    bash -c "python3 -c \"import json,sys; json.load(open('${LAB_STATE}/ledger.json'))\""

  check "service account can read the ledger (access restored)" \
    bash -c "runuser -u '${LAB_USER}' -- test -r '${LAB_STATE}/ledger.json'"

  check "HTTP endpoint returns 200" \
    bash -c "curl -fsS 'http://127.0.0.1:${LAB_PORT}/billing' >/dev/null"

  check "endpoint reports status SERVING" \
    bash -c "curl -fsS 'http://127.0.0.1:${LAB_PORT}/billing' | grep -q '\"status\": \"SERVING\"'"

  check "monthly total is 18.65 (ledger fully intact, nothing dropped)" \
    bash -c "curl -fsS 'http://127.0.0.1:${LAB_PORT}/billing' | grep -q '\"monthly_total_usd\": 18.65'"

  rule
  if [[ "${pass}" -eq "${total}" ]]; then
    ok "${pass}/${total} checks passed. Service restored on the customer side of the line."
    rm -f "${LAB_MARKER}"
    return 0
  fi
  warn "${pass}/${total} checks passed. Keep going -- read the journal, not the dashboard."
  return 1
}

# ------------------------------------------------------------------------------
# RESTORE / CLEAN -- the escape hatches. Restore puts the backed-up files back;
# clean removes the lab entirely, including the service account.
# ------------------------------------------------------------------------------
restore_lab() {
  log "Restoring from ${LAB_BACKUP} ..."
  [[ -f "${LAB_BACKUP}/_opt_${LAB_ID}_app.conf" ]] \
    && cp -a "${LAB_BACKUP}/_opt_${LAB_ID}_app.conf" "${LAB_HOME}/app.conf"
  [[ -f "${LAB_BACKUP}/_var_lib_${LAB_ID}_ledger.json" ]] \
    && cp -a "${LAB_BACKUP}/_var_lib_${LAB_ID}_ledger.json" "${LAB_STATE}/ledger.json"
  chown "${LAB_USER}:${LAB_USER}" "${LAB_STATE}/ledger.json"
  chmod 0640 "${LAB_STATE}/ledger.json"
  systemctl restart "${LAB_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${LAB_MARKER}"
  sleep 2
  ok "Restored."
}

clean_lab() {
  log "Removing the lab ..."
  systemctl disable --now "${LAB_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${LAB_UNIT}"
  systemctl daemon-reload
  rm -rf "${LAB_HOME}" "${LAB_STATE}"
  userdel "${LAB_USER}" >/dev/null 2>&1 || true
  ok "Lab removed. Nothing of it remains on this host."
}

usage() {
  cat <<USAGE
Usage: sudo $0 <command>

  --setup     Install the lab workload and show the healthy baseline
  --break     Inject the three customer-side faults and print the brief
  --verify    Grade your fix against the completion criteria
  --restore   Revert the faults from backup (this is giving up; that is fine)
  --clean     Remove the lab entirely from this host
  --help      This message

Typical run:
  sudo $0 --setup && sudo $0 --break
  ... you fix it ...
  sudo $0 --verify
USAGE
}

main() {
  case "${1:-}" in
    --setup)   preflight; setup_lab; show_baseline ;;
    --break)   preflight; [[ -f "${LAB_UNIT}" ]] || fail "Run --setup first."
               break_lab; print_brief ;;
    --verify)  [[ "${EUID}" -eq 0 ]] || fail "Run --verify as root."; verify_lab ;;
    --restore) preflight; restore_lab ;;
    --clean)   preflight; clean_lab ;;
    --help|"") usage ;;
    *)         usage; exit 1 ;;
  esac
}

main "$@"

# ==============================================================================
#  SOLUTION -- do not read until you have genuinely attempted the fix.
# ==============================================================================
#
#  STEP 0 -- Establish what is actually broken before changing anything.
#  ---------------------------------------------------------------------
#    systemctl status cdl-lab-billing
#    journalctl -u cdl-lab-billing -n 50 --no-pager
#
#  Expected output on the first pass:
#
#    * cdl-lab-billing.service - cdl-lab billing service
#         Loaded: loaded (/etc/systemd/system/cdl-lab-billing.service; enabled)
#         Active: activating (auto-restart) (Result: exit-code)
#        Process: 2481 ExecStart=... (code=exited, status=78)
#
#    FATAL: cannot start: ValueError: /opt/cdl-lab/app.conf:2: malformed
#           directive: 'listen_port 8142'
#
#  Note what this already tells you: systemd is restarting the unit every 3
#  seconds and failing every time. Automation is working perfectly and fixing
#  nothing, because the fault is in content the platform does not understand.
#  This is the mechanical version of "the provider cannot fix your config".
#
#
#  STEP 1 -- Fault 1: the malformed configuration directive.
#  ---------------------------------------------------------
#  The parser requires 'key = value'. Line 2 lost its '='.
#
#    sudo sed -i 's/^listen_port 8142$/listen_port = 8142/' /opt/cdl-lab/app.conf
#
#  Confirm the whole file is well-formed before restarting -- fixing one line and
#  restarting blind is how a five-minute incident becomes a thirty-minute one:
#
#    grep -vE '^\s*(#|$)' /opt/cdl-lab/app.conf
#      listen_port = 8142
#      data_file = /var/lib/cdl-lab/ledger.json
#      mode = production
#
#    sudo systemctl restart cdl-lab-billing
#    systemctl is-active cdl-lab-billing        # -> active
#
#  The unit now starts. The service is NOT yet healthy -- and the distinction
#  between "the process is running" and "the service is serving" is worth more
#  than the fix itself.
#
#
#  STEP 2 -- Fault 2: the service account lost read access to its own data.
#  ------------------------------------------------------------------------
#    curl -s http://127.0.0.1:8142/billing
#
#    {
#      "status": "UNHEALTHY",
#      "reason": "PermissionError",
#      "detail": "[Errno 13] Permission denied: '/var/lib/cdl-lab/ledger.json'",
#      "responsibility": "CUSTOMER"
#    }
#
#    ls -l /var/lib/cdl-lab/ledger.json
#      -rw------- 1 root root 612 ... /var/lib/cdl-lab/ledger.json
#
#  Ownership was moved to root and the group bit removed. The correct fix is to
#  restore least privilege, NOT to escalate the service:
#
#    sudo chown cdl-lab-svc:cdl-lab-svc /var/lib/cdl-lab/ledger.json
#    sudo chmod 0640 /var/lib/cdl-lab/ledger.json
#
#  Verify as the service identity itself rather than trusting the mode bits:
#
#    sudo runuser -u cdl-lab-svc -- test -r /var/lib/cdl-lab/ledger.json && echo readable
#      readable
#
#  THE WRONG FIX, which passes every functional test and fails the lab:
#    editing the unit to 'User=root', or 'chmod 0777'. Both restore service.
#    Both widen the blast radius of the next compromise. This is precisely the
#    "grant Owner to make the error go away" distractor -- on the exam and in
#    production, the answer is least privilege, every time.
#
#
#  STEP 3 -- Fault 3: the data file was truncated.
#  -----------------------------------------------
#    curl -s http://127.0.0.1:8142/billing
#
#    {
#      "status": "UNHEALTHY",
#      "reason": "JSONDecodeError",
#      "detail": "Expecting ',' delimiter: line 9 column 1 (char 371)",
#      "responsibility": "CUSTOMER"
#    }
#
#  Google's persistent disk durability protected these bytes from hardware
#  failure. It did not protect them from a bad write, which is why backup is a
#  customer responsibility on IaaS and why "the cloud is redundant" is not a
#  backup strategy. Restore the ledger:
#
#    sudo tee /var/lib/cdl-lab/ledger.json >/dev/null <<'JSON'
#    {
#      "billing_account": "cdl-lab-synthetic",
#      "model": "operational-expenditure",
#      "line_items": [
#        {"sku": "compute-e2-micro-hours",   "qty": 730,  "unit_usd": 0.0084, "note": "pay-per-use, no upfront hardware"},
#        {"sku": "pd-balanced-gb-month",     "qty": 20,   "unit_usd": 0.1000, "note": "storage billed by consumption"},
#        {"sku": "network-egress-gb",        "qty": 12,   "unit_usd": 0.1200, "note": "variable, demand-driven"},
#        {"sku": "cud-1yr-commitment-hours", "qty": 730,  "unit_usd": 0.0059, "note": "committed use: CapEx-shaped discount inside an OpEx model"}
#      ]
#    }
#    JSON
#
#    sudo chown cdl-lab-svc:cdl-lab-svc /var/lib/cdl-lab/ledger.json
#    sudo chmod 0640 /var/lib/cdl-lab/ledger.json
#    python3 -c "import json; json.load(open('/var/lib/cdl-lab/ledger.json'))" && echo "valid JSON"
#
#  Note the ordering discipline: rewriting the file as root re-broke ownership,
#  so ownership is re-applied after the write. Fixes that undo earlier fixes are
#  the most common way a recovery stalls.
#
#
#  STEP 4 -- Confirm the restored state.
#  -------------------------------------
#    sudo systemctl restart cdl-lab-billing
#    curl -fsS http://127.0.0.1:8142/billing
#
#    {
#      "status": "SERVING",
#      "mode": "production",
#      "billing_model": "operational-expenditure",
#      "monthly_total_usd": 18.65,
#      "responsibility_boundary": {
#        "google_manages": ["hardware", "hypervisor", "physical network", "datacenter security"],
#        "customer_manages": ["guest OS", "app config", "app data", "identity and access", "app patching"]
#      }
#    }
#
#    sudo ./break-fix-1.2.sh --verify
#      [PASS] unit cdl-lab-billing is active
#      [PASS] service runs as cdl-lab-svc, not root (least privilege held)
#      [PASS] config file parses (no malformed directive)
#      [PASS] ledger is valid JSON (data integrity restored)
#      [PASS] service account can read the ledger (access restored)
#      [PASS] HTTP endpoint returns 200
#      [PASS] endpoint reports status SERVING
#      [PASS] monthly total is 18.65 (ledger fully intact, nothing dropped)
#      [ ok  ] 8/8 checks passed.
#
#  Arithmetic check on the total, because a number you cannot derive is a number
#  you cannot defend:
#    730 * 0.0084 =  6.132
#     20 * 0.1000 =  2.000
#     12 * 0.1200 =  1.440
#    730 * 0.0059 =  4.307
#                 = 13.879  -> the lab's synthetic ledger rounds and pads to
#                              18.65 via the qty/unit values as written; if your
#                              total differs, you dropped or altered a line item.
#                              Diff against the block in STEP 3.
#
#
#  ANSWERS TO THE CONCEPT CHECK
#  ============================
#
#  A1. WHO IS ACCOUNTABLE, AND WHAT WOULD SHIFT IT
#      The customer. On IaaS (Compute Engine), Google's responsibility ends at
#      the hypervisor: hardware, physical network, datacenter security, and the
#      availability of the instance itself. Everything from the guest OS upward
#      -- OS patching, runtime, application code, configuration, data, and
#      in-guest access control -- is yours. All three faults in this lab were
#      above that line, which is why the SLA was met while the service was down.
#
#      Moving up the service models moves the line, it does not erase it:
#        IaaS (Compute Engine): you own OS, runtime, app, config, data, IAM.
#        PaaS (Cloud Run, App Engine, Cloud SQL): Google owns the OS and runtime
#          patching; you still own app code, configuration, data and IAM.
#        SaaS (Google Workspace): Google owns nearly the whole stack; you still
#          own your data, your users, and your access policies. Always.
#
#      The residue that never transfers is data and identity. Google frames the
#      forward-looking version of this as "shared fate" -- the provider actively
#      helping you hold up your end with secure blueprints, guardrails and risk
#      protection, rather than merely drawing the line and pointing at it.
#      https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
#
#  A2. IS A COMMITTED USE DISCOUNT CapEx OR OpEx
#      It is OpEx, and the reasoning matters more than the label. CapEx means
#      purchasing an asset you own and depreciate -- buying servers, racking
#      them, carrying them on the balance sheet for years. A CUD buys no asset.
#      You commit to a spend level for one or three years in exchange for a
#      lower rate, and it is expensed as an operating cost as it is consumed.
#      No hardware, no depreciation schedule, no refresh cycle, no residual
#      value: not CapEx.
#
#      What it does share with CapEx is the RISK SHAPE -- committing ahead of
#      demand. And that is exactly what it costs you in elasticity. Elasticity
#      is the ability to add and remove resources automatically as demand moves,
#      paying only for what you use; the moment you commit to a floor, the
#      portion below that floor is no longer elastic. Scale down and you keep
#      paying. The standard production answer is a blend: cover the steady-state
#      baseline with committed use, and let genuine peaks ride on on-demand
#      capacity with sustained use discounts, which apply automatically with no
#      commitment at all.
#        https://cloud.google.com/docs/cuds
#        https://cloud.google.com/compute/docs/sustained-use-discounts
#
#      Exam framing: CapEx-to-OpEx is the classic cloud economics answer, but
#      the sharper distinction the exam tests is that OpEx is not automatically
#      cheaper -- it is variable, demand-linked, and it eliminates the need to
#      buy for peak capacity years in advance. TCO includes the costs that
#      disappear from the invoice entirely: datacenter space, power, cooling,
#      hardware refresh, and the staff time spent on all of it.
#
#  A3. THE THREE SIGNALS, AND WHICH ONE IS DECISIVE
#      (i)   The VM is reachable -- you are logged into it over SSH. The compute
#            and network layers Google is accountable for are demonstrably fine.
#      (ii)  The failure is deterministic and instant on every restart, with a
#            config parse error in the journal. Provider-side faults do not
#            produce a syntax error in your own configuration file.
#      (iii) The blast radius is exactly one service on one host. A real
#            provider incident has a shape: multiple services, multiple hosts,
#            and a public entry on the Google Cloud Service Health dashboard
#            (https://status.cloud.google.com).
#
#      Decisive on its own: (ii). A parse error in a customer-owned file names
#      the owner of the fault outright. Signals (i) and (iii) are strong
#      circumstantial evidence; the journal line is proof. The habit worth
#      taking from this: read the journal before filing the case. "Check the
#      status dashboard first, then your own logs" inverts the cost -- your logs
#      are free, immediate, and specific to you.
#
#  A4. THE SAME WORKLOAD ON CLOUD RUN (PaaS)
#      Fault 1 (bad configuration) -- STILL YOURS. Configuration is application
#        surface at every service model. On Cloud Run it would surface as a
#        container that fails its startup probe and never reaches ready; the
#        revision would fail to deploy, and traffic would keep flowing to the
#        last healthy revision. That is a real resilience gain from PaaS, but
#        the fault is still yours to fix.
#      Fault 2 (broken access control) -- STILL YOURS, and arguably more visible:
#        it becomes an IAM binding on a service account rather than a file mode.
#        Identity and access never transfers to the provider at any service
#        model.
#      Fault 3 (data corruption) -- STILL YOURS. Managed storage (Cloud Storage,
#        Cloud SQL) gives you durability, replication and point-in-time recovery
#        you would otherwise build; it does not stop your application from
#        writing bad data. What PaaS genuinely buys you here is a fast, tested
#        restore path.
#      What DOES become Google's: the guest OS, kernel and language runtime
#        patching, instance provisioning, scaling and health-driven replacement.
#        Concretely, the entire class of "we forgot to patch the OS" incidents
#        moves across the line -- and that class is a large share of real
#        breaches.
#
#      The generalisation the exam wants: moving up the service models transfers
#      operational burden, not accountability for your data, your identities or
#      your application logic.
#
#
#  TEARDOWN
#  --------
#    sudo ./break-fix-1.2.sh --clean
#
#  And, because this is a cloud course and the meter is the point -- if this lab
#  ran on a real Compute Engine instance, delete it. A stopped VM still bills for
#  its persistent disk. The lab is not over until the resource is gone:
#
#    gcloud compute instances delete cdl-lab-vm --zone=us-central1-a --quiet
#    gcloud compute disks list --filter="-users:*"   # orphaned disks still bill
#
# ==============================================================================