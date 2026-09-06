#!/usr/bin/env bash
#
# ==============================================================================
# AZ-900 | Domain 2 - Describe Azure architecture and services
# Topic 2.3 - Describe Azure storage services   (exam weight: 9.62)
# Exam version: AZ-900 (2026-07-20)
#
# BREAK & FIX LAB - "The four layers of a storage failure"
#
# Official reference:
#   https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#   https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview
#   https://learn.microsoft.com/en-us/azure/storage/blobs/access-tiers-overview
#   https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security
#   https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-overview
#
# WHAT THIS SCRIPT DOES
#   It builds a small, disposable Azure Storage lab, then deliberately breaks
#   FOUR independent things. Each fault lives at a different layer of the
#   request path, and a real production incident feels exactly like this: one
#   symptom ("I can't read the file"), four possible causes.
#
#       Layer 1  NETWORK        Can the packet reach the storage endpoint?
#       Layer 2  AUTHENTICATION Is the credential presented still valid?
#       Layer 3  EXISTENCE      Does the object still exist?
#       Layer 4  OBJECT STATE   Is the object online, or is it in Archive?
#
#   Layer 1 masks layers 2-4: while the firewall denies you, every other probe
#   returns the same 403 and you learn nothing. That is the lesson. Fix the
#   layers bottom-up, one at a time, and re-verify after each fix.
#
# SAFETY
#   - Nothing outside its own resource group is touched. The group name must
#     start with "rg-az900" or the script refuses to run.
#   - Every resource is tagged purpose=az900-breakfix.
#   - No key, connection string or SAS is ever printed to stdout; secrets are
#     written to $LAB_DIR/app.env with mode 0600.
#   - Destructive control-plane actions require an explicit typed confirmation
#     (or AZ900_ASSUME_YES=1 for unattended lab rebuilds).
#   - Run this from a DISPOSABLE lab VM, on a DISPOSABLE subscription. It is
#     not a script for a subscription that hosts anything you care about.
#
# COST
#   Two blobs of a few KiB + one 1 GiB-quota file share, LRS, in one region.
#   Storage cost is fractions of a cent. The only non-trivial line item is the
#   Archive tier: Azure applies a 180-day early-deletion charge and a
#   rehydration (data-retrieval) charge. On a 4 KiB blob both round to zero,
#   but understand that on a 4 TiB blob they would not - that is precisely the
#   trade-off Archive exists to expose.
#
# TIME
#   setup ~3 min. Firewall rule propagation ~1 min. Rehydration from Archive
#   is asynchronous: High priority is typically < 1 h for blobs under 10 GiB,
#   Standard priority up to 15 h. The verifier therefore accepts
#   "rehydrate-pending-to-hot" as a PASS - you are graded on issuing the
#   correct operation, not on waiting out Azure's SLA.
#
# USAGE
#   ./az900-2.3-breakfix.sh setup      # build the lab (idempotent)
#   ./az900-2.3-breakfix.sh break      # inject the four faults
#   ./az900-2.3-breakfix.sh verify     # grade yourself (run this often)
#   ./az900-2.3-breakfix.sh hint       # progressive hints, no spoilers
#   ./az900-2.3-breakfix.sh status     # show current lab configuration
#   ./az900-2.3-breakfix.sh cleanup    # delete the resource group
#
# PREREQUISITES
#   Azure CLI >= 2.60, jq, curl, and `az login` against a lab subscription
#   where you hold Contributor + Storage Blob Data Contributor.
# ==============================================================================

set -Eeuo pipefail

trap 'rc=$?; printf "\n[!] %s: aborted at line %s (exit %s)\n" "${0##*/}" "${LINENO}" "${rc}" >&2; exit "${rc}"' ERR

# ------------------------------------------------------------------------------
# Configuration - override any of these with environment variables
# ------------------------------------------------------------------------------
LAB_DIR="${AZ900_LAB_DIR:-$HOME/az900-lab-2-3}"
STATE_FILE="$LAB_DIR/lab.env"
APP_ENV="$LAB_DIR/app.env"

RG="${AZ900_RG:-rg-az900-breakfix}"
LOCATION="${AZ900_LOCATION:-eastus}"
TAGS="purpose=az900-breakfix owner=student lifecycle=disposable"

CONTAINER="courseware"
BLOB_LIVE="lesson-2-3.md"          # target of the soft-delete fault (layer 3)
BLOB_COLD="redundancy-diagram.txt" # target of the Archive fault    (layer 4)
SHARE="classfiles"

