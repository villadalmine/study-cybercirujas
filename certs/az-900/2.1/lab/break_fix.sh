#!/usr/bin/env bash
#
# =============================================================================
#  AZ-900 | Domain 2 | Topic 2.1 - Describe the core architectural components
#                                  of Azure          (exam weight: 9.62 %)
#  Exam version : 2026-07-20
#  Study guide  : https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#
#  LAB TYPE     : break & fix  ("The deployment that lands nowhere")
#  RUN ON       : a DISPOSABLE lab VM only. Never on a workstation you care
#                 about and never against a production subscription.
#  MONEY        : this lab creates only free-of-charge control-plane objects:
#                 a resource group, a management lock, a policy assignment and
#                 one Network Security Group. Template *validation* creates
#                 nothing at all. No compute, no storage, no public IP.
#
#  WHAT IT TEACHES (all of it is topic 2.1 mechanics, made painful on purpose):
#    - the ARM control plane is the single front door: every CLI / portal /
#      Terraform call is an HTTP request against
#      management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/...
#    - the scope hierarchy management group > subscription > resource group >
#      resource, and the fact that policy and locks flow DOWNWARD from the
#      scope where they are attached
#    - region vs availability zone: a region is a set of datacenters within a
#      latency envelope; an availability zone is a physically separate
#      power/cooling/network failure domain INSIDE a region, and not every
#      region has them
#    - the classic beginner trap: a resource group's location is METADATA
#      (where the group's own record lives); the resources inside it can and
#      often do live in other regions
#    - a template is written for ONE deployment scope, declared by its
#      $schema; the wrong schema is rejected before a single resource is touched
#
#  OFFICIAL REFERENCES (cited in the solution block at the bottom):
#    https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview
#    https://learn.microsoft.com/en-us/azure/reliability/regions-overview
#    https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
#    https://learn.microsoft.com/en-us/azure/reliability/availability-zones-region-support
#    https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-cli
#    https://learn.microsoft.com/en-us/azure/governance/management-groups/overview
#    https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
#    https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-resource-group
#    https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-subscription
#    https://learn.microsoft.com/en-us/cli/azure/azure-cli-configuration
#
#  USAGE
#    ./az900-2.1-breakfix.sh break     # apply the faults, print the mission
#    ./az900-2.1-breakfix.sh status    # show the current lab state
#    ./az900-2.1-breakfix.sh verify    # grade yourself (this is the exit gate)
#    ./az900-2.1-breakfix.sh hint [n]  # progressive hints, 1..5
#    ./az900-2.1-breakfix.sh restore   # tear the whole lab down
#
#  SAFETY DESIGN
#    - every az call in this lab runs against an ISOLATED AZURE_CONFIG_DIR
#      under ~/az900-lab-2.1/. Your real ~/.azure is never written to.
#    - the lab resource group is tagged az900-lab=2.1 and 'restore' refuses to
#      delete any resource group that does not carry that tag.
#    - nothing outside ~/az900-lab-2.1/ and the tagged resource group is touched.
# =============================================================================

set -uo pipefail

LAB_NAME="az900-lab-2.1"
LAB_DIR="${HOME}/${LAB_NAME}"
LAB_CFG="${LAB_DIR}/azure-config"
LAB_STATE="${LAB_DIR}/state.env"
LAB_TEMPLATE="${LAB_DIR}/azuredeploy.json"
LAB_ENV="${LAB_DIR}/env.sh"

LAB_RG="rg-az900-lab21"
LAB_NSG="nsg-az900-lab21"
LAB_LOCK="lock-az900-lab21"
LAB_POLICY_ASSIGNMENT="az900-allowed-locations"
LAB_TAG_KEY="az900-lab"
LAB_TAG_VALUE="2.1"

# Built-in policy definition "Allowed locations" (stable GUID, documented at
# https://learn.microsoft.com/en-us/azure/governance/policy/samples/built-in-policies )
ALLOWED_LOCATIONS_POLICY="e56962a6-4747-49cd-b67b-bf8b01975c4c"

# Candidate regions that historically expose NO availability zones. The script
# does not trust this list: it verifies zone counts live against ARM and only
# falls back to the list when running offline.
ZONELESS_CANDIDATES="westus northcentralus westcentralus canadaeast"

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
C_CYA=$'\033[36m'; C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
[[ -t 1 ]] || { C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_BLD=""; C_OFF=""; }

