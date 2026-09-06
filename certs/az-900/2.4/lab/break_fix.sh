#!/usr/bin/env bash
#
# az900-2.4-identity-breakfix.sh
#
# Certification : AZ-900 — Microsoft Azure Fundamentals (exam version 2026-07-20)
# Topic         : 2.4 Describe Azure identity, access, and security
# Exam weight   : 9.62 %
# Official ref  : https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#
# WHAT THIS IS
#   A "break & fix" lab. The script injects up to five controlled faults into a
#   DISPOSABLE lab VM, every one of them mapped to a bullet of exam objective 2.4,
#   then hands the student a symptom sheet and gets out of the way. Nothing is
#   created in Azure, nothing is deleted in your tenant, no role assignment is
#   modified, no money is spent: the whole exercise lives in the identity plane of
#   ONE machine — the Azure CLI profile, the token cache, the name resolution path
#   to the Microsoft Entra ID endpoints, the Instance Metadata Service route, and
#   the local secret hygiene of the box.
#
#   That is the point. AZ-900 2.4 is usually taught as vocabulary (SSO, MFA,
#   Conditional Access, RBAC, Zero Trust, defense in depth, Defender for Cloud).
#   Vocabulary does not survive contact with a broken login. Here you see what each
#   layer looks like from the inside when it stops working, and in which ORDER the
#   layers must be repaired — which is the actual defense-in-depth lesson.
#
# FAULT -> OBJECTIVE MAP
#   FAULT 1  Entra ID token cache and CLI profile removed .... authentication, SSO, tokens
#   FAULT 2  login.microsoftonline.com hijacked in /etc/hosts . identity plane / network layer
#   FAULT 3  IMDS (169.254.169.254) blackholed ................ managed identities
#   FAULT 4  Azure CLI scope + output defaults poisoned ....... RBAC scope vs. permission
#   FAULT 5  Plaintext client secret + AZURE_* in .bashrc ..... Zero Trust, Defender for Cloud
#
# REQUIREMENTS
#   bash 4+, curl, coreutils. Azure CLI (az) strongly recommended. jq optional.
#   sudo is needed for FAULT 2 and FAULT 3 only; without it they are skipped and
#   the script says so instead of pretending.
#
# SAFETY MODEL
#   * Refuses to run without an explicit typed confirmation.
#   * Every file it touches is backed up first, timestamped, under ~/.az900-breakfix/.
#   * Every change is reversible with '--restore', including without network access.
#   * The IMDS route is a runtime route: a reboot clears it even if you do nothing.
#   * It never writes to Azure. Read-only 'az' calls only.
#   * DO NOT RUN THIS ON A WORKSTATION YOU CARE ABOUT. It deletes your local Azure
#     sign-in state. That is the exercise.
#
# USAGE
#   ./az900-2.4-identity-breakfix.sh            # inject the faults + print the briefing
#   ./az900-2.4-identity-breakfix.sh --brief    # reprint the briefing
#   ./az900-2.4-identity-breakfix.sh --verify   # grade yourself (exit 0 = all repaired)
#   ./az900-2.4-identity-breakfix.sh --hint     # progressive hints, no answers
#   ./az900-2.4-identity-breakfix.sh --restore  # escape hatch: undo everything
#
#   The full solution is at the bottom of this file, commented out. Do not read it
#   until '--verify' has beaten you at least twice.
#

set -euo pipefail

LAB_ID="az900-2.4-breakfix"
LAB_HOME="${HOME}/.az900-breakfix"
STATE_FILE="${LAB_HOME}/state.env"
HOSTS_FILE="/etc/hosts"
BASHRC="${HOME}/.bashrc"
SECRET_APP_DIR="${HOME}/az900-lab/app"
SECRET_FILE="${SECRET_APP_DIR}/appsettings.json"
IMDS_IP="169.254.169.254"
ENTRA_LOGIN_HOST="login.microsoftonline.com"
BOGUS_RG="rg-az900-scope-trap"
HOSTS_BEGIN="# >>> ${LAB_ID} >>>"
HOSTS_END="# <<< ${LAB_ID} <<<"
BASHRC_BEGIN="# >>> ${LAB_ID} env credentials >>>"
BASHRC_END="# <<< ${LAB_ID} env credentials <<<"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
  CYA=$'\033[36m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  BOLD=""; RED=""; GRN=""; YEL=""; CYA=""; DIM=""; RST=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[lab ]%s %s\n'  "$CYA" "$RST" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n'  "$GRN" "$RST" "$*"; }
