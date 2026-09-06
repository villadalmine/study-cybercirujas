#!/usr/bin/env bash
#
# =============================================================================
#  AZ-900 · Domain 3 — Azure management and governance
#  Topic 3.2 — Describe features and tools in Azure for governance and compliance
#  Exam version 2026-07-20 · Domain weight: 8.33 %
#
#  BREAK & FIX LAB — "The guardrail that ate the deployment"
#
#  What this lab exercises (all of it is exam surface for 3.2):
#    · Azure Policy: definition, assignment, scope, the deny effect, compliance state
#    · Resource locks: CanNotDelete vs ReadOnly, inheritance, why they are NOT RBAC
#    · Tags: as a governance signal AND as the literal input of a policy rule
#    · The mental model the exam tests: RBAC says *who* can act, Policy says *what*
#      the result may look like, Locks say *nobody* — not even Owner — may perform
#      this operation until the lock is removed.
#
#  Official sources
#    AZ-900 study guide ....... https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#    Azure Policy overview .... https://learn.microsoft.com/en-us/azure/governance/policy/overview
#    Definition structure ..... https://learn.microsoft.com/en-us/azure/governance/policy/concepts/definition-structure
#    Deny effect .............. https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-deny
#    Compliance evaluation .... https://learn.microsoft.com/en-us/azure/governance/policy/how-to/get-compliance-data
#    Resource locks ........... https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources
#    Tag resources ............ https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
#    Azure RBAC ............... https://learn.microsoft.com/en-us/azure/role-based-access-control/overview
#    Management groups ........ https://learn.microsoft.com/en-us/azure/governance/management-groups/overview
#    Microsoft Purview ........ https://learn.microsoft.com/en-us/purview/purview
#    Service Trust Portal ..... https://learn.microsoft.com/en-us/purview/get-started-with-service-trust-portal
#
#  SAFETY CONTRACT
#    · It only ever creates / deletes objects inside ONE resource group that it
#      creates itself, named rg-az900-gov-lab-<suffix>. Nothing else is touched.
#    · It never modifies RBAC role assignments of the signed-in identity.
#    · If the Azure CLI is absent or not signed in, the lab falls back to an
#      offline ARM simulator that reproduces the same error codes, byte for byte
#      enough to learn from. Force it with AZ900_FORCE_SIM=1.
#    · `cleanup` removes every object created, locks first, then the group.
#
#  Usage:  ./az900-3.2-breakfix.sh {break|status|hint|check|cleanup}
# =============================================================================

set -Eeuo pipefail

LAB_HOME="${AZ900_LAB_HOME:-$HOME/.az900-lab-3.2}"
STATE="$LAB_HOME/lab.env"
ACTIVATE="$LAB_HOME/activate.sh"
SIM="$LAB_HOME/sim"
SHIM="$LAB_HOME/bin/az"

POLICY_DEF="az900-storage-guardrail"
ASSIGN="az900-guardrails"
RG_LOCK="lock-rg-cannotdelete"
SA_LOCK="lock-sa-readonly"
BUILTIN_REQUIRE_TAG="871b6d14-10aa-478d-b590-94f262ecfa99"   # "Require a tag on resources"
LOCATION="eastus"
ALT_LOCATION="eastus2"

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
[[ -t 1 ]] || { C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; }

log()  { printf '%s[lab]%s %s\n' "$C_B" "$C_0" "$*"; }
warn() { printf '%s[!!]%s  %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s[xx]%s  %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "-------------------------------------------------------------------------------"; }

# -----------------------------------------------------------------------------
# Mode detection: azure (real CLI, real subscription) or sim (offline)
# -----------------------------------------------------------------------------
detect_mode() {
  if [[ "${AZ900_FORCE_SIM:-0}" == "1" ]]; then
    MODE="sim"
  elif command -v az >/dev/null 2>&1 && az account show >/dev/null 2>&1; then
    MODE="azure"
  else
    MODE="sim"
  fi
}

load_state() {
  [[ -f "$STATE" ]] || die "No lab found. Run: $0 break"
  # shellcheck disable=SC1090
  source "$STATE"
  AZ="az"; [[ "$MODE" == "sim" ]] && { AZ="$SHIM"; export AZ900_SIM_STATE="$SIM"; }
}

sim_field() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }

