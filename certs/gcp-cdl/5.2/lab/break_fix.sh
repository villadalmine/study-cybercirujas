#!/usr/bin/env bash
#
# =============================================================================
#  gcp-cdl — Cloud Digital Leader (exam version 2026-08-12)
#  Section 5. Trust, security, and compliance
#  Topic 5.2 — Business value of making Google part of the security team:
#              defense in depth, multilayered cloud security  (exam weight 9.0)
#
#  BREAK & FIX LAB — "The day every layer failed at once"
#
#  What this lab teaches, and why a business-value objective gets a hands-on lab:
#  the CDL exam does not ask you to type gcloud commands, it asks you to explain
#  WHY a layered posture is worth paying for. The cheapest way to internalise
#  that is to watch a single misconfiguration get absorbed by the layer below it,
#  and then watch what happens when five layers are down simultaneously. This
#  script simulates, on one disposable VM, the five controls Google Cloud gives
#  you by default and the one control Google operates FOR you (Security Command
#  Center), then removes them all.
#
#  Layer map — lab artifact  ->  Google Cloud control it stands in for
#  -----------------------------------------------------------------------------
#   nft/iptables ingress rule ->  VPC firewall default-deny ingress + Cloud Armor
#   iam/policy.json           ->  Cloud IAM allow policy (principals + roles)
#   org-policy/constraints    ->  Organization Policy Service constraints
#   keys/cmek.key + *.enc     ->  Cloud KMS CMEK / encryption at rest
#   logs/audit.log + log sink ->  Cloud Audit Logs exported to a separate project
#   bin/scc-scan.sh           ->  Security Command Center (Google-operated)
#
#  Official references (read these, they are the exam's own sources):
#   - Exam guide:
#     https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#   - Google security foundations / defense in depth whitepaper:
#     https://cloud.google.com/security/overview/whitepaper
#   - Shared responsibility, shared fate:
#     https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
#   - Security Command Center overview:
#     https://cloud.google.com/security-command-center/docs/security-command-center-overview
#   - Organization Policy Service:
#     https://cloud.google.com/resource-manager/docs/organization-policy/overview
#   - Customer-managed encryption keys (CMEK):
#     https://cloud.google.com/kms/docs/cmek
#   - Public access prevention (Cloud Storage):
#     https://cloud.google.com/storage/docs/public-access-prevention
#   - Cloud Audit Logs:
#     https://cloud.google.com/logging/docs/audit
#   - VPC firewall rules:
#     https://cloud.google.com/firewall/docs/firewalls
#
#  SAFETY CONTRACT
#   - Everything lives under $LAB_ROOT (default /opt/gdl-defense-lab).
#   - The only host-wide mutation is ONE ingress firewall rule on TCP/8080,
#     added inside a dedicated table/chain and removed by `--reset`.
#     Port 22 is refused explicitly; you cannot lock yourself out.
#   - No package is installed, no system service is modified, no user is created.
#   - `--reset` returns the VM to its previous state.
#   - Run this ONLY on a disposable lab VM. It asks before touching anything.
#
#  Usage:
#     sudo ./5.2-break-and-fix.sh              # provision, break, print the brief
#     sudo /opt/gdl-defense-lab/bin/scc-scan.sh   # your verification loop
#     sudo ./5.2-break-and-fix.sh --brief      # reprint the mission brief
#     sudo ./5.2-break-and-fix.sh --verify     # same as running the scanner
#     sudo ./5.2-break-and-fix.sh --reset      # remove the lab entirely
# =============================================================================

set -euo pipefail

LAB_ROOT="${LAB_ROOT:-/opt/gdl-defense-lab}"
LAB_PORT="${LAB_PORT:-8080}"
LAB_ASSUME_YES="${LAB_ASSUME_YES:-0}"
FW_BACKEND=""
NFT_TABLE="gdl_lab"

C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'
C_CYA=$'\033[0;36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'

# --------------------------------------------------------------------------- #
# Preconditions
# --------------------------------------------------------------------------- #

die() { printf '%s[ABORT]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 2; }
info() { printf '%s[lab]%s %s\n' "$C_CYA" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"
}

require_deps() {
  local missing=()
  for bin in openssl python3 sha256sum awk sed grep; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing dependencies: ${missing[*]}"

  if command -v nft >/dev/null 2>&1; then
    FW_BACKEND="nft"
  elif command -v iptables >/dev/null 2>&1; then
    FW_BACKEND="iptables"
  else
    die "neither nft nor iptables found; this lab needs a packet filter"
  fi
}

guard_port() {
  case "$LAB_PORT" in
    22|53|80|443) die "LAB_PORT=$LAB_PORT is a real service port; pick something like 8080" ;;
  esac
  [ "$LAB_PORT" -gt 1024 ] 2>/dev/null || die "LAB_PORT must be > 1024"
}