bad()  { printf '%s[fail]%s %s\n'  "$RED" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n'  "$YEL" "$RST" "$*"; }
die()  { printf '%s[stop]%s %s\n'  "$RED" "$RST" "$*" >&2; exit 1; }
rule() { printf '%s%s%s\n' "$DIM" "----------------------------------------------------------------------" "$RST"; }

have() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
resolve_sudo() {
  if [[ ${EUID} -eq 0 ]]; then
    SUDO=""
    return 0
  fi
  if have sudo && sudo -v >/dev/null 2>&1; then
    SUDO="sudo"
    return 0
  fi
  return 1
}

state_set() {
  mkdir -p "${LAB_HOME}"
  touch "${STATE_FILE}"
  chmod 0600 "${STATE_FILE}"
  local key="$1" val="$2"
  grep -v "^${key}=" "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"
  printf '%s=%q\n' "${key}" "${val}" >> "${STATE_FILE}"
}

state_get() {
  local key="$1"
  [[ -f "${STATE_FILE}" ]] || return 1
  local line
  line="$(grep "^${key}=" "${STATE_FILE}" | tail -n1 || true)"
  [[ -n "${line}" ]] || return 1
  eval "printf '%s' ${line#*=}"
}

backup_dir() {
  local d
  if d="$(state_get BACKUP_DIR 2>/dev/null)" && [[ -n "${d}" ]]; then
    printf '%s' "${d}"
    return 0
  fi
  d="${LAB_HOME}/backup-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "${d}"
  chmod 0700 "${d}"
  state_set BACKUP_DIR "${d}"
  printf '%s' "${d}"
}

# Copy a file into the backup directory preserving mode. Refuses to overwrite an
# existing backup: the first snapshot is the pristine one.
backup_file() {
  local src="$1" dst
  [[ -e "${src}" ]] || return 0
  dst="$(backup_dir)/$(printf '%s' "${src}" | tr '/' '_')"
  [[ -e "${dst}" ]] && return 0
  cp -a "${src}" "${dst}"
  chmod 0600 "${dst}" 2>/dev/null || true
}

imds_alive() {
  curl -s -f -m 3 -H "Metadata: true" \
    "http://${IMDS_IP}/metadata/instance?api-version=2021-02-01" >/dev/null 2>&1
}

az_logged_in() {
  have az || return 1
  az account show -o json >/dev/null 2>&1
}

confirm_or_die() {
  cat <<EOF

${BOLD}AZ-900 / 2.4 — Break & Fix lab${RST}
${BOLD}Describe Azure identity, access, and security${RST}

This script is about to modify, on ${BOLD}$(hostname)${RST}, as user ${BOLD}${USER:-$(id -un)}${RST}:

  * ~/.azure/azureProfile.json and ~/.azure/msal_token_cache.json  (moved to backup)
  * ~/.azure/config                                                (CLI defaults poisoned)
  * ${HOSTS_FILE}                                                    (one hijack entry, sudo)
  * the kernel routing table, entry for ${IMDS_IP}/32              (blackhole, sudo, non-persistent)
  * ${BASHRC}                                                      (a marked block appended)
  * ${SECRET_FILE}                                                 (created, world-readable, FAKE secret)

Everything is backed up first and '--restore' undoes all of it.
${YEL}You will be signed out of the Azure CLI on this machine.${RST}

Type exactly ${BOLD}BREAK-MY-LAB-VM${RST} to continue, anything else to abort.
EOF
  local answer=""
  if [[ "${AZ900_LAB_CONFIRM:-}" == "BREAK-MY-LAB-VM" ]]; then
    info "confirmation supplied through AZ900_LAB_CONFIRM"
    return 0
  fi
  read -r -p "> " answer || true
  [[ "${answer}" == "BREAK-MY-LAB-VM" ]] || die "aborted, nothing was modified"
}

# --------------------------------------------------------------------------- #
# FAULT INJECTION
# --------------------------------------------------------------------------- #

fault1_break_entra_session() {
  info "FAULT 1 — invalidating the local Microsoft Entra ID session"
  local az_dir="${HOME}/.azure" moved=0 f
  if [[ ! -d "${az_dir}" ]]; then
    warn "FAULT 1 skipped: ~/.azure does not exist (is the Azure CLI installed and signed in?)"
    state_set FAULT1 skipped
    return 0
  fi
  for f in azureProfile.json msal_token_cache.json service_principal_entries.json clouds.config; do
    if [[ -e "${az_dir}/${f}" ]]; then
      backup_file "${az_dir}/${f}"
      rm -f "${az_dir}/${f}"
      moved=$((moved + 1))
    fi
  done
  if [[ ${moved} -eq 0 ]]; then
    warn "FAULT 1 skipped: no CLI profile or token cache found — you were not signed in"
    state_set FAULT1 skipped
    return 0
  fi
  state_set FAULT1 applied
  ok "FAULT 1 applied (${moved} identity artefacts removed, copies in the backup dir)"
}

fault2_hijack_entra_endpoint() {
  info "FAULT 2 — hijacking the Microsoft Entra ID authentication endpoint"
  if [[ -z "${SUDO}" && ${EUID} -ne 0 ]]; then
    warn "FAULT 2 skipped: no sudo. The lab still works, one layer short."
    state_set FAULT2 skipped
    return 0
  fi
  if grep -qF "${HOSTS_BEGIN}" "${HOSTS_FILE}" 2>/dev/null; then
    state_set FAULT2 applied
    ok "FAULT 2 already present (idempotent)"
    return 0
  fi
  backup_file "${HOSTS_FILE}"
  ${SUDO} tee -a "${HOSTS_FILE}" >/dev/null <<EOF
${HOSTS_BEGIN}
127.0.0.1   ${ENTRA_LOGIN_HOST}
127.0.0.1   login.windows.net
${HOSTS_END}
EOF
  state_set FAULT2 applied
  ok "FAULT 2 applied (${ENTRA_LOGIN_HOST} now resolves to 127.0.0.1)"
}

fault3_blackhole_imds() {
  info "FAULT 3 — cutting the managed identity token path (IMDS)"
  if ! have ip; then
    warn "FAULT 3 skipped: iproute2 not available"
    state_set FAULT3 skipped
    return 0
  fi
  if [[ -z "${SUDO}" && ${EUID} -ne 0 ]]; then
    warn "FAULT 3 skipped: no sudo"
    state_set FAULT3 skipped
    return 0
  fi
  if ! imds_alive; then
    warn "FAULT 3 skipped: no IMDS answered at ${IMDS_IP} — this host is not an Azure VM."
    warn "            Nothing is faked here. Read the FAULT 3 section of the briefing anyway:"
    warn "            it is the single most exam-relevant mechanism of the whole topic."
    state_set FAULT3 skipped
    return 0
  fi
  ${SUDO} ip route replace blackhole "${IMDS_IP}/32"
  state_set FAULT3 applied
  ok "FAULT 3 applied (blackhole route for ${IMDS_IP}/32, cleared by a reboot)"
}

fault4_poison_cli_scope() {
  info "FAULT 4 — poisoning the Azure CLI scope and output defaults"
  if ! have az; then
    warn "FAULT 4 skipped: az not installed"
    state_set FAULT4 skipped
    return 0
  fi
  backup_file "${HOME}/.azure/config"
  az configure --defaults group="${BOGUS_RG}" >/dev/null 2>&1 || true
  az config set core.output=none --only-show-errors >/dev/null 2>&1 || true
  az config set core.only_show_errors=true --only-show-errors >/dev/null 2>&1 || true
  state_set FAULT4 applied
  ok "FAULT 4 applied (default group='${BOGUS_RG}', output='none', warnings suppressed)"
}

fault5_plant_plaintext_credentials() {
  info "FAULT 5 — planting the anti-pattern: a long-lived secret on disk and in the environment"
  mkdir -p "${SECRET_APP_DIR}"
  backup_file "${SECRET_FILE}"
  cat > "${SECRET_FILE}" <<'EOF'
{
  "_comment": "AZ-900 lab artefact. Every value below is FAKE and authenticates nothing.",
  "AzureAd": {
    "Instance": "https://login.microsoftonline.com/",
    "TenantId": "00000000-0000-0000-0000-0000000000aa",
    "ClientId": "00000000-0000-0000-0000-0000000000bb",
    "ClientSecret": "FAKE~DO.NOT.USE-0000000000000000000000000"
  },
  "KeyVault": {
    "VaultUri": "https://kv-az900-lab.vault.azure.net/"
  }
}
EOF
  chmod 0644 "${SECRET_FILE}"
  if ! grep -qF "${BASHRC_BEGIN}" "${BASHRC}" 2>/dev/null; then
    backup_file "${BASHRC}"
    cat >> "${BASHRC}" <<EOF
${BASHRC_BEGIN}
export AZURE_TENANT_ID="00000000-0000-0000-0000-0000000000aa"
export AZURE_CLIENT_ID="00000000-0000-0000-0000-0000000000bb"
export AZURE_CLIENT_SECRET="FAKE~DO.NOT.USE-0000000000000000000000000"
${BASHRC_END}
EOF
  fi
  state_set FAULT5 applied
  ok "FAULT 5 applied (${SECRET_FILE} mode 0644, AZURE_* exported from ~/.bashrc)"
}

# --------------------------------------------------------------------------- #
# BRIEFING
# --------------------------------------------------------------------------- #

brief() {
  cat <<EOF

$(rule)
${BOLD}BRIEFING — AZ-900 2.4, Azure identity, access and security${RST}
$(rule)

SCENARIO
  You are the on-call engineer for a small platform team. A build agent VM signs
  in to Azure with the Azure CLI and, from the application it hosts, with a
  managed identity. Overnight "a hardening script" ran on the box. This morning
  the pipeline is red, the app cannot reach Key Vault, and the previous engineer
  is unreachable.

  Your job is not to reinstall the VM. Your job is to find, layer by layer, what
  was broken, in the right order, and to leave the machine in a state that is
  more secure than the one you found — not merely working again.

$(rule)
${BOLD}SYMPTOMS YOU SHOULD BE ABLE TO REPRODUCE${RST}
$(rule)

  1) The CLI has no identity at all

     \$ az account show
     ERROR: Please run 'az login' to setup account.

     Concept: a signed-in Azure CLI is not "a password stored on the machine".
     It is a token cache. Microsoft Entra ID issued an access token (short lived,
     typically ~60-90 min) and a refresh token, and the CLI keeps them in
     ~/.azure/msal_token_cache.json, with the subscription list in
     ~/.azure/azureProfile.json. Delete those and the machine forgets who it is,
     while your account in Entra ID is untouched. Identity lives in the directory;
     the local files are only a cached proof of a past authentication. That is
     exactly what single sign-on (SSO) is: one authentication, many token
     redemptions, no second credential prompt.

  2) Re-authenticating does not work either

     \$ az login --use-device-code
     ... HTTPSConnectionPool(host='login.microsoftonline.com', port=443):
         Max retries exceeded with url: /common/oauth2/v2.0/devicecode
         (Caused by NewConnectionError('...: Failed to establish a new connection:
         [Errno 111] Connection refused'))

     Concept: every interactive sign-in, every MFA challenge, every Conditional
     Access evaluation happens against the Entra ID authentication endpoint. If
     the host cannot reach login.microsoftonline.com, nothing about identity works
     on this machine — no SSO, no MFA, no passwordless, no device code flow. Note
     the error shape: 'Connection refused' means the name resolved and something
     local answered. A DROP in a firewall would instead hang and end in a timeout.
     The distinction between refused / timed out / DNS failure is your first fork
     in any authentication incident.

  3) The application's managed identity cannot get a token (Azure VMs only)

     \$ curl -s -H "Metadata: true" --max-time 5 \\
         "http://${IMDS_IP}/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/"
     curl: (7) Failed to connect to ${IMDS_IP} port 80: Network is unreachable

     \$ az login --identity
     ERROR: Failed to connect to MSI. Please make sure MSI is configured correctly.
     (newer builds report: ManagedIdentityCredential authentication unavailable,
      no response from the IMDS endpoint)

     Concept: a managed identity is a service principal in Microsoft Entra ID
     whose credential you never see. The VM asks the Instance Metadata Service, a
     non-routable link-local endpoint at ${IMDS_IP}, and Azure returns a bearer
     token for the requested resource. No secret in code, no secret in config, no
     rotation to schedule. Break the path to ${IMDS_IP} and every "passwordless"
     workload on the box loses its identity at once — which is also why nothing
     but the local host must ever be able to reach that address.

  4) Commands "work" but the results make no sense

     \$ az group show --name rg-app-prod
     (nothing at all is printed)

     Concept: two different failures look alike from the outside. Getting nothing
     back can mean 'you are not allowed' (RBAC), 'you are looking in the wrong
     place' (scope: wrong subscription, wrong resource group, wrong tenant), or
     'the tool was told to be quiet'. A genuine RBAC denial is never silent and it
     names all three of the who / what / where triple:

       (AuthorizationFailed) The client 'dev@contoso.com' with object id
       'a1b2c3d4-...' does not have authorization to perform action
       'Microsoft.KeyVault/vaults/read' over scope
       '/subscriptions/<sub-id>/resourceGroups/rg-app-prod' or the scope is invalid.

     Read that message as the definition of Azure RBAC itself: a role assignment
     is (security principal) x (role definition) x (scope), where scope is one of
     management group / subscription / resource group / resource, and assignments
     are inherited downward. If the message ends in 'or the scope is invalid', the
     resource may simply not exist where you are looking.

  5) The box is holding a credential it should not hold

     \$ ls -l ${SECRET_FILE}
     -rw-r--r--. 1 ${USER:-user} ${USER:-user} 412 ... appsettings.json
     \$ env | grep -c AZURE_CLIENT_SECRET
     1

     Concept: this is the pattern managed identities and Azure Key Vault exist to
     delete. A client secret on disk is world-readable, long-lived, copied into
     backups, and it silently wins: the Azure SDK's DefaultAzureCredential tries
     EnvironmentCredential FIRST, so a stale AZURE_CLIENT_SECRET in the shell does
     not fall through to the managed identity — it fails the whole chain with

       EnvironmentCredential: ... AADSTS7000215: Invalid client secret provided.

     Zero Trust says verify explicitly, use least-privilege access, assume breach.
     A shared long-lived secret fails all three; a managed identity scoped with the
     narrowest built-in role satisfies all three. Microsoft Defender for Cloud is
     the service that would flag this VM, score it in Secure Score, and hand you
     the remediation step — defense in depth is only a diagram until something is
     watching each layer.