C_OK=$'\033[0;32m'; C_BAD=$'\033[0;31m'; C_WARN=$'\033[0;33m'
C_HDR=$'\033[1;36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_BAD=""; C_WARN=""; C_HDR=""; C_DIM=""; C_OFF=""; }

log()  { printf '%s[*]%s %s\n' "$C_HDR" "$C_OFF" "$*"; }
ok()   { printf '%s[+] %s%s\n' "$C_OK"  "$*" "$C_OFF"; }
bad()  { printf '%s[-] %s%s\n' "$C_BAD" "$*" "$C_OFF"; }
warn() { printf '%s[!] %s%s\n' "$C_WARN" "$*" "$C_OFF"; }
dim()  { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
die()  { bad "$*"; exit 1; }
rule() { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------------" "$C_OFF"; }

AZ="az"
AZ_Q=(--only-show-errors --output tsv)

# ------------------------------------------------------------------------------
# Guardrails
# ------------------------------------------------------------------------------
preflight() {
  local missing=0 c
  for c in az jq curl; do
    command -v "$c" >/dev/null 2>&1 || { bad "missing required command: $c"; missing=1; }
  done
  (( missing == 0 )) || die "install the missing tools and re-run"

  [[ "$RG" == rg-az900* ]] || die "refusing to operate on resource group '$RG' (name must start with rg-az900)"

  $AZ account show --only-show-errors >/dev/null 2>&1 || die "not logged in - run: az login"

  SUB_NAME=$($AZ account show --query name "${AZ_Q[@]}")
  SUB_ID=$($AZ account show --query id "${AZ_Q[@]}")
  mkdir -p "$LAB_DIR"; chmod 700 "$LAB_DIR"
}

confirm() {
  local prompt="$1" word="${2:-YES}" answer
  [[ "${AZ900_ASSUME_YES:-0}" == "1" ]] && { warn "AZ900_ASSUME_YES=1 - proceeding without prompt"; return 0; }
  rule
  printf '%s\n' "$prompt"
  printf 'Subscription : %s (%s)\n' "$SUB_NAME" "$SUB_ID"
  printf 'Resource grp : %s / %s\n' "$RG" "$LOCATION"
  rule
  read -r -p "Type $word to continue: " answer
  [[ "$answer" == "$word" ]] || die "aborted by user"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "no lab state found - run '$0 setup' first"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "${SA:-}" ]] || die "lab state at $STATE_FILE is incomplete - run '$0 cleanup' then '$0 setup'"
}

# Current, authoritative key fetched from the control plane. Used only by the
# verifier, so that a stale credential in app.env cannot masquerade as a
# network fault (that separation is the whole point of the exercise).
current_key() {
  $AZ storage account keys list -g "$RG" -n "$SA" --query "[0].value" "${AZ_Q[@]}"
}

# Run a command, capture stdout+stderr into PROBE_OUT, never abort the script.
probe() {
  local rc=0
  set +e
  PROBE_OUT="$("$@" 2>&1)"
  rc=$?
  set -e
  return $rc
}