confirm_disposable() {
  [ "$LAB_ASSUME_YES" = "1" ] && return 0
  printf '%s\n' "This script adds a firewall rule and writes under $LAB_ROOT."
  printf '%s\n' "It is meant for a DISPOSABLE lab VM only."
  read -r -p "Type 'disposable' to continue: " answer
  [ "$answer" = "disposable" ] || die "not confirmed; nothing was changed"
}

# --------------------------------------------------------------------------- #
# Firewall abstraction — VPC firewall default-deny ingress, simulated
# --------------------------------------------------------------------------- #

fw_provision() {
  case "$FW_BACKEND" in
    nft)
      nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || \
        nft add table inet "$NFT_TABLE"
      nft list chain inet "$NFT_TABLE" input >/dev/null 2>&1 || \
        nft add chain inet "$NFT_TABLE" input \
          '{ type filter hook input priority 0 ; policy accept ; }'
      ;;
    iptables) : ;;
  esac
  fw_deny_add
}

fw_deny_add() {
  fw_deny_present && return 0
  case "$FW_BACKEND" in
    nft)
      nft add rule inet "$NFT_TABLE" input iif != "lo" tcp dport "$LAB_PORT" drop
      ;;
    iptables)
      iptables -I INPUT -p tcp --dport "$LAB_PORT" '!' -i lo -j DROP
      ;;
  esac
}

fw_deny_del() {
  case "$FW_BACKEND" in
    nft)
      local handle
      handle=$(nft -a list chain inet "$NFT_TABLE" input 2>/dev/null \
               | awk -v p="dport $LAB_PORT" '$0 ~ p && /drop/ {print $NF; exit}')
      [ -n "${handle:-}" ] && nft delete rule inet "$NFT_TABLE" input handle "$handle"
      ;;
    iptables)
      while iptables -C INPUT -p tcp --dport "$LAB_PORT" '!' -i lo -j DROP 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$LAB_PORT" '!' -i lo -j DROP
      done
      ;;
  esac
  return 0
}

fw_deny_present() {
  case "$FW_BACKEND" in
    nft)
      nft list chain inet "$NFT_TABLE" input 2>/dev/null \
        | grep -q "dport $LAB_PORT" && return 0 || return 1
      ;;
    iptables)
      iptables -C INPUT -p tcp --dport "$LAB_PORT" '!' -i lo -j DROP 2>/dev/null
      ;;
  esac
}

fw_teardown() {
  case "$FW_BACKEND" in
    nft)     nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" ;;
    iptables) fw_deny_del ;;
  esac
  return 0
}

# --------------------------------------------------------------------------- #
# Provision — a "compliant" baseline the student never gets to see intact
# --------------------------------------------------------------------------- #

