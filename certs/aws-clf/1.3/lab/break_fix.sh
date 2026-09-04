#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner — CLF-C02 (exam guide v1.0)
#  Domain 1 · Task Statement 1.3
#  "Understand the benefits of and strategies for migration to the AWS Cloud"
#  Exam weight of the domain task: 6.0 %
#
#  BREAK & FIX LAB — "Wave 1 cutover of a rehosted workload"
#
#  WHAT THIS LAB TEACHES
#  ---------------------
#  Task 1.3 is not only vocabulary. The exam asks you to recognise WHICH of the
#  7 Rs applies to a workload, WHAT a migration actually moves (and what it does
#  not), and WHY validation exists between "replication finished" and "cutover
#  succeeded". This lab reproduces, on one throwaway VM, the three failures that
#  dominate real wave-1 cutovers:
#
#    FAULT A — configuration drift after a lift-and-shift: the rehosted instance
#              still carries the source data centre's network identity.
#    FAULT B — an over-filtered replication job: the bytes that the application
#              needs were excluded by a well-intentioned rsync/DataSync filter,
#              so integrity validation fails and the app starts degraded.
#    FAULT C — a migration portfolio whose 7 Rs classification contradicts the
#              cutover runbook: a server marked "retire" is scheduled to cut
#              over in wave 1.
#
#  SIMULATION MAP (everything below is local; no AWS account, no cost)
#  -------------------------------------------------------------------
#    on-prem server  inv-app-01.wattle.internal  -> systemd unit clf13-onprem-inventory
#                    DC NIC 10.20.0.15           -> loopback alias 127.0.20.15
#    target EC2      i-0lab (private IP)         -> loopback address 127.0.30.11
#    AWS MGN / DataSync replication              -> rsync job replicate.sh
#    MGN cutover validation                      -> validate_replication.sh (SHA-256)
#    Migration Hub / Application Discovery       -> discovery/inventory.csv
#    Migration wave plan + runbook               -> migration/wave1_cutover.txt
#
#  OFFICIAL SOURCES (cited, not copied)
#  ------------------------------------
#    CLF-C02 exam guide
#      https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#    The 7 Rs migration strategies (AWS Prescriptive Guidance)
#      https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html
#    AWS Cloud Adoption Framework (AWS CAF) overview
#      https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html
#    AWS Application Migration Service (MGN)
#      https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html
#    AWS DataSync
#      https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
#    AWS Database Migration Service (DMS)
#      https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html
#    AWS Migration Hub
#      https://docs.aws.amazon.com/migrationhub/latest/ug/whatishub.html
#    AWS Snowball Edge (Snow Family)
#      https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
#
#  SAFETY
#  ------
#  Run ONLY on a disposable lab VM. Everything created lives under
#  /opt/aws-clf-c02/lab-1.3 plus two systemd units prefixed "clf13-". Nothing
#  else on the host is modified, no package is installed, no network egress is
#  performed, no existing service is touched. `--cleanup` removes all of it.
#
#  USAGE
#  -----
#    sudo ./clf-c02-1.3-break-fix.sh --break      # build the lab and break it
#    sudo ./clf-c02-1.3-break-fix.sh --briefing   # re-print the student briefing
#    sudo ./clf-c02-1.3-break-fix.sh --verify     # grade yourself (3 checks)
#    sudo ./clf-c02-1.3-break-fix.sh --hints      # progressive hints, no answers
#    sudo ./clf-c02-1.3-break-fix.sh --cleanup    # remove every trace
# ==============================================================================

set -euo pipefail

LAB_ROOT="/opt/aws-clf-c02/lab-1.3"
ONPREM="$LAB_ROOT/onprem"
CLOUD="$LAB_ROOT/cloud"
UNIT_DIR="/etc/systemd/system"
UNIT_SRC="clf13-onprem-inventory"
UNIT_DST="clf13-cloud-inventory"

ONPREM_ADDR="127.0.20.15"     # stands in for the DC NIC 10.20.0.15
TARGET_ADDR="127.0.30.11"     # stands in for the target EC2 private IP
BROKEN_ADDR="10.20.0.15"      # copied verbatim from the CMDB record -> FAULT A
APP_PORT="18080"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RST="$(tput sgr0)"; C_B="$(tput bold)"; C_R="$(tput setaf 1)"
  C_G="$(tput setaf 2)"; C_Y="$(tput setaf 3)"; C_C="$(tput setaf 6)"
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

hdr()  { printf '\n%s%s%s\n' "$C_B$C_C" "$*" "$C_RST"; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s[ PASS ]%s %s\n' "$C_G" "$C_RST" "$*"; }
bad()  { printf '  %s[ FAIL ]%s %s\n' "$C_R" "$C_RST" "$*"; }
warn() { printf '  %s[ WARN ]%s %s\n' "$C_Y" "$C_RST" "$*"; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_RST" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
preflight() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo) — the lab installs two systemd units"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required (this lab uses systemctl/journalctl for diagnosis)"
  [ -d /run/systemd/system ] || die "systemd is not the running init on this host"
  for c in python3 curl sha256sum awk sed grep find; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
  command -v rsync >/dev/null 2>&1 || warn "rsync not found — replicate.sh will fall back to a pure-shell copy with the same filters"
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${APP_PORT}\$"; then
      warn "something already listens on port ${APP_PORT}; the lab binds it on ${ONPREM_ADDR} only"
    fi
  fi
}

confirm_destructive() {
  say ""
  say "${C_Y}This will (re)create ${LAB_ROOT} and install/replace the systemd units"
  say "${UNIT_SRC}.service and ${UNIT_DST}.service on THIS host.${C_RST}"
  say "Run it only on a disposable lab VM."
  if [ "${ASSUME_YES:-0}" = "1" ]; then say "(--yes given, continuing)"; return 0; fi
  printf 'Type BREAK to continue: '
  local answer=""; read -r answer || true
  [ "$answer" = "BREAK" ] || die "aborted by user"
}