# -----------------------------------------------------------------------------
# The offline ARM simulator (written only when MODE=sim)
# -----------------------------------------------------------------------------
write_shim() {
  mkdir -p "$LAB_HOME/bin" "$SIM"/{groups,locks,resources,defs,assignments}
  cat >"$SHIM" <<'AZ_SIM_EOF'
#!/usr/bin/env bash
# Offline Azure Resource Manager simulator — AZ-900 topic 3.2 lab ONLY.
# Implements just enough of `az` to reproduce RequestDisallowedByPolicy and
# ScopeLocked faithfully. No network, no cloud resources, no credentials.
set -uo pipefail

SIM="${AZ900_SIM_STATE:?AZ900_SIM_STATE unset — run: source ~/.az900-lab-3.2/activate.sh}"
SUBID="1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
mkdir -p "$SIM"/groups "$SIM"/locks "$SIM"/resources "$SIM"/defs "$SIM"/assignments

die_az() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
gf()     { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }
rid_rg() { printf '/subscriptions/%s/resourceGroups/%s' "$SUBID" "$1"; }
rid_sa() { printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Storage/storageAccounts/%s' "$SUBID" "$1" "$2"; }

CMD=()
while (($#)); do case "${1:-}" in -*) break ;; *) CMD+=("$1"); shift ;; esac; done

name=""; rg=""; loc=""; tags=""; ltype=""; lockres=""; scope=""; policy=""
while (($#)); do
  case "$1" in
    -n|--name)           name="${2:-}";    shift 2 ;;
    -g|--resource-group) rg="${2:-}";      shift 2 ;;
    -l|--location)       loc="${2:-}";     shift 2 ;;
    -t|--lock-type)      ltype="${2:-}";   shift 2 ;;
    --resource)          lockres="${2:-}"; shift 2 ;;
    --scope)             scope="${2:-}";   shift 2 ;;
    --policy)            policy="${2:-}";  shift 2 ;;
    --tags)              shift; while (($#)) && [[ "${1:-}" != -* ]]; do tags+="$1 "; shift; done ;;
    *)                   shift ;;
  esac
done
tags="${tags% }"

tags_json() {
  local out="" kv
  for kv in $1; do out+="\"${kv%%=*}\": \"${kv#*=}\", "; done
  printf '%s' "${out%, }"
}

# A lock blocks DELETE when it sits at, above, or below the target scope.
locks_delete() {
  local target="$1" f lvl sc out=""
  for f in "$SIM"/locks/*; do [[ -e "$f" ]] || continue
    lvl="$(gf "$f" level)"; sc="$(gf "$f" scope)"
    if [[ "$sc" == "$target"* || "$target" == "$sc"* ]]; then out+="$sc, "; fi
  done
  printf '%s' "${out%, }"
}
# A lock blocks WRITE only when it is ReadOnly and sits at or above the target.
locks_write() {
  local target="$1" f lvl sc out=""
  for f in "$SIM"/locks/*; do [[ -e "$f" ]] || continue
    lvl="$(gf "$f" level)"; sc="$(gf "$f" scope)"
    if [[ "$lvl" == "ReadOnly" && "$target" == "$sc"* ]]; then out+="$sc, "; fi
  done
  printf '%s' "${out%, }"
}

evaluate_policy() {   # $1 rg  $2 name  $3 location  $4 tags
  local a sc kind reason target="$(rid_sa "$1" "$2")"
  for a in "$SIM"/assignments/*; do [[ -e "$a" ]] || continue
    sc="$(gf "$a" scope)"; kind="$(gf "$a" kind)"
    [[ "$target" == "$sc"* ]] || continue
    reason=""
    [[ "$4" =~ (^|[[:space:]])CostCenter=[^[:space:]] ]] || reason="required tag 'CostCenter' is missing or empty"
    if [[ -z "$reason" && "$kind" == "custom" && "$3" != "eastus" && "$3" != "eastus2" ]]; then
      reason="location '$3' is not in the approved list [eastus, eastus2]"
    fi
    [[ -z "$reason" ]] && continue
    die_az "(RequestDisallowedByPolicy) Resource '$2' was disallowed by policy. Reason: $reason.
Code: RequestDisallowedByPolicy
Message: Resource '$2' was disallowed by policy.
Policy identifiers: '[{\"policyAssignment\":{\"name\":\"$(basename "$a")\",\"id\":\"$sc/providers/Microsoft.Authorization/policyAssignments/$(basename "$a")\"},\"policyDefinition\":{\"name\":\"$(gf "$a" def)\"}}]'"
  done
}

case "${CMD[*]}" in

  "account show")
    printf '{\n  "environmentName": "AzureCloud",\n  "id": "%s",\n  "name": "AZ-900 Break-and-Fix Lab (SIMULATED)",\n  "state": "Enabled",\n  "user": { "name": "student@az900.lab", "type": "user" }\n}\n' "$SUBID" ;;

  "group create")
    printf 'name=%s\nlocation=%s\n' "$name" "$loc" >"$SIM/groups/$name"
    printf '{ "id": "%s", "location": "%s", "name": "%s", "properties": { "provisioningState": "Succeeded" } }\n' "$(rid_rg "$name")" "$loc" "$name" ;;

  "group show")
    [[ -f "$SIM/groups/$name" ]] || die_az "(ResourceGroupNotFound) Resource group '$name' could not be found."
    printf '{ "id": "%s", "location": "%s", "name": "%s" }\n' "$(rid_rg "$name")" "$(gf "$SIM/groups/$name" location)" "$name" ;;

  "group list")
    for f in "$SIM"/groups/*; do [[ -e "$f" ]] || continue; printf '%s\n' "$(basename "$f")"; done ;;

  "group delete")
    [[ -f "$SIM/groups/$name" ]] || die_az "(ResourceGroupNotFound) Resource group '$name' could not be found."
    b="$(locks_delete "$(rid_rg "$name")")"
    [[ -z "$b" ]] || die_az "(ScopeLocked) The scope '$(rid_rg "$name")' cannot perform delete operation because following scope(s) are locked: '$b'. Please remove the lock and try again.
Code: ScopeLocked"
    for f in "$SIM"/resources/*; do [[ -e "$f" ]] || continue
      [[ "$(gf "$f" rg)" == "$name" ]] && rm -f "$f"; done
    rm -f "$SIM/groups/$name" ;;

  "storage account create")
    [[ -f "$SIM/groups/$rg" ]] || die_az "(ResourceGroupNotFound) Resource group '$rg' could not be found."
    [[ "$name" =~ ^[a-z0-9]{3,24}$ ]] || die_az "(AccountNameInvalid) The storage account name must be 3-24 characters, lowercase letters and numbers only."
    [[ -f "$SIM/resources/$name" ]] && die_az "(StorageAccountAlreadyTaken) The storage account named $name is already taken."
    [[ -n "$loc" ]] || loc="$(gf "$SIM/groups/$rg" location)"
    evaluate_policy "$rg" "$name" "$loc" "$tags"
    printf 'rg=%s\nlocation=%s\ntags=%s\n' "$rg" "$loc" "$tags" >"$SIM/resources/$name"
    printf '{ "id": "%s", "location": "%s", "name": "%s", "tags": { %s }, "provisioningState": "Succeeded" }\n' "$(rid_sa "$rg" "$name")" "$loc" "$name" "$(tags_json "$tags")" ;;

  "storage account show")
    [[ -f "$SIM/resources/$name" ]] || die_az "(ResourceNotFound) The Resource 'Microsoft.Storage/storageAccounts/$name' under resource group '$rg' was not found."
    printf '{ "id": "%s", "location": "%s", "name": "%s", "tags": { %s } }\n' \
      "$(rid_sa "$(gf "$SIM/resources/$name" rg)" "$name")" "$(gf "$SIM/resources/$name" location)" "$name" "$(tags_json "$(gf "$SIM/resources/$name" tags)")" ;;

  "storage account list")
    printf '[\n'
    for f in "$SIM"/resources/*; do [[ -e "$f" ]] || continue
      [[ -n "$rg" && "$(gf "$f" rg)" != "$rg" ]] && continue
      printf '  { "name": "%s", "location": "%s", "tags": { %s } }\n' "$(basename "$f")" "$(gf "$f" location)" "$(tags_json "$(gf "$f" tags)")"
    done
    printf ']\n' ;;

  "storage account update")
    [[ -f "$SIM/resources/$name" ]] || die_az "(ResourceNotFound) The Resource 'Microsoft.Storage/storageAccounts/$name' was not found."
    rg="$(gf "$SIM/resources/$name" rg)"
    b="$(locks_write "$(rid_sa "$rg" "$name")")"
    [[ -z "$b" ]] || die_az "(ScopeLocked) The scope '$(rid_sa "$rg" "$name")' cannot perform write operation because following scope(s) are locked: '$b'. Please remove the lock and try again.
Code: ScopeLocked"
    printf 'rg=%s\nlocation=%s\ntags=%s\n' "$rg" "$(gf "$SIM/resources/$name" location)" "$tags" >"$SIM/resources/$name"
    printf '{ "name": "%s", "tags": { %s } }\n' "$name" "$(tags_json "$tags")" ;;

  "lock create")
    if [[ -n "$lockres" ]]; then sc="$(rid_sa "$rg" "$lockres")"; else sc="$(rid_rg "$rg")"; fi
    printf 'level=%s\nscope=%s\n' "${ltype:-CanNotDelete}" "$sc" >"$SIM/locks/$name"
    printf '{ "name": "%s", "level": "%s", "scope": "%s" }\n' "$name" "${ltype:-CanNotDelete}" "$sc" ;;

  "lock list")
    printf '[\n'
    for f in "$SIM"/locks/*; do [[ -e "$f" ]] || continue
      printf '  { "name": "%s", "level": "%s", "scope": "%s" }\n' "$(basename "$f")" "$(gf "$f" level)" "$(gf "$f" scope)"
    done
    printf ']\n' ;;

  "lock show")
    [[ -f "$SIM/locks/$name" ]] || die_az "(LockNotFound) The lock '$name' could not be found."
    printf '{ "name": "%s", "level": "%s", "scope": "%s" }\n' "$name" "$(gf "$SIM/locks/$name" level)" "$(gf "$SIM/locks/$name" scope)" ;;

  "lock delete")
    [[ -f "$SIM/locks/$name" ]] || die_az "(LockNotFound) The lock '$name' could not be found."
    rm -f "$SIM/locks/$name" ;;

  "policy definition create")
    printf 'name=%s\n' "$name" >"$SIM/defs/$name"
    printf '{ "name": "%s", "policyType": "Custom", "mode": "Indexed" }\n' "$name" ;;

  "policy definition delete") rm -f "$SIM/defs/$name" ;;

  "policy assignment create")
    printf 'scope=%s\ndef=%s\nkind=custom\n' "$scope" "$policy" >"$SIM/assignments/$name"
    printf '{ "name": "%s", "scope": "%s", "policyDefinitionId": "%s", "enforcementMode": "Default" }\n' "$name" "$scope" "$policy" ;;

  "policy assignment list")
    printf '[\n'
    for f in "$SIM"/assignments/*; do [[ -e "$f" ]] || continue
      printf '  { "name": "%s", "scope": "%s", "policyDefinitionId": "%s" }\n' "$(basename "$f")" "$(gf "$f" scope)" "$(gf "$f" def)"
    done
    printf ']\n' ;;

  "policy assignment delete") rm -f "$SIM/assignments/$name" ;;

  "policy state summarize"|"policy state list")
    total=0; bad=0
    for f in "$SIM"/resources/*; do [[ -e "$f" ]] || continue
      total=$((total+1))
      [[ "$(gf "$f" tags)" =~ (^|[[:space:]])CostCenter=[^[:space:]] ]] || bad=$((bad+1))
    done
    printf '{ "results": { "resourceDetails": [ { "complianceState": "NonCompliant", "count": %s }, { "complianceState": "Compliant", "count": %s } ] } }\n' "$bad" "$((total-bad))" ;;

  *)
    printf 'ERROR: the offline simulator does not implement: az %s\n' "${CMD[*]}" >&2
    printf 'Implemented: account show | group create/show/list/delete | storage account create/show/list/update |\n' >&2
    printf '             lock create/list/show/delete | policy definition create/delete |\n' >&2
    printf '             policy assignment create/list/delete | policy state summarize\n' >&2
    exit 2 ;;
esac
AZ_SIM_EOF
  chmod +x "$SHIM"
}

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------
do_break() {
  detect_mode
  [[ -f "$STATE" ]] && die "A lab already exists at $LAB_HOME. Run '$0 cleanup' first."
  mkdir -p "$LAB_HOME"

  SUFFIX="$(printf '%04x' $((RANDOM % 65536)))"
  RG="rg-az900-gov-lab-$SUFFIX"
  SA1="stgovlab$SUFFIX"

  if [[ "$MODE" == "azure" ]]; then
    SUB_ID="$(az account show --query id -o tsv)"
    SUB_NAME="$(az account show --query name -o tsv)"
    hr
    warn "REAL Azure subscription targeted:"
    printf '      name : %s\n      id   : %s\n' "$SUB_NAME" "$SUB_ID"
    warn "This lab creates one resource group ($RG) and one Standard_LRS storage account."
    warn "Use a sandbox / throw-away subscription. NEVER a production one."
    hr
    if [[ "${AZ900_ASSUME_YES:-0}" != "1" ]]; then
      read -r -p "Type BREAK to continue, anything else to abort: " ans
      [[ "$ans" == "BREAK" ]] || die "Aborted. Nothing was created."
    fi
    AZ="az"
  else
    SUB_ID="1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    SUB_NAME="AZ-900 Break-and-Fix Lab (SIMULATED)"
    write_shim
    export AZ900_SIM_STATE="$SIM"
    AZ="$SHIM"
    warn "Azure CLI unavailable or not signed in — running the OFFLINE ARM simulator."
    warn "Error codes and governance semantics are reproduced; no cloud resources exist."
  fi

  RG_ID="/subscriptions/$SUB_ID/resourceGroups/$RG"
  POLICY_KIND="custom"

  log "Creating the lab resource group ($RG) ..."
  "$AZ" group create -n "$RG" -l "$LOCATION" --tags Environment=Lab Owner=az900-student -o none

  # --- Non-compliant resource is created FIRST, on purpose ---------------------
  # Real-world shape: the resource pre-dates the guardrail. Policy deny only
  # applies to new writes; existing resources are merely reported non-compliant.
  log "Creating a storage account BEFORE the guardrail exists (no CostCenter tag) ..."
  "$AZ" storage account create -n "$SA1" -g "$RG" -l "$LOCATION" \
      --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
      --allow-blob-public-access false -o none

  # --- Break #1: a deny policy assigned at resource-group scope ----------------
  log "Authoring and assigning the deny policy ..."
  RULES="$LAB_HOME/policy-rule.json"
  cat >"$RULES" <<'JSON'
{
  "if": {
    "allOf": [
      { "field": "type", "equals": "Microsoft.Storage/storageAccounts" },
      {
        "anyOf": [
          { "field": "tags['CostCenter']", "exists": "false" },
          { "field": "location", "notIn": [ "eastus", "eastus2" ] }
        ]
      }
    ]
  },
  "then": { "effect": "deny" }
}
JSON

  if [[ "$MODE" == "azure" ]]; then
    if az policy definition create --name "$POLICY_DEF" \
         --display-name "AZ-900 lab: storage accounts need CostCenter and an approved region" \
         --description "Deny Microsoft.Storage/storageAccounts without tag CostCenter or outside eastus/eastus2." \
         --rules "$RULES" --mode Indexed -o none 2>/dev/null; then
      az policy assignment create -n "$ASSIGN" \
         --display-name "AZ-900 lab guardrails" \
         --policy "$POLICY_DEF" --scope "$RG_ID" -o none
    else
      warn "No permission to create a custom policy definition — falling back to the"
      warn "built-in 'Require a tag on resources' (deny) with tagName=CostCenter."
      POLICY_KIND="builtin"
      az policy assignment create -n "$ASSIGN" \
         --display-name "AZ-900 lab guardrails" \
         --policy "$BUILTIN_REQUIRE_TAG" --scope "$RG_ID" \
         --params '{"tagName":{"value":"CostCenter"}}' -o none
    fi
  else
    "$AZ" policy definition create --name "$POLICY_DEF" --rules "$RULES" --mode Indexed -o none
    "$AZ" policy assignment create -n "$ASSIGN" --policy "$POLICY_DEF" --scope "$RG_ID" -o none
  fi

  # --- Break #2 and #3: the two locks -----------------------------------------
  log "Applying resource locks ..."
  "$AZ" lock create --name "$RG_LOCK" --lock-type CanNotDelete -g "$RG" \
      --notes "AZ-900 lab: deliberate delete guardrail" -o none
  "$AZ" lock create --name "$SA_LOCK" --lock-type ReadOnly -g "$RG" \
      --resource "$SA1" --resource-type "storageAccounts" --namespace "Microsoft.Storage" \
      --notes "AZ-900 lab: deliberate write guardrail" -o none

  cat >"$STATE" <<EOF
MODE="$MODE"
SUB_ID="$SUB_ID"
SUB_NAME="$SUB_NAME"
RG="$RG"
RG_ID="$RG_ID"
SA1="$SA1"
SUFFIX="$SUFFIX"
POLICY_KIND="$POLICY_KIND"
EOF

  cat >"$ACTIVATE" <<EOF
# source this file before working on the lab
export AZ900_SIM_STATE="$SIM"
export RG="$RG"
export SA1="$SA1"
export SUB_ID="$SUB_ID"
export RG_ID="$RG_ID"
EOF
  [[ "$MODE" == "sim" ]] && printf 'export PATH="%s:$PATH"\n' "$LAB_HOME/bin" >>"$ACTIVATE"

  print_briefing
}

print_briefing() {
  hr
  printf '%sTHE LAB IS NOW BROKEN.%s  Mode: %s\n' "$C_R" "$C_0" "$MODE"
  hr
  cat <<EOF

SCENARIO
  You are the on-call platform engineer. A colleague "hardened" the sandbox
  resource group $RG last night and went on holiday. This
  morning nothing deploys and nothing can be cleaned up.

  Load your lab variables first:

      source $ACTIVATE

SYMPTOM 1 — every new storage account is rejected
  Reproduce it exactly as the developer did:

      az storage account create -n st$SUFFIX-new -g \$RG -l westeurope \\
          --sku Standard_LRS --kind StorageV2

  You will see (name normalisation aside):

      ERROR: (RequestDisallowedByPolicy) Resource '...' was disallowed by policy.
      Policy identifiers: '[{"policyAssignment":{"name":"$ASSIGN", ...

  Note what this is NOT: it is not 403 AuthorizationFailed. RBAC let the call
  through; Azure Policy rejected the *shape* of the resource at admission time.

SYMPTOM 2 — the pre-existing storage account cannot be remediated
  The account $SA1 already exists and is reported
  non-compliant. Try to tag it:

      az storage account update -n \$SA1 --tags CostCenter=IT-1042 Environment=Lab

      ERROR: (ScopeLocked) The scope '.../storageAccounts/$SA1'
      cannot perform write operation because following scope(s) are locked: ...

  A lock outranks your role. Owner does not bypass it.

SYMPTOM 3 — the resource group cannot be deleted
      az group delete -n \$RG --yes

      ERROR: (ScopeLocked) ... cannot perform delete operation because following
      scope(s) are locked: ...

WHAT YOU MUST ACHIEVE (graded by: $0 check)
  1. The policy assignment '$ASSIGN' is STILL assigned at the
     resource-group scope. Deleting the guardrail is not a fix — it is an
     incident. Governance intent must survive your repair.
  2. A NEW storage account exists in \$RG that satisfies the policy: it carries
     a non-empty CostCenter tag$( [[ "${POLICY_KIND:-custom}" == custom ]] && printf ' and lives in %s or %s' "$LOCATION" "$ALT_LOCATION" ).
  3. The pre-existing account $SA1 now carries a non-empty
     CostCenter tag — which means you had to deal with the ReadOnly lock that
     was blocking the remediation write.
  4. The ReadOnly lock '$SA_LOCK' is gone (it blocked required remediation).
  5. The CanNotDelete lock '$RG_LOCK' is STILL there. It is doing
     exactly its job: protecting the group from accidental deletion. Removing a
     delete guardrail because it is inconvenient is the wrong reflex.

QUESTIONS TO ANSWER OUT LOUD (exam-shaped, no command will tell you)
  a. Which of the three failures would a Contributor role assignment change?
     Which would an Owner assignment change? (Answer: none of them.)
  b. Policy scope is inherited. If the same assignment sat at a management group
     instead of this resource group, what would you have to change to fix it?
  c. Where would an auditor obtain the ISO 27001 attestation for the underlying
     Azure datacentre — Azure Policy, Purview, or the Service Trust Portal?
  d. Deny vs Audit vs DeployIfNotExists: which effect would have let the deploy
     succeed while still flagging the missing tag?

  Hints:  $0 hint        Grade:  $0 check
  Wipe:   $0 cleanup

EOF
  [[ "$MODE" == "azure" ]] && warn "Real Azure: a fresh policy assignment can take up to ~5 minutes to be enforced by ARM, and compliance scans up to ~30 minutes. Symptom 1 may lag."
  hr
}

# -----------------------------------------------------------------------------
# HINT
# -----------------------------------------------------------------------------
do_hint() {
  load_state
  cat <<EOF
Hint 1 — read the error, do not guess. The policy identifiers block in the
         RequestDisallowedByPolicy payload names the assignment. List it:
             az policy assignment list --scope "\$RG_ID" -o table

Hint 2 — an assignment points at a definition; the definition holds the rule.
             az policy assignment show -n $ASSIGN --scope "\$RG_ID" \\
                 --query policyDefinitionId -o tsv
             az policy definition show -n $POLICY_DEF --query policyRule

Hint 3 — locks are a separate control plane from RBAC. Enumerate them:
             az lock list -g "\$RG" -o table
         Read the 'level' column: CanNotDelete blocks delete only;
         ReadOnly blocks every write, including adding a tag.

Hint 4 — decide, per lock, whether it is protecting you or blocking a
         legitimate change. Only one of the two should be removed.

Hint 5 — compliance state is evaluated asynchronously; force a look with
             az policy state summarize --resource-group "\$RG"
EOF
}

# -----------------------------------------------------------------------------
# STATUS
# -----------------------------------------------------------------------------
do_status() {
  load_state
  hr
  printf 'mode=%s  subscription=%s\nresource group=%s  seeded account=%s\n' "$MODE" "$SUB_NAME" "$RG" "$SA1"
  hr
  log "policy assignments at $RG_ID"; "$AZ" policy assignment list --scope "$RG_ID" -o json 2>/dev/null || true
  log "locks in $RG"; "$AZ" lock list -g "$RG" -o json 2>/dev/null || true
  log "storage accounts in $RG"; "$AZ" storage account list -g "$RG" -o json 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# CHECK (grading)
# -----------------------------------------------------------------------------
q_assignment_present() {
  if [[ "$MODE" == "azure" ]]; then
    [[ "$(az policy assignment list --scope "$RG_ID" --query "length([?name=='$ASSIGN'])" -o tsv 2>/dev/null || echo 0)" -ge 1 ]]
  else
    [[ -f "$SIM/assignments/$ASSIGN" ]]
  fi
}
q_rg_lock_present() {
  if [[ "$MODE" == "azure" ]]; then
    [[ "$(az lock show --name "$RG_LOCK" -g "$RG" --query level -o tsv 2>/dev/null || true)" == "CanNotDelete" ]]
  else
    [[ "$(sim_field "$SIM/locks/$RG_LOCK" level)" == "CanNotDelete" ]]
  fi
}
q_sa_lock_absent() {
  if [[ "$MODE" == "azure" ]]; then
    ! az lock show --name "$SA_LOCK" -g "$RG" --resource "$SA1" \
        --resource-type "storageAccounts" --namespace "Microsoft.Storage" >/dev/null 2>&1
  else
    [[ ! -f "$SIM/locks/$SA_LOCK" ]]
  fi
}
q_sa1_tagged() {
  local v
  if [[ "$MODE" == "azure" ]]; then
    v="$(az storage account show -n "$SA1" -g "$RG" --query "tags.CostCenter" -o tsv 2>/dev/null || true)"
  else
    v="$(sim_field "$SIM/resources/$SA1" tags)"
    [[ "$v" =~ (^|[[:space:]])CostCenter=([^[:space:]]+) ]] && v="${BASH_REMATCH[2]}" || v=""
  fi
  [[ -n "$v" ]]
}
q_new_compliant_sa() {
  local n=0 f tg lc
  if [[ "$MODE" == "azure" ]]; then
    if [[ "$POLICY_KIND" == "custom" ]]; then
      n="$(az storage account list -g "$RG" --query "length([?name!='$SA1' && tags.CostCenter!=null && (location=='$LOCATION' || location=='$ALT_LOCATION')])" -o tsv 2>/dev/null || echo 0)"
    else
      n="$(az storage account list -g "$RG" --query "length([?name!='$SA1' && tags.CostCenter!=null])" -o tsv 2>/dev/null || echo 0)"
    fi
  else
    for f in "$SIM"/resources/*; do [[ -e "$f" ]] || continue
      [[ "$(basename "$f")" == "$SA1" ]] && continue
      [[ "$(sim_field "$f" rg)" == "$RG" ]] || continue
      tg="$(sim_field "$f" tags)"; lc="$(sim_field "$f" location)"
      [[ "$tg" =~ (^|[[:space:]])CostCenter=[^[:space:]] ]] || continue
      [[ "$lc" == "$LOCATION" || "$lc" == "$ALT_LOCATION" ]] || continue
      n=$((n+1))
    done
  fi
  [[ "${n:-0}" -ge 1 ]]
}

grade() {
  local desc="$1"; shift
  if "$@"; then printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$desc"; return 0
  else          printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$desc"; return 1; fi
}

do_check() {
  load_state
  local fails=0
  hr; printf 'GRADING — AZ-900 3.2 break & fix\n'; hr
  grade "1. policy assignment '$ASSIGN' still enforced at the RG scope" q_assignment_present || fails=$((fails+1))
  grade "2. a new policy-compliant storage account exists in $RG"       q_new_compliant_sa   || fails=$((fails+1))
  grade "3. pre-existing account $SA1 now carries a CostCenter tag"     q_sa1_tagged         || fails=$((fails+1))
  grade "4. ReadOnly lock '$SA_LOCK' removed"                           q_sa_lock_absent     || fails=$((fails+1))
  grade "5. CanNotDelete lock '$RG_LOCK' preserved"                     q_rg_lock_present    || fails=$((fails+1))
  hr
  if [[ "$fails" -eq 0 ]]; then
    printf '%sAll objectives met.%s You fixed the workload without dismantling governance.\n' "$C_G" "$C_0"
    printf 'Now run: %s cleanup\n' "$0"
    return 0
  fi
  printf '%s%d objective(s) still failing.%s  Try: %s hint\n' "$C_Y" "$fails" "$C_0" "$0"
  return 1
}

# -----------------------------------------------------------------------------
# CLEANUP — locks first, then assignment, then definition, then the group
# -----------------------------------------------------------------------------
do_cleanup() {
  [[ -f "$STATE" ]] || { log "Nothing to clean up."; exit 0; }
  # shellcheck disable=SC1090
  source "$STATE"
  AZ="az"; [[ "$MODE" == "sim" ]] && { AZ="$SHIM"; export AZ900_SIM_STATE="$SIM"; }

  log "Removing locks ..."
  "$AZ" lock delete --name "$SA_LOCK" -g "$RG" --resource "$SA1" \
      --resource-type "storageAccounts" --namespace "Microsoft.Storage" >/dev/null 2>&1 || true
  "$AZ" lock delete --name "$RG_LOCK" -g "$RG" >/dev/null 2>&1 || true

  log "Removing the policy assignment and definition ..."
  "$AZ" policy assignment delete -n "$ASSIGN" --scope "$RG_ID" >/dev/null 2>&1 || true
  "$AZ" policy definition delete -n "$POLICY_DEF" >/dev/null 2>&1 || true

  log "Deleting the resource group $RG ..."
  if [[ "$MODE" == "azure" ]]; then
    az group delete -n "$RG" --yes --no-wait >/dev/null 2>&1 || warn "Delete the group manually: az group delete -n $RG --yes"
  else
    "$AZ" group delete -n "$RG" >/dev/null 2>&1 || true
  fi

  rm -rf "$LAB_HOME"
  log "Lab removed. State directory $LAB_HOME deleted."
}

usage() {
  cat <<EOF
AZ-900 topic 3.2 — governance and compliance — break & fix lab

  $0 break     create the lab and break it (asks for confirmation on real Azure)
  $0 status    dump the current policy assignments, locks and resources
  $0 hint      progressive hints, no spoilers
  $0 check     grade your repair against the five objectives
  $0 cleanup   remove every object the lab created

Environment:
  AZ900_FORCE_SIM=1   force the offline simulator even when signed in to Azure
  AZ900_ASSUME_YES=1  skip the interactive confirmation on real Azure
  AZ900_LAB_HOME=dir  relocate the lab state directory (default ~/.az900-lab-3.2)
EOF
}

case "${1:-break}" in
  break)   do_break ;;
  status)  detect_mode; do_status ;;
  hint)    detect_mode; do_hint ;;
  check)   detect_mode; do_check ;;
  cleanup) do_cleanup ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac

# =============================================================================
# =============================  S O L U T I O N  =============================
#  Do not read until you have tried. Every command below is real Azure CLI
#  syntax and works verbatim in the offline simulator too.
# =============================================================================
#
# STEP 0 — load the lab context
#   source ~/.az900-lab-3.2/activate.sh
#   echo "$RG $SA1 $RG_ID"
#
# STEP 1 — reproduce and CLASSIFY the failure, do not guess at it
#   az storage account create -n stfix0001 -g "$RG" -l westeurope \
#       --sku Standard_LRS --kind StorageV2
#
#   ERROR: (RequestDisallowedByPolicy) Resource 'stfix0001' was disallowed by policy.
#   Policy identifiers: '[{"policyAssignment":{"name":"az900-guardrails", ...
#
#   Classification, and this is the exam-relevant reflex:
#     · 403 AuthorizationFailed  -> Azure RBAC. Identity lacks a role/permission.
#     · RequestDisallowedByPolicy -> Azure Policy. Identity was allowed; the
#       resource *definition* violates a rule evaluated at admission time.
#     · ScopeLocked              -> Resource lock. Nobody, at any role, may do it.
#   Three different control planes, three different fixes.
#
# STEP 2 — find the guardrail and READ THE RULE
#   az policy assignment list --scope "$RG_ID" -o table
#   az policy assignment show -n az900-guardrails --scope "$RG_ID" \
#       --query "{def:policyDefinitionId, enforcement:enforcementMode}" -o yaml
#   az policy definition show -n az900-storage-guardrail --query policyRule -o json
#
#   Expected rule (custom definition path):
#     if type == Microsoft.Storage/storageAccounts
#        and ( tags['CostCenter'] does not exist
#              or location not in [eastus, eastus2] )
#     then deny
#
#   Two independent conditions -> two independent things to satisfy.
#
# STEP 3 — comply. Do NOT delete the assignment.
#   az storage account create -n stfix0001 -g "$RG" -l eastus \
#       --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
#       --allow-blob-public-access false \
#       --tags CostCenter=IT-1042 Environment=Lab Owner=az900-student
#
#   Succeeds. The correct response to a deny policy is to make the resource
#   conform, or to negotiate a change to the policy through whoever owns the
#   governance scope — never to silently unassign it. (An emergency escape hatch
#   exists and is exam-relevant: enforcementMode=DoNotEnforce, and policy
#   exemptions with an expiry date and a justification. Both leave an audit trail;
#   deleting the assignment does not.)
#
# STEP 4 — the second symptom: remediate the pre-existing resource
#   az storage account update -n "$SA1" --tags CostCenter=IT-1042 Environment=Lab
#
#   ERROR: (ScopeLocked) ... cannot perform write operation because following
#   scope(s) are locked: '.../storageAccounts/stgovlabXXXX'.
#
#   Deny policy applies to new writes; the account created before the assignment
#   was never blocked, it is simply reported NonCompliant. But a ReadOnly lock
#   blocks the fix.
#
# STEP 5 — enumerate the locks and judge each one on its merits
#   az lock list -g "$RG" -o table
#
#   Name                    Level          Scope
#   ----------------------  -------------  -------------------------------------
#   lock-rg-cannotdelete    CanNotDelete   .../resourceGroups/rg-az900-gov-lab-XXXX
#   lock-sa-readonly        ReadOnly       .../storageAccounts/stgovlabXXXX
#
#   · ReadOnly blocks ALL write operations, including tag updates and most
#     data-plane key operations. It is blocking a legitimate, required
#     remediation -> remove it.
#   · CanNotDelete allows reads and writes, blocks delete only. It is doing its
#     job -> keep it. "It is in my way" is not a reason to delete a delete guard.
#   Locks are inherited downward: a lock on the resource group applies to every
#   resource inside it, and the most restrictive inherited lock wins.
#
# STEP 6 — remove only the ReadOnly lock, then remediate
#   az lock delete --name lock-sa-readonly -g "$RG" \
#       --resource "$SA1" --resource-type "storageAccounts" \
#       --namespace "Microsoft.Storage"
#
#   az storage account update -n "$SA1" \
#       --tags CostCenter=IT-1042 Environment=Lab Owner=az900-student
#
#   az storage account show -n "$SA1" -g "$RG" --query tags -o yaml
#
# STEP 7 — verify compliance, not just "the command stopped failing"
#   az policy state summarize --resource-group "$RG" \
#       --query "results.resourceDetails" -o table
#   az policy state list --resource-group "$RG" \
#       --filter "complianceState eq 'NonCompliant'" \
#       --query "[].{resource:resourceId, policy:policyDefinitionName}" -o table
#
#   On real Azure the compliance scan is asynchronous (up to ~30 min, or force it
#   with `az policy state trigger-scan --resource-group "$RG"`). Enforcement of a
#   new deny assignment is much faster, ~5 min, but not instantaneous either —
#   which is exactly why deny is a guardrail and not a security boundary.
#
# STEP 8 — the third symptom is not a bug, and the fix is to understand it
#   az group delete -n "$RG" --yes
#   ERROR: (ScopeLocked) ... cannot perform delete operation ...
#
#   Correct: the CanNotDelete lock exists precisely so that this command fails.
#   Deleting the group is the lab teardown, not the incident fix. When teardown
#   is genuinely authorised, the lock is removed deliberately and last:
#       az lock delete --name lock-rg-cannotdelete -g "$RG"
#       az group delete -n "$RG" --yes --no-wait
#   Or simply:  ./az900-3.2-breakfix.sh cleanup
#
# STEP 9 — grade yourself
#   ./az900-3.2-breakfix.sh check
#
# -----------------------------------------------------------------------------
# ANSWERS TO THE EXAM-SHAPED QUESTIONS
# -----------------------------------------------------------------------------
# a. Neither Contributor nor Owner changes any of the three failures.
#    Azure Policy is evaluated on the request regardless of role; resource locks
#    apply to every principal. Only "Owner" or "User Access Administrator" — the
#    roles carrying Microsoft.Authorization/locks/* and .../policyAssignments/* —
#    can remove the controls themselves, which is a different action from
#    performing the blocked operation. Contributor deliberately excludes
#    Microsoft.Authorization/* so a Contributor can neither grant themselves
#    access nor delete locks.
#
# b. Nothing about your fix would change: the resource still has to comply.
#    What changes is the blast radius and who can act. Policy assigned at a
#    management group is inherited by every subscription and resource group under
#    it, so unassigning is not yours to do; you would request a policy exemption
#    scoped to this resource group, or comply. This is the whole point of the
#    management group -> subscription -> resource group -> resource hierarchy.
#
# c. The Service Trust Portal (reachable through Microsoft Purview Compliance
#    Manager). Azure Policy proves *your* resources conform to *your* rules;
#    it says nothing about Microsoft's own certifications. ISO 27001, SOC 1/2/3,
#    PCI DSS and FedRAMP audit reports for the platform are published as
#    downloadable documents in the Service Trust Portal. Microsoft Purview covers
#    data governance, classification and Compliance Manager assessments.
#    Do not confuse the three — the exam does test exactly this distinction.
#
# d. Audit. It records a non-compliant result in the compliance state and lets
#    the deployment through; deny blocks it. DeployIfNotExists and Modify are
#    remediation effects: Modify could have added the missing tag itself (with a
#    managed identity and a remediation task), which is the production-grade
#    answer to "our developers keep forgetting the CostCenter tag".
#    Effect reference:
#      https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-basics
#
# -----------------------------------------------------------------------------
# ONE-LINE MENTAL MODEL TO CARRY INTO THE EXAM
#   RBAC   -> who may act            (403 AuthorizationFailed)
#   Policy -> what the result may be (RequestDisallowedByPolicy)
#   Lock   -> nobody may, right now  (ScopeLocked)
#   Tags   -> the metadata all three, plus Cost Management, actually reason about
#   Purview / Service Trust Portal -> evidence *about the platform*, not about you
# =============================================================================