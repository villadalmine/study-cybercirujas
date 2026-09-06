#!/usr/bin/env bash
# =============================================================================
#  AZ-900 — Microsoft Azure Fundamentals (exam version 2026-07-20)
#  Domain 3 · Topic 3.1 — "Describe cost management in Azure"  (weight: 8.33 %)
#
#  BREAK & FIX LAB — "The month the platform bill tripled and nobody was paged"
#
#  WHAT THIS SCRIPT DOES
#    It builds a self-contained FinOps sandbox under $LAB_ROOT (default:
#    ~/az900-lab-3-1) that mirrors a real Azure cost-management setup:
#
#      * two subscriptions (a production one and a sandbox one)
#      * a tagged resource inventory used for cost allocation
#      * a Microsoft.Consumption/budgets ARM template deployed at subscription
#        scope, with Actual and Forecasted alert notifications
#      * a scheduled Cost Management export writing daily ActualCost CSVs
#      * a cost report tool the "platform team" runs every morning
#
#    It then injects FOUR controlled faults, each mapped to one AZ-900 3.1
#    concept, and hands you a verifier that tells you which ones are still open.
#
#  SAFETY — read before running
#    * Everything lives inside $LAB_ROOT. Nothing outside it is created,
#      modified or deleted. No sudo, no systemd, no package installs.
#    * `$LAB_ROOT/bin/az` is a LAB SHIM, not the Azure CLI. It implements a
#      faithful subset of the real command surface, offline. It performs ZERO
#      network I/O, holds no credentials, and never reads ~/.azure. Because
#      `source lab.env` puts it first in PATH, the real `az` (if installed) is
#      shadowed for that shell only — open a new shell to get it back.
#    * Still: run this on a disposable lab VM, as an unprivileged user.
#    * `./<this-script> clean` removes the lab directory (marker-guarded).
#
#  REQUIREMENTS: bash >= 4, python3 >= 3.8, GNU coreutils (GNU `date -d`).
#
#  OFFICIAL SOURCES
#    AZ-900 study guide
#      https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#    Cost Management + Billing documentation
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/
#    Create and manage budgets
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
#    Microsoft.Consumption/budgets REST reference (properties, enums, limits)
#      https://learn.microsoft.com/en-us/rest/api/consumption/budgets/create-or-update
#    Group and allocate costs with tags
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/group-filter
#    Tag resources — naming rules and limits
#      https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
#    Create and manage exported data (scheduled exports)
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports
#    Understand cost management scopes
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes
#    az costmanagement / az consumption CLI reference
#      https://learn.microsoft.com/en-us/cli/azure/costmanagement
#      https://learn.microsoft.com/en-us/cli/azure/consumption/budget
# =============================================================================

set -euo pipefail

LAB_ROOT="${LAB_ROOT:-$HOME/az900-lab-3-1}"
MARKER=".az900-3-1-lab"
SUB_PROD_ID="11111111-1111-1111-1111-111111111111"
SUB_SBX_ID="22222222-2222-2222-2222-222222222222"
SUB_PROD_NAME="contoso-platform-prod"
SUB_SBX_NAME="contoso-sandbox"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'
c_cya=$'\033[36m'; c_bld=$'\033[1m';  c_off=$'\033[0m'

die() { printf '%s[lab]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
say() { printf '%s[lab]%s %s\n' "$c_cya" "$c_off" "$*"; }

check_deps() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required."
  date -u -d "2026-01-01 +1 month" +%Y-%m-01 >/dev/null 2>&1 \
    || die "GNU 'date -d' is required (this lab expects a Linux VM)."
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 is required."
  [ "$(id -u)" -ne 0 ] || say "${c_yel}WARNING: running as root is unnecessary here.${c_off}"
}

confirm() {
  [ "${LAB_ASSUME_YES:-}" = "yes" ] && return 0
  [ ! -t 0 ] && die "Non-interactive run: set LAB_ASSUME_YES=yes to proceed."
  printf '%s\n' "This will create and then deliberately misconfigure a lab under:"
  printf '    %s\n' "$LAB_ROOT"
  printf '%s' "Type BREAK to continue: "
  local ans; read -r ans
  [ "$ans" = "BREAK" ] || die "Aborted."
}

# ---------------------------------------------------------------------------
# Dates (computed once, injected into generated files)
# ---------------------------------------------------------------------------
MONTH_START="$(date -u +%Y-%m-01)"
CUR_YM="$(date -u +%Y%m)"
MID_MONTH="$(date -u +%Y-%m-15)"
PLUS_ONE_YEAR="$(date -u -d "$MONTH_START +1 year" +%Y-%m-01)"
STALE_YM="$(date -u -d "$MONTH_START -2 months" +%Y%m)"
STALE_DAY="$(date -u -d "$MONTH_START -2 months" +%Y-%m-01)"