provision() {
  info "provisioning the compliant baseline under $LAB_ROOT"
  mkdir -p "$LAB_ROOT"/{bin,iam,org-policy,keys,data,logs,.log-sink}

  # --- Layer: data. Synthetic PII, encrypted at rest with a CMEK-style key ----
  cat > "$LAB_ROOT/data/customers.csv" <<'CSV'
customer_id,full_name,email,national_id,card_last4,monthly_spend_eur
10001,Ada Lovelace,ada@example.invalid,ES-00000001A,4242,1290.55
10002,Grace Hopper,grace@example.invalid,ES-00000002B,1881,842.10
10003,Alan Turing,alan@example.invalid,ES-00000003C,9137,2310.00
10004,Radia Perlman,radia@example.invalid,ES-00000004D,7712,1105.75
CSV
  sha256sum "$LAB_ROOT/data/customers.csv" | awk '{print $1}' \
    > "$LAB_ROOT/data/.customers.sha256"
  chmod 0400 "$LAB_ROOT/data/.customers.sha256"

  openssl rand -hex 32 > "$LAB_ROOT/keys/cmek.key"
  chmod 0400 "$LAB_ROOT/keys/cmek.key"

  openssl enc -aes-256-cbc -pbkdf2 -salt \
    -in "$LAB_ROOT/data/customers.csv" \
    -out "$LAB_ROOT/data/customers.csv.enc" \
    -pass file:"$LAB_ROOT/keys/cmek.key"
  chmod 0640 "$LAB_ROOT/data/customers.csv.enc"
  shred -u "$LAB_ROOT/data/customers.csv" 2>/dev/null || rm -f "$LAB_ROOT/data/customers.csv"
  chmod 0750 "$LAB_ROOT/data"

  # --- Layer: identity. Least-privilege IAM allow policy --------------------
  cat > "$LAB_ROOT/iam/policy.json" <<'JSON'
{
  "version": 3,
  "resource": "//storage.googleapis.com/projects/_/buckets/acme-customer-exports",
  "bindings": [
    {
      "role": "roles/storage.objectViewer",
      "members": [
        "group:data-analysts@acme.example"
      ]
    },
    {
      "role": "roles/storage.objectAdmin",
      "members": [
        "serviceAccount:etl-runner@acme-prod.iam.gserviceaccount.com"
      ]
    }
  ],
  "etag": "BwYb0mL0aQk="
}
JSON
  chmod 0640 "$LAB_ROOT/iam/policy.json"

  # --- Layer: guardrails. Organization Policy constraints -------------------
  cat > "$LAB_ROOT/org-policy/constraints.yaml" <<'YAML'
# Organization Policy Service — inherited by every project in the folder.
# https://cloud.google.com/resource-manager/docs/organization-policy/overview
constraints:
  - name: constraints/storage.publicAccessPrevention
    booleanPolicy:
      enforced: true
  - name: constraints/iam.allowedPolicyMemberDomains
    listPolicy:
      allowedValues:
        - "acme.example"
    enforced: true
  - name: constraints/compute.requireOsLogin
    booleanPolicy:
      enforced: true
YAML
  chmod 0640 "$LAB_ROOT/org-policy/constraints.yaml"

  # --- Layer: audit. Admin Activity logs + export sink to another project ----
  cat > "$LAB_ROOT/logs/audit.log" <<'LOG'
LAB_BASELINE severity=NOTICE service=cloudresourcemanager.googleapis.com method=SetIamPolicy principal=founder@acme.example
LAB_BASELINE severity=NOTICE service=cloudkms.googleapis.com method=CreateCryptoKey principal=founder@acme.example
LAB_BASELINE severity=NOTICE service=orgpolicy.googleapis.com method=UpdatePolicy principal=founder@acme.example
LOG
  cp "$LAB_ROOT/logs/audit.log" "$LAB_ROOT/.log-sink/audit.log"
  chmod 0440 "$LAB_ROOT/.log-sink/audit.log"
  chmod 0640 "$LAB_ROOT/logs/audit.log"
  if chattr +a "$LAB_ROOT/logs/audit.log" 2>/dev/null; then
    : > "$LAB_ROOT/logs/.attr_supported"
  else
    warn "filesystem does not support append-only (chattr +a); log-integrity check falls back to content hashing"
    rm -f "$LAB_ROOT/logs/.attr_supported"
  fi

  install_scanner
  fw_provision
  start_workload
  info "baseline is compliant. Now breaking it."
}

start_workload() {
  if [ -f "$LAB_ROOT/.workload.pid" ] && kill -0 "$(cat "$LAB_ROOT/.workload.pid")" 2>/dev/null; then
    return 0
  fi
  ( cd "$LAB_ROOT/data" && nohup python3 -m http.server "$LAB_PORT" \
      --bind 0.0.0.0 >"$LAB_ROOT/logs/workload.log" 2>&1 &
    echo $! > "$LAB_ROOT/.workload.pid" )
  sleep 1
  info "lab workload (the 'bucket front end') listening on 0.0.0.0:$LAB_PORT"
}

# --------------------------------------------------------------------------- #
# The Security Command Center stand-in — Google's side of shared fate
# --------------------------------------------------------------------------- #

install_scanner() {
  cat > "$LAB_ROOT/bin/scc-scan.sh" <<'SCC'
#!/usr/bin/env bash
# Security Command Center (simulated). Google operates this layer for you:
# it keeps finding your misconfigurations even when every control you own is off.
# https://cloud.google.com/security-command-center/docs/security-command-center-overview
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_PORT="${LAB_PORT:-8080}"
CRIT=0; HIGH=0; MED=0

C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'; C_OFF=$'\033[0m'

finding() {
  local sev="$1" cat="$2" res="$3" desc="$4" color="$C_YEL"
  case "$sev" in
    CRITICAL) CRIT=$((CRIT+1)); color="$C_RED" ;;
    HIGH)     HIGH=$((HIGH+1)); color="$C_RED" ;;
    MEDIUM)   MED=$((MED+1)) ;;
  esac
  printf '%sFINDING%s  %-9s %-26s %-34s %s\n' "$color" "$C_OFF" "$sev" "$cat" "$res" "$desc"
}