hr()   { printf '%s\n' "-----------------------------------------------------------------------------"; }
say()  { printf '%s\n' "$*"; }
info() { printf '%s[i]%s %s\n' "$C_CYA" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
bad()  { printf '%s[-]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()  { bad "$*"; exit 1; }

# Every az invocation in the lab goes through this wrapper, so the isolated
# configuration directory can never be forgotten.
az_lab() { AZURE_CONFIG_DIR="$LAB_CFG" az "$@"; }

require_az() {
  command -v az >/dev/null 2>&1 || die \
    "Azure CLI not found. Install it first:
       curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash          # Debian/Ubuntu
       sudo dnf install -y azure-cli                                   # Fedora/RHEL
     Docs: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
}

# cloud = authenticated against a real subscription; offline = CLI present but
# no usable token. Offline still runs, with a reduced (honestly labelled) scope.
detect_mode() {
  if az_lab account show >/dev/null 2>&1; then echo cloud; else echo offline; fi
}

subscription_id()   { az_lab account show --query id            -o tsv 2>/dev/null; }
subscription_name() { az_lab account show --query name          -o tsv 2>/dev/null; }
tenant_id()         { az_lab account show --query tenantId      -o tsv 2>/dev/null; }

# Number of availability zones ARM advertises for a region. 0 means the region
# is single-zone: any "zones:[...]" property is illegal there.
region_zone_count() {
  local region="$1" n
  n=$(az_lab account list-locations \
        --query "length([?name=='${region}'].availabilityZoneMappings[])" \
        -o tsv 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

region_exists() {
  local region="$1"
  [[ -n "$(az_lab account list-locations --query "[?name=='${region}'].name" -o tsv 2>/dev/null)" ]]
}

confirm_gate() {
  local mode="$1"
  hr
  printf '%sDISPOSABLE LAB VM CHECK%s\n' "$C_BLD" "$C_OFF"
  hr
  if [[ "$mode" == cloud ]]; then
    say "Subscription : $(subscription_name)"
    say "Id           : $(subscription_id)"
    say "Tenant       : $(tenant_id)"
    say ""
    say "This lab will CREATE, in that subscription:"
    say "  - resource group ${LAB_RG}          (free)"
    say "  - a ReadOnly management lock on it   (free)"
    say "  - policy assignment ${LAB_POLICY_ASSIGNMENT} (free)"
    say "It will NOT create any billable resource."
  else
    warn "No Azure session in the isolated config dir -> OFFLINE mode."
    say  "Offline mode breaks and grades only what lives on this VM:"
    say  "  the CLI defaults and the ARM template scope."
  fi
  say ""
  if [[ "${AZ900_LAB_ASSUME_YES:-}" == "1" ]]; then
    warn "AZ900_LAB_ASSUME_YES=1 -> skipping the interactive gate."
    return 0
  fi
  read -r -p "Type BREAK-MY-LAB to continue: " answer
  [[ "$answer" == "BREAK-MY-LAB" ]] || die "Aborted. Nothing was changed."
}

# -----------------------------------------------------------------------------
# Lab scaffolding
# -----------------------------------------------------------------------------
bootstrap_lab_dir() {
  mkdir -p "$LAB_CFG" || die "cannot create ${LAB_CFG}"
  chmod 700 "$LAB_DIR" "$LAB_CFG"

  # Reuse the existing session so the student is not forced to log in twice.
  # This copies token material into the lab dir - acceptable ONLY because this
  # is a disposable VM. 'restore' deletes it.
  local f
  for f in azureProfile.json msal_token_cache.json service_principal_entries.json; do
    [[ -f "${HOME}/.azure/${f}" && ! -f "${LAB_CFG}/${f}" ]] && \
      cp -p "${HOME}/.azure/${f}" "${LAB_CFG}/${f}"
  done
  chmod -R go-rwx "$LAB_CFG" 2>/dev/null

  cat >"$LAB_ENV" <<EOF
# Source this in every shell you use for the lab:
#   source ${LAB_ENV}
# It keeps the broken CLI state inside the lab and out of your real ~/.azure
export AZURE_CONFIG_DIR="${LAB_CFG}"
EOF
}

# The template ships BROKEN: it declares the SUBSCRIPTION deployment schema
# while its only resource (an NSG) is a resource-group-scoped resource, and it
# calls resourceGroup(), a function that does not exist at subscription scope.
write_broken_template() {
  cat >"$LAB_TEMPLATE" <<'JSON'
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "metadata": {
    "comments": "AZ-900 topic 2.1 lab. One free NSG, deployed to prove the control plane, the scope and the region are all correct."
  },
  "parameters": {
    "location": {
      "type": "string",
      "defaultValue": "[resourceGroup().location]",
      "metadata": {
        "description": "Region the NSG is created in. NOT necessarily the resource group's own metadata location."
      }
    },
    "nsgName": {
      "type": "string",
      "defaultValue": "nsg-az900-lab21"
    }
  },
  "resources": [
    {
      "type": "Microsoft.Network/networkSecurityGroups",
      "apiVersion": "2023-11-01",
      "name": "[parameters('nsgName')]",
      "location": "[parameters('location')]",
      "tags": {
        "az900-lab": "2.1"
      },
      "properties": {
        "securityRules": []
      }
    }
  ],
  "outputs": {
    "nsgResourceId": {
      "type": "string",
      "value": "[resourceId('Microsoft.Network/networkSecurityGroups', parameters('nsgName'))]"
    },
    "nsgLocation": {
      "type": "string",
      "value": "[parameters('location')]"
    }
  }
}
JSON
}

pick_zoneless_region() {
  local r
  for r in $ZONELESS_CANDIDATES; do
    if region_exists "$r" && [[ "$(region_zone_count "$r")" == "0" ]]; then
      printf '%s' "$r"; return 0
    fi
  done
  # Last resort: ask ARM for any region with no zone mappings.
  r=$(az_lab account list-locations \
        --query "[?metadata.regionType=='Physical' && length(availabilityZoneMappings || \`[]\`)==\`0\`].name | [0]" \
        -o tsv 2>/dev/null)
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  printf 'westus'
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
cmd_break() {
  require_az
  bootstrap_lab_dir
  local mode; mode="$(detect_mode)"
  confirm_gate "$mode"

  write_broken_template
  local zoneless="westus"

  # ---- FAULT 1: poisoned ARM defaults ------------------------------------
  # az stores defaults in $AZURE_CONFIG_DIR/config. 'westus5' is not a region
  # that exists; 'rg-az900-ghost' is a resource group that was never created.
  az_lab configure --defaults location=westus5 group=rg-az900-ghost >/dev/null 2>&1
  ok "FAULT 1 applied: CLI defaults now point at a non-existent region and a non-existent resource group."

  # ---- FAULT 2: template written for the wrong deployment scope ------------
  ok "FAULT 2 applied: ${LAB_TEMPLATE} declares the subscription-scope schema for a resource-group-scoped resource."

  if [[ "$mode" == cloud ]]; then
    zoneless="$(pick_zoneless_region)"

    # ---- FAULT 3: the group itself lands in a region with zero zones ------
    az_lab group create --name "$LAB_RG" --location "$zoneless" \
      --tags "${LAB_TAG_KEY}=${LAB_TAG_VALUE}" >/dev/null 2>&1 \
      && ok "FAULT 3 applied: resource group ${LAB_RG} created in ${zoneless} (0 availability zones)." \
      || warn "Could not create ${LAB_RG}. Do you have Contributor on this subscription?"

    # ---- FAULT 4: an inherited policy pins the allowed region -------------
    # Assigned AT THE RESOURCE GROUP SCOPE: it applies to every resource
    # created inside the group, forever, no matter who deploys it.
    az_lab policy assignment create \
      --name "$LAB_POLICY_ASSIGNMENT" \
      --display-name "AZ-900 lab 2.1 - allowed locations" \
      --scope "/subscriptions/$(subscription_id)/resourceGroups/${LAB_RG}" \
      --policy "$ALLOWED_LOCATIONS_POLICY" \
      --params "{\"listOfAllowedLocations\":{\"value\":[\"${zoneless}\"]}}" >/dev/null 2>&1 \
      && ok "FAULT 4 applied: policy assignment ${LAB_POLICY_ASSIGNMENT} restricts resources to ${zoneless} only." \
      || warn "Policy assignment failed (needs Owner or Resource Policy Contributor). Fault 4 skipped."

    # ---- FAULT 5: a ReadOnly lock on the group ----------------------------
    az_lab lock create --name "$LAB_LOCK" --lock-type ReadOnly \
      --resource-group "$LAB_RG" \
      --notes "AZ-900 lab 2.1 - remove me" >/dev/null 2>&1 \
      && ok "FAULT 5 applied: ReadOnly management lock ${LAB_LOCK} on ${LAB_RG}." \
      || warn "Lock creation failed (needs Microsoft.Authorization/locks/write). Fault 5 skipped."
  fi

  cat >"$LAB_STATE" <<EOF
LAB_MODE=${mode}
LAB_BROKEN_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LAB_ZONELESS_REGION=${zoneless}
EOF

  print_mission "$mode" "$zoneless"
}

print_mission() {
  local mode="$1" zoneless="$2"
  say ""
  hr
  printf '%sTHE SCENARIO%s\n' "$C_BLD" "$C_OFF"
  hr
  cat <<EOF
You inherited a landing zone. The previous platform engineer left one week ago,
left one template behind, and left no notes. The workload owner has a single
non-negotiable requirement written in the design document:

    "The workload must be deployed into an Azure region that offers at least
     three availability zones, through the Azure Resource Manager control
     plane, using the supplied template, into the platform's resource group."

Nothing deploys. Your job is to find out why - five separate times.

EOF
  hr
  printf '%sSYMPTOMS YOU WILL SEE%s\n' "$C_BLD" "$C_OFF"
  hr
  cat <<EOF
Run this first and watch it fail:

  source ${LAB_ENV}
  az group show

  (ResourceGroupNotFound) Resource group 'rg-az900-ghost' could not be found.

Then, in the order you will hit them:

  1. Every command that omits --resource-group / --location silently targets
     the wrong thing. 'az group show' resolves a group that does not exist,
     and 'az group create' rejects the default region:
       (LocationNotAvailableForResourceGroup) The provided location 'westus5'
       is not available for resource group. List of available regions is ...

  2. The template is refused before any resource is touched:
       (InvalidTemplate) Deployment template validation failed: the template
       schema / the 'resourceGroup' function is not valid at this scope.
     (exact wording varies with the CLI version - the meaning does not)

  3. The deployment is accepted syntactically and then denied by governance:
       (RequestDisallowedByPolicy) Resource 'nsg-az900-lab21' was disallowed
       by policy. Policy identifiers: '[{"policyAssignment":{"name":
       "${LAB_POLICY_ASSIGNMENT}" ...
     Read that message carefully: it names the ASSIGNMENT and the SCOPE it was
     attached to. That scope is where the fix lives.

  4. Once policy stops complaining, the write itself is refused:
       (ScopeLocked) The scope '/subscriptions/<sub>/resourceGroups/${LAB_RG}'
       cannot perform write operation because following scope(s) are locked.
       Please remove the lock and try again.

  5. Even when it finally deploys, it may deploy into a region with ZERO
     availability zones, which fails the design requirement without producing
     any error at all. Silence is the hardest symptom in this lab.

EOF
  hr
  printf '%sYOUR MISSION - what "fixed" means%s\n' "$C_BLD" "$C_OFF"
  hr
  if [[ "$mode" == cloud ]]; then
    cat <<EOF
  [ ] The CLI defaults resolve to a REAL region and to ${LAB_RG}.
  [ ] ${LAB_TEMPLATE} validates cleanly as a RESOURCE GROUP deployment.
  [ ] The NSG ${LAB_NSG} exists inside ${LAB_RG}.
  [ ] The NSG's own location is a region with >= 3 availability zones.
  [ ] You can explain, in one sentence, why you did or did not have to move
      the resource group itself. (The lab created it in ${zoneless}, which has
      zero zones. Read the hint before you delete anything.)

Bonus - the difference between a junior and a platform engineer:
  the policy assignment is a control, not an obstacle. Deleting it makes the
  deployment work. AMENDING it to allow the correct region also makes the
  deployment work, and keeps the guardrail. 'verify' accepts both and tells
  you which one you chose.
EOF
  else
    cat <<EOF
  [ ] The CLI defaults resolve to a REAL region and to ${LAB_RG}.
  [ ] ${LAB_TEMPLATE} declares the resource-group deployment schema and uses
      no function that is illegal at that scope.

  OFFLINE MODE: no Azure session was found, so the lab cannot create or grade
  anything on the Azure side. Everything above is graded locally and honestly;
  the region/zone/policy/lock half of the exercise needs 'az login' first.
EOF
  fi
  say ""
  info "Grade yourself : $0 verify"
  info "Stuck          : $0 hint 1   (five hints, increasing in bluntness)"
  info "Burn it down   : $0 restore"
}

# -----------------------------------------------------------------------------
# STATUS
# -----------------------------------------------------------------------------
cmd_status() {
  require_az
  [[ -d "$LAB_DIR" ]] || die "No lab found at ${LAB_DIR}. Run: $0 break"
  local mode; mode="$(detect_mode)"
  hr; printf '%sLAB STATE%s\n' "$C_BLD" "$C_OFF"; hr
  say "mode              : ${mode}"
  say "config dir        : ${LAB_CFG}"
  say "CLI defaults      :"
  az_lab configure --list-defaults -o tsv 2>/dev/null | sed 's/^/                    /'
  [[ "$mode" == cloud ]] || return 0
  say "subscription      : $(subscription_name) ($(subscription_id))"
  local rgloc
  rgloc=$(az_lab group show -n "$LAB_RG" --query location -o tsv 2>/dev/null)
  say "${LAB_RG} location : ${rgloc:-<absent>}  (zones: $( [[ -n "$rgloc" ]] && region_zone_count "$rgloc" || echo n/a ))"
  say "locks             : $(az_lab lock list -g "$LAB_RG" --query "[].{n:name,t:level}" -o tsv 2>/dev/null | tr '\n' ' ')"
  say "policy assignment : $(az_lab policy assignment list --scope "/subscriptions/$(subscription_id)/resourceGroups/${LAB_RG}" --query "[].name" -o tsv 2>/dev/null | tr '\n' ' ')"
  local nsgloc
  nsgloc=$(az_lab network nsg show -g "$LAB_RG" -n "$LAB_NSG" --query location -o tsv 2>/dev/null)
  say "${LAB_NSG}        : ${nsgloc:-<not deployed>}"
}

# -----------------------------------------------------------------------------
# VERIFY - the exit gate
# -----------------------------------------------------------------------------
PASS=0; FAIL=0
check_pass() { ok  "PASS  $*"; PASS=$((PASS+1)); }
check_fail() { bad "FAIL  $*"; FAIL=$((FAIL+1)); }

cmd_verify() {
  require_az
  [[ -d "$LAB_DIR" ]] || die "No lab found at ${LAB_DIR}. Run: $0 break"
  local mode; mode="$(detect_mode)"
  hr; printf '%sVERIFICATION%s\n' "$C_BLD" "$C_OFF"; hr

  # --- 1. CLI defaults -----------------------------------------------------
  local def_group def_loc
  def_group=$(az_lab configure --list-defaults --query "[?name=='group'].value" -o tsv 2>/dev/null)
  def_loc=$(az_lab   configure --list-defaults --query "[?name=='location'].value" -o tsv 2>/dev/null)
  [[ "$def_group" == "$LAB_RG" ]] \
    && check_pass "CLI default resource group is ${LAB_RG}" \
    || check_fail "CLI default resource group is '${def_group:-<unset>}', expected ${LAB_RG}"

  if [[ "$mode" == cloud ]]; then
    if [[ -n "$def_loc" ]] && region_exists "$def_loc"; then
      check_pass "CLI default location '${def_loc}' is a real Azure region"
    else
      check_fail "CLI default location '${def_loc:-<unset>}' is not a region ARM knows about"
    fi
  else
    [[ -n "$def_loc" && "$def_loc" != "westus5" ]] \
      && check_pass "CLI default location changed away from the bogus 'westus5' (cannot validate offline)" \
      || check_fail "CLI default location is still '${def_loc:-<unset>}'"
  fi

  # --- 2. template scope ---------------------------------------------------
  local schema
  schema=$(grep -o 'deploymentTemplate\.json\|subscriptionDeploymentTemplate\.json' "$LAB_TEMPLATE" 2>/dev/null | head -n1)
  [[ "$schema" == "deploymentTemplate.json" ]] \
    && check_pass "template declares the resource-group deployment schema" \
    || check_fail "template still declares '${schema:-<none>}' - an NSG cannot be deployed at subscription scope"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open('$LAB_TEMPLATE'))" 2>/dev/null \
      && check_pass "template is syntactically valid JSON" \
      || check_fail "template is not valid JSON any more"
  fi

  if [[ "$mode" != cloud ]]; then
    verdict; return
  fi

  # --- 3. ARM-side validation ---------------------------------------------
  if az_lab deployment group validate -g "$LAB_RG" -f "$LAB_TEMPLATE" \
       --parameters "location=${def_loc}" -o none 2>/dev/null; then
    check_pass "'az deployment group validate' is accepted by ARM (template + policy + scope all agree)"
  else
    check_fail "'az deployment group validate' still fails - run it by hand and read the error code"
  fi

  # --- 4. the resource actually exists, in a zone-capable region -----------
  local nsgloc zones
  nsgloc=$(az_lab network nsg show -g "$LAB_RG" -n "$LAB_NSG" --query location -o tsv 2>/dev/null)
  if [[ -n "$nsgloc" ]]; then
    check_pass "${LAB_NSG} exists in ${LAB_RG} (the ReadOnly lock is no longer blocking writes)"
    zones=$(region_zone_count "$nsgloc")
    [[ "$zones" -ge 3 ]] \
      && check_pass "${LAB_NSG} lives in ${nsgloc}, which advertises ${zones} availability zones" \
      || check_fail "${LAB_NSG} lives in ${nsgloc}, which advertises ${zones} availability zones - the design requires >= 3"
  else
    check_fail "${LAB_NSG} was never deployed into ${LAB_RG}"
  fi

  # --- 5. how the governance control was handled ---------------------------
  local pa
  pa=$(az_lab policy assignment list \
        --scope "/subscriptions/$(subscription_id)/resourceGroups/${LAB_RG}" \
        --query "[?name=='${LAB_POLICY_ASSIGNMENT}'].name" -o tsv 2>/dev/null)
  if [[ -n "$pa" ]]; then
    info "BONUS: you kept the policy assignment and amended it. That is the platform-engineer answer."
  else
    info "NOTE: you removed the policy assignment. It works, but in a real landing zone you would have amended listOfAllowedLocations instead."
  fi

  # --- 6. the conceptual trap ---------------------------------------------
  local rgloc
  rgloc=$(az_lab group show -n "$LAB_RG" --query location -o tsv 2>/dev/null)
  if [[ -n "$rgloc" && "$(region_zone_count "$rgloc")" == "0" && -n "$nsgloc" ]]; then
    info "You left ${LAB_RG} in ${rgloc} (0 zones) and still passed. Correct: a resource group's location is metadata about the group record, not a constraint on the resources inside it."
  fi

  verdict
}

verdict() {
  hr
  if [[ "$FAIL" -eq 0 ]]; then
    printf '%sLAB PASSED%s  (%d checks)\n' "$C_GRN$C_BLD" "$C_OFF" "$PASS"
    say "Write down, in your own words, the four different layers that rejected"
    say "your deployment and which scope each one was attached to. That mapping"
    say "IS topic 2.1."
    hr; exit 0
  fi
  printf '%s%d passed, %d failed%s\n' "$C_YEL" "$PASS" "$FAIL" "$C_OFF"
  say "Next hint: $0 hint"
  hr; exit 1
}

# -----------------------------------------------------------------------------
# HINTS
# -----------------------------------------------------------------------------
cmd_hint() {
  local n="${1:-1}"
  case "$n" in
    1) cat <<'EOF'
HINT 1 - stop guessing what the CLI is doing on your behalf.
  Every az command that does not carry --resource-group / --location inherits a
  default from the CLI configuration file. Find them:
      az configure --list-defaults -o table
  Ask yourself where that file physically is (echo $AZURE_CONFIG_DIR).
  Docs: https://learn.microsoft.com/en-us/cli/azure/azure-cli-configuration
EOF
;;
    2) cat <<'EOF'
HINT 2 - a region name is not a free-text field.
  ARM publishes the exact list, per subscription, along with each region's
  availability-zone mapping:
      az account list-locations --query "[].name" -o tsv | sort
      az account list-locations \
        --query "[?length(availabilityZoneMappings || \`[]\`) >= \`3\`].name" -o tsv
  A region with no zones cannot host a zonal deployment - there is nothing to
  spread across. https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview
EOF
;;
    3) cat <<'EOF'
HINT 3 - a template is written for exactly ONE deployment scope.
  The $schema line is the declaration:
    ...schemas/2019-04-01/deploymentTemplate.json#              -> resource group
    ...schemas/2018-05-01/subscriptionDeploymentTemplate.json#  -> subscription
    ...schemas/2019-08-01/managementGroupDeploymentTemplate.json# -> management group
  An NSG is a resource-group-scoped resource, and resourceGroup() only exists
  in a resource-group deployment. Compare what your file says with what it does.
  https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-to-resource-group
EOF
;;
    4) cat <<'EOF'