# ------------------------------------------------------------------------------
# setup - build the disposable lab
# ------------------------------------------------------------------------------
cmd_setup() {
  preflight
  confirm "About to CREATE a disposable AZ-900 storage lab." "CREATE"

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    log "reusing existing lab state (storage account: ${SA})"
  else
    SA="az900bf$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
    printf 'SA=%s\nRG=%s\nLOCATION=%s\nCONTAINER=%s\n' "$SA" "$RG" "$LOCATION" "$CONTAINER" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  fi

  log "resource group: $RG"
  $AZ group create -n "$RG" -l "$LOCATION" --tags $TAGS --output none --only-show-errors

  log "storage account: $SA (StorageV2, Standard_LRS, hot)"
  # General-purpose v2 is the account type the exam expects as the default:
  # it serves blob, file, queue and table from a single namespace.
  # Standard_LRS = 3 synchronous copies inside ONE datacenter. Cheapest, and
  # the only redundancy option that does not survive the loss of a facility.
  if ! $AZ storage account show -g "$RG" -n "$SA" --output none --only-show-errors 2>/dev/null; then
    $AZ storage account create \
      -g "$RG" -n "$SA" -l "$LOCATION" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --access-tier Hot \
      --min-tls-version TLS1_2 \
      --https-only true \
      --allow-blob-public-access false \
      --public-network-access Enabled \
      --tags $TAGS \
      --output none --only-show-errors
  fi

  log "enabling blob soft delete (7 days) - this is the safety net for layer 3"
  $AZ storage account blob-service-properties update \
    -g "$RG" --account-name "$SA" \
    --enable-delete-retention true --delete-retention-days 7 \
    --enable-container-delete-retention true --container-delete-retention-days 7 \
    --output none --only-show-errors

  local key; key=$(current_key)

  log "container: $CONTAINER (private - anonymous access is disabled account-wide)"
  $AZ storage container create \
    --account-name "$SA" --account-key "$key" \
    -n "$CONTAINER" --public-access off \
    --output none --only-show-errors

  printf '# %s\nAzure Storage lesson 2.3 - hot path object.\nIf you can read this line, layers 1-3 are healthy.\n' \
    "$BLOB_LIVE" > "$LAB_DIR/$BLOB_LIVE"
  printf 'LRS  : 3 copies, 1 datacenter\nZRS  : 3 copies, 3 availability zones\nGRS  : LRS + async copy to the paired region\nGZRS : ZRS + async copy to the paired region\n' \
    > "$LAB_DIR/$BLOB_COLD"

  log "uploading course objects"
  $AZ storage blob upload --account-name "$SA" --account-key "$key" \
    -c "$CONTAINER" -n "$BLOB_LIVE" -f "$LAB_DIR/$BLOB_LIVE" --overwrite \
    --output none --only-show-errors
  $AZ storage blob upload --account-name "$SA" --account-key "$key" \
    -c "$CONTAINER" -n "$BLOB_COLD" -f "$LAB_DIR/$BLOB_COLD" --overwrite \
    --output none --only-show-errors

  log "azure files share: $SHARE (1 GiB quota)"
  $AZ storage share-rm create -g "$RG" --storage-account "$SA" -n "$SHARE" --quota 1 \
    --output none --only-show-errors

  log "writing application config (shared-key connection string) to $APP_ENV"
  # This file plays the role of a legacy application's configuration: it pins a
  # shared key. Pinning a key is exactly what makes key rotation an outage.
  umask 077
  cat > "$APP_ENV" <<EOF
# Simulated legacy application configuration - AZ-900 lab 2.3
# Shared Key authorization. Treat this string as a root password for the
# entire storage account: it grants full control over blob, file, queue and
# table data, it cannot be scoped, and it cannot be audited per user.
AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=${SA};AccountKey=${key};EndpointSuffix=core.windows.net"
EOF
  chmod 600 "$APP_ENV"

  rule
  ok "lab ready"
  dim "storage account : $SA"
  dim "container       : $CONTAINER  (blobs: $BLOB_LIVE, $BLOB_COLD)"
  dim "file share      : $SHARE"
  dim "app config      : $APP_ENV"
  rule
  log "baseline check - everything should PASS right now:"
  cmd_verify || true
  printf '\nWhen the baseline is green, run: %s break\n' "$0"
}

# ------------------------------------------------------------------------------
# break - inject the four faults
# ------------------------------------------------------------------------------
cmd_break() {
  preflight
  load_state
  confirm "About to BREAK the lab storage account '$SA'. Four faults will be injected." "BREAK"

  # -- Fault 2 (layer 2: authentication) --------------------------------------
  # Rotate the primary access key. Control-plane callers (az with your Entra ID
  # identity) are unaffected; the application pinned to the old key is not.
  log "fault 2/4 - rotating the primary account key"
  $AZ storage account keys renew -g "$RG" -n "$SA" --key primary --output none --only-show-errors

  local key; key=$(current_key)

  # -- Fault 3 (layer 3: existence) -------------------------------------------
  # Delete a blob. Soft delete is enabled, so this is recoverable - but only if
  # the student knows the deleted object is still there and how to list it.
  log "fault 3/4 - deleting $BLOB_LIVE"
  $AZ storage blob delete --account-name "$SA" --account-key "$key" \
    -c "$CONTAINER" -n "$BLOB_LIVE" --output none --only-show-errors

  # -- Fault 4 (layer 4: object state) ----------------------------------------
  # Move a blob to Archive. The object exists, metadata is queryable, and every
  # read fails. This is the tier trade-off made visible.
  log "fault 4/4 - moving $BLOB_COLD to the Archive access tier"
  $AZ storage blob set-tier --account-name "$SA" --account-key "$key" \
    -c "$CONTAINER" -n "$BLOB_COLD" --tier Archive --output none --only-show-errors

  # -- Fault 1 (layer 1: network) - injected LAST so it masks the others ------
  log "fault 1/4 - setting the storage firewall default action to Deny"
  $AZ storage account update -g "$RG" -n "$SA" \
    --default-action Deny --bypass AzureServices \
    --output none --only-show-errors

  sleep 5
  rule
  cat <<'BRIEF'
INCIDENT TICKET  #AZ900-2.3
Reported by      : the courseware web app
Severity         : 2 - service unavailable

  "Since this morning the app cannot read ANY course file from the storage
   account. It worked yesterday. Nothing in the app changed. The Azure portal
   still shows the storage account as healthy and the container as present."

THE SYMPTOMS YOU WILL SEE

  1) Any data-plane call - list, download, upload - fails with HTTP 403:

        (AuthorizationFailure) This request is not authorized to perform
        this operation.

     Note what this is NOT. It is not 'AuthenticationFailed'. The credential
     was never even evaluated: the request was rejected at the network
     boundary before authorization ran. Control-plane commands
     (az storage account show) keep working perfectly - they go to
     management.azure.com, a completely different endpoint. That asymmetry
     is your first and best clue.

  2) Once the network clears, the application's own calls fail differently:

        (AuthenticationFailed) Server failed to authenticate the request.
        Make sure the value of Authorization header is formed correctly
        including the signature.

     Same 403 status code, different error code, completely different cause.

  3) Then one file returns:

        (BlobNotFound) The specified blob does not exist.

     ...even though nobody in your team deleted anything on purpose, and the
     account was configured with a retention policy.

  4) And the last file returns:

        (BlobArchived) This operation is not permitted on an archived blob.

     The blob is listed. Its size and last-modified date are correct. It
     simply refuses to be read.