# ---------------------------------------------------------------------------
# Lab construction (clean state)
# ---------------------------------------------------------------------------
build_lab() {
  say "Building the sandbox in $LAB_ROOT ..."
  mkdir -p "$LAB_ROOT"/{bin,inventory,budgets,policy,state,exports,docs,.azure}
  : > "$LAB_ROOT/$MARKER"

  # ---- resource inventory (cost allocation source of truth) ----------------
  cat > "$LAB_ROOT/inventory/resources.json" <<'INVENTORY'
{
  "subscriptions": [
    { "id": "11111111-1111-1111-1111-111111111111",
      "name": "contoso-platform-prod", "state": "Enabled",
      "tenantId": "aaaabbbb-cccc-dddd-eeee-ffff00001111" },
    { "id": "22222222-2222-2222-2222-222222222222",
      "name": "contoso-sandbox", "state": "Enabled",
      "tenantId": "aaaabbbb-cccc-dddd-eeee-ffff00001111" }
  ],
  "resources": {
    "11111111-1111-1111-1111-111111111111": [
      { "name": "aks-plat-prod-01", "resourceGroup": "rg-platform-prod",
        "type": "Microsoft.ContainerService/managedClusters", "location": "eastus",
        "meterCategory": "Virtual Machines", "monthlyCost": 2140.80,
        "tags": { "CostCenter": "CC-1001", "Environment": "prod", "Owner": "platform-sre" } },
      { "name": "law-plat-prod", "resourceGroup": "rg-platform-prod",
        "type": "Microsoft.OperationalInsights/workspaces", "location": "eastus",
        "meterCategory": "Azure Monitor", "monthlyCost": 418.25,
        "tags": { "CostCenter": "CC-1001", "Environment": "prod", "Owner": "platform-sre" } },
      { "name": "kv-plat-prod", "resourceGroup": "rg-platform-prod",
        "type": "Microsoft.KeyVault/vaults", "location": "eastus",
        "meterCategory": "Key Vault", "monthlyCost": 12.40,
        "tags": { "CostCenter": "CC-1001", "Environment": "prod", "Owner": "platform-sre" } },
      { "name": "agw-plat-prod", "resourceGroup": "rg-platform-prod",
        "type": "Microsoft.Network/applicationGateways", "location": "eastus",
        "meterCategory": "Application Gateway", "monthlyCost": 286.10,
        "tags": { "CostCenter": "CC-1001", "Environment": "prod", "Owner": "platform-sre" } },
      { "name": "sqlmi-data-prod", "resourceGroup": "rg-data-prod",
        "type": "Microsoft.Sql/managedInstances", "location": "eastus",
        "meterCategory": "SQL Managed Instance", "monthlyCost": 1180.00,
        "tags": { "CostCenter": "CC-2002", "Environment": "prod", "Owner": "data-platform" } },
      { "name": "stdataprod01", "resourceGroup": "rg-data-prod",
        "type": "Microsoft.Storage/storageAccounts", "location": "eastus",
        "meterCategory": "Storage", "monthlyCost": 342.90,
        "tags": { "CostCenter": "CC-2002", "Environment": "prod", "Owner": "data-platform" } },
      { "name": "evhns-data-prod", "resourceGroup": "rg-data-prod",
        "type": "Microsoft.EventHub/namespaces", "location": "eastus",
        "meterCategory": "Event Hubs", "monthlyCost": 221.60,
        "tags": { "CostCenter": "CC-2002", "Environment": "prod", "Owner": "data-platform" } },
      { "name": "cdnp-edge-prod", "resourceGroup": "rg-edge-prod",
        "type": "Microsoft.Cdn/profiles", "location": "global",
        "meterCategory": "Content Delivery Network", "monthlyCost": 96.75,
        "tags": { "CostCenter": "CC-3003", "Environment": "prod", "Owner": "edge-team" } },
      { "name": "pip-edge-prod", "resourceGroup": "rg-edge-prod",
        "type": "Microsoft.Network/publicIPAddresses", "location": "eastus",
        "meterCategory": "Virtual Network", "monthlyCost": 18.25,
        "tags": { "CostCenter": "CC-3003", "Environment": "prod", "Owner": "edge-team" } },
      { "name": "vm-edge-jump-01", "resourceGroup": "rg-edge-prod",
        "type": "Microsoft.Compute/virtualMachines", "location": "eastus",
        "meterCategory": "Virtual Machines", "monthlyCost": 95.50,
        "tags": { "CostCenter": "CC-3003", "Environment": "prod", "Owner": "edge-team" } }
    ],
    "22222222-2222-2222-2222-222222222222": [
      { "name": "vm-sbx-01", "resourceGroup": "rg-sandbox",
        "type": "Microsoft.Compute/virtualMachines", "location": "eastus2",
        "meterCategory": "Virtual Machines", "monthlyCost": 28.40,
        "tags": { "CostCenter": "CC-9999", "Environment": "sandbox", "Owner": "platform-sre" } },
      { "name": "stsbx01", "resourceGroup": "rg-sandbox",
        "type": "Microsoft.Storage/storageAccounts", "location": "eastus2",
        "meterCategory": "Storage", "monthlyCost": 9.15,
        "tags": { "CostCenter": "CC-9999", "Environment": "sandbox", "Owner": "platform-sre" } }
    ]
  }
}
INVENTORY

  # ---- CLI state (mirrors `az account set`) --------------------------------
  cat > "$LAB_ROOT/state/cli-config.json" <<CLICFG
{ "defaultSubscription": "$SUB_PROD_ID" }
CLICFG

  # ---- scheduled Cost Management export ------------------------------------
  cat > "$LAB_ROOT/state/exports.json" <<EXPORTS
{
  "exports": [
    {
      "name": "daily-actualcost",
      "type": "ActualCost",
      "timeframe": "MonthToDate",
      "recurrence": "Daily",
      "scope": "/subscriptions/$SUB_PROD_ID",
      "storageAccountId": "/subscriptions/$SUB_PROD_ID/resourceGroups/rg-platform-prod/providers/Microsoft.Storage/storageAccounts/stcostexports",
      "storageContainer": "costexports",
      "storageDirectory": "exports",
      "status": "Active",
      "lastRun": null
    }
  ]
}
EXPORTS

  # ---- last known-good export (two months old, half the platform) ----------
  cat > "$LAB_ROOT/exports/actualcost-$STALE_YM.csv" <<STALECSV
Date,SubscriptionId,ResourceGroupName,ResourceId,MeterCategory,Quantity,UnitOfMeasure,CostInBillingCurrency,BillingCurrency,Tags
$STALE_DAY,$SUB_PROD_ID,rg-platform-prod,/subscriptions/$SUB_PROD_ID/resourceGroups/rg-platform-prod/providers/Microsoft.ContainerService/managedClusters/aks-plat-prod-01,Virtual Machines,720,1 Hour,712.90,USD,"CostCenter: CC-1001"
$STALE_DAY,$SUB_PROD_ID,rg-platform-prod,/subscriptions/$SUB_PROD_ID/resourceGroups/rg-platform-prod/providers/Microsoft.OperationalInsights/workspaces/law-plat-prod,Azure Monitor,180,1 GB,181.05,USD,"CostCenter: CC-1001"
$STALE_DAY,$SUB_PROD_ID,rg-data-prod,/subscriptions/$SUB_PROD_ID/resourceGroups/rg-data-prod/providers/Microsoft.Sql/managedInstances/sqlmi-data-prod,SQL Managed Instance,720,1 Hour,205.00,USD,"CostCenter: CC-2002"
$STALE_DAY,$SUB_PROD_ID,rg-data-prod,/subscriptions/$SUB_PROD_ID/resourceGroups/rg-data-prod/providers/Microsoft.Storage/storageAccounts/stdataprod01,Storage,4200,1 GB/Month,63.90,USD,"CostCenter: CC-2002"
$STALE_DAY,$SUB_PROD_ID,rg-edge-prod,/subscriptions/$SUB_PROD_ID/resourceGroups/rg-edge-prod/providers/Microsoft.Cdn/profiles/cdnp-edge-prod,Content Delivery Network,9100,1 GB,41.75,USD,"CostCenter: CC-3003"
STALECSV

  # ---- organisational standards the student must satisfy -------------------
  cat > "$LAB_ROOT/policy/tagging-standard.md" <<'TAGSTD'
# Contoso FinOps standard — cost allocation (extract)

## 1. Cost centre tag

Every resource in a production subscription carries the tag `CostCenter`.
The value is assigned per resource group and is **exact**:

| Resource group     | CostCenter |
|--------------------|------------|
| rg-platform-prod   | CC-1001    |
| rg-data-prod       | CC-2002    |
| rg-edge-prod       | CC-3003    |
| rg-sandbox         | CC-9999    |

Allowed value pattern: `^CC-[0-9]{4}$` — uppercase, no leading/trailing spaces.

Why "exact" is written in bold: in Azure Resource Manager, tag **names** are
case-insensitive, but tag **values** are case-SENSITIVE. Cost Management groups
by the literal value it receives, so `CC-3003`, `cc-3003` and `CC-3003 ` are
three different rows in the cost analysis, three different chargeback lines,
and three different arguments with Finance.
  https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
  https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/group-filter

Tags are NOT inherited by child resources and are NOT applied retroactively to
usage recorded before the tag existed. Tag at creation time, enforce with Azure
Policy (`Modify` + a remediation task), audit continuously.

## 2. Budget standard (subscription scope)

* One budget per production subscription, `timeGrain: Monthly`.
* `amount` must be greater than or equal to the previous month's actual cost.
  A budget below current run-rate is noise: it fires on day 2 every month and
  the team learns to ignore the alert.
* Mandatory notifications, both `enabled: true` and both with at least one
  contact:
    - `thresholdType: Actual`,     threshold <= 80  (we already spent it)
    - `thresholdType: Forecasted`, threshold <= 100 (we are going to spend it)
* `timePeriod.startDate` must be the FIRST day of a month.
* A budget does not stop spending. It notifies. Enforcement is a separate
  action group / automation.
  https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets

## 3. Exports

The scheduled export `daily-actualcost` (type `ActualCost`, recurrence `Daily`)
must be `Active` and must write into the `exports` storage directory, which is
the only directory the reporting job reads.
  https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports
TAGSTD

  cat > "$LAB_ROOT/docs/RUNBOOK.md" <<'RUNBOOK'
# Runbook — morning cost review

    source ~/az900-lab-3-1/lab.env     # puts the lab CLI on PATH

    cost-report.sh                     # the report Finance receives
    cost-report.sh --audit-tags        # allocation hygiene

Useful primitives (all implemented by the lab shim):

    az account show
    az account list -o table
    az account set --subscription <name|id>

    az resource list -o table
    az resource list -g rg-edge-prod -o table
    az resource list --query "[?tags.CostCenter == null]" -o table
    az tag list --resource-id <id>
    az tag update --resource-id <id> --operation merge --tags CostCenter=CC-1001

    az costmanagement query --type ActualCost --timeframe MonthToDate \
        --dataset-grouping name=CostCenter type=TagKey -o table
    az costmanagement export list -o table
    az costmanagement export update --name daily-actualcost \
        --storage-directory exports --status Active

    az deployment sub create --name budget-platform --location eastus \
        --template-file budgets/budget-platform-monthly.json
    az consumption budget list -o table

Scope matters: every cost query answers for ONE scope. `az account show` tells
you which subscription you are asking about. Asking the wrong scope returns a
perfectly valid, perfectly useless number.
  https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes
RUNBOOK

  cat > "$LAB_ROOT/lab.env" <<ENVFILE
# source this file: source $LAB_ROOT/lab.env
export LAB_ROOT="$LAB_ROOT"
export PATH="\$LAB_ROOT/bin:\$PATH"
export AZURE_CONFIG_DIR="\$LAB_ROOT/.azure"
echo "[lab] PATH now prefers \$LAB_ROOT/bin — 'az' is the OFFLINE lab shim."
echo "[lab] Open a new shell to get the real Azure CLI back."
ENVFILE

  write_shim
  write_cost_report
  write_verifier
  chmod +x "$LAB_ROOT"/bin/*
}

# ---------------------------------------------------------------------------
# The offline Azure CLI shim
# ---------------------------------------------------------------------------
write_shim() {
  cat > "$LAB_ROOT/bin/az" <<'AZ_SHIM'
#!/usr/bin/env python3
"""Offline lab shim reproducing a subset of the Azure CLI surface.

Real command syntax is preserved on purpose so that muscle memory transfers.
No network I/O, no credentials, no access to ~/.azure. State lives in
$LAB_ROOT/state/.
"""
import csv
import datetime
import json
import os
import re
import sys

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INV_F = os.path.join(LAB, "inventory", "resources.json")
CFG_F = os.path.join(LAB, "state", "cli-config.json")
BUD_F = os.path.join(LAB, "state", "budgets.json")
EXP_F = os.path.join(LAB, "state", "exports.json")

TIME_GRAINS = ("Monthly", "Quarterly", "Annually")
THRESHOLD_TYPES = ("Actual", "Forecasted")
EXPORT_TYPES = ("ActualCost", "AmortizedCost", "Usage")


def fail(code, msg, rc=1):
    sys.stderr.write("ERROR: (%s) %s\n" % (code, msg))
    sys.exit(rc)


def load(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except FileNotFoundError:
        if default is not None:
            return default
        fail("LabStateMissing", "%s not found. Rebuild the lab." % path)
    except ValueError as exc:
        fail("LabStateCorrupt", "%s is not valid JSON: %s" % (path, exc))


def save(path, obj):
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")


def is_flag(tok):
    if not tok.startswith("-"):
        return False
    try:
        float(tok)
        return False
    except ValueError:
        return True


ALIASES = {"g": "resource-group", "o": "output", "n": "name"}


def parse(argv):
    flags, pos, i = {}, [], 0
    while i < len(argv):
        tok = argv[i]
        if tok.startswith("--"):
            key = tok[2:]
        elif is_flag(tok):
            key = ALIASES.get(tok[1:], tok[1:])
        else:
            pos.append(tok)
            i += 1
            continue
        vals, i = [], i + 1
        while i < len(argv) and not is_flag(argv[i]):
            vals.append(argv[i])
            i += 1
        flags[key] = vals
    return pos, flags


def one(flags, key, default=None):
    vals = flags.get(key)
    return vals[0] if vals else default


def kvs(vals):
    out = {}
    for item in vals or []:
        if "=" not in item:
            fail("InvalidArgumentValue", "expected key=value, got '%s'" % item)
        k, v = item.split("=", 1)
        out[k] = v
    return out


def money(x):
    return round(float(x) + 1e-9, 2)


def now():
    return datetime.datetime.utcnow()


def cur_ym():
    return now().strftime("%Y%m")


def month_start():
    return now().strftime("%Y-%m-01")


# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------
def project(query, data):
    if not query:
        return data
    q = query.strip()
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", q):
        if isinstance(data, dict):
            return data.get(q)
        if isinstance(data, list):
            return [d.get(q) for d in data]
    m = re.fullmatch(r"\[\]\.([A-Za-z][A-Za-z0-9_]*)", q)
    if m and isinstance(data, list):
        return [d.get(m.group(1)) for d in data]
    m = re.fullmatch(
        r"\[\?tags\.CostCenter\s*==\s*`?null`?\](?:\.([A-Za-z][A-Za-z0-9_]*))?", q)
    if m and isinstance(data, list):
        rows = [d for d in data if not (d.get("tags") or {}).get("CostCenter")]
        return [r.get(m.group(1)) for r in rows] if m.group(1) else rows
    fail("LabQueryUnsupported",
         "the lab shim implements only a few JMESPath forms "
         "(bare key, [].key, [?tags.CostCenter == null][.key]). "
         "Re-run without --query.", 2)


def emit(data, fmt, cols=None):
    fmt = (fmt or "json").lower()
    if fmt == "json":
        print(json.dumps(data, indent=2))
        return
    if fmt == "tsv":
        if isinstance(data, list):
            for row in data:
                if isinstance(row, dict):
                    print("\t".join(str(row.get(c, "")) for c in (cols or row)))
                else:
                    print("" if row is None else row)
        elif isinstance(data, dict):
            print("\t".join(str(data.get(c, "")) for c in (cols or data)))
        else:
            print("" if data is None else data)
        return
    if fmt == "table":
        rows = data if isinstance(data, list) else [data]
        rows = [r for r in rows if isinstance(r, dict)]
        if not rows:
            return
        cols = cols or list(rows[0].keys())
        widths = [max(len(c), max(len(str(r.get(c, ""))) for r in rows)) for c in cols]
        print("  ".join(c.ljust(w) for c, w in zip(cols, widths)).rstrip())
        print("  ".join("-" * w for w in widths))
        for r in rows:
            print("  ".join(str(r.get(c, "")).ljust(w)
                            for c, w in zip(cols, widths)).rstrip())
        return
    fail("InvalidOutputFormat", "unknown --output '%s'" % fmt)


# --------------------------------------------------------------------------
# state accessors
# --------------------------------------------------------------------------
def current_sub():
    inv = load(INV_F)
    cfg = load(CFG_F, {"defaultSubscription": None})
    sid = cfg.get("defaultSubscription")
    for sub in inv["subscriptions"]:
        if sub["id"] == sid:
            return sub
    fail("SubscriptionNotFound",
         "no active subscription is set. Run 'az account set --subscription <name>'.")


def resources_of(sub_id):
    return load(INV_F)["resources"].get(sub_id, [])


def rid(sub_id, res):
    return "/subscriptions/%s/resourceGroups/%s/providers/%s/%s" % (
        sub_id, res["resourceGroup"], res["type"], res["name"])


def find_by_id(resource_id):
    inv = load(INV_F)
    for sub_id, items in inv["resources"].items():
        for res in items:
            if rid(sub_id, res).lower() == resource_id.lower():
                return inv, sub_id, res
    return None, None, None


def flat(sub_id, res):
    return {
        "id": rid(sub_id, res),
        "name": res["name"],
        "resourceGroup": res["resourceGroup"],
        "type": res["type"],
        "location": res["location"],
        "monthlyCost": res["monthlyCost"],
        "tags": res.get("tags") or {},
    }


# --------------------------------------------------------------------------
# az account
# --------------------------------------------------------------------------
def cmd_account(pos, flags):
    sub_cmd = pos[0] if pos else "show"
    out_fmt = one(flags, "output", "json")
    inv = load(INV_F)
    cfg = load(CFG_F, {"defaultSubscription": None})
    if sub_cmd == "show":
        sub = current_sub()
        data = {"id": sub["id"], "name": sub["name"], "state": sub["state"],
                "tenantId": sub["tenantId"], "isDefault": True}
        emit(project(one(flags, "query"), data), out_fmt,
             ["name", "id", "state", "isDefault"])
    elif sub_cmd == "list":
        data = [{"name": s["name"], "id": s["id"], "state": s["state"],
                 "isDefault": s["id"] == cfg.get("defaultSubscription")}
                for s in inv["subscriptions"]]
        emit(project(one(flags, "query"), data), out_fmt,
             ["name", "id", "state", "isDefault"])
    elif sub_cmd == "set":
        target = one(flags, "subscription")
        if not target:
            fail("MissingArgument", "--subscription is required")
        for s in inv["subscriptions"]:
            if target in (s["id"], s["name"]):
                save(CFG_F, {"defaultSubscription": s["id"]})
                return
        fail("SubscriptionNotFound",
             "The subscription of '%s' doesn't exist in cloud 'AzureCloud'." % target)
    else:
        fail("UnknownCommand", "az account %s is not implemented in the lab shim." % sub_cmd)


# --------------------------------------------------------------------------
# az resource / az tag
# --------------------------------------------------------------------------
def cmd_resource(pos, flags):
    if not pos or pos[0] != "list":
        fail("UnknownCommand", "only 'az resource list' is implemented.")
    sub = current_sub()
    rows = [flat(sub["id"], r) for r in resources_of(sub["id"])]
    rg = one(flags, "resource-group")
    if rg:
        rows = [r for r in rows if r["resourceGroup"].lower() == rg.lower()]
    for k, v in kvs(flags.get("tag")).items():
        rows = [r for r in rows if (r["tags"] or {}).get(k) == v]
    data = project(one(flags, "query"), rows)
    view = data
    if isinstance(data, list) and data and isinstance(data[0], dict):
        view = [{"Name": r["name"], "ResourceGroup": r["resourceGroup"],
                 "Type": r["type"], "Location": r["location"],
                 "CostCenter": (r["tags"] or {}).get("CostCenter", "")} for r in data]
        if (one(flags, "output", "json") or "json").lower() == "json":
            view = data
    emit(view, one(flags, "output", "json"),
         ["Name", "ResourceGroup", "Type", "Location", "CostCenter"])


def cmd_tag(pos, flags):
    sub_cmd = pos[0] if pos else ""
    resource_id = one(flags, "resource-id")
    if sub_cmd not in ("list", "update"):
        fail("UnknownCommand", "only 'az tag list|update --resource-id' is implemented.")
    if not resource_id:
        fail("MissingArgument", "--resource-id is required")
    inv, sub_id, res = find_by_id(resource_id)
    if res is None:
        fail("ResourceNotFound",
             "The Resource '%s' was not found. Check scope and spelling." % resource_id)
    if sub_cmd == "list":
        emit({"id": resource_id, "properties": {"tags": res.get("tags") or {}}},
             one(flags, "output", "json"))
        return
    op = (one(flags, "operation", "merge") or "merge").lower()
    if op not in ("merge", "replace", "delete"):
        fail("InvalidArgumentValue",
             "--operation must be one of merge, replace, delete")
    incoming = kvs(flags.get("tags"))
    tags = dict(res.get("tags") or {})
    if op == "merge":
        tags.update(incoming)
    elif op == "replace":
        tags = incoming
    else:
        for k in incoming:
            tags.pop(k, None)
    for k, v in tags.items():
        if len(k) > 512 or len(v) > 256:
            fail("InvalidTag", "tag name <=512 chars, tag value <=256 chars")
    if len(tags) > 50:
        fail("TooManyTags", "a resource supports at most 50 tags")
    res["tags"] = tags
    save(INV_F, inv)
    emit({"id": resource_id, "properties": {"tags": tags}},
         one(flags, "output", "json"))


# --------------------------------------------------------------------------
# az costmanagement query
# --------------------------------------------------------------------------
def scope_sub(flags):
    scope = one(flags, "scope")
    if not scope:
        return current_sub()["id"]
    m = re.search(r"/subscriptions/([0-9a-fA-F-]{36})", scope)
    if not m:
        fail("InvalidScope",
             "the lab shim supports subscription scopes: /subscriptions/<guid>")
    return m.group(1)


def cm_query(flags):
    q_type = one(flags, "type", "ActualCost")
    if q_type not in ("ActualCost", "AmortizedCost", "Usage"):
        fail("InvalidType", "--type must be ActualCost, AmortizedCost or Usage")
    timeframe = one(flags, "timeframe", "MonthToDate")
    if timeframe not in ("MonthToDate", "BillingMonthToDate", "TheLastMonth",
                         "WeekToDate", "Custom"):
        fail("InvalidTimeframe", "unsupported --timeframe '%s'" % timeframe)
    grouping = kvs(flags.get("dataset-grouping"))
    g_name = grouping.get("name", "ResourceGroupName")
    g_type = grouping.get("type", "Dimension")
    if g_type not in ("Dimension", "TagKey"):
        fail("InvalidGrouping", "grouping type must be Dimension or TagKey")
    sub_id = scope_sub(flags)
    buckets = {}
    for res in resources_of(sub_id):
        if g_type == "TagKey":
            # Cost Management returns tag keys lower-cased and preserves the
            # value verbatim -- which is exactly why value drift splits rows.
            key = (res.get("tags") or {}).get(g_name, "")
        else:
            key = {"ResourceGroupName": res["resourceGroup"],
                   "ResourceType": res["type"],
                   "MeterCategory": res["meterCategory"]}.get(g_name)
            if key is None:
                fail("InvalidGrouping", "unsupported dimension '%s'" % g_name)
        buckets[key] = money(buckets.get(key, 0) + res["monthlyCost"])
    if g_type == "TagKey":
        cols = [{"name": "PreTaxCost", "type": "Number"},
                {"name": "TagKey", "type": "String"},
                {"name": "TagValue", "type": "String"},
                {"name": "Currency", "type": "String"}]
        rows = [[v, g_name.lower(), k, "USD"] for k, v in sorted(buckets.items())]
    else:
        cols = [{"name": "PreTaxCost", "type": "Number"},
                {"name": g_name, "type": "String"},
                {"name": "Currency", "type": "String"}]
        rows = [[v, k, "USD"] for k, v in sorted(buckets.items())]
    return {"id": "/subscriptions/%s/providers/Microsoft.CostManagement/query" % sub_id,
            "name": "lab-query", "type": "Microsoft.CostManagement/query",
            "properties": {"nextLink": None},
            "columns": cols, "rows": rows}


def write_export(export, sub_id):
    directory = export.get("storageDirectory") or "exports"
    target = os.path.join(LAB, directory)
    os.makedirs(target, exist_ok=True)
    path = os.path.join(target, "actualcost-%s.csv" % cur_ym())
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["Date", "SubscriptionId", "ResourceGroupName", "ResourceId",
                    "MeterCategory", "Quantity", "UnitOfMeasure",
                    "CostInBillingCurrency", "BillingCurrency", "Tags"])
        for res in resources_of(sub_id):
            tags = res.get("tags") or {}
            tag_str = "; ".join("%s: %s" % (k, v) for k, v in sorted(tags.items()))
            w.writerow([month_start(), sub_id, res["resourceGroup"],
                        rid(sub_id, res), res["meterCategory"], 720, "1 Hour",
                        "%.2f" % res["monthlyCost"], "USD", tag_str])
    return path


def cmd_costmanagement(pos, flags):
    out_fmt = one(flags, "output", "json")
    if pos and pos[0] == "query":
        data = cm_query(flags)
        if (out_fmt or "json").lower() == "table":
            names = [c["name"] for c in data["columns"]]
            emit([dict(zip(names, r)) for r in data["rows"]], "table", names)
        else:
            emit(data, out_fmt)
        return
    if not pos or pos[0] != "export":
        fail("UnknownCommand",
             "implemented: az costmanagement query | az costmanagement export list|show|update")
    sub_cmd = pos[1] if len(pos) > 1 else "list"
    state = load(EXP_F)
    if sub_cmd == "list":
        emit([{"Name": e["name"], "Type": e["type"], "Recurrence": e["recurrence"],
               "Status": e["status"], "StorageDirectory": e["storageDirectory"],
               "LastRun": e.get("lastRun") or ""} for e in state["exports"]],
             out_fmt, ["Name", "Type", "Recurrence", "Status",
                       "StorageDirectory", "LastRun"])
        return
    name = one(flags, "name")
    match = [e for e in state["exports"] if e["name"] == name]
    if not match:
        fail("ExportNotFound", "export '%s' not found in this scope." % name)
    export = match[0]
    if sub_cmd == "show":
        emit(export, out_fmt)
        return
    if sub_cmd != "update":
        fail("UnknownCommand", "az costmanagement export %s is not implemented." % sub_cmd)
    if "status" in flags:
        status = one(flags, "status")
        if status not in ("Active", "Inactive"):
            fail("InvalidArgumentValue", "--status must be Active or Inactive")
        export["status"] = status
    if "storage-directory" in flags:
        export["storageDirectory"] = one(flags, "storage-directory")
    if "recurrence" in flags:
        rec = one(flags, "recurrence")
        if rec not in ("Daily", "Weekly", "Monthly", "Annually"):
            fail("InvalidArgumentValue",
                 "--recurrence must be Daily, Weekly, Monthly or Annually")
        export["recurrence"] = rec
    if "type" in flags:
        etype = one(flags, "type")
        if etype not in EXPORT_TYPES:
            fail("InvalidArgumentValue",
                 "--type must be one of %s" % ", ".join(EXPORT_TYPES))
        export["type"] = etype
    if export["status"] == "Active":
        sub_id = scope_sub({"scope": [export["scope"]]})
        path = write_export(export, sub_id)
        export["lastRun"] = now().strftime("%Y-%m-%dT%H:%M:%SZ")
        sys.stderr.write(
            "Note (lab): schedule re-armed, so a run was executed now and wrote %s.\n"
            "            In Azure the next file lands at the next scheduled run, or\n"
            "            immediately via Exports - Execute / 'Run now' in the portal.\n"
            % path)
    save(EXP_F, state)
    emit(export, out_fmt)


# --------------------------------------------------------------------------
# az deployment sub create  (Microsoft.Consumption/budgets)
# --------------------------------------------------------------------------
def validate_budget(props, name):
    tg = props.get("timeGrain")
    if tg not in TIME_GRAINS:
        fail("InvalidTimeGrain",
             "Budget '%s': timeGrain '%s' is invalid. Allowed: %s. "
             "See https://learn.microsoft.com/en-us/rest/api/consumption/budgets/create-or-update"
             % (name, tg, ", ".join(TIME_GRAINS)))
    period = props.get("timePeriod") or {}
    start = str(period.get("startDate", ""))
    if not re.match(r"^\d{4}-\d{2}-\d{2}", start):
        fail("InvalidStartDate", "Budget '%s': timePeriod.startDate is missing or malformed." % name)
    if start[8:10] != "01":
        fail("InvalidStartDate",
             "Budget '%s': the start date must be the first day of a month, got %s."
             % (name, start[:10]))
    if props.get("category") not in ("Cost", "Usage"):
        fail("InvalidCategory", "Budget '%s': category must be Cost or Usage." % name)
    try:
        amount = float(props.get("amount"))
    except (TypeError, ValueError):
        fail("InvalidAmount", "Budget '%s': amount must be a number." % name)
    if amount <= 0:
        fail("InvalidAmount", "Budget '%s': amount must be greater than zero." % name)
    for key, note in (props.get("notifications") or {}).items():
        if note.get("thresholdType") not in THRESHOLD_TYPES:
            fail("InvalidNotification",
                 "Budget '%s' notification '%s': thresholdType must be Actual or Forecasted."
                 % (name, key))
        if note.get("operator") not in ("GreaterThan", "GreaterThanOrEqualTo"):
            fail("InvalidNotification",
                 "Budget '%s' notification '%s': operator must be GreaterThan or "
                 "GreaterThanOrEqualTo." % (name, key))
        try:
            th = float(note.get("threshold"))
        except (TypeError, ValueError):
            fail("InvalidNotification",
                 "Budget '%s' notification '%s': threshold must be a number." % (name, key))
        if not 0 < th <= 1000:
            fail("InvalidNotification",
                 "Budget '%s' notification '%s': threshold must be in (0, 1000]." % (name, key))
        if note.get("enabled") and not (note.get("contactEmails")
                                        or note.get("contactRoles")
                                        or note.get("contactGroups")):
            fail("InvalidNotification",
                 "Budget '%s' notification '%s' is enabled but has no contactEmails, "
                 "contactRoles or contactGroups." % (name, key))


def cmd_deployment(pos, flags):
    if len(pos) < 2 or pos[0] not in ("sub", "subscription") or pos[1] != "create":
        fail("UnknownCommand", "only 'az deployment sub create' is implemented.")
    tpl = one(flags, "template-file")
    if not tpl:
        fail("MissingArgument", "--template-file is required")
    if not one(flags, "location"):
        fail("MissingArgument",
             "--location is required for subscription-scope deployments")
    path = tpl if os.path.isabs(tpl) else os.path.join(os.getcwd(), tpl)
    if not os.path.exists(path):
        path = os.path.join(LAB, tpl)
    try:
        with open(path) as fh:
            template = json.load(fh)
    except FileNotFoundError:
        fail("InvalidTemplateFile", "template file not found: %s" % tpl)
    except ValueError as exc:
        fail("InvalidTemplate",
             "Deployment template file is not valid JSON: %s. "
             "Fix the syntax before ARM will even look at the resources." % exc)
    deployed = load(BUD_F, {"budgets": []})
    count = 0
    for res in template.get("resources", []):
        rtype = res.get("type", "")
        if rtype != "Microsoft.Consumption/budgets":
            fail("InvalidTemplate",
                 "unsupported resource type '%s' in this lab (expected "
                 "Microsoft.Consumption/budgets)." % rtype)
        if not res.get("apiVersion"):
            fail("InvalidTemplate", "resource '%s' has no apiVersion." % res.get("name"))
        props = res.get("properties") or {}
        validate_budget(props, res.get("name"))
        deployed["budgets"] = [b for b in deployed["budgets"]
                               if b["name"] != res["name"]]
        deployed["budgets"].append({"name": res["name"],
                                    "apiVersion": res["apiVersion"],
                                    "scope": "/subscriptions/%s" % current_sub()["id"],
                                    "properties": props})
        count += 1
    save(BUD_F, deployed)
    emit({"id": "/subscriptions/%s/providers/Microsoft.Resources/deployments/%s"
                % (current_sub()["id"], one(flags, "name", "budget-deploy")),
          "name": one(flags, "name", "budget-deploy"),
          "properties": {"provisioningState": "Succeeded",
                         "timestamp": now().strftime("%Y-%m-%dT%H:%M:%SZ"),
                         "outputResources": count}},
         one(flags, "output", "json"))


# --------------------------------------------------------------------------
# az consumption budget list
# --------------------------------------------------------------------------
def cmd_consumption(pos, flags):
    if len(pos) < 2 or pos[0] != "budget" or pos[1] not in ("list", "show"):
        fail("UnknownCommand", "implemented: az consumption budget list|show")
    deployed = load(BUD_F, {"budgets": []})["budgets"]
    if pos[1] == "show":
        name = one(flags, "budget-name") or one(flags, "name")
        match = [b for b in deployed if b["name"] == name]
        if not match:
            fail("BudgetNotFound", "budget '%s' not found." % name)
        emit(match[0], one(flags, "output", "json"))
        return
    sub = current_sub()
    spend = money(sum(r["monthlyCost"] for r in resources_of(sub["id"])))
    rows = []
    for b in deployed:
        p = b["properties"]
        enabled = [k for k, n in (p.get("notifications") or {}).items() if n.get("enabled")]
        amount = float(p.get("amount", 0)) or 1
        rows.append({"Name": b["name"], "Amount": "%.2f" % float(p.get("amount", 0)),
                     "TimeGrain": p.get("timeGrain", ""),
                     "CurrentSpend": "%.2f" % spend,
                     "Consumed%": "%.1f" % (spend / amount * 100.0),
                     "EnabledAlerts": len(enabled)})
    out_fmt = (one(flags, "output", "json") or "json").lower()
    if out_fmt == "json":
        emit(deployed, "json")
    else:
        emit(rows, out_fmt,
             ["Name", "Amount", "TimeGrain", "CurrentSpend", "Consumed%", "EnabledAlerts"])


HELP = """az (OFFLINE LAB SHIM for AZ-900 topic 3.1 -- not the real Azure CLI)

Implemented:
  az account show|list|set --subscription <name|id>
  az resource list [-g RG] [--tag K=V] [--query ...] [-o json|table|tsv]
  az tag list|update --resource-id ID [--operation merge|replace|delete] [--tags K=V]
  az costmanagement query --type T --timeframe TF --dataset-grouping name=N type=TagKey|Dimension
  az costmanagement export list|show|update [--name N] [--status Active|Inactive]
                                            [--storage-directory D] [--recurrence R]
  az deployment sub create --location L --template-file F [--name N]
  az consumption budget list|show [-o table]
"""


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(HELP)
        return
    if argv[0] in ("version", "--version"):
        print("azure-cli (lab shim) 0.0.0-offline  [AZ-900 3.1]")
        return
    group, rest = argv[0], argv[1:]
    pos, flags = parse(rest)
    handlers = {"account": cmd_account, "resource": cmd_resource, "tag": cmd_tag,
                "costmanagement": cmd_costmanagement, "deployment": cmd_deployment,
                "consumption": cmd_consumption}
    handler = handlers.get(group)
    if not handler:
        fail("UnknownCommand", "'%s' is not implemented in the lab shim. "
                               "Run 'az --help'." % group, 2)
    handler(pos, flags)


if __name__ == "__main__":
    main()
AZ_SHIM
}

# ---------------------------------------------------------------------------
# The daily cost report (the tool Finance reads)
# ---------------------------------------------------------------------------
write_cost_report() {
  cat > "$LAB_ROOT/bin/cost-report.sh" <<'COSTREPORT'
#!/usr/bin/env bash
# Daily cost review. Built on the same primitives you would use in production:
#   az account show                -> which scope am I answering for?
#   az costmanagement query        -> live cost, grouped by the CostCenter tag
#   az consumption budget list     -> the budget and how much of it is consumed
#   the exports directory          -> what actually got billed and archived
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$LAB/bin:$PATH"
export LAB_ROOT="$LAB"

mode="${1:-report}"

case "$mode" in
  --audit-tags|audit)
    echo "== Resources with no CostCenter tag (unallocatable spend) =="
    az resource list --query "[?tags.CostCenter == null]" -o table || true
    echo
    echo "== CostCenter value drift =="
    az resource list -o json | python3 -c '
import json, re, sys
rows = json.load(sys.stdin)
seen = {}
for r in rows:
    v = (r.get("tags") or {}).get("CostCenter")
    if v is None:
        continue
    seen.setdefault(v, []).append("%s/%s" % (r["resourceGroup"], r["name"]))
ok = re.compile(r"^CC-[0-9]{4}$")
bad = False
for v, names in sorted(seen.items()):
    flag = "  <-- does not match ^CC-[0-9]{4}$" if not ok.match(v) else ""
    if flag:
        bad = True
    print("  value <%s>  x%d  %s%s" % (v, len(names), ", ".join(names), flag))
print()
print("  distinct CostCenter values: %d" % len(seen))
if bad:
    print("  NOTE: tag NAMES are case-insensitive in ARM, tag VALUES are not.")
'
    exit 0
    ;;
  report) : ;;
  *) echo "usage: cost-report.sh [report|--audit-tags]" >&2; exit 2 ;;
esac

sub_name="$(az account show --query name -o tsv)"
sub_id="$(az account show --query id -o tsv)"
echo "==============================================================="
echo " Contoso platform cost review"
echo " Scope : subscription '$sub_name'"
echo "         /subscriptions/$sub_id"
echo " Period: month to date"
echo "==============================================================="
echo

echo "-- Live cost by CostCenter tag (az costmanagement query) ------"
az costmanagement query --type ActualCost --timeframe MonthToDate \
  --dataset-grouping name=CostCenter type=TagKey -o json \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = [c["name"] for c in d["columns"]]
i_cost, i_val = names.index("PreTaxCost"), names.index("TagValue")
total = 0.0
print("  %-18s %14s" % ("COST CENTRE", "COST (USD)"))
print("  %-18s %14s" % ("-" * 18, "-" * 14))
for row in sorted(d["rows"], key=lambda r: -r[i_cost]):
    label = row[i_val] or "(untagged)"
    total += row[i_cost]
    print("  %-18s %14.2f" % (label, row[i_cost]))
print("  %-18s %14s" % ("-" * 18, "-" * 14))
print("  %-18s %14.2f" % ("TOTAL", total))
open("/tmp/.az900_total", "w").write("%.2f" % total)
'
live_total="$(cat /tmp/.az900_total 2>/dev/null || echo 0)"
echo

echo "-- Latest archived export -------------------------------------"
latest="$(ls -1 "$LAB"/exports/actualcost-*.csv 2>/dev/null | sort | tail -n 1 || true)"
if [ -z "$latest" ]; then
  echo "  NO EXPORT FILE FOUND in $LAB/exports/"
else
  period="$(basename "$latest" | sed -E 's/actualcost-([0-9]{6})\.csv/\1/')"
  lines="$(( $(wc -l < "$latest") - 1 ))"
  billed="$(awk -F, 'NR>1 {s+=$8} END {printf "%.2f", s}' "$latest")"
  echo "  file        : $latest"
  echo "  period      : $period"
  echo "  rows        : $lines resources"
  echo "  billed total: USD $billed"
  if [ "$period" != "$(date -u +%Y%m)" ]; then
    echo "  *** STALE: this export is not from the current billing month ***"
  fi
fi
echo

echo "-- Budget -----------------------------------------------------"
budget_json="$(az consumption budget list -o json)"
printf '%s' "$budget_json" | LIVE="$live_total" python3 -c '
import json, os, sys
budgets = json.load(sys.stdin)
live = float(os.environ.get("LIVE") or 0)
if not budgets:
    print("  NO BUDGET DEPLOYED at this scope. Nothing will ever alert.")
    sys.exit(0)
for b in budgets:
    p = b["properties"]
    amount = float(p.get("amount", 0)) or 0.0
    pct = (live / amount * 100.0) if amount else float("inf")
    print("  name        : %s" % b["name"])
    print("  timeGrain   : %s" % p.get("timeGrain"))
    print("  amount      : USD %.2f" % amount)
    print("  actual MTD  : USD %.2f  (%.1f%% of budget)" % (live, pct))
    notes = p.get("notifications") or {}
    on = [(k, n) for k, n in notes.items() if n.get("enabled")]
    if not on:
        print("  alerts      : NONE ENABLED -- no human will be notified")
    for k, n in on:
        who = n.get("contactEmails") or n.get("contactRoles") or []
        print("  alert       : %-14s %s %s%% -> %s"
              % (k, n.get("thresholdType"), n.get("threshold"),
                 ", ".join(who) or "NOBODY"))
'
echo
echo "Reference: https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/group-filter"
COSTREPORT
}

# ---------------------------------------------------------------------------
# The verifier — tells the student WHAT is wrong, never HOW to fix it
# ---------------------------------------------------------------------------
write_verifier() {
  cat > "$LAB_ROOT/bin/lab-verify" <<'VERIFIER'
#!/usr/bin/env python3
"""AZ-900 3.1 break & fix — acceptance checks."""
import csv
import datetime
import glob
import json
import os
import re
import sys

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROD = "11111111-1111-1111-1111-111111111111"
PROD_NAME = "contoso-platform-prod"
RG_MAP = {"rg-platform-prod": "CC-1001",
          "rg-data-prod": "CC-2002",
          "rg-edge-prod": "CC-3003"}
GREEN, RED, YELLOW, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
results = []


def load(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (IOError, ValueError):
        return default


def check(title, ok, detail, hint):
    results.append((title, ok, detail, hint))


inv = load(os.path.join(LAB, "inventory", "resources.json"), {})
cfg = load(os.path.join(LAB, "state", "cli-config.json"), {})
budgets = (load(os.path.join(LAB, "state", "budgets.json"), {}) or {}).get("budgets", [])
exports = (load(os.path.join(LAB, "state", "exports.json"), {}) or {}).get("exports", [])
prod = inv.get("resources", {}).get(PROD, [])
actual_total = round(sum(r["monthlyCost"] for r in prod), 2)

# --- 1. scope --------------------------------------------------------------
active = cfg.get("defaultSubscription")
check("1. Cost queries run against the production scope",
      active == PROD,
      "active subscription = %s" % (active or "none"),
      "Which subscription does 'az account show' report? A cost figure is only "
      "meaningful together with its scope.")

# --- 2. tag hygiene --------------------------------------------------------
untagged, drifted, values = [], [], set()
pat = re.compile(r"^CC-[0-9]{4}$")
for r in prod:
    v = (r.get("tags") or {}).get("CostCenter")
    label = "%s/%s" % (r["resourceGroup"], r["name"])
    if v is None:
        untagged.append(label)
        continue
    values.add(v)
    if not pat.match(v) or v != RG_MAP.get(r["resourceGroup"]):
        drifted.append("%s=<%s> (expected <%s>)" % (label, v, RG_MAP.get(r["resourceGroup"])))
check("2. Every production resource is allocatable to one cost centre",
      not untagged and not drifted and values == set(RG_MAP.values()),
      "untagged=%d drifted=%d distinct=%d %s"
      % (len(untagged), len(drifted), len(values),
         ("| " + "; ".join(untagged + drifted)) if (untagged or drifted) else ""),
      "See policy/tagging-standard.md. Remember: ARM tag values are "
      "case-sensitive and whitespace is significant.")

# --- 3. budget -------------------------------------------------------------
if not budgets:
    check("3. A compliant monthly budget is deployed at subscription scope",
          False, "no budget deployed",
          "Deploy budgets/budget-platform-monthly.json with "
          "'az deployment sub create'. Read the error it returns, fix, repeat.")
else:
    b = budgets[0]
    p = b.get("properties", {})
    start = str((p.get("timePeriod") or {}).get("startDate", ""))[:10]
    this_month_start = datetime.datetime.utcnow().strftime("%Y-%m-01")
    amount = float(p.get("amount") or 0)
    notes = p.get("notifications") or {}

    def has(kind, max_th):
        for n in notes.values():
            if (n.get("enabled") and n.get("thresholdType") == kind
                    and 0 < float(n.get("threshold", 0)) <= max_th
                    and (n.get("contactEmails") or n.get("contactRoles")
                         or n.get("contactGroups"))):
                return True
        return False

    problems = []
    if p.get("timeGrain") != "Monthly":
        problems.append("timeGrain=%s" % p.get("timeGrain"))
    if start != this_month_start:
        problems.append("startDate=%s (want %s)" % (start, this_month_start))
    if amount < actual_total:
        problems.append("amount=%.2f below current run-rate %.2f" % (amount, actual_total))
    if not has("Actual", 80):
        problems.append("no enabled Actual notification <=80% with a contact")
    if not has("Forecasted", 100):
        problems.append("no enabled Forecasted notification <=100% with a contact")
    check("3. A compliant monthly budget is deployed at subscription scope",
          not problems,
          "; ".join(problems) if problems else
          "amount=%.2f vs actual=%.2f, %d enabled alerts" % (amount, actual_total, len(
              [n for n in notes.values() if n.get("enabled")])),
          "policy/tagging-standard.md section 2 defines the standard. A budget "
          "notifies; it does not block spending.")

# --- 4. export -------------------------------------------------------------
exp = exports[0] if exports else None
files = sorted(glob.glob(os.path.join(LAB, "exports", "actualcost-*.csv")))
cur = datetime.datetime.utcnow().strftime("%Y%m")
fresh = [f for f in files if cur in os.path.basename(f)]
rows = 0
if fresh:
    with open(fresh[-1]) as fh:
        rows = sum(1 for _ in csv.DictReader(fh))
problems = []
if not exp:
    problems.append("export definition missing")
else:
    if exp.get("status") != "Active":
        problems.append("status=%s" % exp.get("status"))
    if exp.get("storageDirectory") != "exports":
        problems.append("storageDirectory=%s (the report only reads 'exports')"
                        % exp.get("storageDirectory"))
    if exp.get("type") != "ActualCost":
        problems.append("type=%s" % exp.get("type"))
if not fresh:
    problems.append("no export for the current month (%s)" % cur)
elif rows != len(prod):
    problems.append("current export covers %d of %d resources" % (rows, len(prod)))
check("4. The scheduled ActualCost export is Active and lands where the report reads",
      not problems,
      "; ".join(problems) if problems else
      "%s, %d rows" % (os.path.basename(fresh[-1]), rows),
      "'az costmanagement export list -o table' shows the definition. Compare it "
      "against policy/tagging-standard.md section 3.")

# --- report ----------------------------------------------------------------
print()
print("AZ-900 3.1 -- break & fix acceptance checks")
print("=" * 63)
passed = 0
for title, ok, detail, hint in results:
    mark = GREEN + "PASS" + OFF if ok else RED + "FAIL" + OFF
    print("[%s] %s" % (mark, title))
    print("       %s" % detail)
    if not ok:
        print("       %shint:%s %s" % (YELLOW, OFF, hint))
    passed += 1 if ok else 0
print("=" * 63)
print("%d/%d checks passing" % (passed, len(results)))
if passed == len(results):
    print(GREEN + "Lab complete. The bill is allocatable, budgeted and observed." + OFF)
    sys.exit(0)
sys.exit(1)
VERIFIER
}

# ---------------------------------------------------------------------------
# Fault injection
# ---------------------------------------------------------------------------
inject_faults() {
  say "Injecting faults ..."

  # FAULT 1 — wrong scope: the CLI defaults to the sandbox subscription.
  cat > "$LAB_ROOT/state/cli-config.json" <<CLIBAD
{ "defaultSubscription": "$SUB_SBX_ID" }
CLIBAD

  # FAULT 2 — cost allocation: 4 resources lose CostCenter, 2 values drift.
  python3 - "$LAB_ROOT" <<'BREAKTAGS'
import json, os, sys
lab = sys.argv[1]
path = os.path.join(lab, "inventory", "resources.json")
with open(path) as fh:
    inv = json.load(fh)
prod = inv["resources"]["11111111-1111-1111-1111-111111111111"]
drop = {"law-plat-prod", "kv-plat-prod", "evhns-data-prod", "pip-edge-prod"}
drift = {"vm-edge-jump-01": "cc-3003", "stdataprod01": "CC-2002 "}
for res in prod:
    if res["name"] in drop:
        res["tags"].pop("CostCenter", None)
    if res["name"] in drift:
        res["tags"]["CostCenter"] = drift[res["name"]]
with open(path, "w") as fh:
    json.dump(inv, fh, indent=2)
    fh.write("\n")
BREAKTAGS

  # FAULT 3 — the budget template: invalid JSON, invalid enum, mid-month start,
  #           amount below run-rate, the only notification disabled and unrouted.
  cat > "$LAB_ROOT/budgets/budget-platform-monthly.json" <<'BUDGETBAD'
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [
    {
      "type": "Microsoft.Consumption/budgets",
      "apiVersion": "2021-10-01",
      "name": "platform-monthly",
      "properties": {
        "category": "Cost",
        "timeGrain": "Month",
        "amount": 1500,
        "timePeriod": {
          "startDate": "__MID_MONTH__T00:00:00Z",
          "endDate": "__PLUS_ONE_YEAR__T00:00:00Z"
        },
        "filter": {
          "dimensions": {
            "name": "ResourceGroupName",
            "operator": "In",
            "values": [ "rg-platform-prod", "rg-data-prod", "rg-edge-prod" ]
          }
        },
        "notifications": {
          "overrun": {
            "enabled": false,
            "operator": "GreaterThan",
            "threshold": 120,
            "thresholdType": "Actual",
            "contactEmails": [],
            "contactRoles": []
          }
        },
      }
    }
  ]
}
BUDGETBAD
  sed -i "s/__MID_MONTH__/$MID_MONTH/; s/__PLUS_ONE_YEAR__/$PLUS_ONE_YEAR/" \
    "$LAB_ROOT/budgets/budget-platform-monthly.json"
  rm -f "$LAB_ROOT/state/budgets.json"

  # FAULT 4 — the scheduled export is Inactive and points at a directory
  #           nobody reads. Silent divergence: no error anywhere.
  python3 - "$LAB_ROOT" <<'BREAKEXPORT'
import json, os, sys
lab = sys.argv[1]
path = os.path.join(lab, "state", "exports.json")
with open(path) as fh:
    state = json.load(fh)
exp = state["exports"][0]
exp["status"] = "Inactive"
exp["storageDirectory"] = "exports-archive-old"
exp["lastRun"] = None
with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
BREAKEXPORT
}

# ---------------------------------------------------------------------------
# Briefing
# ---------------------------------------------------------------------------
briefing() {
  cat <<BRIEF

${c_bld}================================================================${c_off}
${c_bld} AZ-900 · 3.1 — Describe cost management in Azure${c_off}
${c_bld} BREAK & FIX: "The month the bill tripled and nobody was paged"${c_off}
${c_bld}================================================================${c_off}

${c_bld}THE STORY${c_off}
  Finance escalated: the Azure invoice for the platform subscription came in
  at roughly ${c_bld}USD 4,800${c_off} for the month. Your team's own dashboard has been
  reporting about ${c_bld}USD 1,200${c_off} all along, the monthly budget alert never
  fired, and the chargeback file sent to Finance leaves a large block of
  spend allocated to nobody. Nothing crashed. Every tool returned success.

${c_bld}START HERE${c_off}
  ${c_cya}source $LAB_ROOT/lab.env${c_off}
  ${c_cya}cd $LAB_ROOT${c_off}
  ${c_cya}cost-report.sh${c_off}
  ${c_cya}cost-report.sh --audit-tags${c_off}
  ${c_cya}cat docs/RUNBOOK.md policy/tagging-standard.md${c_off}

${c_bld}SYMPTOMS YOU WILL SEE${c_off}
  1. ${c_yel}cost-report.sh reports a total near USD 37${c_off} with a cost centre you do
     not recognise. The number is real — it is just not the answer to the
     question you asked.
  2. ${c_yel}A large share of spend groups under "(untagged)"${c_off}, and the same cost
     centre appears more than once with slightly different spelling.
  3. ${c_yel}The budget section says NO BUDGET DEPLOYED${c_off}. Deploying the template
     fails first with a JSON parse error and then with an ARM validation
     error — read each message, it names the exact property.
  4. ${c_yel}The archived export is months old${c_off} and covers half the estate, so the
     "billed total" everyone trusted describes a platform that no longer
     exists.

${c_bld}YOUR MISSION${c_off}
  Make all four acceptance checks pass:
      ${c_cya}lab-verify${c_off}
  Concretely, you must end up with:
    · cost queries answered at the correct ${c_bld}scope${c_off} (the production subscription);
    · every production resource allocatable to exactly one cost centre, with
      values matching ^CC-[0-9]{4}\$ and the resource-group mapping in
      policy/tagging-standard.md;
    · a ${c_bld}Monthly${c_off} Microsoft.Consumption/budgets resource deployed at
      subscription scope, starting on the first of this month, with an amount
      at or above the current run-rate, and two enabled notifications that
      actually route to somebody (Actual <= 80 %, Forecasted <= 100 %);
    · the ${c_bld}daily ActualCost export${c_off} Active and writing into the directory the
      reporting job reads, with a current-month file covering all 10 resources.

  Only ${c_cya}az${c_off}, a text editor and the files under $LAB_ROOT are needed.
  Nothing outside that directory was touched.

  Reset and re-break:  ${c_cya}bash $0 break${c_off}
  Check progress:      ${c_cya}bash $0 verify${c_off}   (or ${c_cya}lab-verify${c_off})
  Remove the lab:      ${c_cya}bash $0 clean${c_off}

BRIEF
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
cmd_break() {
  check_deps
  confirm
  if [ -d "$LAB_ROOT" ]; then
    [ -f "$LAB_ROOT/$MARKER" ] || die "$LAB_ROOT exists and is not a lab directory. Refusing."
    say "Resetting the existing lab."
    rm -rf "${LAB_ROOT:?}"
  fi
  build_lab
  inject_faults
  briefing
}

cmd_verify() {
  [ -f "$LAB_ROOT/$MARKER" ] || die "No lab found at $LAB_ROOT. Run: bash $0 break"
  set +e
  python3 "$LAB_ROOT/bin/lab-verify"
  rc=$?
  set -e
  exit "$rc"
}

cmd_clean() {
  [ -d "$LAB_ROOT" ] || { say "Nothing to remove."; exit 0; }
  [ -f "$LAB_ROOT/$MARKER" ] || die "$LAB_ROOT is not a lab directory. Refusing to delete."
  rm -rf "${LAB_ROOT:?}"
  say "Removed $LAB_ROOT. Open a new shell to drop the lab PATH."
}

usage() {
  cat <<USAGE
usage: bash $0 [break|verify|clean|help]

  break   (default) build the sandbox and inject the four faults
  verify  run the acceptance checks
  clean   delete \$LAB_ROOT (marker-guarded)

  LAB_ROOT=<dir>        change the sandbox location (default ~/az900-lab-3-1)
  LAB_ASSUME_YES=yes    skip the interactive confirmation
USAGE
}

case "${1:-break}" in
  break)          cmd_break ;;
  verify|check)   cmd_verify ;;
  clean|reset)    cmd_clean ;;
  help|-h|--help) usage ;;
  *)              usage; exit 2 ;;
esac

# =============================================================================
#  SOLUTION — do not read until you have fought with `lab-verify` for a while.
# =============================================================================
#
#  Preparation
#  -----------
#      source ~/az900-lab-3-1/lab.env
#      cd ~/az900-lab-3-1
#      lab-verify                      # 0/4 -- confirm the starting point
#
#  ---------------------------------------------------------------------------
#  FAULT 1 — wrong scope
#  ---------------------------------------------------------------------------
#  Concept: every Cost Management answer belongs to exactly one scope
#  (management group, subscription, resource group, or an invoice/billing
#  scope on an MCA/EA account). A cost query against the wrong scope is not an
#  error, it is a different question. This is why the report showed ~USD 37:
#  it was faithfully reporting the sandbox subscription.
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes
#
#  Diagnosis
#      az account show -o table
#      az account list -o table
#
#  Expected (broken):
#      Name             Id                                    State    IsDefault
#      ---------------  ------------------------------------  -------  ---------
#      contoso-sandbox  22222222-2222-2222-2222-222222222222  Enabled  True
#
#  Fix
#      az account set --subscription contoso-platform-prod
#      az account show --query name -o tsv          # -> contoso-platform-prod
#      cost-report.sh                                # total jumps to ~4812.55
#
#  ---------------------------------------------------------------------------
#  FAULT 2 — unallocatable and drifted cost centre tags
#  ---------------------------------------------------------------------------
#  Concept: Cost Management can only group by what the usage record carries.
#  Tags are the primary cost-allocation mechanism; they are not inherited by
#  child resources, are not applied retroactively to past usage, tag NAMES are
#  case-insensitive but tag VALUES are case-sensitive, and trailing whitespace
#  is significant. Four resources have no CostCenter at all, and two have
#  values that only look right: `cc-3003` and `CC-2002 ` (trailing space).
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/group-filter
#      https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources
#
#  Diagnosis
#      cost-report.sh --audit-tags
#      az resource list --query "[?tags.CostCenter == null]" -o table
#
#  Expected (broken): 4 rows listed as untagged; the drift block prints
#      value <CC-2002 >  x1  rg-data-prod/stdataprod01  <-- does not match ^CC-[0-9]{4}$
#      value <cc-3003>   x1  rg-edge-prod/vm-edge-jump-01  <-- does not match ...
#      distinct CostCenter values: 5
#
#  Fix — the mapping lives in policy/tagging-standard.md (RG -> cost centre):
#
#      SUB=$(az account show --query id -o tsv)
#      for rg_cc in "rg-platform-prod:CC-1001" "rg-data-prod:CC-2002" "rg-edge-prod:CC-3003"; do
#        rg="${rg_cc%%:*}"; cc="${rg_cc##*:}"
#        for id in $(az resource list -g "$rg" --query "[].id" -o tsv); do
#          az tag update --resource-id "$id" --operation merge \
#                        --tags "CostCenter=$cc" -o none 2>/dev/null \
#            || az tag update --resource-id "$id" --operation merge --tags "CostCenter=$cc" >/dev/null
#        done
#      done
#
#  (`--operation merge` keeps Environment and Owner; `replace` would delete
#   them. `merge` also overwrites the drifted values with the canonical ones.)
#
#      cost-report.sh --audit-tags        # distinct CostCenter values: 3, no drift
#      az costmanagement query --type ActualCost --timeframe MonthToDate \
#          --dataset-grouping name=CostCenter type=TagKey -o table
#
#  Expected (fixed):
#      PreTaxCost  TagKey      TagValue  Currency
#      ----------  ----------  --------  --------
#      2857.55     costcenter  CC-1001   USD
#      1744.5      costcenter  CC-2002   USD
#      210.5       costcenter  CC-3003   USD
#
#  In production, close the loop with Azure Policy: a `deny` on resource
#  creation without CostCenter, or `modify` + a remediation task to backfill.
#  Note the timing rule — tagging today does not retag yesterday's usage.
#
#  ---------------------------------------------------------------------------
#  FAULT 3 — the budget
#  ---------------------------------------------------------------------------
#  Concept: a budget is a Microsoft.Consumption/budgets resource with a
#  timeGrain, an amount, a time period and a set of notifications. It NOTIFIES;
#  it never stops spending. A disabled notification with no recipients is a
#  budget that exists only to look good in a compliance screenshot.
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
#      https://learn.microsoft.com/en-us/rest/api/consumption/budgets/create-or-update
#
#  Diagnosis — deploy it and read the errors, one at a time:
#      az deployment sub create --name budget-platform --location eastus \
#          --template-file budgets/budget-platform-monthly.json
#
#      ERROR: (InvalidTemplate) Deployment template file is not valid JSON: ...
#          -> trailing comma after the "notifications" object
#      ERROR: (InvalidTimeGrain) Budget 'platform-monthly': timeGrain 'Month' is
#             invalid. Allowed: Monthly, Quarterly, Annually.
#      ERROR: (InvalidStartDate) the start date must be the first day of a month
#
#  Fix — edit budgets/budget-platform-monthly.json so the resource reads
#  (replace YYYY-MM with the current month, and +1 year for endDate):
#
#      {
#        "type": "Microsoft.Consumption/budgets",
#        "apiVersion": "2021-10-01",
#        "name": "platform-monthly",
#        "properties": {
#          "category": "Cost",
#          "timeGrain": "Monthly",
#          "amount": 5300,
#          "timePeriod": {
#            "startDate": "YYYY-MM-01T00:00:00Z",
#            "endDate":   "YYYY+1-MM-01T00:00:00Z"
#          },
#          "filter": {
#            "dimensions": {
#              "name": "ResourceGroupName",
#              "operator": "In",
#              "values": [ "rg-platform-prod", "rg-data-prod", "rg-edge-prod" ]
#            }
#          },
#          "notifications": {
#            "actual-80": {
#              "enabled": true, "operator": "GreaterThan",
#              "threshold": 80, "thresholdType": "Actual",
#              "contactEmails": [ "finops@contoso.example" ],
#              "contactRoles": [ "Owner" ]
#            },
#            "forecast-100": {
#              "enabled": true, "operator": "GreaterThan",
#              "threshold": 100, "thresholdType": "Forecasted",
#              "contactEmails": [ "finops@contoso.example" ]
#            }
#          }
#        }
#      }
#
#  Note the trailing comma after "notifications" must be gone, and the amount
#  must be >= the current run-rate (4812.55) — 5300 gives ~10 % headroom, so
#  the 80 % Actual alert fires at 4240, i.e. before the month runs away.
#
#      az deployment sub create --name budget-platform --location eastus \
#          --template-file budgets/budget-platform-monthly.json
#      az consumption budget list -o table
#
#  Expected (fixed):
#      Name              Amount   TimeGrain  CurrentSpend  Consumed%  EnabledAlerts
#      ----------------  -------  ---------  ------------  ---------  -------------
#      platform-monthly  5300.00  Monthly    4812.55       90.8       2
#
#  90.8 % > 80 % -> in a real subscription the Actual notification would have
#  already fired to finops@contoso.example. That is the whole point of the
#  exercise: the alert did not fail, it was never armed.
#
#  ---------------------------------------------------------------------------
#  FAULT 4 — the scheduled export
#  ---------------------------------------------------------------------------
#  Concept: scheduled exports push cost data (ActualCost / AmortizedCost /
#  Usage) to a storage account on a recurrence, and they are how anything
#  downstream — chargeback, BI, a FinOps warehouse — sees Azure cost. An export
#  that is Inactive, or that writes to a directory nobody reads, produces no
#  error at all; the consumer silently keeps serving the last good file.
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports
#
#  Diagnosis
#      az costmanagement export list -o table
#      ls -l exports/
#
#  Expected (broken):
#      Name              Type        Recurrence  Status    StorageDirectory     LastRun
#      ----------------  ----------  ----------  --------  -------------------  -------
#      daily-actualcost  ActualCost  Daily       Inactive  exports-archive-old
#
#  Fix
#      az costmanagement export update --name daily-actualcost \
#          --storage-directory exports --status Active -o table
#
#  The lab shim re-arms the schedule and runs it immediately; in Azure the next
#  file appears at the next scheduled run, or right away via the Exports -
#  Execute REST operation / "Run now" in the portal.
#
#      cost-report.sh
#
#  Expected (fixed): period equals the current YYYYMM, 10 resources, billed
#  total USD 4812.55, no STALE warning.
#
#  ---------------------------------------------------------------------------
#  Final check
#  ---------------------------------------------------------------------------
#      lab-verify
#
#      [PASS] 1. Cost queries run against the production scope
#      [PASS] 2. Every production resource is allocatable to one cost centre
#      [PASS] 3. A compliant monthly budget is deployed at subscription scope
#      [PASS] 4. The scheduled ActualCost export is Active and lands where the
#               report reads
#      4/4 checks passing
#
#  ---------------------------------------------------------------------------
#  WHAT TO TAKE INTO THE EXAM (and into production)
#  ---------------------------------------------------------------------------
#  · Cost is always scoped. "How much are we spending?" is unanswerable until
#    someone names the management group, subscription, resource group or
#    billing scope.
#  · Tags are the allocation mechanism, and they are fragile by design: not
#    inherited, not retroactive, values case-sensitive. Enforce with Azure
#    Policy, audit continuously — an untagged resource is not free, it is
#    unattributable, which is worse.
#  · A budget notifies, it does not cap. Alerting on Actual is a post-mortem;
#    alerting on Forecasted is the only one that can still change the outcome.
#    A budget below run-rate trains the team to ignore alerts.
#  · Cost Analysis is for humans and ad-hoc questions; scheduled exports are
#    for machines and for anything anyone downstream depends on. A broken
#    export fails silently — monitor the freshness of the file, not just the
#    existence of the job.
#  · Other AZ-900 3.1 levers this lab deliberately does not simulate, and that
#    you should be able to name: the Pricing Calculator and the Total Cost of
#    Ownership (TCO) Calculator (pre-purchase estimation), Azure Reservations
#    and Savings Plans, Azure Hybrid Benefit, spot VMs, right-sizing and
#    Azure Advisor cost recommendations, and the factors that change price at
#    all — region, resource type, bandwidth/egress, and the billing model
#    behind the subscription.
#      https://azure.microsoft.com/en-us/pricing/calculator/
#      https://azure.microsoft.com/en-us/pricing/tco/calculator/
#      https://learn.microsoft.com/en-us/azure/cost-management-billing/
# =============================================================================