HINT 4 - read the rejection, it tells you the scope.
  RequestDisallowedByPolicy names the policy ASSIGNMENT. List it and read the
  parameters you are being held to:
      az policy assignment list --scope "/subscriptions/<sub>/resourceGroups/rg-az900-lab21" -o table
      az policy assignment show  --name az900-allowed-locations \
        --scope "/subscriptions/<sub>/resourceGroups/rg-az900-lab21" \
        --query parameters
  ScopeLocked names the locked scope:
      az lock list -g rg-az900-lab21 -o table
  Both were attached ABOVE the resource, and both flowed down to it. That is
  the whole point of the management group > subscription > group > resource
  hierarchy. https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
EOF
;;
    5) cat <<'EOF'
HINT 5 - the trap you are about to fall into.
  You are probably about to delete and recreate the resource group so that its
  location has zones. You do not have to, and doing it for that reason means
  you have the model wrong.
  A resource group's location only records where the GROUP'S OWN metadata is
  stored. The resources inside it are each stamped with their own location and
  may live in completely different regions. Deploy the NSG with an explicit
  location parameter pointing at a zone-capable region and leave the group
  where it is.
  https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview#resource-groups
EOF
;;
    *) warn "Hints run from 1 to 5.";;
  esac
}

# -----------------------------------------------------------------------------
# RESTORE
# -----------------------------------------------------------------------------
cmd_restore() {
  require_az
  [[ -d "$LAB_DIR" ]] || die "Nothing to restore: ${LAB_DIR} does not exist."
  local mode; mode="$(detect_mode)"

  if [[ "$mode" == cloud ]]; then
    local tag
    tag=$(az_lab group show -n "$LAB_RG" --query "tags.\"${LAB_TAG_KEY}\"" -o tsv 2>/dev/null)
    if [[ "$tag" == "$LAB_TAG_VALUE" ]]; then
      if [[ "${AZ900_LAB_ASSUME_YES:-}" != "1" ]]; then
        read -r -p "Delete resource group ${LAB_RG} and everything in it? [yes/NO] " a
        [[ "$a" == "yes" ]] || die "Aborted."
      fi
      az_lab lock delete --name "$LAB_LOCK" -g "$LAB_RG" >/dev/null 2>&1
      az_lab policy assignment delete --name "$LAB_POLICY_ASSIGNMENT" \
        --scope "/subscriptions/$(subscription_id)/resourceGroups/${LAB_RG}" >/dev/null 2>&1
      az_lab group delete --name "$LAB_RG" --yes --no-wait >/dev/null 2>&1 \
        && ok "Deletion of ${LAB_RG} submitted (asynchronous)."
    elif [[ -n "$tag" || -n "$(az_lab group exists -n "$LAB_RG" 2>/dev/null | grep -i true)" ]]; then
      warn "${LAB_RG} exists but is NOT tagged ${LAB_TAG_KEY}=${LAB_TAG_VALUE}. Refusing to delete it."
    else
      info "${LAB_RG} not present, nothing to delete in Azure."
    fi
  fi

  rm -rf -- "$LAB_DIR" && ok "Removed ${LAB_DIR} (including the isolated CLI config)."
  info "Your real ~/.azure was never modified by this lab."
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-help}" in
  break)   cmd_break ;;
  status)  cmd_status ;;
  verify)  cmd_verify ;;
  hint)    cmd_hint "${2:-1}" ;;
  restore) cmd_restore ;;
  help|-h|--help) usage ;;
  *) die "Unknown command '${1}'. Try: break | status | verify | hint | restore" ;;