WHAT YOU MUST ACHIEVE

  Make './az900-2.3-breakfix.sh verify' report 4/4 PASS:

    [L1] NETWORK        data-plane reachable from this VM
    [L2] AUTHENTICATION the credential in app.env is accepted
    [L3] EXISTENCE      lesson-2-3.md is readable again, same content
    [L4] OBJECT STATE   redundancy-diagram.txt is online (or rehydrating)

RULES OF ENGAGEMENT

  - Do NOT delete and recreate the storage account. Recovering state is the
    exercise; rebuilding is an admission of defeat.
  - Do NOT re-upload the missing blob from the local copy in the lab
    directory. Recover it from Azure. In production there is no local copy.
  - Fix ONE layer, re-run verify, read the NEW error. The error message
    changing is how you know you moved down the stack.
  - Everything you need is discoverable with 'az storage account --help',
    'az storage blob --help' and the Microsoft Learn links in this script's
    header. Run 'hint' if you stall for more than 15 minutes.

BRIEF
  rule
  warn "the lab is now broken - start with: $0 verify"
}

# ------------------------------------------------------------------------------
# verify - grade the four layers independently
# ------------------------------------------------------------------------------
cmd_verify() {
  preflight
  load_state

  local pass=0 net_ok=0 key cs
  key=$(current_key)

  rule
  printf '%sVERIFICATION - storage account %s%s\n' "$C_HDR" "$SA" "$C_OFF"
  rule

  # ---- Layer 1: network -----------------------------------------------------
  if probe $AZ storage container list --account-name "$SA" --account-key "$key" \
       --num-results 1 --only-show-errors --output none; then
    ok "[L1] NETWORK        data plane reachable from this host"
    net_ok=1; pass=$((pass+1))
  else
    if grep -qi 'AuthorizationFailure\|not authorized to perform this operation' <<<"$PROBE_OUT"; then
      bad "[L1] NETWORK        403 AuthorizationFailure - blocked at the firewall"
      dim "the request never reached the authorization stage"
    else
      bad "[L1] NETWORK        data-plane call failed"
      dim "$(head -n 2 <<<"$PROBE_OUT")"
    fi
    dim "current default action: $($AZ storage account show -g "$RG" -n "$SA" --query networkRuleSet.defaultAction "${AZ_Q[@]}")"
  fi

  # ---- Layer 2: authentication ---------------------------------------------
  if (( net_ok == 0 )); then
    warn "[L2] AUTHENTICATION masked by L1 - cannot be evaluated yet"
  elif [[ ! -f "$APP_ENV" ]]; then
    bad "[L2] AUTHENTICATION $APP_ENV is missing"
  else
    # shellcheck disable=SC1090
    cs=$(grep -oP '(?<=^AZURE_STORAGE_CONNECTION_STRING=").*(?="$)' "$APP_ENV" || true)
    if [[ -z "$cs" ]]; then
      bad "[L2] AUTHENTICATION no connection string found in $APP_ENV"
    elif probe $AZ storage container list --connection-string "$cs" \
           --num-results 1 --only-show-errors --output none; then
      ok "[L2] AUTHENTICATION the credential in app.env is accepted"
      pass=$((pass+1))
    elif grep -qi 'AuthenticationFailed\|Signature' <<<"$PROBE_OUT"; then
      bad "[L2] AUTHENTICATION 403 AuthenticationFailed - the app's key is stale"
      dim "the signature computed by the client does not match the server's"
    else
      bad "[L2] AUTHENTICATION $(head -n 1 <<<"$PROBE_OUT")"
    fi
  fi

  # ---- Layer 3: existence ---------------------------------------------------
  if (( net_ok == 0 )); then
    warn "[L3] EXISTENCE      masked by L1 - cannot be evaluated yet"
  else
    local exists deleted_out
    exists=$($AZ storage blob exists --account-name "$SA" --account-key "$key" \
              -c "$CONTAINER" -n "$BLOB_LIVE" --query exists "${AZ_Q[@]}" 2>/dev/null || echo false)
    if [[ "$exists" == "true" ]]; then
      rm -f "$LAB_DIR/.verify.out"
      if probe $AZ storage blob download --account-name "$SA" --account-key "$key" \
           -c "$CONTAINER" -n "$BLOB_LIVE" -f "$LAB_DIR/.verify.out" \
           --only-show-errors --output none \
         && grep -q 'layers 1-3 are healthy' "$LAB_DIR/.verify.out" 2>/dev/null; then
        ok "[L3] EXISTENCE      $BLOB_LIVE recovered, content intact"
        pass=$((pass+1))
      else
        bad "[L3] EXISTENCE      $BLOB_LIVE exists but its content is wrong"
        dim "recover the original version - do not fabricate a replacement"
      fi
    else
      bad "[L3] EXISTENCE      BlobNotFound: $BLOB_LIVE"
      deleted_out=$($AZ storage blob list --account-name "$SA" --account-key "$key" \
                     -c "$CONTAINER" --include d \
                     --query "length([?deleted])" "${AZ_Q[@]}" 2>/dev/null || echo 0)
      dim "soft-deleted blobs currently retained in this container: ${deleted_out}"
    fi
  fi

  # ---- Layer 4: object state ------------------------------------------------
  if (( net_ok == 0 )); then
    warn "[L4] OBJECT STATE   masked by L1 - cannot be evaluated yet"
  else
    local tier rehyd
    tier=$($AZ storage blob show --account-name "$SA" --account-key "$key" \
            -c "$CONTAINER" -n "$BLOB_COLD" --query properties.blobTier "${AZ_Q[@]}" 2>/dev/null || echo UNKNOWN)
    rehyd=$($AZ storage blob show --account-name "$SA" --account-key "$key" \
             -c "$CONTAINER" -n "$BLOB_COLD" --query properties.rehydrationStatus "${AZ_Q[@]}" 2>/dev/null || echo "")
    case "$tier" in
      Hot|Cool|Cold)
        ok "[L4] OBJECT STATE   $BLOB_COLD is online (tier: $tier)"
        pass=$((pass+1)) ;;
      Archive)
        if [[ -n "$rehyd" ]]; then
          ok "[L4] OBJECT STATE   rehydration in progress ($rehyd) - correct action taken"
          dim "the blob stays unreadable until Azure completes the copy; that is by design"
          pass=$((pass+1))
        else
          bad "[L4] OBJECT STATE   $BLOB_COLD is in Archive, no rehydration requested"
          dim "Archive is offline storage: reads are rejected until the blob is rehydrated"
        fi ;;
      *)
        bad "[L4] OBJECT STATE   could not read the tier of $BLOB_COLD (got: $tier)" ;;
    esac
  fi

  rule
  if (( pass == 4 )); then
    ok "SCORE 4/4 - incident resolved. Remember to run '$0 cleanup'."
  else
    printf '%sSCORE %s/4 - keep going. Fix the lowest failing layer first.%s\n' "$C_WARN" "$pass" "$C_OFF"
  fi
  rule
  (( pass == 4 ))
}