# ------------------------------------------------------------------------------
# Lab construction — the "healthy" pre-migration estate
# ------------------------------------------------------------------------------
build_lab() {
  hdr "[1/5] Building the simulated on-premises estate"
  rm -rf "$LAB_ROOT"
  mkdir -p "$ONPREM/app" "$ONPREM/etc" "$ONPREM/srv/data" \
           "$CLOUD/app"  "$CLOUD/etc"  "$CLOUD/srv/data" \
           "$LAB_ROOT/migration" "$LAB_ROOT/discovery" "$LAB_ROOT/state"

  # ---- the legacy application -------------------------------------------------
  cat > "$ONPREM/app/inventory_api.py" <<'PYEOF'
#!/usr/bin/env python3
"""Wattle Retail — legacy inventory API (2014 vintage, no code changes allowed).

Reads a flat key=value config file, serves two endpoints:

    GET /health     200 when every required on-disk artifact is present,
                    503 (degraded) listing what is missing otherwise.
    GET /inventory  the catalogue items read from <data_dir>/items-*.json

This is exactly the class of workload that AWS Prescriptive Guidance points at
REHOST (lift and shift): still in active use, source code frozen, OS supported
by AWS Application Migration Service, no appetite for refactoring.
    https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html
"""
import glob
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUIRED_ARTIFACTS = ["catalog.db", ".license.key"]


def load_conf(path):
    conf = {}
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            conf[key.strip()] = value.split("#", 1)[0].strip()
    return conf


CONF_PATH = sys.argv[1] if len(sys.argv) > 1 else ""
if not CONF_PATH or not os.path.isfile(CONF_PATH):
    print("FATAL: configuration file not found: %r" % CONF_PATH, file=sys.stderr)
    raise SystemExit(78)  # EX_CONFIG

CONF = load_conf(CONF_PATH)
SITE = CONF.get("site", "unknown")
BIND = CONF.get("bind_address", "127.0.0.1")
PORT = int(CONF.get("listen_port", "18080"))
DATA_DIR = CONF.get("data_dir", "")


def missing_artifacts():
    return [name for name in REQUIRED_ARTIFACTS
            if not os.path.isfile(os.path.join(DATA_DIR, name))]


class Handler(BaseHTTPRequestHandler):
    server_version = "WattleInventory/1.4"

    def _reply(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        missing = missing_artifacts()
        if self.path.startswith("/health"):
            if missing:
                self._reply(503, {"status": "degraded", "site": SITE,
                                  "data_dir": DATA_DIR, "missing": missing,
                                  "detail": "required artifacts absent from data_dir"})
            else:
                self._reply(200, {"status": "ok", "site": SITE,
                                  "data_dir": DATA_DIR, "missing": []})
            return
        if self.path.startswith("/inventory"):
            if missing:
                self._reply(503, {"status": "degraded", "missing": missing})
                return
            items = []
            for path in sorted(glob.glob(os.path.join(DATA_DIR, "items-*.json"))):
                with open(path, "r", encoding="utf-8") as fh:
                    items.extend(json.load(fh))
            self._reply(200, {"status": "ok", "site": SITE,
                              "count": len(items), "items": items})
            return
        self._reply(404, {"status": "not_found", "path": self.path})

    def log_message(self, fmt, *a):  # keep the journal readable
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % a))


def main():
    print("starting inventory-api site=%s bind=%s:%d data_dir=%s"
          % (SITE, BIND, PORT, DATA_DIR), file=sys.stderr)
    missing = missing_artifacts()
    if missing:
        print("WARNING: missing artifacts in data_dir: %s" % ", ".join(missing),
              file=sys.stderr)
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print("listening on %s:%d" % (BIND, PORT), file=sys.stderr)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
  chmod 0755 "$ONPREM/app/inventory_api.py"

  # ---- source configuration ---------------------------------------------------
  cat > "$ONPREM/etc/inventory.conf" <<EOF
# inv-app-01.wattle.internal — managed by the on-prem CMDB, do not hand-edit.
# The physical NIC in dc-melbourne-1 is 10.20.0.15; in this lab that address is
# simulated with the loopback alias below so the source keeps working.
site           = dc-melbourne-1
bind_address   = ${ONPREM_ADDR}
listen_port    = ${APP_PORT}
data_dir       = ${ONPREM}/srv/data
db_endpoint    = inv-db-01.wattle.internal:5432
license_server = lic-09.wattle.internal:27000
EOF

  # ---- source data (synthetic) ------------------------------------------------
  cat > "$ONPREM/srv/data/items-au.json" <<'EOF'
[
  {"sku": "AU-1001", "name": "Merino wool scarf",   "qty": 148, "warehouse": "MEL-1"},
  {"sku": "AU-1002", "name": "Cork yoga block",     "qty":  62, "warehouse": "MEL-1"},
  {"sku": "AU-1003", "name": "Enamel camp mug",     "qty": 310, "warehouse": "SYD-2"}
]
EOF
  cat > "$ONPREM/srv/data/items-nz.json" <<'EOF'
[
  {"sku": "NZ-2001", "name": "Manuka honey 500g",   "qty":  90, "warehouse": "AKL-1"},
  {"sku": "NZ-2002", "name": "Possum-blend beanie", "qty":  41, "warehouse": "AKL-1"}
]
EOF
  # Embedded catalogue: application state living on the filesystem, NOT in the
  # managed database. This distinction is the whole point of FAULT B.
  cat > "$ONPREM/srv/data/catalog.db" <<'EOF'
# SQLite-style embedded catalogue (synthetic lab artifact, not a real database file)
# table: catalog(sku TEXT PRIMARY KEY, category TEXT, active INTEGER)
AU-1001|apparel|1
AU-1002|fitness|1
AU-1003|outdoor|1
NZ-2001|grocery|1
NZ-2002|apparel|1
EOF
  cat > "$ONPREM/srv/data/.license.key" <<'EOF'