$(rule)
${BOLD}YOUR OBJECTIVE${RST}
$(rule)

  Leave the machine in this state, and be able to explain each item out loud:

    [ ] 'az account show -o json' prints a real subscription again.
    [ ] The host resolves ${ENTRA_LOGIN_HOST} to a Microsoft address, not to 127.0.0.1.
    [ ] ${IMDS_IP} is reachable again (on an Azure VM: IMDS answers with Metadata: true).
    [ ] The Azure CLI has no bogus default resource group and no silenced output.
    [ ] No plaintext client secret on disk and no AZURE_CLIENT_SECRET in the environment.

  ${BOLD}Order matters.${RST} Repair the network path before the identity, and the identity
  before the authorization. Trying to fix RBAC while the sign-in endpoint is
  hijacked is how real incidents lose two hours.

$(rule)
${BOLD}DIAGNOSTIC TOOLBOX (all read-only, all free)${RST}
$(rule)

  Layer 0 — is the tool lying to me?
    az config get core.output            # a CLI-level default can hide everything
    az configure --list-defaults -o table
    az --version

  Layer 1 — name resolution and reachability
    getent hosts ${ENTRA_LOGIN_HOST}
    grep -n microsoftonline ${HOSTS_FILE}
    curl -sS -o /dev/null -w '%{http_code}\\n' https://${ENTRA_LOGIN_HOST}/common/discovery/instance
    ip route get ${IMDS_IP}
    ip route show ${IMDS_IP}

  Layer 2 — who am I, according to Entra ID
    az account show -o json
    az ad signed-in-user show -o json          # the directory object, not the local cache
    az account get-access-token --query expiresOn -o tsv
    az account get-access-token --query accessToken -o tsv | cut -d. -f2 \\
      | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{aud,iss,appid,oid,tid,scp,wids}'
      # aud = the audience the token is valid for, oid = your object id in the tenant,
      # tid = tenant, wids = directory role template ids, scp = delegated permissions.
      # An access token is a bearer credential: treat the decoded output as secret.

  Layer 3 — what am I allowed to do, and where
    az role assignment list --assignee "\$(az ad signed-in-user show --query id -o tsv)" --all -o table
    az role definition list --name "Reader" --query "[].permissions" -o json
    az account list --query "[].{name:name, id:id, tenant:tenantId, default:isDefault}" -o table

  Layer 4 — posture
    ls -l ${SECRET_FILE} 2>/dev/null
    env | grep '^AZURE_' || echo 'clean'
    az security secure-scores list -o table    # needs: az extension add --name security

  Grade yourself at any time:   ${BOLD}$0 --verify${RST}
  Stuck for more than 20 min:   ${BOLD}$0 --hint${RST}