# ------------------------------------------------------------------------------
# hint / status / cleanup
# ------------------------------------------------------------------------------
cmd_hint() {
  cat <<'HINTS'
PROGRESSIVE HINTS - read only as far as you need.

L1  Compare what works with what does not. 'az storage account show' succeeds;
    'az storage blob list' does not. Those two commands talk to two different
    endpoints. Which Azure feature can allow one and block the other?
    Then: az storage account show -g <rg> -n <sa> --query networkRuleSet
    Caveat for Azure-hosted lab VMs: a VM in the SAME region as the storage
    account reaches it over the Azure backbone, so a public-IP rule may not
    match. Use a VNet service endpoint rule, or set the default action back to
    Allow, and understand why the two are not equivalent.

L2  The status code is still 403, but the error CODE changed from
    AuthorizationFailure to AuthenticationFailed. Authorization is "may you";
    authentication is "are you". Something re-issued the account's credential.
    Look at: az storage account keys list -g <rg> -n <sa> --query "[].keyName"
    Then ask the better question: why does an application hold an account key
    at all? What are the two alternatives the AZ-900 objectives name?

L3  Deleting a blob does not always destroy it. The account was configured
    with a retention policy before the incident. Blobs in that state are
    invisible to a normal list - there is a flag that reveals them, and a
    single verb that brings them back.
    Start with: az storage blob list ... --include d

L4  The blob is listed, sized and dated - and unreadable. Look at
    properties.blobTier. One of the four access tiers is offline storage:
    the data is on low-cost media and must be copied back to an online tier
    before any read succeeds. That copy is not instant, and you can pay to
    make it faster. Find the flag that controls the priority.
HINTS
}

