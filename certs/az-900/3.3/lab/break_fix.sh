#!/usr/bin/env bash
#
# =============================================================================
#  AZ-900 · Microsoft Azure Fundamentals  (exam version 2026-07-20)
#  Domain 3 — Describe Azure management and governance
#  Topic  3.3 — Describe features and tools for managing and deploying
#               Azure resources                             (exam weight 8.33)
#
#  BREAK & FIX LAB — "the control-plane toolchain is down"
#
#  Official reference material
#    AZ-900 study guide
#      https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#    Azure CLI configuration (AZURE_CONFIG_DIR, defaults, config file format)
#      https://learn.microsoft.com/en-us/cli/azure/azure-cli-configuration
#    Bicep CLI (az bicep install/build/version)
#      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-cli
#    ARM template syntax and structure
#      https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/syntax
#    Resource dependencies (dependsOn)
#      https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/resource-dependency
#    Azure Arc-enabled servers / Connected Machine agent
#      https://learn.microsoft.com/en-us/azure/azure-arc/servers/overview
#      https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview
#
#  WHAT THIS LAB TEACHES
#    Topic 3.3 is usually memorised as a list of names — portal, Cloud Shell,
#    Azure CLI, Azure PowerShell, Azure Arc, ARM, ARM templates/Bicep. That list
#    is useless until you have felt each one fail. Here the *management plane
#    tooling* is broken in six independent places, layered the way real
#    incidents are layered: the CLI cannot even start, so you cannot see that
#    its deployment scope is wrong; the Bicep compiler is dead, so you cannot
#    see that the template underneath it does not compile; and the Arc agent is
#    down, so the machine has no ARM identity at all.
#
#    Everything is local and offline. No Azure subscription, no sign-in, no
#    money, no resources created. What is exercised is exactly what ARM
#    exercises before it ever reaches the cloud: tool health, deployment scope,
#    template syntax, template semantics, agent registration.
#
#  SAFETY CONTRACT — read this before running
#    * Intended for a DISPOSABLE lab VM.
#    * Your real Azure CLI profile is NEVER touched. The lab exports its own
#      AZURE_CONFIG_DIR under $LAB_ROOT, so ~/.azure (tokens, subscriptions,
#      service principals) is only ever read, and only to copy a working
#      `bicep` binary if one is already installed.
#    * No sudo. No system-wide systemd unit. No package installs. No firewall,
#      network, disk or kernel changes. Nothing outside $LAB_ROOT and one
#      per-user systemd unit file.
#    * `clean` removes both, completely.
#
#  USAGE
#    ./az900-3.3-breakfix.sh break     # inject the faults (default action)
#    ./az900-3.3-breakfix.sh verify    # grade your repair, fault by fault
#    ./az900-3.3-breakfix.sh hint      # progressive hints, no spoilers
#    ./az900-3.3-breakfix.sh clean     # remove the lab entirely
#
#  REQUIREMENTS
#    azure-cli >= 2.50, python3, bash >= 4, coreutils.
#    Optional: a user systemd instance (for the Azure Arc agent simulation),
#    outbound HTTPS (only if `bicep` is not already present, for az bicep install).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Lab constants. Override the root with AZ900_LAB_ROOT if you want it elsewhere.
# ---------------------------------------------------------------------------
LAB_ID="az900-3.3"
LAB_ROOT="${AZ900_LAB_ROOT:-$HOME/az900-lab-3.3}"
CFG_DIR="$LAB_ROOT/azure-config"          # becomes AZURE_CONFIG_DIR
IAC_DIR="$LAB_ROOT/iac"
ARC_DIR="$LAB_ROOT/arc"
BIN_DIR="$LAB_ROOT/bin"
BAK_DIR="$LAB_ROOT/backup"
STATE="$LAB_ROOT/.state"
ENV_FILE="$LAB_ROOT/env.sh"

BICEP_FILE="$IAC_DIR/main.bicep"
ARM_FILE="$IAC_DIR/azuredeploy.json"
ARC_CONF="$ARC_DIR/agentconfig.json"
ARC_MOCK="$BIN_DIR/az900-arc-mock"

UNIT_NAME="az900-arc-mock.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/$UNIT_NAME"

# The two values the whole lab must converge on. They are the "single source of
# truth" for the deployment scope, exactly like a real environment contract.
TARGET_RG="rg-az900-lab-33"
TARGET_LOCATION="eastus"