$(rule)

EOF
}

# --------------------------------------------------------------------------- #
# VERIFY
# --------------------------------------------------------------------------- #

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local label="$1" state="$2" detail="${3:-}"
  if [[ "${state}" == "pass" ]]; then
    ok "${label}${detail:+ — ${detail}}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    bad "${label}${detail:+ — ${detail}}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

verify() {
  say ""
  say "${BOLD}VERIFICATION — AZ-900 2.4 break & fix${RST}"
  rule

  # 1. Entra ID session
  if ! have az; then
    check "1. Azure CLI session" fail "az is not installed"
  elif az_logged_in; then
    local sub
    sub="$(az account show -o tsv --query name 2>/dev/null || echo '?')"
    check "1. Azure CLI session" pass "signed in, subscription '${sub}'"
  else
    check "1. Azure CLI session" fail "'az account show -o json' still fails"
  fi

  # 2. Entra ID endpoint resolution
  local resolved
  resolved="$(getent hosts "${ENTRA_LOGIN_HOST}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if grep -qF "${HOSTS_BEGIN}" "${HOSTS_FILE}" 2>/dev/null; then
    check "2. Entra ID endpoint" fail "the hijack block is still in ${HOSTS_FILE}"
  elif [[ "${resolved}" == "127.0.0.1" || "${resolved}" == "::1" ]]; then
    check "2. Entra ID endpoint" fail "${ENTRA_LOGIN_HOST} still resolves to ${resolved}"
  elif [[ -z "${resolved}" ]]; then
    check "2. Entra ID endpoint" fail "${ENTRA_LOGIN_HOST} does not resolve at all (DNS?)"
  else
    check "2. Entra ID endpoint" pass "${ENTRA_LOGIN_HOST} -> ${resolved}"
  fi

  # 3. IMDS path
  if [[ "$(state_get FAULT3 2>/dev/null || echo skipped)" == "skipped" ]]; then
    warn "3. Managed identity path — not graded, this host has no IMDS (not an Azure VM)"
  elif have ip && ip route show "${IMDS_IP}/32" 2>/dev/null | grep -q blackhole; then
    check "3. Managed identity path" fail "blackhole route for ${IMDS_IP}/32 is still installed"
  elif imds_alive; then
    check "3. Managed identity path" pass "IMDS answers at ${IMDS_IP}"
  else
    check "3. Managed identity path" fail "${IMDS_IP} unreachable and no blackhole route — look further"
  fi

  # 4. CLI scope and output defaults
  if have az; then
    local def_group out_fmt
    def_group="$(az configure --list-defaults -o tsv --query "[?name=='group'].value" 2>/dev/null || true)"
    out_fmt="$(az config get core.output --query value -o tsv 2>/dev/null || true)"
    if [[ "${def_group}" == "${BOGUS_RG}" ]]; then
      check "4. CLI scope defaults" fail "default resource group is still '${BOGUS_RG}'"
    elif [[ "${out_fmt}" == "none" ]]; then
      check "4. CLI scope defaults" fail "core.output is still 'none' — the CLI is silenced"
    else
      check "4. CLI scope defaults" pass "no bogus default group, output format '${out_fmt:-json}'"
    fi
  else
    check "4. CLI scope defaults" fail "az is not installed"
  fi

  # 5. Secret hygiene
  local secret_bad=0 why=""
  if [[ -f "${SECRET_FILE}" ]] && grep -q '"ClientSecret"[[:space:]]*:[[:space:]]*"[^"]' "${SECRET_FILE}" 2>/dev/null; then
    secret_bad=1; why="plaintext ClientSecret still in ${SECRET_FILE}"
  fi
  if [[ ${secret_bad} -eq 0 && -f "${SECRET_FILE}" ]]; then
    local mode
    mode="$(stat -c '%a' "${SECRET_FILE}" 2>/dev/null || echo '???')"
    if [[ "${mode}" != "600" && "${mode}" != "640" && "${mode}" != "400" ]]; then
      secret_bad=1; why="${SECRET_FILE} is mode ${mode}, still readable by others"
    fi
  fi
  if [[ ${secret_bad} -eq 0 ]] && grep -qF "${BASHRC_BEGIN}" "${BASHRC}" 2>/dev/null; then
    secret_bad=1; why="AZURE_CLIENT_SECRET is still exported from ${BASHRC}"
  fi
  if [[ ${secret_bad} -eq 0 && -n "${AZURE_CLIENT_SECRET:-}" ]]; then
    secret_bad=1; why="AZURE_CLIENT_SECRET is set in THIS shell (open a new one, or unset it)"
  fi
  if [[ ${secret_bad} -eq 0 ]]; then
    check "5. Secret hygiene" pass "no plaintext secret on disk, no AZURE_CLIENT_SECRET in env"
  else
    check "5. Secret hygiene" fail "${why}"
  fi

  rule
  if [[ ${FAIL_COUNT} -eq 0 ]]; then
    say "${GRN}${BOLD}ALL CHECKS PASSED (${PASS_COUNT}).${RST}"
    say "Now answer these out loud before you close the terminal:"
    say "  * Which of the five faults was an ${BOLD}authentication${RST} problem and which an ${BOLD}authorization${RST} one?"
    say "  * Where would MFA and Conditional Access have been evaluated — on the VM, or in Entra ID?"
    say "  * Which fault would a managed identity have made impossible in the first place?"
    say "  * Name the layer each fault sat on, and the Defender for Cloud control that watches it."
    say ""
    say "Remember to remove the credential backups when you are done:"
    say "  shred -u ${LAB_HOME}/backup-*/*msal_token_cache.json 2>/dev/null; rm -rf ${LAB_HOME}"
    return 0
  fi
  say "${RED}${BOLD}${FAIL_COUNT} check(s) still failing, ${PASS_COUNT} passing.${RST}  Try '$0 --hint'."
  return 1
}