cmd_status() {
  preflight; load_state
  rule
  printf 'account      : %s\n' "$SA"
  printf 'sku          : %s\n' "$($AZ storage account show -g "$RG" -n "$SA" --query sku.name "${AZ_Q[@]}")"
  printf 'kind         : %s\n' "$($AZ storage account show -g "$RG" -n "$SA" --query kind "${AZ_Q[@]}")"
  printf 'access tier  : %s\n' "$($AZ storage account show -g "$RG" -n "$SA" --query accessTier "${AZ_Q[@]}")"
  printf 'firewall     : %s\n' "$($AZ storage account show -g "$RG" -n "$SA" --query networkRuleSet.defaultAction "${AZ_Q[@]}")"
  printf 'ip rules     : %s\n' "$($AZ storage account show -g "$RG" -n "$SA" --query "join(',', networkRuleSet.ipRules[].ipAddressOrRange)" "${AZ_Q[@]}")"
  printf 'soft delete  : %s day(s)\n' "$($AZ storage account blob-service-properties show -g "$RG" --account-name "$SA" --query deleteRetentionPolicy.days "${AZ_Q[@]}")"
  printf 'your egress  : %s\n' "$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo 'unknown')"
  rule
}

cmd_cleanup() {
  preflight
  [[ -f "$STATE_FILE" ]] && { # shellcheck disable=SC1090
    source "$STATE_FILE"; }
  confirm "About to DELETE resource group '$RG' and every resource in it." "DELETE"
  $AZ group delete -n "$RG" --yes --no-wait --only-show-errors
  rm -f "$STATE_FILE" "$APP_ENV" "$LAB_DIR/.verify.out" "$LAB_DIR/$BLOB_LIVE" "$LAB_DIR/$BLOB_COLD"
  ok "deletion requested (asynchronous). Confirm later with: az group exists -n $RG"
}

# ------------------------------------------------------------------------------
main() {
  case "${1:-}" in
    setup)   cmd_setup ;;
    break)   cmd_break ;;
    verify)  cmd_verify ;;
    hint)    cmd_hint ;;
    status)  cmd_status ;;
    cleanup) cmd_cleanup ;;
    *) printf 'usage: %s {setup|break|verify|hint|status|cleanup}\n' "${0##*/}"; exit 2 ;;
  esac
}
main "$@"