printf '\nSCANNING resource set: //acme-prod  (simulated SCC Premium, posture findings)\n\n'
printf '%-8s %-9s %-26s %-34s %s\n' "STATE" "SEVERITY" "CATEGORY" "RESOURCE" "DESCRIPTION"

# --- IAM ------------------------------------------------------------------
if grep -q '"allUsers"\|"allAuthenticatedUsers"' "$LAB_ROOT/iam/policy.json" 2>/dev/null; then
  finding CRITICAL PUBLIC_BUCKET_ACL iam/policy.json \
    "allUsers/allAuthenticatedUsers granted access to customer data"
fi
if grep -q '"roles/owner"\|"roles/editor"' "$LAB_ROOT/iam/policy.json" 2>/dev/null; then
  finding HIGH OVER_PRIVILEGED_ACCOUNT iam/policy.json \
    "basic role granted where a predefined role suffices"
fi

# --- Organization Policy --------------------------------------------------
if ! grep -A2 'storage.publicAccessPrevention' "$LAB_ROOT/org-policy/constraints.yaml" 2>/dev/null \
     | grep -q 'enforced: true'; then
  finding MEDIUM ORG_POLICY_DISABLED org-policy/constraints.yaml \
    "publicAccessPrevention not enforced at folder level"
fi

# --- Data at rest ---------------------------------------------------------
if [ -f "$LAB_ROOT/data/customers.csv" ]; then
  finding CRITICAL UNENCRYPTED_DATA data/customers.csv \
    "cleartext PII object present outside CMEK protection"
fi
if [ ! -f "$LAB_ROOT/data/customers.csv.enc" ]; then
  finding CRITICAL DATA_LOSS data/customers.csv.enc \
    "encrypted object missing"
else
  dec_hash=$(openssl enc -d -aes-256-cbc -pbkdf2 \
               -in "$LAB_ROOT/data/customers.csv.enc" \
               -pass file:"$LAB_ROOT/keys/cmek.key" 2>/dev/null \
             | sha256sum | awk '{print $1}')
  want_hash=$(cat "$LAB_ROOT/data/.customers.sha256" 2>/dev/null || echo none)
  if [ "$dec_hash" != "$want_hash" ]; then
    finding CRITICAL DATA_INTEGRITY data/customers.csv.enc \
      "ciphertext does not decrypt to the attested object hash"
  fi
fi

# --- Key material ---------------------------------------------------------
key_mode=$(stat -c '%a' "$LAB_ROOT/keys/cmek.key" 2>/dev/null || echo 777)
if [ "$key_mode" != "400" ]; then
  finding CRITICAL KEY_MATERIAL_EXPOSED keys/cmek.key \
    "key readable beyond its owner (mode $key_mode, expected 400)"
fi
dir_mode=$(stat -c '%a' "$LAB_ROOT/data" 2>/dev/null || echo 777)
if [ "$dir_mode" != "750" ]; then
  finding HIGH BUCKET_POLICY_WEAK data/ \
    "object container world-accessible (mode $dir_mode, expected 750)"
fi

# --- Perimeter ------------------------------------------------------------
fw_ok=1
if command -v nft >/dev/null 2>&1 && nft list table inet gdl_lab >/dev/null 2>&1; then
  nft list chain inet gdl_lab input 2>/dev/null | grep -q "dport $LAB_PORT" || fw_ok=0
elif command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "$LAB_PORT" '!' -i lo -j DROP 2>/dev/null || fw_ok=0
fi
if [ "$fw_ok" -eq 0 ]; then
  finding HIGH OPEN_FIREWALL "vpc/ingress-tcp-$LAB_PORT" \
    "0.0.0.0/0 ingress allowed to a data-serving port"
fi

# --- Audit trail ----------------------------------------------------------
base_hash=$(sha256sum "$LAB_ROOT/.log-sink/audit.log" 2>/dev/null | awk '{print $1}')
head_hash=$(head -n 3 "$LAB_ROOT/logs/audit.log" 2>/dev/null | sha256sum | awk '{print $1}')
if [ "$base_hash" != "$head_hash" ]; then
  finding HIGH AUDIT_LOG_TAMPERED logs/audit.log \
    "Admin Activity entries missing versus the export sink"