esac

# =============================================================================
#  SOLUTION - do not read until you have spent real time on 'hint 5'
# =============================================================================
#
#  STEP 0 - enter the lab shell
#  ---------------------------------------------------------------------------
#    source ~/az900-lab-2.1/env.sh
#    echo "$AZURE_CONFIG_DIR"
#      /home/<user>/az900-lab-2.1/azure-config
#
#    Everything below is scoped to that directory. Nothing you break here can
#    reach your real ~/.azure.
#
#
#  STEP 1 - find and repair the CLI defaults          (FAULT 1)
#  ---------------------------------------------------------------------------
#    az configure --list-defaults -o table
#      Name      Source                                          Value
#      --------  ----------------------------------------------  -----------------
#      group     /home/<user>/az900-lab-2.1/azure-config/config  rg-az900-ghost
#      location  /home/<user>/az900-lab-2.1/azure-config/config  westus5
#
#    Prove that 'westus5' is fiction and pick a region that satisfies the
#    design requirement (>= 3 availability zones):
#
#    az account list-locations \
#      --query "[?length(availabilityZoneMappings || \`[]\`) >= \`3\`].{region:name, zones:length(availabilityZoneMappings)}" \
#      -o table
#      Region        Zones
#      ------------  -------
#      eastus        3
#      eastus2       3
#      westus2       3
#      westus3       3
#      northeurope   3
#      westeurope    3
#      ...
#
#    Pick one - eastus2 in this walkthrough - and set the defaults honestly:
#
#    az configure --defaults group=rg-az900-lab21 location=eastus2
#    az group show -o table
#      Location    Name
#      ----------  ---------------
#      westus      rg-az900-lab21
#
#    Note what just happened: the group resolves now, and its location is
#    'westus' (0 zones) while your default deployment location is 'eastus2'.
#    Those two facts are allowed to disagree. See STEP 5.
#
#
#  STEP 2 - fix the deployment scope of the template  (FAULT 2)
#  ---------------------------------------------------------------------------
#    az deployment group validate -g rg-az900-lab21 -f ~/az900-lab-2.1/azuredeploy.json
#      ERROR: (InvalidTemplate) Deployment template validation failed:
#      'The template function 'resourceGroup' is not expected at this location.'
#
#    The file declares a SUBSCRIPTION deployment but contains a resource-group
#    resource. Swap the schema:
#
#    sed -i 's#2018-05-01/subscriptionDeploymentTemplate.json#2019-04-01/deploymentTemplate.json#' \
#      ~/az900-lab-2.1/azuredeploy.json
#
#    grep '"\$schema"' ~/az900-lab-2.1/azuredeploy.json
#      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
#
#    The scope table, worth memorising for the exam:
#      resource group    deploymentTemplate.json                 az deployment group create
#      subscription      subscriptionDeploymentTemplate.json     az deployment sub create
#      management group  managementGroupDeploymentTemplate.json  az deployment mg create
#      tenant            tenantDeploymentTemplate.json           az deployment tenant create
#
#
#  STEP 3 - deal with the inherited policy            (FAULT 4)
#  ---------------------------------------------------------------------------
#    az deployment group validate -g rg-az900-lab21 \
#      -f ~/az900-lab-2.1/azuredeploy.json --parameters location=eastus2
#      ERROR: (RequestDisallowedByPolicy) Resource 'nsg-az900-lab21' was
#      disallowed by policy. Policy identifiers: '[{"policyAssignment":
#      {"name":"az900-allowed-locations", ... "policyDefinition":
#      {"name":"Allowed locations" ...
#
#    Find where the rule is attached and what it allows:
#
#    SUB=$(az account show --query id -o tsv)
#    RGSCOPE="/subscriptions/$SUB/resourceGroups/rg-az900-lab21"
#
#    az policy assignment list --scope "$RGSCOPE" -o table
#      Name                     DisplayName                          Scope
#      -----------------------  -----------------------------------  ----------------
#      az900-allowed-locations  AZ-900 lab 2.1 - allowed locations   .../rg-az900-lab21
#
#    az policy assignment show --name az900-allowed-locations --scope "$RGSCOPE" \
#      --query parameters
#      { "listOfAllowedLocations": { "value": [ "westus" ] } }
#
#    THE PLATFORM-ENGINEER FIX - keep the guardrail, widen it deliberately:
#
#    az policy assignment update --name az900-allowed-locations --scope "$RGSCOPE" \
#      --params '{"listOfAllowedLocations":{"value":["westus","eastus2"]}}'
#
#    (If your CLI version has no 'update' for assignments, delete and recreate
#     with the corrected parameters - same result, same scope:
#       az policy assignment delete --name az900-allowed-locations --scope "$RGSCOPE"
#       az policy assignment create --name az900-allowed-locations --scope "$RGSCOPE" \
#         --policy e56962a6-4747-49cd-b67b-bf8b01975c4c \
#         --params '{"listOfAllowedLocations":{"value":["westus","eastus2"]}}' )
#
#    The blunt fix - 'az policy assignment delete' - also unblocks you and is
#    the wrong instinct in a landing zone: you removed a control instead of
#    complying with it.
#
#
#  STEP 4 - remove the management lock                (FAULT 5)
#  ---------------------------------------------------------------------------
#    az deployment group create -g rg-az900-lab21 --name az900-21 \
#      -f ~/az900-lab-2.1/azuredeploy.json --parameters location=eastus2
#      ERROR: (ScopeLocked) The scope '/subscriptions/<sub>/resourceGroups/
#      rg-az900-lab21' cannot perform write operation because following
#      scope(s) are locked: '.../rg-az900-lab21'. Please remove the lock and
#      try again.
#
#    az lock list -g rg-az900-lab21 -o table
#      Name              Level     Notes
#      ----------------  --------  ----------------------------
#      lock-az900-lab21  ReadOnly  AZ-900 lab 2.1 - remove me
#
#    az lock delete --name lock-az900-lab21 -g rg-az900-lab21
#
#    Lock semantics for the exam: CanNotDelete allows reads and writes but
#    blocks deletion; ReadOnly blocks every write, which is stricter than the
#    Reader role and is why it broke a create. Locks are inherited by every
#    child scope and are evaluated independently from RBAC - Owner does not
#    bypass a lock, you must delete the lock first.
#
#
#  STEP 5 - deploy, and answer the conceptual question   (FAULT 3)
#  ---------------------------------------------------------------------------
#    az deployment group create -g rg-az900-lab21 --name az900-21 \
#      -f ~/az900-lab-2.1/azuredeploy.json --parameters location=eastus2 \
#      --query "{state:properties.provisioningState, nsg:properties.outputs.nsgLocation.value}" -o table
#      State      Nsg
#      ---------  -------
#      Succeeded  eastus2
#
#    az network nsg show -g rg-az900-lab21 -n nsg-az900-lab21 \
#      --query "{name:name, resourceLocation:location}" -o table
#      Name             ResourceLocation
#      ---------------  ------------------
#      nsg-az900-lab21  eastus2
#
#    az group show -n rg-az900-lab21 --query "{group:name, metadataLocation:location}" -o table
#      Group            MetadataLocation
#      ---------------  ------------------
#      rg-az900-lab21   westus
#
#    THE ANSWER: the resource group stays in 'westus' and that is correct.
#    A resource group's location is where Azure stores the group's own metadata
#    record (and it matters only for the availability of that metadata during a
#    regional outage). It does not constrain, and is not inherited by, the
#    resources inside the group. The workload's region is the location stamped
#    on each resource - here, eastus2, which advertises three availability
#    zones. Deleting and recreating the group to "move it" would have been
#    wasted work built on a misunderstanding.
#
#    Confirm the zone claim rather than trusting it:
#      az account list-locations \
#        --query "[?name=='eastus2'].availabilityZoneMappings[].logicalZone" -o tsv
#        1
#        2
#        3
#    Remember that logical zone 1 in YOUR subscription is not necessarily the
#    same physical datacenter as logical zone 1 in someone else's - the mapping
#    is per-subscription by design, so that Azure can balance load across the
#    physical zones. The 'physicalZone' field in the same output is what
#    actually identifies the datacenter set.
#
#
#  STEP 6 - grade and clean up
#  ---------------------------------------------------------------------------
#    ./az900-2.1-breakfix.sh verify
#    ./az900-2.1-breakfix.sh restore
#
#
#  WHAT THE FIVE FAULTS MAP TO ON THE EXAM
#  ---------------------------------------------------------------------------
#    FAULT 1  client-side defaults          -> a "subscription/resource group
#                                              context" question in disguise
#    FAULT 2  template $schema              -> deployment scope: group, sub,
#                                              management group, tenant
#    FAULT 3  zoneless region + RG location -> regions, region pairs,
#                                              availability zones, and the
#                                              metadata-vs-resource location
#                                              distinction
#    FAULT 4  policy assignment at RG scope -> inheritance down the management
#                                              group > subscription > RG >
#                                              resource hierarchy
#    FAULT 5  ReadOnly lock                 -> control-plane protection that is
#                                              independent of RBAC
#
#    All five failed at the SAME place: the Azure Resource Manager control
#    plane, before any workload existed. That is the single sentence that ties
#    topic 2.1 together - ARM is the one door, and every scope above the
#    resource gets a vote on what comes through it.
# =============================================================================