# --------------------------------------------------------------------------- #
# HINTS
# --------------------------------------------------------------------------- #

hint() {
  cat <<EOF

${BOLD}HINTS — escalating, no commands given away${RST}
$(rule)
  H1  Do not start with the CLI. Start with 'getent hosts ${ENTRA_LOGIN_HOST}'.
      If the identity provider is unreachable, nothing else can be diagnosed.

  H2  '${HOSTS_FILE}' is consulted before DNS on almost every Linux distribution
      (see /etc/nsswitch.conf, the 'hosts:' line). The lab left marked comments.

  H3  A sign-in creates files under ~/.azure. Look at what is there now and
      compare it with ${LAB_HOME}/backup-*/. You have two legitimate ways back in:
      authenticate again, or restore the cached tokens. Prefer the first, and
      then ask yourself why keeping a copy of a token cache is itself a finding.

  H4  If a command prints absolutely nothing — not even an error — suspect the
      tool before the cloud. 'az config get core.output' and
      'az configure --list-defaults'. Any '-o json' on the command line beats
      the configured default, which is a good way to confirm the theory in one shot.

  H5  '${IMDS_IP}' is link-local and must never leave the host. Ask the kernel how
      it intends to reach it: 'ip route get ${IMDS_IP}'. The word in the output tells
      you the fault. Remember: unreachable != filtered != timed out.

  H6  For the credential: deleting the file is half the job. The other half is in
      your shell startup, it survives 'unset', and it is the reason the SDK never
      falls through to the managed identity.
$(rule)

EOF
}