fi
if [ -f "$LAB_ROOT/logs/.attr_supported" ]; then
  if ! lsattr "$LAB_ROOT/logs/audit.log" 2>/dev/null | awk '{print $1}' | grep -q 'a'; then
    finding HIGH AUDIT_LOG_MUTABLE logs/audit.log \
      "append-only protection removed from the audit sink"
  fi
fi

total=$((CRIT+HIGH+MED))
printf '\n'
if [ "$total" -eq 0 ]; then
  printf '%sSCAN COMPLETE: 0 findings — posture restored.%s\n\n' "$C_GRN" "$C_OFF"
  exit 0
fi
printf '%sSCAN COMPLETE: %d findings (%d CRITICAL, %d HIGH, %d MEDIUM)%s\n\n' \
  "$C_RED" "$total" "$CRIT" "$HIGH" "$MED" "$C_OFF"
exit 1
SCC
  chmod 0755 "$LAB_ROOT/bin/scc-scan.sh"
}

# --------------------------------------------------------------------------- #
# The break — five independent layers, one afternoon, one very bad outcome
# --------------------------------------------------------------------------- #

break_lab() {
  info "applying the incident scenario"

  # 1. Perimeter: someone "opened it for a demo" and never closed it.
  fw_deny_del

  # 2. Identity: a public binding plus a basic role on a service account.
  python3 - "$LAB_ROOT/iam/policy.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for b in d["bindings"]:
    if b["role"] == "roles/storage.objectViewer" and "allUsers" not in b["members"]:
        b["members"].append("allUsers")
d["bindings"].append({
    "role": "roles/owner",
    "members": ["serviceAccount:etl-runner@acme-prod.iam.gserviceaccount.com"],
})
json.dump(d, open(p, "w"), indent=2)
PY

  # 3. Guardrails: the constraint that would have blocked step 2 was relaxed.
  sed -i '/storage.publicAccessPrevention/,+2 s/enforced: true/enforced: false/' \
    "$LAB_ROOT/org-policy/constraints.yaml"

  # 4. Data: decrypted "for a quick export", key left world-readable.
  openssl enc -d -aes-256-cbc -pbkdf2 \
    -in "$LAB_ROOT/data/customers.csv.enc" \
    -out "$LAB_ROOT/data/customers.csv" \
    -pass file:"$LAB_ROOT/keys/cmek.key"
  chmod 0644 "$LAB_ROOT/data/customers.csv"
  chmod 0644 "$LAB_ROOT/keys/cmek.key"
  chmod 0777 "$LAB_ROOT/data"

  # 5. Audit: the trail that would have shown all of the above, truncated.
  chattr -a "$LAB_ROOT/logs/audit.log" 2>/dev/null || true
  printf 'severity=NOTICE service=compute.googleapis.com method=Insert principal=contractor@partner.invalid\n' \
    > "$LAB_ROOT/logs/audit.log"

  start_workload
}

# --------------------------------------------------------------------------- #
# Mission brief
# --------------------------------------------------------------------------- #

brief() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip="${ip:-127.0.0.1}"

  cat <<EOF

${C_BLD}=============================================================================
 gcp-cdl 5.2 — BREAK & FIX: "The day every layer failed at once"
=============================================================================${C_OFF}

${C_BLD}SCENARIO${C_OFF}
ACME migrated a customer-export bucket to Google Cloud. Over one sprint, five
separate people made five reasonable-sounding changes. Individually, each one
would have been absorbed by the layer underneath it. Together they produced a
public, cleartext PII exposure with no audit trail.

${C_BLD}THE SYMPTOM YOU WILL SEE NOW${C_OFF}

  \$ curl -s --max-time 3 http://${ip}:${LAB_PORT}/
  <a href="customers.csv">customers.csv</a>
  <a href="customers.csv.enc">customers.csv.enc</a>

  \$ curl -s --max-time 3 http://${ip}:${LAB_PORT}/customers.csv | head -3
  customer_id,full_name,email,national_id,card_last4,monthly_spend_eur
  10001,Ada Lovelace,ada@example.invalid,ES-00000001A,4242,1290.55
  10002,Grace Hopper,grace@example.invalid,ES-00000002B,1881,842.10