# Synthetic lab licence file — NOT a credential, NOT valid for anything.
WATTLE-LAB-0000-0000-0000
EOF
  chmod 0600 "$ONPREM/srv/data/.license.key"

  # ---- discovery output (Application Discovery Service / Migration Hub) --------
  cat > "$LAB_ROOT/discovery/inventory.csv" <<'EOF'
server_id,hostname,role,os,vcpu,mem_gb,app,dependencies,seven_r_strategy,wave,decommission_date
srv-inv-01,inv-app-01.wattle.internal,application,Ubuntu 22.04 LTS,4,16,inventory-api,srv-db-01,rehost,1,
srv-db-01,inv-db-01.wattle.internal,database,Ubuntu 22.04 LTS,8,32,inventory-db,,replatform,1,
srv-crm-03,crm-03.wattle.internal,application,RHEL 8,4,16,vendor-crm,srv-db-01,repurchase,2,
srv-rpt-02,rpt-legacy-02.wattle.internal,reporting,Windows Server 2012 R2,2,8,crystal-reports,srv-db-01,retire,none,2027-01-31
srv-esx-07,esx-07.wattle.internal,hypervisor,VMware ESXi 7.0,32,256,vmware-cluster,,relocate,3,
srv-lic-09,lic-09.wattle.internal,licensing,Windows Server 2008 R2,2,4,legacy-license,,retain,none,
EOF

  cat > "$LAB_ROOT/discovery/strategy_rules.md" <<'EOF'
# Wattle Retail — 7 Rs classification rules (portfolio board, ratified)

Source of the taxonomy:
https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html

| Strategy   | Apply when                                                                                  | Typical AWS service            |
|------------|---------------------------------------------------------------------------------------------|--------------------------------|
| rehost     | In active use, source frozen, OS supported by MGN, must move with no code change             | AWS Application Migration Service (MGN) |
| replatform | Moves mostly as-is but one managed-service swap pays for itself (e.g. self-managed DB -> RDS) | AWS DMS + Schema Conversion    |
| refactor   | Business case justifies re-architecting (scale, cost, feature velocity)                       | Containers / serverless        |
| repurchase | A SaaS product replaces the workload outright                                                 | AWS Marketplace                |
| retire     | No longer used; switch it off. MUST have a decommission_date and MUST NOT be in any wave      | —                              |
| retain     | Stays where it is for now (licensing, latency, compliance). MUST NOT be in any wave           | —                              |
| relocate   | VMware estate moved at hypervisor level, no OS/app change                                     | VMware Cloud on AWS            |

Hard rules enforced by `migration/validate_wave.sh`:

  R1  seven_r_strategy must be one of the seven values above.
  R2  a server assigned to a numbered wave must NOT be retire or retain.
  R3  retire/retain must have wave=none; retire must carry a decommission_date.
  R4  every dependency of a migrating server must cut over in the same wave or earlier.
  R5  relocate applies only to VMware ESXi hosts.
  R6  runbook method=mgn-lift-and-shift  => seven_r_strategy must be rehost.
  R7  runbook method=dms-replatform      => seven_r_strategy must be replatform.
EOF

  cat > "$LAB_ROOT/migration/wave1_cutover.txt" <<'EOF'
# Wave 1 cutover runbook — 2026-09-12T14:00Z, change ref CHG-4471
# Format: <server_id> method=<method> owner=<team>
srv-inv-01 method=mgn-lift-and-shift owner=platform
srv-db-01  method=dms-replatform     owner=data
EOF

  # ---- replication job (stands in for MGN / DataSync) -------------------------
  cat > "$LAB_ROOT/migration/replicate.sh" <<'EOF'
#!/usr/bin/env bash
# Replication job for wave 1 — stands in for AWS Application Migration Service
# block replication (https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html)
# and for an AWS DataSync task with include/exclude filters
# (https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html).
#
# Scope: the application directory and its data directory. /etc is NOT replicated;
# the target configuration is templated by the cutover runbook from the CMDB.
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$LAB/onprem"
DST="$LAB/cloud"

# --- replication filters -------------------------------------------------------
# Anything listed here is NOT copied to the target.
EXCLUDES=(
  '*.tmp'
  '*.swp'
  'core.*'
)
# -------------------------------------------------------------------------------

copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    local args=(-a --delete)
    local pattern
    for pattern in "${EXCLUDES[@]}"; do args+=(--exclude="$pattern"); done
    rsync "${args[@]}" "$src/" "$dst/"
  else
    # Portable fallback with the same filter semantics (name globs).
    rm -rf "${dst:?}"/* "${dst:?}"/.[!.]* 2>/dev/null || true
    ( cd "$src" && find . -mindepth 1 -print ) | while read -r rel; do
        rel="${rel#./}"
        base="$(basename "$rel")"
        skip=0
        for pattern in "${EXCLUDES[@]}"; do
          case "$base" in $pattern) skip=1 ;; esac
        done
        [ "$skip" -eq 1 ] && continue
        if [ -d "$src/$rel" ]; then
          mkdir -p "$dst/$rel"
        else
          mkdir -p "$dst/$(dirname "$rel")"
          cp -p "$src/$rel" "$dst/$rel"
        fi
      done
  fi
}

echo "[replicate] app/      $SRC/app      -> $DST/app"
copy_tree "$SRC/app" "$DST/app"
echo "[replicate] srv/data/ $SRC/srv/data -> $DST/srv/data"
copy_tree "$SRC/srv/data" "$DST/srv/data"
echo "[replicate] filters in effect: ${EXCLUDES[*]}"
echo "[replicate] done. Run validate_replication.sh before cutover."
EOF
  chmod 0755 "$LAB_ROOT/migration/replicate.sh"

  # ---- replication validation (stands in for MGN cutover validation) ----------
  cat > "$LAB_ROOT/migration/validate_replication.sh" <<'EOF'
#!/usr/bin/env bash
# Pre-cutover integrity gate: every source file must exist on the target with an
# identical SHA-256. A migration is only "done" when the target is provably the
# same bytes plus the intended platform changes — never when the job says 100 %.
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$LAB/onprem/srv/data"
DST="$LAB/cloud/srv/data"

manifest() {
  local dir="$1"
  ( cd "$dir" 2>/dev/null || exit 0
    find . -type f | LC_ALL=C sort | while read -r f; do
      printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${f#./}"
    done )
}

echo "source manifest : $SRC"
echo "target manifest : $DST"
echo "----------------------------------------------------------------------"
fail=0
while read -r hash rel; do
  [ -z "${rel:-}" ] && continue
  if [ ! -f "$DST/$rel" ]; then
    printf 'MISSING   %s\n' "$rel"; fail=$((fail+1)); continue
  fi
  thash="$(sha256sum "$DST/$rel" | cut -d' ' -f1)"
  if [ "$thash" != "$hash" ]; then
    printf 'MISMATCH  %s\n' "$rel"; fail=$((fail+1))
  else
    printf 'OK        %s\n' "$rel"
  fi
done < <(manifest "$SRC")
echo "----------------------------------------------------------------------"
if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAILED — $fail artifact(s) not replicated correctly. DO NOT CUT OVER."
  exit 1
fi
echo "RESULT: PASSED — target is byte-identical to the source data set."
EOF
  chmod 0755 "$LAB_ROOT/migration/validate_replication.sh"

  # ---- wave plan validation ---------------------------------------------------
  cat > "$LAB_ROOT/migration/validate_wave.sh" <<'EOF'
#!/usr/bin/env bash
# Portfolio consistency gate. Enforces rules R1..R7 from discovery/strategy_rules.md
# against discovery/inventory.csv and migration/wave1_cutover.txt.
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="$LAB/discovery/inventory.csv"
RUNBOOK="$LAB/migration/wave1_cutover.txt"
violations=0

field() { awk -F, -v id="$1" -v n="$2" 'NR>1 && $1==id {print $n}' "$CSV"; }

echo "portfolio : $CSV"
echo "runbook   : $RUNBOOK"
echo "----------------------------------------------------------------------"

while IFS=, read -r id host role os vcpu mem app deps strategy wave decom; do
  [ "$id" = "server_id" ] && continue
  [ -z "${id:-}" ] && continue

  case "$strategy" in
    rehost|replatform|refactor|repurchase|retire|retain|relocate) ;;
    *) echo "R1 VIOLATION  $id: '$strategy' is not one of the 7 Rs"
       violations=$((violations+1)) ;;
  esac

  if [ "$wave" != "none" ]; then
    case "$strategy" in
      retire|retain)
        echo "R2 VIOLATION  $id: strategy '$strategy' but scheduled in wave $wave — a server that is being switched off or left in place cannot cut over"
        violations=$((violations+1)) ;;
    esac
  fi

  case "$strategy" in
    retire|retain)
      if [ "$wave" != "none" ]; then
        echo "R3 VIOLATION  $id: strategy '$strategy' requires wave=none (found '$wave')"
        violations=$((violations+1))
      fi
      if [ "$strategy" = "retire" ] && [ -z "${decom:-}" ]; then
        echo "R3 VIOLATION  $id: retire requires a decommission_date"
        violations=$((violations+1))
      fi ;;
  esac

  if [ "$wave" != "none" ] && [ -n "${deps:-}" ]; then
    IFS=';' read -r -a dep_list <<< "$deps"
    for dep in "${dep_list[@]}"; do
      [ -z "$dep" ] && continue
      dep_wave="$(field "$dep" 10)"
      if [ -z "$dep_wave" ]; then
        echo "R4 VIOLATION  $id: dependency '$dep' is not in the portfolio"
        violations=$((violations+1))
      elif [ "$dep_wave" = "none" ]; then
        echo "R4 VIOLATION  $id: cuts over in wave $wave but dependency '$dep' never migrates"
        violations=$((violations+1))
      elif [ "$dep_wave" -gt "$wave" ] 2>/dev/null; then
        echo "R4 VIOLATION  $id: wave $wave depends on '$dep' in later wave $dep_wave"
        violations=$((violations+1))
      fi
    done
  fi

  if [ "$strategy" = "relocate" ] && ! printf '%s' "$os" | grep -qi 'esxi'; then
    echo "R5 VIOLATION  $id: relocate applies only to VMware ESXi hosts (os='$os')"
    violations=$((violations+1))
  fi
done < "$CSV"

while read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  id="$(printf '%s' "$line" | awk '{print $1}')"
  method="$(printf '%s' "$line" | grep -o 'method=[^ ]*' | cut -d= -f2)"
  strategy="$(field "$id" 9)"
  case "$method" in
    mgn-lift-and-shift)
      if [ "$strategy" != "rehost" ]; then
        echo "R6 VIOLATION  $id: runbook method '$method' implies rehost, portfolio says '$strategy'"
        violations=$((violations+1))
      fi ;;
    dms-replatform)
      if [ "$strategy" != "replatform" ]; then
        echo "R7 VIOLATION  $id: runbook method '$method' implies replatform, portfolio says '$strategy'"
        violations=$((violations+1))
      fi ;;
  esac
done < "$RUNBOOK"

echo "----------------------------------------------------------------------"
if [ "$violations" -ne 0 ]; then
  echo "RESULT: FAILED — $violations rule violation(s). Wave 1 is not approved."
  exit 1
fi
echo "RESULT: PASSED — portfolio and runbook agree; wave 1 is internally consistent."
EOF
  chmod 0755 "$LAB_ROOT/migration/validate_wave.sh"

  # ---- loopback alias for the "DC NIC" ----------------------------------------
  if ! ip -o addr show dev lo 2>/dev/null | grep -q "$ONPREM_ADDR"; then
    ip addr add "$ONPREM_ADDR/32" dev lo 2>/dev/null || true
  fi
  say "  on-prem estate built under $ONPREM"
}

install_units() {
  hdr "[2/5] Registering the source and target hosts with systemd"
  cat > "$UNIT_DIR/$UNIT_SRC.service" <<EOF
[Unit]
Description=CLF-C02 lab 1.3 - inv-app-01.wattle.internal (SOURCE, on-premises)
Documentation=https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 $ONPREM/app/inventory_api.py $ONPREM/etc/inventory.conf
Restart=no

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/$UNIT_DST.service" <<EOF
[Unit]
Description=CLF-C02 lab 1.3 - i-0lab rehosted inventory-api (TARGET, AWS)
Documentation=https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 $CLOUD/app/inventory_api.py $CLOUD/etc/inventory.conf
Restart=no

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl restart "$UNIT_SRC.service"
  sleep 1
  if systemctl is-active --quiet "$UNIT_SRC.service"; then
    say "  source service running on ${ONPREM_ADDR}:${APP_PORT} (your known-good reference)"
  else
    warn "the source service did not start — inspect: journalctl -u $UNIT_SRC -n 30"
  fi
}

# ------------------------------------------------------------------------------
# Fault injection
# ------------------------------------------------------------------------------
inject_faults() {
  hdr "[3/5] Running the wave-1 replication job (with the filters as configured)"
  # FAULT B — an operator widened the replication filters, reasoning that hidden
  # files are editor droppings and that "the database is handled by DMS anyway".
  # catalog.db is embedded application state on the filesystem, and .license.key
  # is required at runtime: neither is covered by DMS.
  sed -i "s|^  'core\.\*'$|  'core.*'\n  '.*'      # hidden files: editor/temp droppings\n  '*.db'    # databases are handled by DMS, no need to copy|" \
      "$LAB_ROOT/migration/replicate.sh"
  "$LAB_ROOT/migration/replicate.sh" | sed 's/^/  /'

  hdr "[4/5] Templating the target configuration from the CMDB record"
  # FAULT A — the runbook rendered the target config from the CMDB, which stores
  # the physical data centre address. A rehost moves the machine, not its network
  # identity: the target instance has no such interface.
  cat > "$CLOUD/etc/inventory.conf" <<EOF
# i-0lab (rehosted target) — rendered by the wave-1 cutover runbook from the
# CMDB record for inv-app-01.wattle.internal. Review before cutover.
site           = aws-ap-southeast-2
bind_address   = ${BROKEN_ADDR}
listen_port    = ${APP_PORT}
data_dir       = ${CLOUD}/srv/data
db_endpoint    = inv-db-01.wattle.internal:5432
license_server = lic-09.wattle.internal:27000
EOF
  say "  wrote $CLOUD/etc/inventory.conf"

  # FAULT C — the portfolio was edited after the runbook was signed off.
  sed -i 's|^srv-inv-01,\(.*\),rehost,1,$|srv-inv-01,\1,retire,1,|' \
      "$LAB_ROOT/discovery/inventory.csv"

  hdr "[5/5] Attempting the cutover"
  systemctl daemon-reload
  systemctl start "$UNIT_DST.service" || true
  sleep 2
  systemctl --no-pager --full status "$UNIT_DST.service" 2>&1 | sed 's/^/  /' || true
}

# ------------------------------------------------------------------------------
# Student briefing
# ------------------------------------------------------------------------------
briefing() {
  cat <<EOF

${C_B}==============================================================================${C_RST}
${C_B} CLF-C02 · Task 1.3 · BREAK & FIX — Wave 1 cutover of a rehosted workload${C_RST}
${C_B}==============================================================================${C_RST}

${C_B}THE SITUATION${C_RST}
Wattle Retail is migrating out of dc-melbourne-1. Wave 1 contains two servers:
srv-inv-01 (the inventory API, lift-and-shift with AWS Application Migration
Service) and srv-db-01 (its database, replatformed with AWS DMS). You are the
platform engineer on the cutover bridge. The replication job reported success.
The cutover did not.

Lab root : ${LAB_ROOT}
Source   : systemd unit ${C_C}${UNIT_SRC}${C_RST}  -> ${ONPREM_ADDR}:${APP_PORT}   (healthy reference)
Target   : systemd unit ${C_C}${UNIT_DST}${C_RST}  -> currently NOT serving

${C_B}SYMPTOMS YOU WILL SEE${C_RST}
  1. ${C_Y}systemctl status ${UNIT_DST}${C_RST} shows the unit ${C_R}failed${C_RST} seconds after start.
     ${C_Y}curl${C_RST} against the target returns "Connection refused" or "Couldn't connect".
     The journal ends in a Python traceback from the socket bind.
  2. Once the service does start, ${C_Y}GET /health${C_RST} answers ${C_R}HTTP 503${C_RST} with a JSON body
     naming artifacts it cannot find, and ${C_Y}GET /inventory${C_RST} serves nothing.
     ${LAB_ROOT}/migration/validate_replication.sh prints MISSING lines.
  3. ${LAB_ROOT}/migration/validate_wave.sh exits non-zero: the portfolio
     classification for srv-inv-01 contradicts the signed wave-1 runbook.

${C_B}YOUR OBJECTIVE${C_RST}
Get all three checks to PASS:

  ${C_C}sudo $0 --verify${C_RST}

  [1] ${UNIT_DST} is active and answers HTTP 200 on /health at the
      address and port declared in ${CLOUD}/etc/inventory.conf
  [2] every file under ${ONPREM}/srv/data exists under
      ${CLOUD}/srv/data with an identical SHA-256, and the target
      still reads its own data_dir (pointing the target back at the source
      directory is NOT a migration — check [2] rejects it)
  [3] ${LAB_ROOT}/migration/validate_wave.sh exits 0

${C_B}RULES OF ENGAGEMENT${C_RST}
  · Do not edit the application source (${CLOUD}/app/inventory_api.py).
    A rehost changes no code — that constraint is the exam point.
  · Fix the ${C_B}replication job${C_RST}, not the symptom: copying the missing files by
    hand will be undone the next time replicate.sh runs, and check [2] re-runs
    the real job. This is why AWS gates cutover on validation, not on "100 %".
  · Everything you need is on disk. Read, in this order:
      ${LAB_ROOT}/discovery/strategy_rules.md
      ${LAB_ROOT}/migration/wave1_cutover.txt
      ${LAB_ROOT}/migration/replicate.sh

${C_B}DIAGNOSTIC STARTING POINTS${C_RST}
  systemctl --failed
  systemctl status ${UNIT_DST} --no-pager -l
  journalctl -u ${UNIT_DST} -n 40 --no-pager
  ip -brief addr show
  ss -ltnp | grep ${APP_PORT}
  curl -si http://${ONPREM_ADDR}:${APP_PORT}/health     # the reference, works
  ${LAB_ROOT}/migration/validate_replication.sh
  ${LAB_ROOT}/migration/validate_wave.sh

${C_B}EXAM FRAMING (why each fault is a 1.3 question)${C_RST}
  FAULT A  A rehost moves the workload, not its network identity. Expect exam
           items on what MGN does and does not carry across, and on why even a
           "lift and shift" needs a cutover runbook.
  FAULT B  Migration tooling moves what you tell it to move. DMS moves database
           engines; DataSync moves files subject to your filters; Snow Family
           moves bulk data offline when the network cannot. Knowing which tool
           owns which bytes is the difference between a clean cutover and a
           degraded one.
  FAULT C  The 7 Rs are a decision, and a wrong one propagates: retire and
           retain never appear in a wave. AWS CAF calls this the alignment
           between the Business and Platform perspectives.

Hints without answers: ${C_C}sudo $0 --hints${C_RST}
Remove the lab:        ${C_C}sudo $0 --cleanup${C_RST}

EOF
}

hints() {
  cat <<EOF

${C_B}HINT 1 (fault A)${C_RST}
  Compare ${C_Y}ip -brief addr show${C_RST} with the ${C_Y}bind_address${C_RST} line in
  ${CLOUD}/etc/inventory.conf. A socket can only bind an address that
  exists on the host; errno 99 (EADDRNOTAVAIL) says exactly that. Which value
  belongs to a machine in dc-melbourne-1 and which to your target instance?
  The target instance address in this lab is ${TARGET_ADDR}.

${C_B}HINT 2 (fault B)${C_RST}
  Run validate_replication.sh and note the two file names it reports. Then open
  ${LAB_ROOT}/migration/replicate.sh and read the EXCLUDES array out
  loud against those names. Ask: is an embedded .db file the same thing as the
  managed database that DMS is migrating? Is every dotfile a temp file?

${C_B}HINT 3 (fault C)${C_RST}
  validate_wave.sh names the rules it breaks. Open strategy_rules.md, find the
  row that matches srv-inv-01's actual situation (in active use, source frozen,
  moving with no code change, runbook says mgn-lift-and-shift), and make the
  portfolio say so. One field on one line.

EOF
}

# ------------------------------------------------------------------------------
# Grading
# ------------------------------------------------------------------------------
conf_get() {
  awk -F= -v k="$2" '
    /^[[:space:]]*#/ {next}
    NF>1 {
      key=$1; sub(/^[[:space:]]+/,"",key); sub(/[[:space:]]+$/,"",key)
      if (key==k) { sub(/^[^=]*=/,""); sub(/#.*$/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit }
    }' "$1"
}

dir_manifest() {
  local dir="$1"
  ( cd "$dir" 2>/dev/null || exit 0
    find . -type f | LC_ALL=C sort | while read -r f; do
      printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "${f#./}"
    done )
}

verify() {
  [ -d "$LAB_ROOT" ] || die "lab not found at $LAB_ROOT — run: sudo $0 --break"
  local pass=0

  hdr "CHECK 1/3 — the rehosted service is up and healthy"
  local conf="$CLOUD/etc/inventory.conf" bind port target code body
  if [ ! -f "$conf" ]; then
    bad "target configuration missing: $conf"
  else
    bind="$(conf_get "$conf" bind_address)"
    port="$(conf_get "$conf" listen_port)"
    target="$bind"
    [ "$bind" = "0.0.0.0" ] && target="127.0.0.1"
    if ! systemctl is-active --quiet "$UNIT_DST.service"; then
      bad "$UNIT_DST is not active (state: $(systemctl is-active "$UNIT_DST.service" 2>/dev/null || true))"
      say "        journalctl -u $UNIT_DST -n 20 --no-pager"
    else
      body="$(curl -s --max-time 4 -o /tmp/clf13.body -w '%{http_code}' "http://$target:$port/health" 2>/dev/null || echo 000)"
      code="$body"
      if [ "$code" = "200" ] && grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' /tmp/clf13.body; then
        ok "GET http://$target:$port/health -> 200 {\"status\": \"ok\"}"
        pass=$((pass+1))
      elif [ "$code" = "503" ]; then
        bad "service is up but degraded (HTTP 503): $(cat /tmp/clf13.body)"
      else
        bad "no healthy answer from http://$target:$port/health (HTTP $code)"
      fi
    fi
    rm -f /tmp/clf13.body
  fi

  hdr "CHECK 2/3 — replication integrity (source vs target data set)"
  local dd; dd="$(conf_get "$conf" data_dir 2>/dev/null || true)"
  case "${dd:-}" in
    "$CLOUD"/*)
      if [ "$(dir_manifest "$ONPREM/srv/data")" = "$(dir_manifest "$CLOUD/srv/data")" ] \
         && [ -n "$(dir_manifest "$ONPREM/srv/data")" ]; then
        ok "every source artifact present on the target with a matching SHA-256"
        if "$LAB_ROOT/migration/replicate.sh" >/dev/null 2>&1 \
           && [ "$(dir_manifest "$ONPREM/srv/data")" = "$(dir_manifest "$CLOUD/srv/data")" ]; then
          ok "re-running the replication job keeps the target complete (the job itself is fixed)"
          pass=$((pass+1))
        else
          bad "the target is complete now, but re-running replicate.sh breaks it again — fix the job, not the copy"
        fi
      else
        bad "target data set differs from the source"
        "$LAB_ROOT/migration/validate_replication.sh" 2>&1 | grep -E '^(MISSING|MISMATCH)' | sed 's/^/        /' || true
      fi ;;
    *)
      bad "target data_dir is '${dd:-<unset>}' — it must live under $CLOUD (pointing the rehosted app back at the source is not a migration)" ;;
  esac

  hdr "CHECK 3/3 — migration wave plan consistency (7 Rs vs runbook)"
  if "$LAB_ROOT/migration/validate_wave.sh" >/tmp/clf13.wave 2>&1; then
    ok "validate_wave.sh: all rules satisfied"
    pass=$((pass+1))
  else
    bad "validate_wave.sh reports violations:"
    grep -E 'VIOLATION|RESULT' /tmp/clf13.wave | sed 's/^/        /'
  fi
  rm -f /tmp/clf13.wave

  hdr "SCORE: $pass/3"
  if [ "$pass" -eq 3 ]; then
    say "${C_G}${C_B}Cutover approved. srv-inv-01 is rehosted, validated and consistent with the wave plan.${C_RST}"
    say "Now answer these out loud — they are the exam:"
    say "  · Which of the 7 Rs did srv-db-01 use, and which AWS service implements it?"
    say "  · Your source data set is 400 TB and the WAN link is 200 Mbps. What changes?"
    say "  · Which AWS CAF perspective owns the decision to retire srv-rpt-02?"
  else
    say "Keep going. ${C_C}sudo $0 --hints${C_RST} for hints without answers."
  fi
  [ "$pass" -eq 3 ]
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
cleanup() {
  hdr "Removing the lab"
  for u in "$UNIT_DST" "$UNIT_SRC"; do
    systemctl stop "$u.service" 2>/dev/null || true
    systemctl disable "$u.service" 2>/dev/null || true
    rm -f "$UNIT_DIR/$u.service"
  done
  systemctl daemon-reload
  systemctl reset-failed "$UNIT_SRC.service" "$UNIT_DST.service" 2>/dev/null || true
  ip addr del "$ONPREM_ADDR/32" dev lo 2>/dev/null || true
  if [ "$LAB_ROOT" = "/opt/aws-clf-c02/lab-1.3" ] && [ -d "$LAB_ROOT" ]; then
    rm -rf "$LAB_ROOT"
    rmdir /opt/aws-clf-c02 2>/dev/null || true
  fi
  ok "systemd units, loopback alias and $LAB_ROOT removed"
}

status() {
  hdr "Lab status"
  [ -d "$LAB_ROOT" ] && ok "lab root present: $LAB_ROOT" || bad "lab root absent"
  for u in "$UNIT_SRC" "$UNIT_DST"; do
    printf '  %-28s %s\n' "$u" "$(systemctl is-active "$u.service" 2>/dev/null || echo absent)"
  done
  ip -brief addr show dev lo 2>/dev/null | sed 's/^/  /' || true
}

usage() {
  cat <<EOF
CLF-C02 Task 1.3 — break & fix lab (migration to the AWS Cloud)

  sudo $0 --break [--yes]   build the lab and inject the three faults
  sudo $0 --briefing        re-print the student briefing
  sudo $0 --verify          grade the three objectives
  sudo $0 --hints           progressive hints, no answers
  sudo $0 --status          show units and lab root
  sudo $0 --cleanup         remove everything this script created
EOF
}

ASSUME_YES=0
ACTION=""
for arg in "${@:-}"; do
  case "$arg" in
    --break)    ACTION="break" ;;
    --verify)   ACTION="verify" ;;
    --briefing) ACTION="briefing" ;;
    --hints)    ACTION="hints" ;;
    --status)   ACTION="status" ;;
    --cleanup)  ACTION="cleanup" ;;
    --yes|-y)   ASSUME_YES=1 ;;
    ""|-h|--help) : ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done

case "$ACTION" in
  break)
    preflight; confirm_destructive
    build_lab; install_units; inject_faults; briefing ;;
  verify)   preflight; verify ;;
  briefing) briefing ;;
  hints)    hints ;;
  status)   status ;;
  cleanup)  [ "$(id -u)" -eq 0 ] || die "run as root"; cleanup ;;
  *)        usage ;;
esac

# ==============================================================================
#  SOLUTION — do not read until you have tried. Step by step.
# ==============================================================================
#
#  ── STEP 0 · Reconnaissance ────────────────────────────────────────────────
#
#    systemctl --failed
#    systemctl status clf13-cloud-inventory --no-pager -l
#    journalctl -u clf13-cloud-inventory -n 40 --no-pager
#
#  The journal ends with:
#
#    starting inventory-api site=aws-ap-southeast-2 bind=10.20.0.15:18080 ...
#    OSError: [Errno 99] Cannot assign requested address
#
#  Errno 99 is EADDRNOTAVAIL: the process asked to bind an IP that does not
#  exist on this host. Confirm with `ip -brief addr show` — 10.20.0.15 is on the
#  data centre NIC of inv-app-01, not on the target instance.
#
#  ── STEP 1 · Fault A: strip the source's network identity ──────────────────
#
#    sudo sed -i 's/^bind_address .*= .*/bind_address   = 127.0.30.11/' \
#         /opt/aws-clf-c02/lab-1.3/cloud/etc/inventory.conf
#    sudo systemctl restart clf13-cloud-inventory
#    systemctl is-active clf13-cloud-inventory        # -> active
#    curl -si http://127.0.30.11:18080/health
#
#  (0.0.0.0 also works, but note that the source already holds
#  127.0.20.15:18080 — one address/port pair per socket. Binding the specific
#  target address is what a real EC2 instance does.)
#
#  The service is now up and returns:
#
#    HTTP/1.0 503 Service Unavailable
#    {"status": "degraded", ..., "missing": ["catalog.db", ".license.key"]}
#
#  Symptom 1 is fixed; symptom 2 is now visible. That ordering is deliberate —
#  a failed unit hides every application-level fault behind it.
#
#  ── STEP 2 · Fault B: fix the replication job, not the copy ────────────────
#
#    /opt/aws-clf-c02/lab-1.3/migration/validate_replication.sh
#
#      MISSING   .license.key
#      MISSING   catalog.db
#      RESULT: FAILED — 2 artifact(s) not replicated correctly. DO NOT CUT OVER.
#
#  Open migration/replicate.sh and read the filters:
#
#      EXCLUDES=(
#        '*.tmp'
#        '*.swp'
#        'core.*'
#        '.*'      # hidden files: editor/temp droppings     <-- drops .license.key
#        '*.db'    # databases are handled by DMS            <-- drops catalog.db
#      )
#
#  Both assumptions are wrong for this workload. catalog.db is embedded
#  application state on the filesystem; AWS DMS migrates the PostgreSQL engine on
#  srv-db-01 and never sees it. .license.key is a runtime dependency that happens
#  to start with a dot. Delete the two patterns:
#
#    sudo sed -i "/^  '\.\*'/d;/^  '\*\.db'/d" \
#         /opt/aws-clf-c02/lab-1.3/migration/replicate.sh
#    sudo /opt/aws-clf-c02/lab-1.3/migration/replicate.sh
#    /opt/aws-clf-c02/lab-1.3/migration/validate_replication.sh   # RESULT: PASSED
#    curl -s http://127.0.30.11:18080/health   # {"status": "ok", ...}
#    curl -s http://127.0.30.11:18080/inventory | head -c 200
#
#  Copying the two files by hand would turn /health green and still be wrong:
#  the next replication cycle deletes them again. Check [2] re-runs the job on
#  purpose to catch exactly that shortcut.
#
#  ── STEP 3 · Fault C: reconcile the 7 Rs classification ────────────────────
#
#    /opt/aws-clf-c02/lab-1.3/migration/validate_wave.sh
#
#      R2 VIOLATION  srv-inv-01: strategy 'retire' but scheduled in wave 1 ...
#      R3 VIOLATION  srv-inv-01: strategy 'retire' requires wave=none (found '1')
#      R3 VIOLATION  srv-inv-01: retire requires a decommission_date
#      R6 VIOLATION  srv-inv-01: runbook method 'mgn-lift-and-shift' implies
#                    rehost, portfolio says 'retire'
#
#  discovery/strategy_rules.md: in active use, source frozen, OS supported by
#  MGN, must move with no code change => rehost. The runbook already says
#  mgn-lift-and-shift. Correct the portfolio, not the runbook:
#
#    sudo sed -i 's/^\(srv-inv-01,.*\),retire,1,$/\1,rehost,1,/' \
#         /opt/aws-clf-c02/lab-1.3/discovery/inventory.csv
#    /opt/aws-clf-c02/lab-1.3/migration/validate_wave.sh   # RESULT: PASSED
#
#  ── STEP 4 · Grade ─────────────────────────────────────────────────────────
#
#    sudo ./clf-c02-1.3-break-fix.sh --verify      # SCORE: 3/3
#    sudo ./clf-c02-1.3-break-fix.sh --cleanup
#
#  ── EXTRA CREDIT (not graded) ──────────────────────────────────────────────
#
#  cloud/etc/inventory.conf still points db_endpoint at
#  inv-db-01.wattle.internal:5432 and license_server at lic-09 (srv-lic-09 is
#  classified retain — it never moves). Neither is exercised by /health, and
#  both are real cutover work:
#    · the database is being replatformed with AWS DMS, so after cutover the
#      endpoint is an Amazon RDS endpoint, not the on-prem hostname;
#    · the licence server stays on-premises, so the target needs hybrid
#      connectivity (AWS Site-to-Site VPN or AWS Direct Connect) and a DNS
#      resolution path to reach it. That dependency is precisely why "retain"
#      is a strategy and not an omission.
#
#  ── WHAT THE EXAM ASKS ABOUT THIS (Task 1.3) ───────────────────────────────
#
#  · The 7 Rs and how to recognise each from a one-paragraph scenario:
#    rehost (MGN, no code change), replatform (e.g. self-managed DB -> Amazon
#    RDS via DMS), refactor (re-architect), repurchase (move to SaaS), retire
#    (switch off), retain (leave in place for now), relocate (VMware Cloud on
#    AWS, hypervisor-level).
#  · AWS Cloud Adoption Framework: six perspectives — Business, People,
#    Governance, Platform, Security, Operations — used to find capability gaps
#    before a migration, and its phases Envision, Align, Launch, Scale.
#  · Migration tooling and when each applies: AWS Application Migration Service
#    (server rehost), AWS DMS (databases, homogeneous and heterogeneous),
#    AWS DataSync (online file transfer over the network), AWS Snow Family
#    (offline bulk transfer when the network cannot carry the data in time),
#    AWS Migration Hub (single pane over the portfolio), AWS Application
#    Discovery Service (the inventory that feeds the 7 Rs decision).
#  · Benefits framed as the exam frames them: shifting CapEx to OpEx, stopping
#    guesses about capacity, higher business agility and speed of experiments,
#    and operational resilience — see the CLF-C02 exam guide, Domain 1.
#
#  Sources:
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#    https://docs.aws.amazon.com/prescriptive-guidance/latest/large-migration-guide/migration-strategies.html
#    https://docs.aws.amazon.com/whitepapers/latest/overview-aws-cloud-adoption-framework/welcome.html
#    https://docs.aws.amazon.com/mgn/latest/ug/what-is-application-migration-service.html
#    https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html
#    https://docs.aws.amazon.com/datasync/latest/userguide/what-is-datasync.html
#    https://docs.aws.amazon.com/snowball/latest/developer-guide/whatisedge.html
#    https://docs.aws.amazon.com/migrationhub/latest/ug/whatishub.html
# ==============================================================================