# The lab always drives the Azure CLI against its own profile directory.
export AZURE_CONFIG_DIR="$CFG_DIR"
export AZURE_CORE_COLLECT_TELEMETRY=0

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3)
    C_BLU=$(tput setaf 4); C_BLD=$(tput bold);    C_OFF=$(tput sgr0)
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[..]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
err()  { printf '%s[XX]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

die() { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_tools() {
    command -v az >/dev/null 2>&1 || die "azure-cli not found. Install it: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    command -v python3 >/dev/null 2>&1 || die "python3 not found (used only to validate JSON locally)."
}

have_user_systemd() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

state_set() { printf '%s=%s\n' "$1" "$2" >> "$STATE"; }
state_get() { [ -f "$STATE" ] && awk -F= -v k="$1" '$1==k{v=$2} END{print v}' "$STATE" || true; }

# ---------------------------------------------------------------------------
# Obtain a known-good bicep binary BEFORE we sabotage anything.
# Priority: the user's already installed bicep -> a bicep on PATH -> download.
# If none of the three works we skip the two Bicep faults and say so out loud;
# a lab that silently drops half its content is worse than a smaller lab.
# ---------------------------------------------------------------------------
prepare_bicep() {
    local real_cfg="${HOME}/.azure/bin/bicep"
    mkdir -p "$CFG_DIR/bin" "$BAK_DIR"

    if [ -x "$real_cfg" ]; then
        info "Reusing the bicep binary already installed in ~/.azure/bin (read-only copy)."
        cp -p "$real_cfg" "$CFG_DIR/bin/bicep"
    elif command -v bicep >/dev/null 2>&1; then
        info "Reusing the bicep binary found on PATH."
        cp -p "$(command -v bicep)" "$CFG_DIR/bin/bicep"
    else
        info "No local bicep found; asking the Azure CLI to install one into the lab profile..."
        if ! az bicep install >/dev/null 2>&1; then
            warn "az bicep install failed (no network?). Faults F3 and F4 will be SKIPPED."
            return 1
        fi
    fi

    chmod +x "$CFG_DIR/bin/bicep" 2>/dev/null || true
    if ! az bicep version >/dev/null 2>&1; then
        warn "The bicep binary does not run on this host. Faults F3 and F4 will be SKIPPED."
        return 1
    fi

    cp -p "$CFG_DIR/bin/bicep" "$BAK_DIR/bicep.good"
    info "Known-good bicep archived at $BAK_DIR/bicep.good"
    return 0
}

# ---------------------------------------------------------------------------
# Fault writers
# ---------------------------------------------------------------------------

write_env_file() {
    cat > "$ENV_FILE" <<EOF
# Source this file in every shell you use for the lab:
#     source "$ENV_FILE"
# It isolates the Azure CLI profile so the lab cannot touch your real ~/.azure.
export AZURE_CONFIG_DIR="$CFG_DIR"
export AZURE_CORE_COLLECT_TELEMETRY=0
export PATH="$BIN_DIR:\$PATH"
export AZ900_LAB_ROOT="$LAB_ROOT"
EOF
}

# --- F1 + F2: the Azure CLI profile ----------------------------------------
# Two faults in one file, which is exactly how this happens in the field: a
# config management job appends a stanza, the write is truncated, and every
# `az` invocation on the box dies before it parses a single argument.
#   F1: the [core] header lost its opening bracket and [bicep is unterminated
#       -> Python's configparser raises MissingSectionHeaderError / ParsingError
#   F2: the deployment scope defaults point at somebody else's production RG
#       -> once the CLI runs again, every scoped command targets the wrong RG
write_broken_cli_config() {
    cat > "$CFG_DIR/config" <<'EOF'
core]
output = json
only_show_errors = false
collect_telemetry = false

[defaults]
group = rg-contoso-prod-weu
location = westeurope

[bicep
use_binary_from_path = false
EOF
}

# --- F3: the Bicep compiler -------------------------------------------------
# Replace the real binary with a stub that fails the way a partially downloaded
# or architecture-mismatched binary fails. `az bicep build`, `az bicep version`
# and any `az deployment group create --template-file *.bicep` all go through it.
write_broken_bicep() {
    cat > "$CFG_DIR/bin/bicep" <<'EOF'
#!/bin/sh
echo "bicep: cannot execute binary file: Exec format error" >&2
exit 126
EOF
    chmod +x "$CFG_DIR/bin/bicep"
}

# --- F4: the Bicep template -------------------------------------------------
# Three genuine compile errors, all of them classic:
#   BCP057  symbol 'location' used but never declared as a param/var
#   BCP037  'skuName' is not a property of the storage account resource body
#   BCP035  the resource body is missing the required 'sku' and 'kind'
write_broken_bicep_template() {
    cat > "$BICEP_FILE" <<'EOF'
// -----------------------------------------------------------------------------
// main.bicep - lab storage account for AZ-900 topic 3.3
// Deploy with:
//   az deployment group create -g rg-az900-lab-33 --template-file main.bicep
// -----------------------------------------------------------------------------
targetScope = 'resourceGroup'

@description('Short workload name; part of the storage account name.')
@maxLength(11)
param workload string = 'az900lab'

@description('Replication SKU for the storage account.')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
])
param skuName string = 'Standard_LRS'

var storageName = toLower('st${workload}${uniqueString(resourceGroup().id)}')

resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  skuName: skuName
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

output storageAccountId string = stg.id
output blobEndpoint string = stg.properties.primaryEndpoints.blob
EOF
}

# --- F5: the ARM JSON template ---------------------------------------------
# Four faults, in descending order of how loudly they fail:
#   a) trailing comma after the last element of "resources" -> not valid JSON
#   b) missing "contentVersion" -> rejected by the deploymentTemplate schema
#   c) $schema is the SUBSCRIPTION-scope schema, but the resources are
#      resource-group-scope and the template calls resourceGroup()
#   d) the web app has no dependsOn for its plan -> race at deployment time
write_broken_arm_template() {
    cat > "$ARM_FILE" <<'EOF'
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "metadata": {
    "description": "AZ-900 lab - Linux App Service plan plus web app (resource group scope)."
  },
  "parameters": {
    "location": {
      "defaultValue": "[resourceGroup().location]",
      "metadata": {
        "description": "Region for both resources."
      }
    },
    "planName": {
      "type": "string",
      "defaultValue": "plan-az900-lab-33"
    }
  },
  "variables": {
    "siteName": "[format('app-{0}', uniqueString(resourceGroup().id))]"
  },
  "resources": [
    {
      "type": "Microsoft.Web/serverfarms",
      "apiVersion": "2023-12-01",
      "name": "[parameters('planName')]",
      "location": "[parameters('location')]",
      "sku": {
        "name": "B1",
        "tier": "Basic"
      },
      "kind": "linux",
      "properties": {
        "reserved": true
      }
    },
    {
      "type": "Microsoft.Web/sites",
      "apiVersion": "2023-12-01",
      "name": "[variables('siteName')]",
      "location": "[parameters('location')]",
      "kind": "app,linux",
      "properties": {
        "httpsOnly": true,
        "serverFarmId": "[resourceId('Microsoft.Web/serverfarms', parameters('planName'))]",
        "siteConfig": {
          "linuxFxVersion": "DOTNETCORE|8.0",
          "minTlsVersion": "1.2",
          "ftpsState": "Disabled"
        }
      }
    },
  ]
}
EOF
}