# ==============================================================================
# SOLUTION - do not read until you have scored at least 2/4 on your own
# ==============================================================================
#
# Load the lab identifiers first; every command below assumes them:
#
#   source ~/az900-lab-2-3/lab.env      # exports SA, RG, LOCATION, CONTAINER
#   KEY=$(az storage account keys list -g "$RG" -n "$SA" --query "[0].value" -o tsv)
#
# ------------------------------------------------------------------------------
# LAYER 1 - NETWORK : the storage firewall is denying you
# ------------------------------------------------------------------------------
# Diagnosis. The control plane answers, the data plane does not. That single
# observation localises the fault, because the two live behind different
# endpoints: management.azure.com (ARM, governed by Azure RBAC) versus
# <account>.blob.core.windows.net (data, governed additionally by the account's
# network rule set).
#
#   az storage account show -g "$RG" -n "$SA" --query networkRuleSet
#     {
#       "bypass": "AzureServices",
#       "defaultAction": "Deny",        <-- everything not explicitly allowed
#       "ipRules": [],
#       "virtualNetworkRules": []
#     }
#
# Fix A - production-shaped: keep Deny, allow only this host's egress address.
#
#   MYIP=$(curl -fsS https://api.ipify.org)
#   az storage account network-rule add -g "$RG" --account-name "$SA" --ip-address "$MYIP"
#   # rule propagation is not instantaneous - allow up to ~60 seconds
#   sleep 60
#   az storage container list --account-name "$SA" --account-key "$KEY" -o table
#
# Fix B - only if the lab VM is an Azure VM in the SAME region as the account.
# Public-IP rules do not match that traffic: it never leaves the Azure
# backbone, so the service sees a private source address. The correct answer
# there is a virtual network rule backed by a service endpoint:
#
#   az network vnet subnet update -g "$RG" --vnet-name <vnet> -n <subnet> \
#       --service-endpoints Microsoft.Storage
#   az storage account network-rule add -g "$RG" --account-name "$SA" \
#       --vnet-name <vnet> --subnet <subnet>
#
# Fix C - the blunt instrument. Acceptable in a throwaway lab, a finding in a
# real audit, because it re-exposes the account to the whole public internet:
#
#   az storage account update -g "$RG" -n "$SA" --default-action Allow
#
# Exam framing: the firewall is a NETWORK control. It never grants access - it
# only removes reachability. You still need a valid credential afterwards,
# which is exactly what layer 2 is about to prove.
#
# ------------------------------------------------------------------------------
# LAYER 2 - AUTHENTICATION : the application holds a rotated key
# ------------------------------------------------------------------------------
# Diagnosis. Same HTTP 403, different error code: AuthenticationFailed with a
# reference to the Authorization header signature. Shared Key authorization
# works by having the client HMAC-sign a canonicalised request with the account
# key; the service recomputes the signature with the key it currently holds. If
# key1 was regenerated, every previously issued signature stops matching -
# instantly, everywhere, for every client using that key.
#
#   az storage account keys list -g "$RG" -n "$SA" --query "[].{name:keyName}" -o table
#
# Fix - re-point the application at a currently valid credential:
#
#   NEWCS=$(az storage account show-connection-string -g "$RG" -n "$SA" \
#             --query connectionString -o tsv)
#   printf 'AZURE_STORAGE_CONNECTION_STRING="%s"\n' "$NEWCS" > ~/az900-lab-2-3/app.env
#   chmod 600 ~/az900-lab-2-3/app.env
#
# The better fix, and the one the AZ-900 objectives actually want you to name.
# Storage supports three authorization models, in increasing order of quality:
#
#   1. Shared Key      - the account key. Full control over blob, file, queue
#                        and table. Cannot be scoped, expired or attributed to
#                        a person. One leak compromises the whole account.
#   2. SAS token       - a signed URL: scoped to a resource, a permission set
#                        and a time window. A user delegation SAS is signed
#                        with an Entra ID credential rather than the account
#                        key, so revoking the identity revokes the token.
#   3. Microsoft Entra ID + Azure RBAC - no secret in the application at all.
#                        A managed identity holds a role such as
#                        'Storage Blob Data Reader', access is per-principal,
#                        auditable, and key rotation becomes a non-event.
#
# Demonstrate the third model, which would have made this fault impossible:
#
#   ME=$(az ad signed-in-user show --query id -o tsv)
#   SCOPE=$(az storage account show -g "$RG" -n "$SA" --query id -o tsv)
#   az role assignment create --assignee-object-id "$ME" \
#      --assignee-principal-type User \
#      --role "Storage Blob Data Contributor" --scope "$SCOPE"
#   # wait for RBAC propagation, then use no key at all:
#   az storage blob list --account-name "$SA" -c "$CONTAINER" --auth-mode login -o table
#
# ------------------------------------------------------------------------------
# LAYER 3 - EXISTENCE : the blob was deleted, and soft delete retained it
# ------------------------------------------------------------------------------
# Diagnosis. BlobNotFound on read, but the account was created with a blob
# delete-retention policy. A soft-deleted blob is retained for the configured
# window and is simply hidden from ordinary listings.
#
#   az storage account blob-service-properties show -g "$RG" --account-name "$SA" \
#      --query deleteRetentionPolicy
#     { "days": 7, "enabled": true }
#
#   az storage blob list --account-name "$SA" --account-key "$KEY" \
#      -c "$CONTAINER" --include d \
#      --query "[].{name:name, deleted:deleted, ttl:properties.remainingRetentionDays}" -o table
#     Name            Deleted    Ttl
#     --------------  ---------  -----
#     lesson-2-3.md   True       7
#
# Fix - undelete restores the blob and all of its retained versions:
#
#   az storage blob undelete --account-name "$SA" --account-key "$KEY" \
#      -c "$CONTAINER" -n lesson-2-3.md
#   az storage blob download --account-name "$SA" --account-key "$KEY" \
#      -c "$CONTAINER" -n lesson-2-3.md -f /tmp/lesson-2-3.md && cat /tmp/lesson-2-3.md
#
# Exam framing: soft delete is a RECOVERY control, not a backup, and its scope
# is deliberately narrow. It protects against deletion and overwrite of an
# object inside a retained window. It does not protect against the deletion of
# the storage account itself, it does not survive the retention window, and it
# is off by default on accounts created before it existed. Its companions in
# the objective are blob versioning (keeps every prior version), point-in-time
# restore (rolls a whole container back), and the resource lock
# (`az lock create --lock-type CanNotDelete`) that stops the account from being
# deleted at the control plane in the first place.
#
# ------------------------------------------------------------------------------
# LAYER 4 - OBJECT STATE : the blob is in the Archive access tier
# ------------------------------------------------------------------------------
# Diagnosis. The blob is listed with correct size and timestamps, yet every
# read returns BlobArchived. Archive is OFFLINE storage: the data sits on the
# cheapest media Azure offers, the metadata stays online so you can list, tag
# and set properties, and no read is possible until the blob is copied back to
# an online tier.
#
#   az storage blob show --account-name "$SA" --account-key "$KEY" \
#      -c "$CONTAINER" -n redundancy-diagram.txt \
#      --query "{tier:properties.blobTier, status:properties.rehydrationStatus}"
#     { "tier": "Archive", "status": null }
#
# Fix A - rehydrate in place, asking for the expensive-but-fast priority:
#
#   az storage blob set-tier --account-name "$SA" --account-key "$KEY" \
#      -c "$CONTAINER" -n redundancy-diagram.txt --tier Hot --rehydrate-priority High
#
#   az storage blob show --account-name "$SA" --account-key "$KEY" \
#      -c "$CONTAINER" -n redundancy-diagram.txt \
#      --query "{tier:properties.blobTier, status:properties.rehydrationStatus}"
#     { "tier": "Archive", "status": "rehydrate-pending-to-hot" }
#
#   The tier stays Archive and reads keep failing until the copy completes:
#   typically under 1 hour at High priority for blobs below 10 GiB, up to 15
#   hours at Standard. You cannot cancel a rehydration, and you cannot make it
#   synchronous. That latency IS the product.
#
# Fix B - when you need the data now and cannot wait: copy the archived blob to
# a NEW blob in an online tier. The copy is served from the archive tier
# asynchronously as well, but it leaves the original untouched and lets you
# stage the destination however you like:
#
#   az storage blob copy start --account-name "$SA" --account-key "$KEY" \
#      --destination-container "$CONTAINER" --destination-blob redundancy-diagram-online.txt \
#      --source-container "$CONTAINER" --source-blob redundancy-diagram.txt \
#      --tier Hot --rehydrate-priority High
#
# Exam framing - the four access tiers, and the single trade-off behind them.
# You pay in two dimensions and they move in opposite directions: the colder
# the tier, the lower the per-GiB storage price and the higher the per-GiB
# access price, plus a minimum retention period whose early violation is
# billed anyway.
#
#   Hot     - highest storage cost, lowest access cost.  No minimum.
#   Cool    - lower storage cost, higher access cost.     30-day minimum.
#   Cold    - lower still, higher access cost again.      90-day minimum.
#   Archive - lowest storage cost, highest access cost.  180-day minimum,
#             OFFLINE: rehydration required before any read.
#
# Hot/Cool/Cold can be switched instantly and are online throughout. Archive is
# the only tier that changes the AVAILABILITY of the data, not just its price,
# and it is per-blob only - it cannot be an account's default tier. In practice
# you never set it by hand: an account lifecycle management policy moves blobs
# down the tiers by age, for example
# "tierToCool after 30 days without access, tierToArchive after 180, delete
# after 2555", which is how a seven-year compliance retention costs almost
# nothing to keep.
#
# ------------------------------------------------------------------------------
# FINAL CHECK AND TEARDOWN
# ------------------------------------------------------------------------------
#   ./az900-2.3-breakfix.sh verify     # expect SCORE 4/4
#   ./az900-2.3-breakfix.sh cleanup    # delete the resource group
#
# WHAT TO CARRY INTO THE EXAM - AND INTO PRODUCTION
#   Four failures, four layers, one indistinguishable symptom ("I can't read
#   the file") and, for the first three, one identical HTTP status code. The
#   discriminator was never the status code; it was the Azure error code in the
#   response body: AuthorizationFailure (network), AuthenticationFailed
#   (credential), BlobNotFound (existence), BlobArchived (tier). Read the error
#   code before you touch anything, work the layers from the bottom up, and
#   re-verify after every single change so that a changing error message tells
#   you that you are making progress.
# ==============================================================================