# --------------------------------------------------------------------------- #
# RESTORE (escape hatch)
# --------------------------------------------------------------------------- #

restore() {
  local bdir
  bdir="$(state_get BACKUP_DIR 2>/dev/null || true)"
  info "restoring from ${bdir:-<no backup recorded>}"
  resolve_sudo || warn "no sudo: ${HOSTS_FILE} and the route will not be restored"

  if [[ -n "${bdir}" && -d "${bdir}" ]]; then
    local f target
    for f in "${bdir}"/*; do
      [[ -e "${f}" ]] || continue
      target="$(basename "${f}" | tr '_' '/')"
      case "${target}" in
        "${HOSTS_FILE}")
          [[ -n "${SUDO}" || ${EUID} -eq 0 ]] && ${SUDO} cp -a "${f}" "${HOSTS_FILE}" && ok "restored ${HOSTS_FILE}"
          ;;
        *)
          mkdir -p "$(dirname "${target}")"
          cp -a "${f}" "${target}" && ok "restored ${target}"
          ;;
      esac
    done
  fi

  if have ip && ip route show "${IMDS_IP}/32" 2>/dev/null | grep -q blackhole; then
    ${SUDO} ip route del blackhole "${IMDS_IP}/32" && ok "removed the blackhole route"
  fi
  if grep -qF "${HOSTS_BEGIN}" "${HOSTS_FILE}" 2>/dev/null; then
    ${SUDO} sed -i "/${HOSTS_BEGIN}/,/${HOSTS_END}/d" "${HOSTS_FILE}" && ok "cleaned ${HOSTS_FILE}"
  fi
  if grep -qF "${BASHRC_BEGIN}" "${BASHRC}" 2>/dev/null; then
    sed -i "\|${BASHRC_BEGIN}|,\|${BASHRC_END}|d" "${BASHRC}" && ok "cleaned ${BASHRC}"
  fi
  if have az; then
    az configure --defaults group='' >/dev/null 2>&1 || true
    az config unset core.output >/dev/null 2>&1 || true
    az config unset core.only_show_errors >/dev/null 2>&1 || true
    ok "cleared the CLI defaults"
  fi
  rm -f "${SECRET_FILE}" 2>/dev/null || true
  ok "restore finished — 'az login' may still be required, and open a new shell"
}

# --------------------------------------------------------------------------- #
# MAIN
# --------------------------------------------------------------------------- #

do_break() {
  have curl || die "curl is required"
  have az || warn "az not found: faults 1 and 4 will be skipped and the lab loses most of its value"
  confirm_or_die
  mkdir -p "${LAB_HOME}"; chmod 0700 "${LAB_HOME}"
  backup_dir >/dev/null
  resolve_sudo || warn "no usable sudo: the /etc/hosts and routing faults will be skipped"
  say ""
  fault1_break_entra_session
  fault2_hijack_entra_endpoint
  fault3_blackhole_imds
  fault4_poison_cli_scope
  fault5_plant_plaintext_credentials
  state_set BROKEN_AT "$(date -Is)"
  say ""
  ok "the lab is broken. Backups: $(backup_dir)"
  warn "that backup contains a token cache — a bearer credential. Shred it when you finish."
  brief
}

main() {
  case "${1:---break}" in
    --break|"")  do_break ;;
    --brief)     brief ;;
    --verify)    verify ;;
    --hint)      hint ;;
    --restore)   restore ;;
    -h|--help)
      sed -n '1,60p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown option '$1' (try --help)" ;;
  esac
}

main "$@"

# ===========================================================================
# SOLUTION — read only after '--verify' has failed you twice
# ===========================================================================
#
# The whole exercise is one idea: identity failures are layered, and you repair
# them from the network upward. Bottom to top: name resolution -> authentication
# -> authorization -> posture. Every step below is verified before moving on.
#
# ---------------------------------------------------------------------------
# STEP 0 — make the tool honest again (FAULT 4, first half)
# ---------------------------------------------------------------------------
# Before believing any output, prove the CLI is not silencing itself. A command
# that prints nothing at all is a tooling symptom, not a cloud symptom.
#
#   $ az config get core.output
#   {
#     "name": "output",
#     "source": "/home/lab/.azure/config",
#     "value": "none"
#   }
#
#   $ az config unset core.output
#   $ az config unset core.only_show_errors
#   $ az config get core.output
#   ERROR: Configuration 'core.output' is not set.        # expected, means default (json)
#
# Tip you should keep for the exam and for real life: an explicit '-o json' on
# the command line always overrides the configured default, so
# 'az account show -o json' is the one-shot way to test this theory.
#
# ---------------------------------------------------------------------------
# STEP 1 — restore the path to Microsoft Entra ID (FAULT 2)
# ---------------------------------------------------------------------------
#   $ getent hosts login.microsoftonline.com
#   127.0.0.1       login.microsoftonline.com
#
# 127.0.0.1 for a Microsoft endpoint is never legitimate. /etc/hosts is consulted
# before DNS (see the 'hosts:' line in /etc/nsswitch.conf), so a single line here
# outranks the whole resolver chain.
#
#   $ sudo cp /etc/hosts /etc/hosts.bak
#   $ sudo sed -i '/# >>> az900-2.4-breakfix >>>/,/# <<< az900-2.4-breakfix <<</d' /etc/hosts
#   $ getent hosts login.microsoftonline.com
#   20.190.xxx.xxx  login.microsoftonline.com          # a real Microsoft address
#
#   $ curl -sS -o /dev/null -w '%{http_code}\n' https://login.microsoftonline.com/common/discovery/instance
#   400        # a 400 here is SUCCESS: TLS completed and Entra ID answered.
#              # Connection refused / timeout would mean the path is still broken.
#
# Why this is step 1: interactive sign-in, MFA, passwordless and Conditional
# Access are all evaluated by Entra ID at this endpoint. With it unreachable, the
# device can present no identity at all, and every later diagnostic lies to you.
#
# ---------------------------------------------------------------------------
# STEP 2 — re-authenticate (FAULT 1)
# ---------------------------------------------------------------------------
#   $ az account show
#   ERROR: Please run 'az login' to setup account.
#
# The correct fix is to authenticate again, not to copy the cache back. On a
# headless build agent use the device code flow:
#
#   $ az login --use-device-code
#   To sign in, use a web browser to open the page https://microsoft.com/devicelogin
#   and enter the code XXXXXXXXX to authenticate.
#
# What you are watching happen, in exam vocabulary:
#   * The device code flow separates the device from the browser doing the sign-in.
#   * The browser session is where SSO applies: if you already authenticated to
#     another Microsoft app in that browser, no credential is requested again.
#   * If MFA is required you are challenged now (Authenticator push, FIDO2 key,
#     Windows Hello, passkey — the passwordless methods of objective 2.4).
#   * If a Conditional Access policy denies the sign-in you will see the reason
#     encoded in the AADSTS error, not a generic failure:
#         AADSTS50076  MFA required, interaction needed
#         AADSTS53003  access blocked by a Conditional Access policy
#         AADSTS50158  external security challenge not satisfied
#         AADSTS700082 refresh token expired due to inactivity
#         AADSTS7000215 invalid client secret
#     Always read the AADSTS code. It names the control that stopped you.
#
#   $ az account show -o table
#   Name            CloudName    SubscriptionId                        State    IsDefault
#   --------------  -----------  ------------------------------------  -------  ---------
#   Sandbox-AZ900   AzureCloud   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  Enabled  True
#
# The fallback, valid only in this lab, is restoring the cached tokens:
#   $ cp ~/.az900-breakfix/backup-*/_home_lab_.azure_msal_token_cache.json ~/.azure/msal_token_cache.json
#   $ cp ~/.az900-breakfix/backup-*/_home_lab_.azure_azureProfile.json     ~/.azure/azureProfile.json
# It works because those files ARE the credential. That is the lesson: never back
# up a token cache, and shred this one when the lab is over:
#   $ shred -u ~/.az900-breakfix/backup-*/*msal_token_cache.json
#
# ---------------------------------------------------------------------------
# STEP 3 — restore the managed identity path (FAULT 3, Azure VM only)
# ---------------------------------------------------------------------------
#   $ ip route get 169.254.169.254
#   RTNETLINK answers: Network is unreachable
#
#   $ ip route show 169.254.169.254
#   blackhole 169.254.169.254
#
# 'blackhole' is a local kernel decision, not a cloud one and not a firewall one.
# Diagnostic rule worth memorising:
#     Network is unreachable  -> routing (ip route)
#     Connection refused      -> something answered and said no (local listener, proxy)
#     Timed out               -> silently dropped (firewall DROP, NSG deny, black hole in path)
#
#   $ sudo ip route del blackhole 169.254.169.254/32
#   $ ip route get 169.254.169.254
#   169.254.169.254 dev eth0 src 10.0.0.4 uid 1000
#
#   $ curl -s -H "Metadata: true" \
#       "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq .compute.name
#   "vm-az900-lab"
#
#   $ curl -s -H "Metadata: true" \
#       "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
#       | jq '{token_type, expires_in, client_id}'
#   {
#     "token_type": "Bearer",
#     "expires_in": "86399",
#     "client_id": "cccccccc-cccc-cccc-cccc-cccccccccccc"
#   }
#
#   $ az login --identity                       # system-assigned
#   $ az login --identity --client-id <client-id-of-the-uami>   # user-assigned, az >= 2.68
#   # older CLI builds use:  az login --identity --username <client-id>
#
# Concepts proved here, all examinable:
#   * A managed identity is a service principal in Entra ID with no credential you
#     ever handle; Azure rotates it. System-assigned dies with the resource,
#     user-assigned is an independent object you can attach to many resources.
#   * The token is fetched from a link-local address that must never be reachable
#     from outside the VM. If it were, the identity would be stealable.
#   * The token is only authentication. What the identity may DO comes from role
#     assignments — the next step.
#
# ---------------------------------------------------------------------------
# STEP 4 — clear the scope trap and read RBAC correctly (FAULT 4, second half)
# ---------------------------------------------------------------------------
#   $ az configure --list-defaults -o table
#   Name    Source                        Value
#   ------  ----------------------------  ---------------------
#   group   /home/lab/.azure/config       rg-az900-scope-trap
#
#   $ az configure --defaults group=''
#   $ az configure --list-defaults -o table        # empty
#
# Now practise reading an authorization failure. The real message names the three
# components of every Azure role assignment:
#
#   (AuthorizationFailed) The client 'dev@contoso.com' with object id 'a1b2c3d4-...'
#     does not have authorization to perform action 'Microsoft.KeyVault/vaults/read'
#     over scope '/subscriptions/<sub>/resourceGroups/rg-app-prod' or the scope is invalid.
#      ^ security principal                ^ action from a role definition        ^ scope
#
#   $ MYID=$(az ad signed-in-user show --query id -o tsv)
#   $ az role assignment list --assignee "$MYID" --all -o table
#   Principal        Role         Scope
#   ---------------  -----------  ------------------------------------------------
#   dev@contoso.com  Reader       /subscriptions/xxxx
#   dev@contoso.com  Contributor  /subscriptions/xxxx/resourceGroups/rg-app-dev
#
# What to take to the exam:
#   * Scope hierarchy: management group > subscription > resource group > resource.
#     Assignments are inherited downward and are additive.
#   * Allow is additive; an explicit deny assignment always wins over any allow.
#   * Least privilege means picking the narrowest built-in role at the narrowest
#     scope: 'Key Vault Secrets User' on one vault, not 'Contributor' on the
#     subscription. Owner/Contributor/Reader/User Access Administrator are the four
#     you must be able to distinguish; only Owner and User Access Administrator can
#     grant access to others.
#   * RBAC governs the Azure control plane (management.azure.com). What a user may
#     do INSIDE Microsoft Entra ID is governed by directory roles (Global
#     Administrator, User Administrator...), which is a different system. Do not
#     mix them up — the exam does.
#
# ---------------------------------------------------------------------------
# STEP 5 — remove the credential, not just the file (FAULT 5)
# ---------------------------------------------------------------------------
#   $ ls -l ~/az900-lab/app/appsettings.json
#   -rw-r--r--. 1 lab lab 412 Sep  6 10:02 appsettings.json      # world readable
#
#   $ env | grep AZURE_
#   AZURE_TENANT_ID=00000000-0000-0000-0000-0000000000aa
#   AZURE_CLIENT_ID=00000000-0000-0000-0000-0000000000bb
#   AZURE_CLIENT_SECRET=FAKE~DO.NOT.USE-0000000000000000000000000
#
# Remediate all three surfaces — disk, shell startup, current process:
#
#   $ shred -u ~/az900-lab/app/appsettings.json      # or strip the secret and: chmod 600
#   $ sed -i '/# >>> az900-2.4-breakfix env credentials >>>/,/# <<< az900-2.4-breakfix env credentials <<</d' ~/.bashrc
#   $ unset AZURE_CLIENT_SECRET AZURE_CLIENT_ID AZURE_TENANT_ID
#   $ exec bash -l                                    # prove it in a fresh login shell
#   $ env | grep -c AZURE_
#   0
#
# Then replace the pattern, do not just delete it. The application should read its
# configuration from Azure Key Vault, authenticating with the VM's managed identity:
#
#   # conceptual, control-plane commands an admin would run in a real subscription:
#   az keyvault set-policy ... (vault access policy model)         # legacy model
#   az role assignment create \
#       --assignee <managed-identity-client-id> \
#       --role "Key Vault Secrets User" \
#       --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>
#   # least privilege: 'Secrets User' can read secret values, and nothing else,
#   # in exactly one vault. Not 'Contributor', which can read the vault's config
#   # but is also far broader than the task requires.
#
# And in code, DefaultAzureCredential now resolves to the managed identity because
# the environment no longer hijacks the chain:
#   EnvironmentCredential -> WorkloadIdentityCredential -> ManagedIdentityCredential
#     -> SharedTokenCacheCredential -> AzureCliCredential -> ...
# The first credential that is *available* wins; if it is available but fails
# (a wrong secret), the chain stops with an error instead of falling through.
# That is precisely why a stale AZURE_CLIENT_SECRET breaks a perfectly good VM.
#
# ---------------------------------------------------------------------------
# STEP 6 — verify, then close the loop with posture
# ---------------------------------------------------------------------------
#   $ ./az900-2.4-identity-breakfix.sh --verify
#   [ ok ] 1. Azure CLI session — signed in, subscription 'Sandbox-AZ900'
#   [ ok ] 2. Entra ID endpoint — login.microsoftonline.com -> 20.190.xxx.xxx
#   [ ok ] 3. Managed identity path — IMDS answers at 169.254.169.254
#   [ ok ] 4. CLI scope defaults — no bogus default group, output format 'json'
#   [ ok ] 5. Secret hygiene — no plaintext secret on disk, no AZURE_CLIENT_SECRET in env
#   ALL CHECKS PASSED (5).
#
# Finally, the part of objective 2.4 that no local command can prove: the reason
# you found any of this is that someone was watching. Microsoft Defender for Cloud
# is the CNAPP that continuously assesses these resources, expresses the result as
# Secure Score, and issues the remediation recommendations — including "Machines
# should have secrets findings resolved" and "Management ports should be closed".
#
#   $ az extension add --name security
#   $ az security secure-scores list -o table
#   Name    DisplayName     Weight  Current  Max  Percentage
#   ------  --------------  ------  -------  ---  ----------
#   ascScore  ASC score        18       32   45        0.71
#
# ---------------------------------------------------------------------------
# THE FIVE SENTENCES TO REMEMBER
# ---------------------------------------------------------------------------
#  1. Microsoft Entra ID is the identity provider; the local machine only caches
#     the tokens it issued. Deleting the cache does not delete the identity.
#  2. Authentication (who you are: SSO, MFA, passwordless, Conditional Access)
#     always precedes authorization (what you may do: Azure RBAC). Every incident
#     is one or the other, and treating them as one costs you the diagnosis.
#  3. An RBAC assignment is principal x role definition x scope, inherited
#     downward from management group to resource; deny assignments beat allows.
#  4. A managed identity removes the credential from your code, your disk and your
#     backups: the VM asks IMDS at 169.254.169.254 and Azure hands it a token.
#  5. Defense in depth means these controls stack — network, identity,
#     authorization, host hygiene, monitoring — and Zero Trust means none of them
#     is trusted because of where the request came from. Verify explicitly, grant
#     least privilege, assume breach.
#
# Reference: https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
# ===========================================================================