# --- F6: the Azure Arc connected machine agent (simulated) ------------------
# A stand-in for himds/azcmagent. It refuses to start unless its configuration
# is valid JSON, complete, scoped to the right resource group, and marked
# Connected. Two faults: the unit's ExecStart has a typo (systemd 203/EXEC) and
# the agent configuration is broken.
write_arc_mock() {
    mkdir -p "$BIN_DIR"
    cat > "$ARC_MOCK" <<'MOCK'
#!/usr/bin/env bash
# Mock of the Azure Connected Machine agent (himds) for the AZ-900 3.3 lab.
# Real counterpart: azcmagent connect / azcmagent show
#   https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview
set -euo pipefail

CONFIG="${ARC_MOCK_CONFIG:-}"

fail() { printf 'azcmagent-mock: %s\n' "$*" >&2; exit 78; }   # 78 = EX_CONFIG

[ -n "$CONFIG" ] || fail "ARC_MOCK_CONFIG is not set in the unit environment"
[ -r "$CONFIG" ] || fail "agent configuration not readable: $CONFIG"

python3 - "$CONFIG" <<'PY' || fail "agent configuration rejected"
import json, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        cfg = json.load(fh)
except Exception as exc:
    print(f"  config is not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

required = ("resourceName", "resourceGroup", "location", "tenantId", "agentStatus")
missing = [k for k in required if not str(cfg.get(k, "")).strip()]
if missing:
    print("  missing or empty keys: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

if cfg["resourceGroup"] != "rg-az900-lab-33":
    print(f"  resourceGroup '{cfg['resourceGroup']}' does not match the lab scope "
          f"'rg-az900-lab-33'", file=sys.stderr)
    sys.exit(1)

if cfg["agentStatus"] != "Connected":
    print(f"  agentStatus is '{cfg['agentStatus']}'; the machine is not projected "
          f"into ARM", file=sys.stderr)
    sys.exit(1)

print(f"Connected: {cfg['resourceName']} -> "
      f"/subscriptions/<sub>/resourceGroups/{cfg['resourceGroup']}"
      f"/providers/Microsoft.HybridCompute/machines/{cfg['resourceName']} "
      f"({cfg['location']})")
PY

[ "${1:-}" = "--status" ] && exit 0

printf 'azcmagent-mock: heartbeat started (60s interval)\n'
exec sleep infinity
MOCK
    chmod +x "$ARC_MOCK"
}

write_broken_arc_config() {
    mkdir -p "$ARC_DIR"
    cat > "$ARC_CONF" <<'EOF'
{
  "resourceName": "arc-lab-vm-01",
  "resourceGroup": "",
  "location": "eastus",
  "tenantId": "00000000-0000-0000-0000-000000000000",
  "cloud": "AzureCloud",
  "agentStatus": "Disconnected",
}
EOF
}

write_broken_unit() {
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=AZ-900 lab - mock Azure Arc Connected Machine agent (himds)
Documentation=https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview
After=network-online.target

[Service]
Type=simple
Environment=ARC_MOCK_CONFIG=$ARC_CONF
ExecStart=$BIN_DIR/az900-arc-mokc
Restart=no

[Install]
WantedBy=default.target
EOF
}

# ---------------------------------------------------------------------------
# break
# ---------------------------------------------------------------------------
do_break() {
    require_tools

    if [ -f "$STATE" ]; then
        warn "A lab already exists at $LAB_ROOT."
        warn "Run '$0 verify' to grade it, or '$0 clean' to start over."
        exit 1
    fi

    rule
    say "${C_BLD}AZ-900 · Topic 3.3 — break & fix lab${C_OFF}"
    rule
    say "This will create $LAB_ROOT and one per-user systemd unit ($UNIT_NAME),"
    say "and will break the Azure management toolchain INSIDE that directory only."
    say "Your real ~/.azure profile is not modified. Run this on a disposable VM."
    say ""
    if [ "${1:-}" != "--yes" ]; then
        printf 'Type BREAK to continue: '
        read -r answer
        [ "$answer" = "BREAK" ] || die "Aborted; nothing was changed."
    fi

    mkdir -p "$CFG_DIR/bin" "$IAC_DIR" "$ARC_DIR" "$BIN_DIR" "$BAK_DIR"
    chmod 700 "$CFG_DIR"
    : > "$STATE"
    state_set LAB "$LAB_ID"
    state_set ROOT "$LAB_ROOT"

    write_env_file

    local bicep_ok=1
    prepare_bicep || bicep_ok=0
    state_set BICEP_FAULTS "$bicep_ok"

    write_broken_bicep_template
    write_broken_arm_template
    write_arc_mock
    write_broken_arc_config

    local arc_ok=0
    if have_user_systemd; then
        write_broken_unit
        systemctl --user daemon-reload
        systemctl --user enable --now "$UNIT_NAME" >/dev/null 2>&1 || true
        arc_ok=1
    else
        warn "No user systemd instance available. Fault F6 (Azure Arc agent) is SKIPPED."
    fi
    state_set ARC_FAULT "$arc_ok"

    if [ "$bicep_ok" -eq 1 ]; then
        write_broken_bicep
    fi
    # The CLI profile is corrupted last, so every setup step above could still
    # use the CLI normally.
    write_broken_cli_config

    print_brief
}

# ---------------------------------------------------------------------------
# The student-facing brief
# ---------------------------------------------------------------------------
print_brief() {
    local bicep_ok arc_ok
    bicep_ok="$(state_get BICEP_FAULTS)"
    arc_ok="$(state_get ARC_FAULT)"

    cat <<EOF

$(rule)
${C_BLD}INCIDENT BRIEF${C_OFF}
$(rule)

You are on call. A configuration-management run half-applied on this jump host
and then died. The host is the only place from which the team deploys the
'$TARGET_RG' lab environment, and it is now unable to deploy anything at all.

FIRST, in every shell you use for this lab:

    source "$ENV_FILE"

That points the Azure CLI at the lab profile ($CFG_DIR)
instead of your own. Nothing you do here can damage your real Azure setup.

$(rule)
${C_BLD}THE SCOPE CONTRACT${C_OFF} — every fix must converge on these two values
$(rule)
    resource group : $TARGET_RG
    location       : $TARGET_LOCATION

$(rule)
${C_BLD}SYMPTOMS YOU WILL SEE${C_OFF}
$(rule)

F1 · The Azure CLI does not run at all.
     Try:   az version
            az configure --list-defaults
     Expect something equivalent to:
            Unable to load configuration file '.../config'.
            MissingSectionHeaderError: File contains no section headers.
     (Exact wording varies with the CLI version; the failure does not.)
     GOAL: any 'az' command starts cleanly again.

F2 · Once the CLI runs, its deployment scope is somebody else's.
     Try:   az configure --list-defaults --output table
     You will find a group/location pair that is NOT the scope contract above.
     This is the quiet one: nothing errors, deployments simply land in the
     wrong resource group and region.
     GOAL: 'az configure --list-defaults' reports group=$TARGET_RG
           and location=$TARGET_LOCATION.
EOF

    if [ "${bicep_ok}" = "1" ]; then
        cat <<EOF

F3 · The Bicep compiler is dead.
     Try:   az bicep version
     Expect:
            bicep: cannot execute binary file: Exec format error
     Every 'az bicep build' and every '--template-file main.bicep' deployment
     goes through this binary, so nothing IaC-related works until it does.
     A known-good copy was archived for you at $BAK_DIR/bicep.good
     (use it if this VM has no outbound network).
     GOAL: 'az bicep version' prints a version and exits 0.

F4 · $IAC_DIR/main.bicep does not compile.
     Try (only after F3):
            az bicep build --file "$BICEP_FILE" --stdout
     Expect three distinct BCPxxx diagnostics: an undeclared symbol, a property
     that does not exist on the resource body, and a resource body missing
     required properties. Read the codes — Bicep tells you exactly what ARM
     would have rejected.
     GOAL: the file compiles, and the emitted ARM JSON still contains a
           Microsoft.Storage/storageAccounts resource with a location, a
           sku.name and a kind.
EOF
    fi

    cat <<EOF

F5 · $IAC_DIR/azuredeploy.json is not a deployable ARM template.
     Try:   python3 -m json.tool "$ARM_FILE"
     It fails on the very first parse. Behind that parse error there are three
     more problems: a missing top-level element that the deploymentTemplate
     schema requires, a \$schema that declares the wrong deployment scope for
     resources that call resourceGroup(), and a web app that can start
     provisioning before the App Service plan it points at exists.
     GOAL: the file parses; \$schema is the resource-group deploymentTemplate
           schema; contentVersion is present; every parameter declares a type;
           and Microsoft.Web/sites depends on Microsoft.Web/serverfarms.
EOF

    if [ "${arc_ok}" = "1" ]; then
        cat <<EOF

F6 · The Azure Arc connected machine agent will not start.
     Try:   systemctl --user status $UNIT_NAME
            journalctl --user -u $UNIT_NAME -n 30 --no-pager
     Expect a start failure with status=203/EXEC, and — once that is fixed — a
     second, different failure coming from the agent's own configuration at
     $ARC_CONF.
     Without this agent the machine is not projected into ARM at all: no
     Microsoft.HybridCompute/machines resource, so no Azure Policy, no tags, no
     Azure Monitor, no RBAC on this box.
     GOAL: 'systemctl --user is-active $UNIT_NAME' prints 'active', and
           '$ARC_MOCK --status' prints a Connected line for $TARGET_RG.
EOF
    fi

    cat <<EOF

$(rule)
${C_BLD}RULES OF ENGAGEMENT${C_OFF}
$(rule)
  * Fix, do not delete. Removing the storage resource from main.bicep or
    emptying the ARM template does not count and the grader will say so.
  * The faults are layered on purpose: F3 hides F4. Work outside-in, exactly
    as you would with a real incident — restore the tool, then read what the
    tool finally has to say.
  * Nothing here needs a subscription or an 'az login'. Everything is a
    local control-plane check that ARM would run before touching the cloud.

  Grade yourself:   $0 verify
  Stuck:            $0 hint
  Tear it all down: $0 clean

EOF
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
PASS_N=0; FAIL_N=0; SKIP_N=0

ok()   { printf '%s[PASS]%s %-4s %s\n' "$C_GRN" "$C_OFF" "$1" "$2"; PASS_N=$((PASS_N+1)); }
ko()   { printf '%s[FAIL]%s %-4s %s\n' "$C_RED" "$C_OFF" "$1" "$2"; FAIL_N=$((FAIL_N+1)); }
skip() { printf '%s[SKIP]%s %-4s %s\n' "$C_YEL" "$C_OFF" "$1" "$2"; SKIP_N=$((SKIP_N+1)); }

check_f1() {
    if az configure --list-defaults --output json >/dev/null 2>&1; then
        ok "F1" "Azure CLI starts and parses its configuration file"
    else
        ko "F1" "Azure CLI still cannot read $CFG_DIR/config"
    fi
}

check_f2() {
    local json group location
    json="$(az configure --list-defaults --output json 2>/dev/null || echo '[]')"
    group="$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((x.get("value","") for x in d if x.get("name")=="group"),""))' 2>/dev/null || true)"
    location="$(printf '%s' "$json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((x.get("value","") for x in d if x.get("name")=="location"),""))' 2>/dev/null || true)"
    if [ "$group" = "$TARGET_RG" ] && [ "$location" = "$TARGET_LOCATION" ]; then
        ok "F2" "CLI defaults scoped to $TARGET_RG / $TARGET_LOCATION"
    else
        ko "F2" "CLI defaults are group='${group:-<unset>}' location='${location:-<unset>}'"
    fi
}

check_f3() {
    if az bicep version >/dev/null 2>&1; then
        ok "F3" "Bicep CLI runs ($(az bicep version 2>/dev/null | head -n1))"
        return 0
    fi
    ko "F3" "Bicep CLI still fails to execute"
    return 1
}

check_f4() {
    local out
    out="$(mktemp)"
    if ! az bicep build --file "$BICEP_FILE" --outfile "$out" >/dev/null 2>&1; then
        ko "F4" "main.bicep still does not compile"
        rm -f "$out"; return
    fi
    if python3 - "$out" <<'PY'
import json, sys
tpl = json.load(open(sys.argv[1]))
res = tpl.get("resources", [])
items = list(res.values()) if isinstance(res, dict) else list(res)
sa = [r for r in items if str(r.get("type", "")).lower() == "microsoft.storage/storageaccounts"]
if not sa:
    print("no storage account left in the compiled template", file=sys.stderr); sys.exit(1)
r = sa[0]
for key in ("location", "kind"):
    if not r.get(key):
        print(f"storage account has no '{key}'", file=sys.stderr); sys.exit(1)
if not (r.get("sku") or {}).get("name"):
    print("storage account has no sku.name", file=sys.stderr); sys.exit(1)
sys.exit(0)
PY
    then
        ok "F4" "main.bicep compiles to a complete storageAccounts resource"
    else
        ko "F4" "main.bicep compiles but the storage account is incomplete or gone"
    fi
    rm -f "$out"
}

check_f5() {
    if python3 - "$ARM_FILE" <<'PY'
import json, sys

path = sys.argv[1]
try:
    tpl = json.load(open(path))
except Exception as exc:
    print(f"not valid JSON: {exc}", file=sys.stderr); sys.exit(1)

schema = tpl.get("$schema", "")
if "deploymentTemplate.json" not in schema or "subscription" in schema.lower():
    print(f"$schema is not the resource-group deploymentTemplate schema: {schema}", file=sys.stderr)
    sys.exit(1)

if not tpl.get("contentVersion"):
    print("contentVersion is missing", file=sys.stderr); sys.exit(1)

for name, spec in (tpl.get("parameters") or {}).items():
    if not isinstance(spec, dict) or "type" not in spec:
        print(f"parameter '{name}' declares no type", file=sys.stderr); sys.exit(1)

res = tpl.get("resources", [])
items = list(res.values()) if isinstance(res, dict) else list(res)
sites = [r for r in items if str(r.get("type", "")).lower() == "microsoft.web/sites"]
farms = [r for r in items if str(r.get("type", "")).lower() == "microsoft.web/serverfarms"]
if not sites or not farms:
    print("the plan and/or the web app were removed instead of fixed", file=sys.stderr); sys.exit(1)

dep = sites[0].get("dependsOn") or []
if isinstance(dep, str):
    dep = [dep]
if not any("serverfarms" in str(d).lower() for d in dep):
    print("Microsoft.Web/sites has no dependsOn for the App Service plan", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
    then
        ok "F5" "azuredeploy.json is a valid, correctly scoped, ordered ARM template"
    else
        ko "F5" "azuredeploy.json is still not deployable"
    fi
}

check_f6() {
    local active status
    active="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
    if [ "$active" != "active" ]; then
        ko "F6" "$UNIT_NAME is '$active', expected 'active'"
        return
    fi
    status="$(ARC_MOCK_CONFIG="$ARC_CONF" "$ARC_MOCK" --status 2>/dev/null || true)"
    case "$status" in
        Connected*"$TARGET_RG"*) ok "F6" "Arc agent running and projected into $TARGET_RG" ;;
        *)                       ko "F6" "Arc agent runs but is not Connected to $TARGET_RG" ;;
    esac
}

do_verify() {
    require_tools
    [ -f "$STATE" ] || die "No lab found at $LAB_ROOT. Run '$0 break' first."

    rule
    say "${C_BLD}AZ-900 · Topic 3.3 — repair report${C_OFF}"
    rule

    check_f1
    check_f2

    if [ "$(state_get BICEP_FAULTS)" = "1" ]; then
        if check_f3; then check_f4; else skip "F4" "not graded while the Bicep CLI is broken"; fi
    else
        skip "F3" "no usable bicep binary on this host"
        skip "F4" "no usable bicep binary on this host"
    fi

    check_f5

    if [ "$(state_get ARC_FAULT)" = "1" ]; then
        check_f6
    else
        skip "F6" "no user systemd instance on this host"
    fi

    rule
    printf 'passed: %s%d%s   failed: %s%d%s   skipped: %d\n' \
        "$C_GRN" "$PASS_N" "$C_OFF" "$C_RED" "$FAIL_N" "$C_OFF" "$SKIP_N"
    rule
    if [ "$FAIL_N" -eq 0 ]; then
        say "${C_GRN}Toolchain restored.${C_OFF} On a real subscription the next two commands"
        say "would be the ones that actually prove it, and neither of them creates anything:"
        say "    az deployment group validate -g $TARGET_RG --template-file $BICEP_FILE"
        say "    az deployment group what-if  -g $TARGET_RG --template-file $ARM_FILE"
        say ""
        say "The full solution is at the bottom of this script, commented out."
        return 0
    fi
    say "Keep going. '$0 hint' gives pointers without spoiling the fix."
    return 1
}

# ---------------------------------------------------------------------------
# hint
# ---------------------------------------------------------------------------
do_hint() {
    cat <<EOF
$(rule)
${C_BLD}HINTS${C_OFF} — pointers only; the worked solution is commented at the end of this file
$(rule)

F1  The Azure CLI config file is an INI file read by Python's configparser.
    Open $CFG_DIR/config in an editor and read it as
    configparser would: what must the very first non-blank line be? How many
    brackets does a section header need? Reference:
      https://learn.microsoft.com/en-us/cli/azure/azure-cli-configuration

F2  Two ways to set defaults: edit the [defaults] stanza by hand, or use the
    supported command 'az configure --defaults key=value'. Note the ordering
    problem — the second one needs F1 already fixed.

F3  'az bicep' keeps its binary inside AZURE_CONFIG_DIR, not in /usr/bin.
    Look at \$AZURE_CONFIG_DIR/bin/bicep and ask what it actually is now.
    Two supported ways back: reinstall it, or restore the archived copy in
    $BAK_DIR. Also check 'az bicep version' vs 'az bicep list-versions'.
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-cli

F4  Do not guess — compile and read the codes:
      az bicep build --file "$BICEP_FILE" --stdout
    BCP057 = a name used that was never declared. BCP037 = you invented a
    property. BCP035 = the resource type requires properties you did not give.
    For the last one, look up what a storageAccounts body actually requires:
      https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/storageaccounts

F5  Fix in this order: make it parse (JSON has no trailing commas), then make
    it schema-valid (which top-level elements are mandatory in a
    deploymentTemplate?), then make the scope coherent (a template that calls
    resourceGroup() cannot declare the subscription-scope schema), then make
    the ordering explicit (implicit dependencies exist in Bicep via symbolic
    references; in raw JSON with resourceId() you must state dependsOn).
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/syntax
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/resource-dependency

F6  systemd status 203/EXEC means "the binary in ExecStart is not there".
    Compare 'systemctl --user cat $UNIT_NAME' with 'ls $BIN_DIR'.
    After editing a unit file you must reload the manager before restarting.
    Then read the second failure with 'journalctl --user -u $UNIT_NAME'
    — it is the agent complaining about its own configuration, and the agent
    prints exactly which keys it dislikes.
      https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview

EOF
}

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
do_clean() {
    if have_user_systemd && [ -f "$UNIT_FILE" ]; then
        systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
        rm -f "$UNIT_FILE"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        info "Removed user unit $UNIT_NAME"
    fi
    case "$LAB_ROOT" in
        "$HOME"/*|/tmp/*|/var/tmp/*)
            if [ -f "$STATE" ] || [ -d "$CFG_DIR" ]; then
                rm -rf "$LAB_ROOT"
                info "Removed $LAB_ROOT"
            else
                warn "$LAB_ROOT does not look like this lab; leaving it alone."
            fi
            ;;
        *)
            warn "Refusing to delete '$LAB_ROOT' automatically — remove it by hand."
            ;;
    esac
    say "Lab removed. Your real ~/.azure was never touched."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
case "${1:-break}" in
    break)  shift || true; do_break "${1:-}" ;;
    verify) do_verify ;;
    hint)   do_hint ;;
    clean)  do_clean ;;
    -h|--help|help)
        say "usage: $0 [break [--yes] | verify | hint | clean]"
        ;;
    *)
        die "unknown action '$1' — try: break | verify | hint | clean"
        ;;
esac


# =============================================================================
# =                                                                           =
# =                        S O L U T I O N   ( spoilers )                     =
# =                                                                           =
# =  Read this only after you have tried. Every command below assumes you     =
# =  have already run:   source "$HOME/az900-lab-3.3/env.sh"                  =
# =                                                                           =
# =============================================================================
#
# -----------------------------------------------------------------------------
# STEP 0 — Establish the blast radius before touching anything
# -----------------------------------------------------------------------------
#   echo "$AZURE_CONFIG_DIR"          # must be the lab dir, never ~/.azure
#   ls -la "$AZURE_CONFIG_DIR"
#   az version                        # fails: this is where the incident starts
#
# Lesson for the exam: AZURE_CONFIG_DIR is what makes the Azure CLI multi-tenant
# on a single host. CI agents, Cloud Shell and jump hosts all rely on it. The
# portal has no equivalent because it is stateless per browser session; Cloud
# Shell persists $HOME (including .azure) in the mounted Azure Files share.
#
# -----------------------------------------------------------------------------
# STEP 1 — F1: repair the Azure CLI configuration file
# -----------------------------------------------------------------------------
# Diagnosis:
#   head -5 "$AZURE_CONFIG_DIR/config"
#     core]                <- missing opening bracket: configparser sees data
#     ...                     before any section, hence MissingSectionHeaderError
#     [bicep               <- unterminated section header
#
# Fix (writes the whole file, defaults included — this also closes F2):
#
#   cat > "$AZURE_CONFIG_DIR/config" <<'CFG'
#   [core]
#   output = json
#   only_show_errors = false
#   collect_telemetry = false
#
#   [defaults]
#   group = rg-az900-lab-33
#   location = eastus
#
#   [bicep]
#   use_binary_from_path = false
#   CFG
#
# Verify:
#   az version                        # runs again
#   az configure --list-defaults -o table
#
# -----------------------------------------------------------------------------
# STEP 2 — F2: the supported way to set the deployment scope
# -----------------------------------------------------------------------------
# If you fixed only the syntax in step 1 and left the Contoso defaults, use the
# CLI itself rather than hand-editing (idempotent, and it validates keys):
#
#   az configure --defaults group=rg-az900-lab-33 location=eastus
#   az configure --list-defaults --output table
#     Name      Source                                        Value
#     --------  --------------------------------------------  -----------------
#     group     .../azure-config/config                       rg-az900-lab-33
#     location  .../azure-config/config                       eastus
#
# To clear a default instead:  az configure --defaults group=''
#
# Why this matters: `az group deployment` was retired; today every scoped
# command (`az deployment group create`, `az vm create`, `az storage ...`)
# resolves -g from this file when you omit it. A wrong default here is the
# cheapest way to deploy into production by accident, and it never errors.
#
# -----------------------------------------------------------------------------
# STEP 3 — F3: restore the Bicep CLI
# -----------------------------------------------------------------------------
# Diagnosis:
#   file "$AZURE_CONFIG_DIR/bin/bicep"
#   head -3 "$AZURE_CONFIG_DIR/bin/bicep"     # a 3-line sh stub, not a binary
#
# Option A — reinstall from Microsoft (needs outbound HTTPS):
#   az bicep uninstall 2>/dev/null || true
#   az bicep install
#   az bicep version
#
# Option B — offline restore from the archive the lab left you:
#   cp -p "$HOME/az900-lab-3.3/backup/bicep.good" "$AZURE_CONFIG_DIR/bin/bicep"
#   chmod +x "$AZURE_CONFIG_DIR/bin/bicep"
#   az bicep version
#     Bicep CLI version 0.x.y (abcdef1234)
#
# Related commands worth knowing: `az bicep list-versions`, `az bicep upgrade`,
# and the [bicep] use_binary_from_path setting, which decides whether the CLI
# prefers a system-wide bicep over its own managed copy.
#
# -----------------------------------------------------------------------------
# STEP 4 — F4: make main.bicep compile
# -----------------------------------------------------------------------------
# Diagnosis — let the compiler name every fault:
#   az bicep build --file "$AZ900_LAB_ROOT/iac/main.bicep" --stdout
#     Error BCP057: The name "location" does not exist in the current context.
#     Error BCP037: The property "skuName" is not allowed on objects of type
#                   "StorageAccountPropertiesCreateParameters...".
#     Error BCP035: The specified "resource" declaration is missing the
#                   following required properties: "kind", "sku".
#
# Fixed file:
#
#   targetScope = 'resourceGroup'
#
#   @description('Short workload name; part of the storage account name.')
#   @maxLength(11)
#   param workload string = 'az900lab'
#
#   @description('Region for the storage account. Defaults to the RG region.')
#   param location string = resourceGroup().location          // <- fixes BCP057
#
#   @description('Replication SKU for the storage account.')
#   @allowed([
#     'Standard_LRS'
#     'Standard_GRS'
#   ])
#   param skuName string = 'Standard_LRS'
#
#   var storageName = toLower('st${workload}${uniqueString(resourceGroup().id)}')
#
#   resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' = {
#     name: storageName
#     location: location
#     sku: {                                                  // <- fixes BCP037
#       name: skuName
#     }
#     kind: 'StorageV2'                                       // <- fixes BCP035
#     properties: {
#       minimumTlsVersion: 'TLS1_2'
#       supportsHttpsTrafficOnly: true
#       allowBlobPublicAccess: false
#     }
#   }
#
#   output storageAccountId string = stg.id
#   output blobEndpoint string = stg.properties.primaryEndpoints.blob
#
# Verify:
#   az bicep build --file "$AZ900_LAB_ROOT/iac/main.bicep" --outfile /tmp/main.json
#   python3 -m json.tool /tmp/main.json | head -30
#
# Exam framing: Bicep is a transpiler, not a runtime. `az bicep build` produces
# the ARM JSON that Resource Manager actually receives; every guarantee you get
# from ARM — idempotency, declarative desired state, RBAC, locks, tags,
# dependency ordering — belongs to ARM, not to Bicep. Bicep only makes the JSON
# writable by humans, and catches these three classes of error before the wire.
#
# -----------------------------------------------------------------------------
# STEP 5 — F5: make azuredeploy.json deployable
# -----------------------------------------------------------------------------
# Diagnosis, one layer at a time:
#   python3 -m json.tool "$AZ900_LAB_ROOT/iac/azuredeploy.json"
#     Expecting value: line 45 column 5 (char ...)     <- the trailing comma
#
# The four fixes:
#   (a) delete the comma after the last element of "resources"
#   (b) add the mandatory "contentVersion": "1.0.0.0"
#   (c) $schema must match the deployment scope. Resource-group scope is
#       https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#
#       The subscriptionDeploymentTemplate schema forbids resourceGroup() and
#       expects a different resource set — the two are not interchangeable.
#   (d) the web app references the plan through resourceId(), which ARM cannot
#       see as a dependency. Add an explicit dependsOn, or ARM may start the
#       site before the serverfarm exists and fail with a 404 on serverFarmId.
#
# Fixed head of the file:
#
#   {
#     "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
#     "contentVersion": "1.0.0.0",
#     "parameters": {
#       "location": {
#         "type": "string",
#         "defaultValue": "[resourceGroup().location]",
#         "metadata": { "description": "Region for both resources." }
#       },
#       ...
#
# and the sites resource:
#
#       {
#         "type": "Microsoft.Web/sites",
#         "apiVersion": "2023-12-01",
#         "name": "[variables('siteName')]",
#         "location": "[parameters('location')]",
#         "kind": "app,linux",
#         "dependsOn": [
#           "[resourceId('Microsoft.Web/serverfarms', parameters('planName'))]"
#         ],
#         "properties": { ... }
#       }
#     ]
#   }
#
# Verify locally:
#   python3 -m json.tool "$AZ900_LAB_ROOT/iac/azuredeploy.json" >/dev/null && echo "JSON OK"
#
# Verify against ARM (needs a real subscription and an existing RG — outside
# this offline lab, but this is the command the exam expects you to know):
#   az group create -n rg-az900-lab-33 -l eastus
#   az deployment group validate -g rg-az900-lab-33 \
#       --template-file azuredeploy.json
#   az deployment group what-if  -g rg-az900-lab-33 \
#       --template-file azuredeploy.json
#   az deployment group create   -g rg-az900-lab-33 \
#       --name az900-lab-33-run1 --template-file azuredeploy.json
#   az deployment group list -g rg-az900-lab-33 -o table   # deployment history
#
# `validate` checks schema and scope; `what-if` shows the delta ARM would apply
# and is the closest thing to a plan; `create` is idempotent in Incremental mode
# (the default) — Complete mode would DELETE resources in the RG that are not in
# the template, which is the single most dangerous ARM flag on the exam.
#
# -----------------------------------------------------------------------------
# STEP 6 — F6: bring the Azure Arc agent back
# -----------------------------------------------------------------------------
# Diagnosis, fault 1 of 2:
#   systemctl --user status az900-arc-mock.service
#     Active: failed (Result: exit-code)
#     ... (code=exited, status=203/EXEC)
#   systemctl --user cat az900-arc-mock.service | grep ExecStart
#     ExecStart=/home/<you>/az900-lab-3.3/bin/az900-arc-mokc     <- typo
#   ls "$AZ900_LAB_ROOT/bin"
#     az900-arc-mock
#
# Fix and reload (editing a unit without daemon-reload changes nothing):
#   systemctl --user edit --full az900-arc-mock.service   # or edit the file
#   # ExecStart=%h/az900-lab-3.3/bin/az900-arc-mock
#   systemctl --user daemon-reload
#   systemctl --user restart az900-arc-mock.service
#
# Diagnosis, fault 2 of 2 — now the agent itself speaks:
#   journalctl --user -u az900-arc-mock.service -n 20 --no-pager
#     azcmagent-mock: config is not valid JSON: Expecting property name ...
#   ... then, after the comma is removed:
#     azcmagent-mock:   missing or empty keys: resourceGroup
#   ... then:
#     azcmagent-mock:   agentStatus is 'Disconnected'; the machine is not
#                       projected into ARM
#
# Fixed $AZ900_LAB_ROOT/arc/agentconfig.json:
#
#   {
#     "resourceName": "arc-lab-vm-01",
#     "resourceGroup": "rg-az900-lab-33",
#     "location": "eastus",
#     "tenantId": "00000000-0000-0000-0000-000000000000",
#     "cloud": "AzureCloud",
#     "agentStatus": "Connected"
#   }
#
# Restart and confirm:
#   systemctl --user restart az900-arc-mock.service
#   systemctl --user is-active az900-arc-mock.service      # active
#   ARC_MOCK_CONFIG="$AZ900_LAB_ROOT/arc/agentconfig.json" \
#       "$AZ900_LAB_ROOT/bin/az900-arc-mock" --status
#     Connected: arc-lab-vm-01 -> /subscriptions/<sub>/resourceGroups/
#     rg-az900-lab-33/providers/Microsoft.HybridCompute/machines/arc-lab-vm-01 (eastus)
#
# On a real machine the equivalent sequence is:
#   sudo systemctl status himds
#   sudo azcmagent show
#   sudo azcmagent connect --resource-group rg-az900-lab-33 --location eastus \
#        --subscription-id <sub> --tenant-id <tenant>
#   az connectedmachine list -g rg-az900-lab-33 -o table
#
# Exam framing: Azure Arc's whole purpose is to create that
# Microsoft.HybridCompute/machines ARM resource for a server that lives
# somewhere else — on-premises, another cloud, the edge. Once the resource
# exists, the ordinary Azure management plane applies to it: RBAC, tags, Azure
# Policy / guest configuration, Update Manager, Defender for Cloud, Azure
# Monitor. Agent down means the ARM resource stops receiving heartbeats and
# every one of those controls silently stops applying to that machine — which
# is why F6 is a governance incident, not a Linux one.
#
# -----------------------------------------------------------------------------
# STEP 7 — Grade and tear down
# -----------------------------------------------------------------------------
#   ./az900-3.3-breakfix.sh verify
#   ./az900-3.3-breakfix.sh clean
#
# -----------------------------------------------------------------------------
# WHAT THIS MAPS TO IN THE 3.3 OBJECTIVE
# -----------------------------------------------------------------------------
#   Azure portal ......... the only tool that survives all six faults, because
#                          it runs in Microsoft's browser front end, not here.
#                          That is its role: the break-glass path when the local
#                          toolchain is the thing that is broken. It is also the
#                          least reproducible — nothing you click is in git.
#   Azure Cloud Shell .... the same fix, without F1/F3: the CLI, PowerShell and
#                          bicep are pre-installed and Microsoft-maintained, and
#                          $HOME persists in an Azure Files share. It trades
#                          local control for a maintained toolchain.
#   Azure CLI ............ F1, F2, F3 — cross-platform, `az <group> <cmd>`,
#                          config in AZURE_CONFIG_DIR, defaults define scope.
#   Azure PowerShell ..... same control plane, different client: Connect-AzAccount,
#                          New-AzResourceGroupDeployment, Set-AzDefault. Choose
#                          by ecosystem, not by capability; both call ARM.
#   Azure Arc ............ F6 — projects non-Azure machines into ARM so that one
#                          management plane covers hybrid and multicloud estate.
#   ARM ................... the thing every one of the above talks to. Single
#                          control plane, per-resource-group scoping,
#                          idempotent declarative deployments, RBAC and locks
#                          enforced at the plane, not at the client.
#   ARM templates / Bicep . F4, F5 — infrastructure as code. Declarative, so you
#                          state desired state and ARM computes the delta;
#                          idempotent, so re-running is safe; modular and
#                          reviewable, so infrastructure changes go through the
#                          same gate as application code.
# =============================================================================