That is unauthenticated, unencrypted PII served to anything that can route to
this host. Then look at what your own detection tells you:

  \$ cat ${LAB_ROOT}/logs/audit.log
  severity=NOTICE service=compute.googleapis.com method=Insert principal=contractor@partner.invalid

One line. The record of who opened the firewall, who added the public IAM
binding, who relaxed the org policy and who decrypted the object is gone.
Business translation: without an intact audit trail you cannot scope the breach,
you cannot notify regulators accurately within the GDPR 72-hour window, and you
cannot prove which records were touched. Detection gaps are not an IT problem,
they are a disclosure-liability problem.

${C_BLD}WHAT IS STILL WORKING FOR YOU${C_OFF}
Two things survived, and they are the point of this objective:

  1. Security Command Center still sees everything. You did not configure it,
     you did not keep it running, and it does not depend on any control you
     broke. That is the Google side of ${C_BLD}shared fate${C_OFF}: Google is not a passive
     vendor handing you a checklist, it is an active participant with default
     posture management, curated detectors and secure-by-default infrastructure.
       https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate

  2. The audit export sink in a separate, restricted project still holds the
     original entries (${LAB_ROOT}/.log-sink/audit.log). Exporting logs
     out of the project that generates them is exactly why the tamper failed.
       https://cloud.google.com/logging/docs/audit

${C_BLD}YOUR OBJECTIVE${C_OFF}
Restore the multilayered posture until Google's scanner reports a clean bill:

  \$ sudo ${LAB_ROOT}/bin/scc-scan.sh

  ${C_GRN}SCAN COMPLETE: 0 findings — posture restored.${C_OFF}

The scanner is your only pass condition. Run it now to see the full finding
list — it is your remediation backlog, ordered by severity, the same way a real
SCC console hands you one.

${C_BLD}CONSTRAINTS (a real remediation has them too)${C_OFF}
  - Do NOT delete customers.csv.enc. The ciphertext must still decrypt to the
    attested SHA-256 in data/.customers.sha256 — losing customer data to fix a
    finding is a worse outcome than the finding.
  - Do NOT stop the workload process. In production you cannot fix an exposure
    by taking the service down; the perimeter and the IAM layer must do it.
  - Localhost access must keep working after you close the perimeter
    (curl http://127.0.0.1:${LAB_PORT}/ must still answer). Internal reachability
    is the whole difference between a firewall rule and an outage.

${C_BLD}THE EXAM-LEVEL QUESTION TO ANSWER OUT LOUD WHEN YOU ARE DONE${C_OFF}
For each of the five broken layers, name (a) the Google Cloud service that
implements it, (b) which single failure it would have contained on its own, and
(c) the business metric it protects — breach cost, time to detect, regulatory
exposure, or customer trust. If you can do that, 5.2 is finished.

${C_BLD}COMMANDS${C_OFF}
  sudo ${LAB_ROOT}/bin/scc-scan.sh   # verify (this is the grader)
  sudo $0 --brief                    # reprint this brief
  sudo $0 --reset                    # destroy the lab, restore the VM

EOF
}

# --------------------------------------------------------------------------- #
# Reset
# --------------------------------------------------------------------------- #

reset_lab() {
  info "tearing down"
  if [ -f "$LAB_ROOT/.workload.pid" ]; then
    kill "$(cat "$LAB_ROOT/.workload.pid")" 2>/dev/null || true
  fi
  pkill -f "http.server $LAB_PORT" 2>/dev/null || true
  fw_teardown
  [ -f "$LAB_ROOT/logs/audit.log" ] && { chattr -a "$LAB_ROOT/logs/audit.log" 2>/dev/null || true; }
  case "$LAB_ROOT" in
    /|/home|/opt|/usr|/var|/etc) die "refusing to remove $LAB_ROOT" ;;
  esac
  rm -rf "$LAB_ROOT"
  info "lab removed; firewall rule withdrawn"
}

# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #

main() {
  require_root "$@"
  require_deps
  guard_port

  case "${1:-deploy}" in
    deploy)
      confirm_disposable
      provision
      break_lab
      brief
      warn "run 'sudo $LAB_ROOT/bin/scc-scan.sh' now — it will exit non-zero, that is expected"
      ;;
    --brief|brief)   brief ;;
    --verify|verify) exec "$LAB_ROOT/bin/scc-scan.sh" ;;
    --reset|reset)   reset_lab ;;
    -h|--help)
      printf 'usage: %s [deploy|--brief|--verify|--reset]\n' "$0" ;;
    *) die "unknown mode: $1" ;;
  esac
}

main "$@"

# =============================================================================
#  SOLUTION — do not read until the scanner has beaten you at least twice.
# =============================================================================
#
#  Work top-down through the SCC findings by severity, exactly as you would in
#  the real console. All paths are relative to /opt/gdl-defense-lab.
#
#  ---------------------------------------------------------------------------
#  STEP 0 — Read the backlog before touching anything
#  ---------------------------------------------------------------------------
#     sudo /opt/gdl-defense-lab/bin/scc-scan.sh
#
#  Expected (8 findings): PUBLIC_BUCKET_ACL, UNENCRYPTED_DATA,
#  KEY_MATERIAL_EXPOSED (CRITICAL); OVER_PRIVILEGED_ACCOUNT, BUCKET_POLICY_WEAK,
#  OPEN_FIREWALL, AUDIT_LOG_TAMPERED (+ AUDIT_LOG_MUTABLE on ext4/xfs) (HIGH);
#  ORG_POLICY_DISABLED (MEDIUM).
#
#  ---------------------------------------------------------------------------
#  STEP 1 — Stop the bleeding at the perimeter (VPC firewall)
#  ---------------------------------------------------------------------------
#  Close 0.0.0.0/0 ingress first: it is the one change that makes the exposure
#  unreachable while you fix the rest. Keep loopback working.
#
#     # nftables hosts:
#     sudo nft add rule inet gdl_lab input iif != "lo" tcp dport 8080 drop
#
#     # iptables hosts:
#     sudo iptables -I INPUT -p tcp --dport 8080 '!' -i lo -j DROP
#
#     # Verify both directions:
#     curl -s --max-time 3 http://127.0.0.1:8080/            # still answers
#     curl -s --max-time 3 http://$(hostname -I | awk '{print $1}'):8080/ ; echo "exit=$?"
#     # -> exit=28 (timeout). The service is up; the internet just cannot reach it.
#
#  Real-world equivalent: a VPC firewall rule denying ingress, or removing the
#  external IP entirely and fronting the service with Cloud Load Balancing +
#  Cloud Armor.  https://cloud.google.com/firewall/docs/firewalls
#
#  ---------------------------------------------------------------------------
#  STEP 2 — Remove the public principal and the basic role (Cloud IAM)
#  ---------------------------------------------------------------------------
#     sudo python3 - <<'PY'
#     import json
#     p = "/opt/gdl-defense-lab/iam/policy.json"
#     d = json.load(open(p))
#     for b in d["bindings"]:
#         b["members"] = [m for m in b["members"]
#                         if m not in ("allUsers", "allAuthenticatedUsers")]
#     d["bindings"] = [b for b in d["bindings"]
#                      if b["role"] not in ("roles/owner", "roles/editor")
#                      and b["members"]]
#     json.dump(d, open(p, "w"), indent=2)
#     PY
#
#     grep -c allUsers /opt/gdl-defense-lab/iam/policy.json   # -> 0
#
#  The ETL service account keeps roles/storage.objectAdmin, which is what it
#  actually needs. Basic roles (owner/editor/viewer) are the single most common
#  privilege-escalation path in a GCP estate — replace them with predefined or
#  custom roles.  https://cloud.google.com/iam/docs/roles-overview
#
#  ---------------------------------------------------------------------------
#  STEP 3 — Re-encrypt the data and destroy the cleartext copy (CMEK)
#  ---------------------------------------------------------------------------
#  Order matters: fix the key permissions FIRST, otherwise you re-encrypt with a
#  key that the whole machine has already read.
#
#     sudo chmod 0400 /opt/gdl-defense-lab/keys/cmek.key
#     cd /opt/gdl-defense-lab
#     sudo openssl enc -aes-256-cbc -pbkdf2 -salt \
#          -in data/customers.csv -out data/customers.csv.enc \
#          -pass file:keys/cmek.key
#     sudo chmod 0640 data/customers.csv.enc
#     sudo shred -u data/customers.csv
#     sudo chmod 0750 data
#
#     # Prove the ciphertext still yields the attested object:
#     sudo openssl enc -d -aes-256-cbc -pbkdf2 -in data/customers.csv.enc \
#          -pass file:keys/cmek.key | sha256sum
#     sudo cat data/.customers.sha256      # the two hashes must match
#
#  In Google Cloud you would never hold the key on the VM: Cloud KMS holds it,
#  the object is CMEK-encrypted, and revoking the key revokes the data. That is
#  the control that turns "we lost a bucket" into "we lost ciphertext".
#     https://cloud.google.com/kms/docs/cmek
#
#  ---------------------------------------------------------------------------
#  STEP 4 — Restore the audit trail from the export sink, then re-lock it
#  ---------------------------------------------------------------------------
#     sudo chattr -a /opt/gdl-defense-lab/logs/audit.log 2>/dev/null || true
#     sudo cp /opt/gdl-defense-lab/.log-sink/audit.log \
#             /opt/gdl-defense-lab/logs/audit.log
#     sudo chmod 0640 /opt/gdl-defense-lab/logs/audit.log
#     sudo chattr +a /opt/gdl-defense-lab/logs/audit.log 2>/dev/null || true
#     lsattr /opt/gdl-defense-lab/logs/audit.log     # -> -----a-------------- ...
#
#  Note what saved you: the copy lived outside the project that was compromised.
#  Admin Activity audit logs in Google Cloud cannot be disabled and are written
#  by Google, not by your workload; exporting them to a locked-down project with
#  a separate IAM boundary is the standard pattern.
#     https://cloud.google.com/logging/docs/audit
#
#  ---------------------------------------------------------------------------
#  STEP 5 — Re-enforce the guardrail so step 2 cannot recur (Org Policy)
#  ---------------------------------------------------------------------------
#     sudo sed -i '/storage.publicAccessPrevention/,+2 s/enforced: false/enforced: true/' \
#          /opt/gdl-defense-lab/org-policy/constraints.yaml
#     grep -A2 publicAccessPrevention /opt/gdl-defense-lab/org-policy/constraints.yaml
#
#  This is the highest-leverage step and the lowest severity in the report,
#  which is exactly the trap. Steps 1-4 fix one incident; step 5 makes the
#  public-bucket class of incident impossible for every project under the
#  folder, including projects that do not exist yet. Preventive guardrails beat
#  detective controls on cost per incident avoided.
#     https://cloud.google.com/storage/docs/public-access-prevention
#     https://cloud.google.com/resource-manager/docs/organization-policy/overview
#
#  ---------------------------------------------------------------------------
#  STEP 6 — Verify
#  ---------------------------------------------------------------------------
#     sudo /opt/gdl-defense-lab/bin/scc-scan.sh
#     # SCAN COMPLETE: 0 findings — posture restored.
#     echo $?    # -> 0
#
#     sudo /opt/gdl-defense-lab/../gdl-defense-lab/bin/scc-scan.sh >/dev/null && \
#       echo "clean"
#
#  Then tear down:
#     sudo ./5.2-break-and-fix.sh --reset
#
#  ---------------------------------------------------------------------------
#  ANSWER KEY for the exam-level question
#  ---------------------------------------------------------------------------
#  Layer      | Google Cloud service        | Contains on its own        | Business metric
#  -----------+-----------------------------+----------------------------+---------------------------
#  Perimeter  | VPC firewall, Cloud Armor,  | Public IAM binding is      | Breach probability;
#             | Private Google Access       | unreachable from internet  | DDoS/L7 attack cost
#  Identity   | Cloud IAM, IAM Recommender  | Open port serves nothing   | Insider + credential-theft
#             |                             | without an authorized      | blast radius
#             |                             | principal                  |
#  Guardrails | Organization Policy Service | The public binding is      | Cost of prevention vs
#             |                             | rejected at write time     | cost of remediation, org-wide
#  Data       | Cloud KMS / CMEK, default   | What leaks is ciphertext   | Regulatory exposure
#             | encryption at rest          |                            | (GDPR Art. 34 safe harbour)
#  Audit      | Cloud Audit Logs + sink to  | You can scope, notify and  | Time to detect/respond,
#             | a restricted project        | prove the impact           | disclosure liability
#  Detection  | Security Command Center     | Google finds it even when  | Shared fate: Google is a
#             | (Google-operated)           | all of the above are off   | participant, not a vendor
#
#  The business value statement the exam wants: defense in depth means no single
#  human error becomes a breach, because the next layer is owned by a different
#  team, enforced by a different mechanism, and — for the outermost layer —
#  operated by Google itself under a shared-fate model, with secure-by-default
#  infrastructure, curated detectors, and risk-protection programs on top.
#     https://cloud.google.com/security/overview/whitepaper
# =============================================================================