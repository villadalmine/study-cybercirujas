#!/usr/bin/env bash
#
# =============================================================================
#  BREAK & FIX LAB — gcp-cdl 6.1
#  "Recognize how Google Cloud supports an organization's ability to control
#   their cloud costs"  (Cloud Digital Leader, exam version 2026-08-12, weight 5.0)
# =============================================================================
#
#  WHAT THIS IS
#  ------------
#  A self-contained, offline FinOps simulator plus a controlled failure injection.
#  It reproduces, as plain files on a throwaway VM, the four control planes Google
#  Cloud gives an organization to keep cloud spend under control:
#
#    (a) COST ATTRIBUTION  — labels on resources + the BigQuery billing export,
#                            which is what turns one invoice into a per-team bill.
#    (b) BUDGETS & ALERTS  — Cloud Billing budgets, threshold rules, and the
#                            programmatic Pub/Sub notification path.
#    (c) QUOTAS & LIMITS   — consumer quota overrides and BigQuery custom quotas,
#                            the only *hard* stop; budgets alert, quotas cap.
#    (d) BILLING EXPORT    — the BigQuery export sink that feeds every report.
#
#  Nothing here calls gcloud, touches a real billing account, or reaches the
#  network. Everything is created under a single lab directory and can be deleted
#  with one rm -rf. It is still a "break & fix": the fault injection is real,
#  the symptoms are real, and the grader is machine-checkable.
#
#  SAFETY CONTRACT
#  ---------------
#    * Writes ONLY under $LAB_ROOT (default: $HOME/gcp-cost-lab-6.1).
#    * Never invokes gcloud/bq/curl; no credentials are read or written.
#    * --reset only removes a directory that carries this lab's .lab-marker file.
#    * Intended for a disposable lab VM (e.g. an e2-micro you delete afterwards).
#
#  OFFICIAL SOURCES (all content below is original; these are the references)
#    Exam guide .......... https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#    Budgets ............. https://cloud.google.com/billing/docs/how-to/budgets
#    Budget automation ... https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications
#    BigQuery export ..... https://cloud.google.com/billing/docs/how-to/export-data-bigquery
#    Export schema ....... https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/detailed-usage
#    Labels .............. https://cloud.google.com/resource-manager/docs/creating-managing-labels
#    Quotas .............. https://cloud.google.com/docs/quotas/overview
#    BigQuery custom quota https://cloud.google.com/bigquery/docs/custom-quotas
#    CUD ................. https://cloud.google.com/docs/cuds
#    SUD ................. https://cloud.google.com/compute/docs/sustained-use-discounts
#    Active Assist ....... https://cloud.google.com/recommender/docs/whatis-activeassist
#
set -euo pipefail
umask 022

LAB_ROOT="${LAB_ROOT:-$HOME/gcp-cost-lab-6.1}"
ASSUME_YES="${LAB_ASSUME_YES:-0}"
DO_RESET=0

if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; Z=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; Z=""
fi

die() { printf '%sERROR:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
hr()  { printf '%s\n' "-------------------------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--root DIR] [--reset] [--yes] [--help]

  --root DIR   lab directory (default: \$HOME/gcp-cost-lab-6.1)
  --reset      delete an existing lab directory (only if it carries .lab-marker)
  --yes        skip the interactive "this is a disposable VM" confirmation
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)  LAB_ROOT="${2:?--root needs a directory}"; shift 2 ;;
    --reset) DO_RESET=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# --- preflight ---------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 is required (Debian/Ubuntu: sudo apt-get install -y python3)"
PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
case "$PYV" in 3.[89]|3.1[0-9]) : ;; *) die "python3 >= 3.8 required, found $PYV" ;; esac

if [ "$ASSUME_YES" != "1" ]; then
  hr
  printf '%sBREAK & FIX LAB — gcp-cdl 6.1 (cloud cost control)%s\n' "$B" "$Z"
  hr
  say "This script creates a simulated Cloud Billing environment and then breaks it"
  say "on purpose so you can diagnose and repair it."
  say ""
  say "  Lab directory : $LAB_ROOT"
  say "  Writes outside it? no      Network calls? no      gcloud calls? no"
  say ""
  printf 'Run it on a DISPOSABLE lab VM. Continue? [y/N] '
  read -r ans || true
  case "${ans:-}" in y|Y|yes|YES) : ;; *) say "Aborted."; exit 0 ;; esac
fi

if [ "$DO_RESET" = "1" ] && [ -d "$LAB_ROOT" ]; then
  [ -f "$LAB_ROOT/.lab-marker" ] || die "refusing to --reset $LAB_ROOT: no .lab-marker file there"
  rm -rf -- "$LAB_ROOT"
fi
if [ -d "$LAB_ROOT" ] && [ ! -f "$LAB_ROOT/.lab-marker" ] && [ -n "$(ls -A "$LAB_ROOT" 2>/dev/null || true)" ]; then
  die "$LAB_ROOT exists, is not empty, and is not a lab directory. Pick another --root."
fi

mkdir -p "$LAB_ROOT"/{bin,state/billing_export,config/budgets,config/quotas}
printf 'gcp-cdl 6.1 break-and-fix lab; safe to delete this whole directory\n' > "$LAB_ROOT/.lab-marker"

# =============================================================================
#  bin/costctl — the lab's FinOps CLI (stands in for Cloud Billing reports,
#  the budgets API, quota administration and the export sink)
# =============================================================================
cat > "$LAB_ROOT/bin/costctl" <<'COSTCTL_EOF'
#!/usr/bin/env python3
"""costctl - offline FinOps control plane for the gcp-cdl 6.1 lab.

Data model mirrors the real thing:
  state/billing_export/usage_cost.jsonl  rows shaped like the BigQuery
                                         detailed usage cost export
  state/inventory.json                   resources and the labels ON them
  config/budgets/*.json                  Cloud Billing Budget API v1 resources
  config/quotas/quota_overrides.json     consumer quota overrides
  config/export_sink.json                the BigQuery export configuration

Cost attribution is a JOIN: export rows carry a resource_id, labels live on the
resource. Break the labels and the join produces an UNALLOCATED bucket - exactly
what happens to a chargeback report in production.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, "state")
CONFIG = os.path.join(ROOT, "config")

INVENTORY = os.path.join(STATE, "inventory.json")
USAGE = os.path.join(STATE, "billing_export", "usage_cost.jsonl")
PROJECTS = os.path.join(STATE, "projects.json")
TOPICS = os.path.join(STATE, "pubsub_topics.json")
CHANNELS = os.path.join(STATE, "notification_channels.json")
POLICY = os.path.join(CONFIG, "label_policy.json")
BUDGET_DIR = os.path.join(CONFIG, "budgets")
QUOTAS = os.path.join(CONFIG, "quotas", "quota_overrides.json")
SINK = os.path.join(CONFIG, "export_sink.json")

# List prices used only to turn a quota ceiling into an amount of money.
VCPU_HOUR_USD = 0.031611          # N2 predefined vCPU, us-central1, on-demand
BQ_ON_DEMAND_TIB_USD = 6.25       # BigQuery on-demand analysis, per TiB scanned
HOURS_PER_MONTH = 730
FORECAST_FACTOR = 30.0 / 28.0     # 28-day export window -> 30-day month


# ----------------------------------------------------------------- io helpers
def jload(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def jdump(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def jsonl(path):
    out = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def money(x):
    return "${:,.2f}".format(x)


def now_utc():
    return datetime.now(timezone.utc)


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


# --------------------------------------------------------------- data loading
def load_rows():
    """Join billing export rows with the labels currently on each resource."""
    inv = {r["id"]: r for r in jload(INVENTORY)["resources"]}
    rows = []
    for row in jsonl(USAGE):
        res = inv.get(row["resource_id"], {})
        credits_total = round(sum(c["amount"] for c in row.get("credits", [])), 6)
        rows.append({
            "resource_id": row["resource_id"],
            "project_id": row["project"]["id"],
            "project_number": row["project"]["number"],
            "service": row["service"]["description"],
            "sku": row["sku"]["description"],
            "usage_start_time": row["usage_start_time"],
            "cost": float(row["cost"]),
            "credits": row.get("credits", []),
            "credit_total": credits_total,
            "net_cost": round(float(row["cost"]) + credits_total, 6),
            "labels": dict(res.get("labels", {})),
        })
    return rows


def group_value(row, key, policy):
    """Return the group a row belongs to, or None when it cannot be attributed.

    A label only attributes cost if the key is present AND the value satisfies
    the taxonomy. Google Cloud label values are lowercase-only; an uppercase
    value is not merely ugly, it cannot exist on the resource, so a row carrying
    one is a resource somebody labelled outside the sanctioned path.
    """
    if key == "project":
        return row["project_id"]
    if key == "service":
        return row["service"]
    val = row["labels"].get(key)
    if val is None or val == "":
        return None
    if not re.match(policy["value_pattern"], val):
        return None
    allowed = policy.get("allowed_values", {}).get(key)
    if allowed and val not in allowed:
        return None
    return val


def allocation_stats(rows, key, policy):
    total = round(sum(r["net_cost"] for r in rows), 2)
    unalloc = round(sum(r["net_cost"] for r in rows
                        if group_value(r, key, policy) is None), 2)
    return total, unalloc


def label_violations(resources, policy):
    out = []
    key_re = re.compile(policy["key_pattern"])
    val_re = re.compile(policy["value_pattern"])
    for res in resources:
        labels = res.get("labels", {}) or {}
        problems = []
        for key in policy["required_keys"]:
            if key not in labels:
                problems.append("missing required key '%s'" % key)
                continue
            val = labels[key]
            if not val_re.match(val):
                problems.append("value '%s' for '%s' violates the label value "
                                "format (lowercase, digits, - and _ only)" % (val, key))
                continue
            allowed = policy.get("allowed_values", {}).get(key)
            if allowed and val not in allowed:
                problems.append("value '%s' for '%s' is not in the approved "
                                "taxonomy %s" % (val, key, allowed))
        for key in labels:
            if not key_re.match(key):
                problems.append("key '%s' violates the label key format" % key)
            elif key not in policy["required_keys"] and key not in policy.get("optional_keys", []):
                problems.append("key '%s' is not part of the taxonomy (drift)" % key)
        if problems:
            out.append((res["id"], res.get("project_id", "?"), problems))
    return out


# --------------------------------------------------------------------- report
def cmd_report(args):
    rows = load_rows()
    policy = jload(POLICY)
    key = args.group_by
    buckets = {}
    for r in rows:
        g = group_value(r, key, policy) or "(UNALLOCATED)"
        b = buckets.setdefault(g, {"gross": 0.0, "credits": 0.0, "net": 0.0})
        b["gross"] += r["cost"]
        b["credits"] += r["credit_total"]
        b["net"] += r["net_cost"]

    total_net = sum(b["net"] for b in buckets.values())
    if args.json:
        print(json.dumps({"group_by": key, "total_net": round(total_net, 2),
                          "buckets": {k: {kk: round(vv, 2) for kk, vv in v.items()}
                                      for k, v in buckets.items()}}, indent=2))
        return 0

    print()
    print("Cost report - current billing period (trailing 28 days of export data)")
    print("grouped by: %s" % key)
    print("=" * 79)
    print("{:<26}{:>15}{:>15}{:>15}{:>8}".format("GROUP", "GROSS", "CREDITS", "NET", "%"))
    print("-" * 79)
    ordered = sorted(buckets.items(), key=lambda kv: kv[1]["net"], reverse=True)
    for name, b in ordered:
        pct = (b["net"] / total_net * 100) if total_net else 0.0
        print("{:<26}{:>15}{:>15}{:>15}{:>7.1f}%".format(
            name, money(b["gross"]), money(b["credits"]), money(b["net"]), pct))
    print("-" * 79)
    gross = sum(b["gross"] for b in buckets.values())
    creds = sum(b["credits"] for b in buckets.values())
    print("{:<26}{:>15}{:>15}{:>15}{:>8}".format(
        "TOTAL", money(gross), money(creds), money(total_net), "100.0%"))
    if "(UNALLOCATED)" in buckets:
        u = buckets["(UNALLOCATED)"]["net"]
        print()
        print("!! %s of net spend (%.1f%%) cannot be charged back to any %s."
              % (money(u), (u / total_net * 100) if total_net else 0, key))
        print("   Showback that does not sum to the invoice is showback nobody trusts.")
    print()
    return 0


def cmd_label_audit(args):
    policy = jload(POLICY)
    resources = jload(INVENTORY)["resources"]
    viol = label_violations(resources, policy)
    print()
    print("Label taxonomy audit  (policy: %s)" % os.path.relpath(POLICY, ROOT))
    print("required keys: %s" % ", ".join(policy["required_keys"]))
    print("=" * 79)
    if not viol:
        print("OK - %d resources, 0 violations." % len(resources))
        print()
        return 0
    for rid, proj, problems in viol:
        print("%-22s %-20s" % (rid, proj))
        for p in problems:
            print("    - %s" % p)
    print("-" * 79)
    print("%d of %d resources violate the taxonomy." % (len(viol), len(resources)))
    print()
    return 1


def cmd_labels(args):
    inv = jload(INVENTORY)
    target = None
    for res in inv["resources"]:
        if res["id"] == args.resource:
            target = res
            break
    if target is None:
        print("no such resource: %s" % args.resource, file=sys.stderr)
        return 2
    labels = target.setdefault("labels", {})
    for pair in args.set or []:
        if "=" not in pair:
            print("--set expects key=value, got %r" % pair, file=sys.stderr)
            return 2
        k, v = pair.split("=", 1)
        labels[k] = v
    for k in args.remove or []:
        labels.pop(k, None)
    jdump(INVENTORY, inv)
    print("%s labels -> %s" % (target["id"], json.dumps(labels, sort_keys=True)))
    return 0


# --------------------------------------------------------------------- budget
def evaluate_budget(budget, rows, projects, topics, channels):
    misconfig = []
    bf = budget.get("budgetFilter", {}) or {}

    known = {p["project_number"]: p for p in projects["projects"]}
    scoped = set()
    for ref in bf.get("projects", []) or []:
        num = str(ref).split("/")[-1]
        if num in known:
            scoped.add(num)
        else:
            misconfig.append("budgetFilter.projects references %s, which is not a "
                             "project under this billing account" % ref)
    if not bf.get("projects"):
        misconfig.append("budgetFilter.projects is empty")

    treatment = bf.get("creditTypesTreatment", "INCLUDE_ALL_CREDITS")
    field = "net_cost" if treatment == "INCLUDE_ALL_CREDITS" else "cost"

    in_scope = round(sum(r[field] for r in rows if r["project_number"] in scoped), 2)
    billed = round(sum(r[field] for r in rows), 2)
    coverage = (in_scope / billed * 100) if billed else 0.0
    if coverage < 99.0:
        misconfig.append("budget scope covers %.1f%% of billed spend - %s is "
                         "outside every threshold rule" % (coverage, money(billed - in_scope)))

    amount = budget.get("amount", {}) or {}
    if "specifiedAmount" in amount:
        target = float(amount["specifiedAmount"].get("units", 0)) + \
                 float(amount["specifiedAmount"].get("nanos", 0)) / 1e9
    elif "lastPeriodAmount" in amount:
        target = 0.0
        misconfig.append("amount is lastPeriodAmount: the budget chases spend "
                         "instead of constraining it")
    else:
        target = 0.0
        misconfig.append("amount is not set")

    pct = (in_scope / target * 100) if target else 0.0
    forecast = in_scope * FORECAST_FACTOR
    fpct = (forecast / target * 100) if target else 0.0

    rules = budget.get("thresholdRules", []) or []
    if not rules:
        misconfig.append("thresholdRules is empty: a budget with no rule never "
                         "notifies anyone, it only draws a line on a chart")
    have = {(round(float(r.get("thresholdPercent", 0)), 4),
             r.get("spendBasis", "CURRENT_SPEND")) for r in rules}
    for want in [(0.5, "CURRENT_SPEND"), (0.9, "CURRENT_SPEND"), (1.0, "CURRENT_SPEND")]:
        if want not in have:
            misconfig.append("no %d%% %s threshold rule" % (want[0] * 100, want[1]))
    if not any(b == "FORECASTED_SPEND" for _, b in have):
        misconfig.append("no FORECASTED_SPEND rule: current-spend alerts only ever "
                         "arrive after the money is gone")

    nr = budget.get("notificationsRule", {}) or {}
    recipients = []
    topic = nr.get("pubsubTopic")
    if topic:
        if topic in topics["topics"]:
            recipients.append("pubsub:%s" % topic)
            if nr.get("schemaVersion") != "1.0":
                misconfig.append("notificationsRule.schemaVersion must be \"1.0\"")
        else:
            misconfig.append("notificationsRule.pubsubTopic %s does not exist: "
                             "every notification is silently dropped" % topic)
    for ch in nr.get("monitoringNotificationChannels", []) or []:
        if ch in channels["channels"]:
            recipients.append("channel:%s" % ch)
        else:
            misconfig.append("monitoringNotificationChannels entry %s does not exist" % ch)
    if not nr.get("disableDefaultIamRecipients", False):
        recipients.append("iam:billing-account-admins+users")
    elif not recipients:
        misconfig.append("disableDefaultIamRecipients is true and no Pub/Sub topic "
                         "or notification channel is reachable: nobody is notified")

    fired = []
    for r in rules:
        p = float(r.get("thresholdPercent", 0))
        basis = r.get("spendBasis", "CURRENT_SPEND")
        actual = pct if basis == "CURRENT_SPEND" else fpct
        fired.append({"percent": p, "basis": basis, "fired": actual >= p * 100})

    return {
        "displayName": budget.get("displayName", "?"),
        "target": target, "in_scope": in_scope, "billed": billed,
        "coverage": coverage, "pct": pct, "forecast": forecast, "fpct": fpct,
        "treatment": treatment, "rules": fired, "recipients": recipients,
        "misconfig": misconfig, "scoped": sorted(scoped),
    }


def all_budgets():
    out = []
    for name in sorted(os.listdir(BUDGET_DIR)):
        if name.endswith(".json"):
            out.append(jload(os.path.join(BUDGET_DIR, name)))
    return out


def cmd_budget_check(args):
    rows = load_rows()
    projects, topics, channels = jload(PROJECTS), jload(TOPICS), jload(CHANNELS)
    rc = 0
    for b in all_budgets():
        e = evaluate_budget(b, rows, projects, topics, channels)
        print()
        print("Budget: %s" % e["displayName"])
        print("=" * 79)
        print("  scope            : %s (%s)" % (", ".join(e["scoped"]) or "NOTHING IN SCOPE",
                                                e["treatment"]))
        print("  budget amount    : %s / month" % money(e["target"]))
        print("  in-scope spend   : %s  (%.1f%% of budget)" % (money(e["in_scope"]), e["pct"]))
        print("  forecast (30d)   : %s  (%.1f%% of budget)" % (money(e["forecast"]), e["fpct"]))
        print("  billed on account: %s  (scope covers %.1f%%)" % (money(e["billed"]), e["coverage"]))
        print("  threshold rules  : %d" % len(e["rules"]))
        for r in e["rules"]:
            print("      %5.0f%% %-16s %s" % (r["percent"] * 100, r["basis"],
                                              "FIRED" if r["fired"] else "not reached"))
        print("  notified parties : %s" % (", ".join(e["recipients"]) or "NOBODY"))
        if e["misconfig"]:
            rc = 1
            print("  misconfigurations:")
            for m in e["misconfig"]:
                print("      - %s" % m)
        else:
            print("  misconfigurations: none")
    print()
    return rc


# --------------------------------------------------------------------- quotas
def implied_monthly_usd(entry):
    metric = entry["metric"]
    val = entry.get("override_value")
    if val is None:
        return None
    if metric.endswith("/cpus"):
        return float(val) * HOURS_PER_MONTH * VCPU_HOUR_USD
    if "query/usage" in metric:
        return float(val) / 1024.0 * BQ_ON_DEMAND_TIB_USD * 30.0
    return None


def cmd_quota_check(args):
    q = jload(QUOTAS)
    print()
    print("Consumer quota overrides - blast radius per project")
    print("=" * 79)
    print("{:<20}{:<40}{:>10}{:>15}".format("PROJECT", "METRIC", "LIMIT", "MAX $/MONTH"))
    print("-" * 79)
    rc = 0
    for e in q["overrides"]:
        val = e.get("override_value")
        cost = implied_monthly_usd(e)
        print("{:<20}{:<40}{:>10}{:>15}".format(
            e["project_id"], e["metric"],
            "UNLIMITED" if val is None else str(val),
            "unbounded" if cost is None else money(cost)))
        if val is None:
            rc = 1
    print("-" * 79)
    print("Quotas are the only hard stop in Google Cloud. A budget alert is an email;")
    print("a quota is a wall. Read these as: 'the worst a runaway job in this project")
    print("can cost me before a human intervenes'.")
    print()
    return rc


def cmd_quota_set(args):
    q = jload(QUOTAS)
    hit = None
    for e in q["overrides"]:
        if e["project_id"] == args.project and e["metric"] == args.metric:
            hit = e
            break
    if hit is None:
        print("no override for %s / %s" % (args.project, args.metric), file=sys.stderr)
        return 2
    hit["override_value"] = args.value
    if args.justification:
        hit["justification"] = args.justification
    jdump(QUOTAS, q)
    cost = implied_monthly_usd(hit)
    print("%s %s -> %s (max %s / month)" % (
        args.project, args.metric, args.value,
        "unbounded" if cost is None else money(cost)))
    return 0


# ----------------------------------------------------------------------- sink
def sink_age_hours(sink):
    return (now_utc() - parse_ts(sink["last_export_time"])).total_seconds() / 3600.0


def cmd_sink(args):
    sink = jload(SINK)
    if args.action == "status":
        age = sink_age_hours(sink)
        print()
        print("BigQuery billing export sink")
        print("=" * 79)
        print("  enabled          : %s" % sink["enabled"])
        print("  export type      : %s" % sink["export_type"])
        print("  destination      : %s.%s" % (sink["dataset"], sink["table"]))
        print("  last export time : %s (%.1f hours ago)" % (sink["last_export_time"], age))
        print("  rows materialized: %d" % sink["rows"])
        print()
        if not sink["enabled"]:
            print("!! Export is OFF. Cost data stops accumulating the moment it is")
            print("   disabled, and Google does NOT backfill the gap when you re-enable it.")
            print()
            return 1
        if age > 24:
            print("!! Export is stale (>24h). Every report and every budget forecast")
            print("   downstream is quietly reporting on yesterday's world.")
            print()
            return 1
        return 0
    if args.action == "enable":
        sink["enabled"] = True
        jdump(SINK, sink)
        print("export sink enabled; run 'costctl sink run' to materialize rows")
        return 0
    if args.action == "disable":
        sink["enabled"] = False
        jdump(SINK, sink)
        print("export sink disabled")
        return 0
    if args.action == "run":
        if not sink["enabled"]:
            print("refusing to run: the export sink is disabled", file=sys.stderr)
            return 1
        sink["rows"] = len(jsonl(USAGE))
        sink["last_export_time"] = now_utc().strftime("%Y-%m-%dT%H:%M:%SZ")
        jdump(SINK, sink)
        print("export run complete: %d rows, watermark %s" % (sink["rows"], sink["last_export_time"]))
        return 0
    return 2


# ------------------------------------------------------------------ discounts
def cmd_discounts(args):
    rows = load_rows()
    by_type = {}
    for r in rows:
        for c in r["credits"]:
            by_type.setdefault(c["type"], 0.0)
            by_type[c["type"]] += c["amount"]
    gross = sum(r["cost"] for r in rows)
    commitable = sum(r["cost"] for r in rows
                     if r["service"] in ("Compute Engine", "Kubernetes Engine", "Cloud SQL"))
    cud = -by_type.get("COMMITTED_USAGE_DISCOUNT", 0.0)
    covered = cud / 0.30 if cud else 0.0   # lab assumption: 30% CUD rate
    print()
    print("Discount posture")
    print("=" * 79)
    print("  gross spend                    : %s" % money(gross))
    for t, v in sorted(by_type.items()):
        print("  %-31s: %s" % (t, money(v)))
    print("  commitment-eligible spend      : %s" % money(commitable))
    print("  approx. spend covered by a CUD : %s (%.0f%% of eligible)"
          % (money(covered), (covered / commitable * 100) if commitable else 0))
    print()
    print("  SUD is automatic on eligible Compute Engine usage - no action, no risk.")
    print("  CUD is a contract: 1 or 3 years in exchange for a lower rate. Uncovered")
    print("  steady-state usage is money left on the table; over-commitment is money")
    print("  spent on capacity nobody runs. Right-size against the trailing baseline,")
    print("  never against the peak.")
    print()
    return 0


# --------------------------------------------------------------------- verify
def cmd_verify(args):
    checks = []

    policy = jload(POLICY)
    rows = load_rows()
    inv = jload(INVENTORY)["resources"]
    viol = label_violations(inv, policy)
    total_net, unalloc = allocation_stats(rows, "cost-center", policy)
    upct = (unalloc / total_net * 100) if total_net else 0.0
    checks.append((
        "1  Cost attribution",
        len(viol) == 0 and upct <= 0.5,
        "%d label violations, %s (%.1f%%) unallocated  [target: 0 violations, <=0.5%%]"
        % (len(viol), money(unalloc), upct)))

    projects, topics, channels = jload(PROJECTS), jload(TOPICS), jload(CHANNELS)
    bud = [b for b in all_budgets() if b.get("displayName") == "acme-eng-monthly"]
    if not bud:
        checks.append(("2  Budget & alerting", False, "budget 'acme-eng-monthly' not found"))
    else:
        e = evaluate_budget(bud[0], rows, projects, topics, channels)
        fired = [r for r in e["rules"] if r["fired"]]
        ok = (not e["misconfig"]) and bool(fired) and bool(e["recipients"])
        checks.append((
            "2  Budget & alerting", ok,
            "%d misconfigurations, %d/%d rules firing, %d recipients  "
            "[target: 0 / >=1 / >=1]" % (len(e["misconfig"]), len(fired),
                                         len(e["rules"]), len(e["recipients"]))))

    q = jload(QUOTAS)
    cpu = next((x for x in q["overrides"]
                if x["project_id"] == "acme-lab-sandbox" and x["metric"].endswith("/cpus")), None)
    bq = next((x for x in q["overrides"]
               if x["metric"] == "bigquery.googleapis.com/quota/query/usage"), None)
    cpu_ok = bool(cpu) and cpu.get("override_value") is not None \
        and 1 <= int(cpu["override_value"]) <= 24 and bool(cpu.get("justification"))
    bq_ok = bool(bq) and bq.get("override_value") is not None and int(bq["override_value"]) <= 2000
    checks.append((
        "3  Hard limits (quotas)", cpu_ok and bq_ok,
        "sandbox cpus=%s (need 1..24 + justification), bigquery query cap=%s GiB/day "
        "(need <=2000)" % (cpu.get("override_value") if cpu else "absent",
                           bq.get("override_value") if bq else "absent")))

    sink = jload(SINK)
    age = sink_age_hours(sink)
    checks.append((
        "4  Billing export sink", bool(sink["enabled"]) and age <= 24,
        "enabled=%s, last export %.1fh ago  [target: enabled, <=24h]" % (sink["enabled"], age)))

    print()
    print("LAB GRADER - gcp-cdl 6.1 cost control")
    print("=" * 79)
    failed = 0
    for name, ok, detail in checks:
        print("[%s] %-26s %s" % ("PASS" if ok else "FAIL", name, detail))
        if not ok:
            failed += 1
    print("-" * 79)
    if failed:
        print("%d of %d checks failing. The lab is not repaired yet." % (failed, len(checks)))
        print()
        return 1
    print("All %d checks passing. Cost controls restored." % len(checks))
    print()
    return 0


def main():
    p = argparse.ArgumentParser(prog="costctl", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("report", help="cost report grouped by label, project or service")
    r.add_argument("--group-by", default="cost-center")
    r.add_argument("--json", action="store_true")
    r.set_defaults(func=cmd_report)

    la = sub.add_parser("label-audit", help="audit resource labels against the taxonomy")
    la.set_defaults(func=cmd_label_audit)

    lb = sub.add_parser("labels", help="set or remove labels on a resource")
    lb.add_argument("--resource", required=True)
    lb.add_argument("--set", action="append", metavar="KEY=VALUE")
    lb.add_argument("--remove", action="append", metavar="KEY")
    lb.set_defaults(func=cmd_labels)

    bc = sub.add_parser("budget-check", help="evaluate every budget against actual spend")
    bc.set_defaults(func=cmd_budget_check)

    qc = sub.add_parser("quota-check", help="show quota overrides and their cost ceiling")
    qc.set_defaults(func=cmd_quota_check)

    qs = sub.add_parser("quota-set", help="change a consumer quota override")
    qs.add_argument("--project", required=True)
    qs.add_argument("--metric", required=True)
    qs.add_argument("--value", required=True, type=int)
    qs.add_argument("--justification", default="")
    qs.set_defaults(func=cmd_quota_set)

    sk = sub.add_parser("sink", help="billing export sink: status|enable|disable|run")
    sk.add_argument("action", choices=["status", "enable", "disable", "run"])
    sk.set_defaults(func=cmd_sink)

    ds = sub.add_parser("discounts", help="SUD / CUD posture")
    ds.set_defaults(func=cmd_discounts)

    vf = sub.add_parser("verify", help="grade the lab")
    vf.set_defaults(func=cmd_verify)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
COSTCTL_EOF
chmod +x "$LAB_ROOT/bin/costctl"

# =============================================================================
#  bin/seed-lab.py — writes the healthy baseline
# =============================================================================
cat > "$LAB_ROOT/bin/seed-lab.py" <<'SEED_EOF'
#!/usr/bin/env python3
"""Seed the pristine (healthy) state of the cost-control lab."""
import json
import os
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, "state")
CONFIG = os.path.join(ROOT, "config")
BILLING_ACCOUNT = "01A2B3-C4D5E6-F7G8H9"

PROJECTS = [
    {"project_id": "acme-shop-prod",    "project_number": "482910573001",
     "parent": "folders/770001", "note": "customer-facing storefront"},
    {"project_id": "acme-shop-stage",   "project_number": "482910573002",
     "parent": "folders/770001", "note": "pre-production"},
    {"project_id": "acme-data-lake",    "project_number": "482910573003",
     "parent": "folders/770002", "note": "analytics"},
    {"project_id": "acme-lab-sandbox",  "project_number": "482910573004",
     "parent": "folders/770003", "note": "engineer sandbox, no SLO"},
    {"project_id": "acme-billing-admin", "project_number": "482910573000",
     "parent": "organizations/9911", "note": "billing export + alert plumbing"},
]
PNUM = {p["project_id"]: p["project_number"] for p in PROJECTS}

SUD = "SUSTAINED_USAGE_DISCOUNT"
CUD = "COMMITTED_USAGE_DISCOUNT"

# id, project, service, sku, monthly cost, unit, unit price, credits, labels
RESOURCES = [
    ("web-prod-a", "acme-shop-prod", "Compute Engine",
     "N2 Instance Core running in Americas", 420.00, "vCPU-hour", 0.031611,
     [("Sustained Usage Discount", SUD, -84.00)],
     {"cost-center": "cc-1001", "team": "platform", "env": "prod", "owner": "sre-core"}),
    ("web-prod-b", "acme-shop-prod", "Compute Engine",
     "N2 Instance Core running in Americas", 420.00, "vCPU-hour", 0.031611,
     [("Sustained Usage Discount", SUD, -84.00)],
     {"cost-center": "cc-1001", "team": "platform", "env": "prod", "owner": "sre-core"}),
    ("gke-prod-nodes", "acme-shop-prod", "Kubernetes Engine",
     "N2 Instance Core running in Americas", 610.00, "vCPU-hour", 0.031611,
     [("Committed Use Discount - 1yr", CUD, -183.00)],
     {"cost-center": "cc-1001", "team": "platform", "env": "prod", "owner": "sre-core"}),
    ("https-lb-prod", "acme-shop-prod", "Cloud Load Balancing",
     "HTTPS Load Balancer Forwarding Rule Minimum Service Charge", 95.00,
     "forwarding-rule-hour", 0.025, [],
     {"cost-center": "cc-1001", "team": "platform", "env": "prod", "owner": "sre-core"}),
    ("orders-db-prod", "acme-shop-prod", "Cloud SQL",
     "Cloud SQL for PostgreSQL: Zonal - vCPU in Americas", 310.00, "vCPU-hour", 0.0590,
     [("Committed Use Discount - 1yr", CUD, -62.00)],
     {"cost-center": "cc-1001", "team": "platform", "env": "prod", "owner": "sre-core"}),
    ("analytics-warehouse", "acme-data-lake", "BigQuery",
     "Analysis (on-demand)", 380.00, "TiB-scanned", 6.25, [],
     {"cost-center": "cc-2044", "team": "data", "env": "prod", "owner": "data-eng"}),
    ("raw-events-bucket", "acme-data-lake", "Cloud Storage",
     "Standard Storage US Multi-region", 128.00, "GiB-month", 0.026, [],
     {"cost-center": "cc-2044", "team": "data", "env": "prod", "owner": "data-eng"}),
    ("batch-stage-a", "acme-shop-stage", "Compute Engine",
     "E2 Instance Core running in Americas", 140.00, "vCPU-hour", 0.021811, [],
     {"cost-center": "cc-3100", "team": "growth", "env": "stage", "owner": "growth-eng"}),
    ("promo-api", "acme-shop-stage", "Cloud Run",
     "Cloud Run CPU Allocation Time", 76.00, "vCPU-second", 0.000024, [],
     {"cost-center": "cc-3100", "team": "growth", "env": "stage", "owner": "growth-eng"}),
    ("campaign-assets", "acme-shop-stage", "Cloud Storage",
     "Standard Storage US Multi-region", 34.00, "GiB-month", 0.026, [],
     {"cost-center": "cc-3100", "team": "growth", "env": "stage", "owner": "growth-eng"}),
    ("lab-vm-01", "acme-lab-sandbox", "Compute Engine",
     "N2 Instance Core running in Americas", 88.00, "vCPU-hour", 0.031611, [],
     {"cost-center": "cc-1001", "team": "platform", "env": "sandbox", "owner": "sre-core"}),
    ("lab-vm-02", "acme-lab-sandbox", "Compute Engine",
     "N2 Instance Core running in Americas", 59.00, "vCPU-hour", 0.031611, [],
     {"cost-center": "cc-1001", "team": "platform", "env": "sandbox", "owner": "sre-core"}),
]


def split(total, parts=4):
    step = round(total / parts, 2)
    vals = [step] * (parts - 1)
    vals.append(round(total - step * (parts - 1), 2))
    return vals


def jdump(path, obj):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")


def main():
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    weeks = [(now - timedelta(days=28 - 7 * i), now - timedelta(days=21 - 7 * i))
             for i in range(4)]

    jdump(os.path.join(STATE, "projects.json"),
          {"billing_account_id": BILLING_ACCOUNT, "projects": PROJECTS})
    jdump(os.path.join(STATE, "pubsub_topics.json"),
          {"topics": ["projects/acme-billing-admin/topics/budget-alerts",
                      "projects/acme-billing-admin/topics/recommender-findings"]})
    jdump(os.path.join(STATE, "notification_channels.json"),
          {"channels": ["projects/acme-billing-admin/notificationChannels/1187456320991"]})

    inventory = []
    for (rid, proj, svc, sku, cost, unit, price, credits, labels) in RESOURCES:
        inventory.append({"id": rid, "project_id": proj, "project_number": PNUM[proj],
                          "service": svc, "labels": dict(labels)})
    jdump(os.path.join(STATE, "inventory.json"), {"resources": inventory})

    rows = 0
    out = os.path.join(STATE, "billing_export", "usage_cost.jsonl")
    with open(out, "w", encoding="utf-8") as fh:
        for (rid, proj, svc, sku, cost, unit, price, credits, labels) in RESOURCES:
            for wcost, (start, end) in zip(split(cost), weeks):
                share = wcost / cost if cost else 0
                row = {
                    "billing_account_id": BILLING_ACCOUNT,
                    "invoice": {"month": start.strftime("%Y%m")},
                    "service": {"description": svc},
                    "sku": {"description": sku},
                    "project": {"id": proj, "number": PNUM[proj]},
                    "resource_id": rid,
                    "usage_start_time": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "usage_end_time": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "usage": {"amount": round(wcost / price, 2), "unit": unit},
                    "cost": wcost,
                    "currency": "USD",
                    "credits": [{"name": n, "type": t, "amount": round(a * share, 2)}
                                for (n, t, a) in credits],
                }
                fh.write(json.dumps(row) + "\n")
                rows += 1

    jdump(os.path.join(CONFIG, "label_policy.json"), {
        "required_keys": ["cost-center", "team", "env", "owner"],
        "optional_keys": ["component", "data-class"],
        "key_pattern": "^[a-z][a-z0-9_-]{0,62}$",
        "value_pattern": "^[a-z0-9][a-z0-9_-]{0,62}$",
        "allowed_values": {
            "cost-center": ["cc-1001", "cc-2044", "cc-3100"],
            "env": ["prod", "stage", "dev", "sandbox"],
            "team": ["platform", "data", "growth"],
        },
        "_note": "Google Cloud label keys and values are lowercase-only, max 63 "
                 "characters, from [a-z0-9_-]; keys must start with a lowercase "
                 "letter. See cloud.google.com/resource-manager/docs/creating-managing-labels",
    })

    jdump(os.path.join(CONFIG, "budgets", "budget-eng-prod.json"), {
        "name": "billingAccounts/%s/budgets/9f1c2b7a-eng-prod" % BILLING_ACCOUNT,
        "displayName": "acme-eng-monthly",
        "budgetFilter": {
            "projects": ["projects/482910573001", "projects/482910573002",
                         "projects/482910573003", "projects/482910573004"],
            "creditTypesTreatment": "INCLUDE_ALL_CREDITS",
            "calendarPeriod": "MONTH",
        },
        "amount": {"specifiedAmount": {"currencyCode": "USD", "units": "2000"}},
        "thresholdRules": [
            {"thresholdPercent": 0.5, "spendBasis": "CURRENT_SPEND"},
            {"thresholdPercent": 0.9, "spendBasis": "CURRENT_SPEND"},
            {"thresholdPercent": 1.0, "spendBasis": "CURRENT_SPEND"},
            {"thresholdPercent": 1.0, "spendBasis": "FORECASTED_SPEND"},
        ],
        "notificationsRule": {
            "pubsubTopic": "projects/acme-billing-admin/topics/budget-alerts",
            "schemaVersion": "1.0",
            "monitoringNotificationChannels":
                ["projects/acme-billing-admin/notificationChannels/1187456320991"],
            "disableDefaultIamRecipients": False,
        },
        "etag": "BwXk9Qa1lTs=",
    })

    jdump(os.path.join(CONFIG, "quotas", "quota_overrides.json"), {"overrides": [
        {"project_id": "acme-lab-sandbox", "service": "compute.googleapis.com",
         "metric": "compute.googleapis.com/cpus", "unit": "1/{project}/{region}",
         "dimensions": {"region": "us-central1"}, "default_limit": 24,
         "override_value": 24,
         "justification": "sandbox blast radius cap approved by FinOps"},
        {"project_id": "acme-shop-prod", "service": "compute.googleapis.com",
         "metric": "compute.googleapis.com/cpus", "unit": "1/{project}/{region}",
         "dimensions": {"region": "us-central1"}, "default_limit": 24,
         "override_value": 96,
         "justification": "production capacity plan 2026H2"},
        {"project_id": "acme-data-lake", "service": "bigquery.googleapis.com",
         "metric": "bigquery.googleapis.com/quota/query/usage", "unit": "1/d/{project}",
         "dimensions": {}, "default_limit": None, "override_value": 2000,
         "justification": "custom quota: GiB scanned per day, on-demand pricing"},
    ]})

    jdump(os.path.join(CONFIG, "export_sink.json"), {
        "enabled": True,
        "billing_account_id": BILLING_ACCOUNT,
        "export_type": "detailed_usage_cost",
        "dataset": "acme-billing-admin:billing_export",
        "table": "gcp_billing_export_resource_v1_01A2B3_C4D5E6_F7G8H9",
        "last_export_time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rows": rows,
    })
    print("seeded %d export rows across %d resources" % (rows, len(RESOURCES)))


if __name__ == "__main__":
    main()
SEED_EOF
chmod +x "$LAB_ROOT/bin/seed-lab.py"

# =============================================================================
#  bin/break-lab.py — the controlled failure injection (4 faults)
# =============================================================================
cat > "$LAB_ROOT/bin/break-lab.py" <<'BREAK_EOF'
#!/usr/bin/env python3
"""Inject four realistic cost-control failures. Data-only, fully reversible."""
import json
import os
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(ROOT, "state")
CONFIG = os.path.join(ROOT, "config")


def jload(p):
    with open(p, "r", encoding="utf-8") as fh:
        return json.load(fh)


def jdump(p, o):
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(o, fh, indent=2)
        fh.write("\n")


# --- FAULT A: label taxonomy drift -------------------------------------------
# Six months of "just ship it" tagging: two key spellings that are not the
# standard one, one resource never labelled at the SQL layer, one value typed in
# uppercase by someone copying a spreadsheet, and two sandbox VMs created by
# script with no labels at all.
inv_path = os.path.join(STATE, "inventory.json")
inv = jload(inv_path)
for res in inv["resources"]:
    labels = res.get("labels", {})
    if res["id"] == "web-prod-b" and "cost-center" in labels:
        labels["cost_center"] = labels.pop("cost-center")
    elif res["id"] == "gke-prod-nodes" and "cost-center" in labels:
        labels["costcenter"] = labels.pop("cost-center")
    elif res["id"] == "orders-db-prod":
        labels.pop("cost-center", None)
    elif res["id"] == "raw-events-bucket":
        labels["cost-center"] = "CC-2044"
    elif res["id"] in ("lab-vm-01", "lab-vm-02"):
        res["labels"] = {}
jdump(inv_path, inv)

# --- FAULT B: the budget that cannot alert ------------------------------------
# Scope re-pointed at a decommissioned project number during a migration, all
# threshold rules dropped, the Pub/Sub topic deleted with the old alerting stack,
# the Monitoring channel emptied, and default IAM recipients switched off "to
# stop the noise".
b_path = os.path.join(CONFIG, "budgets", "budget-eng-prod.json")
b = jload(b_path)
b["budgetFilter"]["projects"] = ["projects/999999999999"]
b["thresholdRules"] = []
b["notificationsRule"]["pubsubTopic"] = "projects/acme-billing-admin/topics/budget-alerts-old"
b["notificationsRule"]["monitoringNotificationChannels"] = []
b["notificationsRule"]["disableDefaultIamRecipients"] = True
jdump(b_path, b)

# --- FAULT C: the hard limits removed -----------------------------------------
# A quota increase requested for a one-off load test and never rolled back, plus
# a BigQuery custom quota deleted so on-demand queries scan without a ceiling.
q_path = os.path.join(CONFIG, "quotas", "quota_overrides.json")
q = jload(q_path)
for e in q["overrides"]:
    if e["project_id"] == "acme-lab-sandbox" and e["metric"].endswith("/cpus"):
        e["override_value"] = 100000
        e["justification"] = ""
    if e["metric"] == "bigquery.googleapis.com/quota/query/usage":
        e["override_value"] = None
jdump(q_path, q)

# --- FAULT D: the export sink switched off ------------------------------------
s_path = os.path.join(CONFIG, "export_sink.json")
s = jload(s_path)
s["enabled"] = False
s["last_export_time"] = (datetime.now(timezone.utc) - timedelta(days=9)) \
    .strftime("%Y-%m-%dT%H:%M:%SZ")
jdump(s_path, s)

print("4 faults injected")
BREAK_EOF
chmod +x "$LAB_ROOT/bin/break-lab.py"

# =============================================================================
#  Run: seed -> prove healthy -> break -> prove broken -> brief the student
# =============================================================================
export PATH="$LAB_ROOT/bin:$PATH"

hr
printf '%s[1/4] Seeding a healthy Cloud Billing environment%s\n' "$B" "$Z"
hr
python3 "$LAB_ROOT/bin/seed-lab.py"

printf '\n%s[2/4] Baseline - this is what "under control" looks like%s\n' "$B" "$Z"
"$LAB_ROOT/bin/costctl" report --group-by cost-center
"$LAB_ROOT/bin/costctl" verify

printf '\n%s[3/4] Injecting faults%s\n' "$B" "$Z"
python3 "$LAB_ROOT/bin/break-lab.py"

printf '\n%s[4/4] Post-break state%s\n' "$B" "$Z"
"$LAB_ROOT/bin/costctl" report --group-by cost-center || true
"$LAB_ROOT/bin/costctl" verify || true

cat <<BRIEF

$(hr)
${B}INCIDENT BRIEF — "the invoice doubled and nobody heard about it"${Z}
$(hr)

You are the platform engineer on call for FinOps at ACME. Finance forwarded the
Cloud Billing invoice for the current period: it is ${B}\$2,347 net${Z} against a
\$2,000 monthly budget — 117% — and ${B}no budget alert was ever received${Z}.
Worse, when Finance asked which team to charge, the report could not say.

Add the lab CLI to your PATH first:

    ${C}export PATH="$LAB_ROOT/bin:\$PATH"${Z}

Your diagnostic tools (all read-only unless stated):

    ${C}costctl report --group-by cost-center${Z}   showback / chargeback report
    ${C}costctl report --group-by project${Z}       same money, different lens
    ${C}costctl label-audit${Z}                     resource labels vs the taxonomy
    ${C}costctl budget-check${Z}                    budgets vs actual spend and forecast
    ${C}costctl quota-check${Z}                     the cost ceiling per project
    ${C}costctl sink status${Z}                     is the billing export even running
    ${C}costctl discounts${Z}                       SUD / CUD posture (informational)
    ${C}costctl verify${Z}                          the grader: 4 checks, fix them all

${B}FAULT A — the chargeback report does not sum to the invoice${Z}
  ${Y}Symptom${Z}   \`costctl report --group-by cost-center\` puts more than half of
             net spend into a bucket called (UNALLOCATED). Finance cannot bill
             a cost center that owns 55% of the money and has no name.
  ${Y}Diagnose${Z}  \`costctl label-audit\`. Remember what a Google Cloud label
             actually is: a key/value pair ON the resource, propagated into the
             billing export rows. Keys and values are lowercase-only. A key
             spelled three different ways is three different keys.
  ${Y}Objective${Z} 0 taxonomy violations, and UNALLOCATED net spend <= 0.5%.

${B}FAULT B — a budget that was never going to alert${Z}
  ${Y}Symptom${Z}   \`costctl budget-check\` reports in-scope spend of \$0.00, 0
             threshold rules and NOBODY in the recipient list, while the account
             is at 117% of budget. The budget exists. It is decorative.
  ${Y}Diagnose${Z}  Read config/budgets/budget-eng-prod.json field by field:
             budgetFilter.projects, thresholdRules, notificationsRule. A budget
             does not cap anything — it observes a scope and notifies. If the
             scope is wrong, the rules are absent, or the notification path is
             dead, all three failures look identical from the outside: silence.
  ${Y}Objective${Z} 0 misconfigurations reported, at least one threshold rule
             firing at current spend, and at least one real recipient. Include a
             FORECASTED_SPEND rule — a current-spend alert always arrives late.

${B}FAULT C — the hard limits are gone${Z}
  ${Y}Symptom${Z}   \`costctl quota-check\` shows the sandbox project able to run
             100,000 vCPUs (a theoretical \$2.3M/month) and BigQuery on-demand
             queries with no daily ceiling at all — one bad \`SELECT *\` away
             from a five-figure line item.
  ${Y}Diagnose${Z}  config/quotas/quota_overrides.json. Understand the division of
             labour: a budget ALERTS after the fact, a quota REFUSES the request.
             Only one of the two can stop a runaway job at 03:00.
  ${Y}Objective${Z} sandbox compute CPU override between 1 and 24 with a written
             justification, and the BigQuery daily query-usage custom quota back
             at 2000 GiB/day or lower.

${B}FAULT D — the billing export is off${Z}
  ${Y}Symptom${Z}   \`costctl sink status\` reports enabled=False and a watermark
             9 days old. Every report and every forecast above is running on
             stale data, and Google does not backfill the gap.
  ${Y}Diagnose${Z}  config/export_sink.json.
  ${Y}Objective${Z} export enabled and a watermark newer than 24 hours.

${B}DONE WHEN${Z}  ${C}costctl verify${Z} prints 4/4 PASS and exits 0.
${B}RESET${Z}      re-run this script with ${C}--reset --yes${Z} to start over.
${B}CLEANUP${Z}    ${C}rm -rf "$LAB_ROOT"${Z}

Work it through before scrolling to the bottom of this script: the full solution
is there, commented out.
$(hr)

BRIEF

exit 0

# =============================================================================
# =============================================================================
#  SOLUTION — do not read until you have tried it.
#
#  Each step gives (1) the lab command, (2) the equivalent real Google Cloud
#  command or console path, and (3) the reason it is the right control.
# =============================================================================
# =============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 — Establish the ground truth before touching anything.
# ---------------------------------------------------------------------------
#   export PATH="$HOME/gcp-cost-lab-6.1/bin:$PATH"
#   costctl verify            # 4 FAIL - this is your worklist
#   costctl sink status       # fix this FIRST: everything else reads its output
#
#   Order matters. Repairing attribution or budgets on top of a dead export is
#   repairing a report, not a system.
#
# ---------------------------------------------------------------------------
# STEP 1 — FAULT D: bring the billing export back.
# ---------------------------------------------------------------------------
#   costctl sink enable
#   costctl sink run
#   costctl sink status       # enabled=True, watermark < 1h
#
#   Real Google Cloud:
#     Console > Billing > Billing export > BigQuery export > Edit settings.
#     Enable "Detailed usage cost" (per-resource granularity; "Standard usage
#     cost" has no resource-level rows, so per-VM showback is impossible).
#     The destination dataset is created first:
#       bq mk --dataset --location=US acme-billing-admin:billing_export
#     There is no gcloud command to create the export - it is console-only, and
#     it is NOT retroactive: data for the days it was off is gone for good.
#     https://cloud.google.com/billing/docs/how-to/export-data-bigquery
#
#   Why this control: Cloud Billing reports in the console answer "how much".
#   The BigQuery export is what lets you answer "how much, by whom, per SKU,
#   per label, joined against your own systems" - it is the substrate every
#   FinOps practice is built on.
#
# ---------------------------------------------------------------------------
# STEP 2 — FAULT A: restore cost attribution.
# ---------------------------------------------------------------------------
#   costctl label-audit       # read every violation before fixing any of them
#
#   costctl labels --resource web-prod-b        --set cost-center=cc-1001 --remove cost_center
#   costctl labels --resource gke-prod-nodes    --set cost-center=cc-1001 --remove costcenter
#   costctl labels --resource orders-db-prod    --set cost-center=cc-1001
#   costctl labels --resource raw-events-bucket --set cost-center=cc-2044
#   costctl labels --resource lab-vm-01 --set cost-center=cc-1001 --set team=platform \
#                                       --set env=sandbox --set owner=sre-core
#   costctl labels --resource lab-vm-02 --set cost-center=cc-1001 --set team=platform \
#                                       --set env=sandbox --set owner=sre-core
#
#   costctl label-audit                 # 0 violations
#   costctl report --group-by cost-center   # UNALLOCATED gone
#
#   Real Google Cloud - labels are per-service, so the command changes with the
#   resource type, but the key/value semantics never do:
#     gcloud compute instances add-labels lab-vm-01 --zone=us-central1-a \
#         --labels=cost-center=cc-1001,team=platform,env=sandbox,owner=sre-core
#     gcloud sql instances patch orders-db-prod --update-labels=cost-center=cc-1001
#     gcloud storage buckets update gs://raw-events-bucket --update-labels=cost-center=cc-2044
#     gcloud container clusters update gke-prod --region=us-central1 \
#         --update-labels=cost-center=cc-1001,team=platform,env=prod,owner=sre-core
#     bq update --set_label cost-center:cc-2044 acme-data-lake:warehouse
#     https://cloud.google.com/resource-manager/docs/creating-managing-labels
#
#   Three things worth internalizing:
#     * Label keys and values are lowercase [a-z0-9_-], max 63 chars, keys must
#       start with a letter. "CC-2044" is not a stylistic problem - it is not a
#       valid label value, so it never came from the sanctioned path.
#     * Labels are NOT retroactive in the export. Rows already written keep the
#       labels the resource had at the time. Relabelling fixes tomorrow's report;
#       yesterday's is corrected with a mapping table in your BigQuery queries.
#     * Labels are the finest lens, not the only one. The resource hierarchy -
#       organization > folders > projects - is the coarse one, and it is the
#       durable one: a project can only ever belong to one billing account, so
#       grouping by project or folder cannot drift the way labels can. Design
#       the hierarchy so that most attribution questions are already answered
#       before labels are consulted.
#       https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
#
#   Prevention, not repair: enforce the taxonomy at creation time rather than
#   auditing it monthly. Terraform default_labels / provider-level labels,
#   Organization Policy constraints, and a scheduled BigQuery query over the
#   export that alerts when unallocated spend crosses a threshold.
#
# ---------------------------------------------------------------------------
# STEP 3 — FAULT B: make the budget capable of alerting.
# ---------------------------------------------------------------------------
#   Edit $HOME/gcp-cost-lab-6.1/config/budgets/budget-eng-prod.json so that it
#   reads:
#
#     "budgetFilter": {
#       "projects": ["projects/482910573001", "projects/482910573002",
#                    "projects/482910573003", "projects/482910573004"],
#       "creditTypesTreatment": "INCLUDE_ALL_CREDITS",
#       "calendarPeriod": "MONTH"
#     },
#     "thresholdRules": [
#       {"thresholdPercent": 0.5, "spendBasis": "CURRENT_SPEND"},
#       {"thresholdPercent": 0.9, "spendBasis": "CURRENT_SPEND"},
#       {"thresholdPercent": 1.0, "spendBasis": "CURRENT_SPEND"},
#       {"thresholdPercent": 1.0, "spendBasis": "FORECASTED_SPEND"}
#     ],
#     "notificationsRule": {
#       "pubsubTopic": "projects/acme-billing-admin/topics/budget-alerts",
#       "schemaVersion": "1.0",
#       "monitoringNotificationChannels":
#           ["projects/acme-billing-admin/notificationChannels/1187456320991"],
#       "disableDefaultIamRecipients": false
#     }
#
#   costctl budget-check      # 0 misconfigurations, 100% CURRENT_SPEND rule FIRED
#
#   Real Google Cloud:
#     gcloud billing budgets update BUDGET_ID \
#       --billing-account=01A2B3-C4D5E6-F7G8H9 \
#       --filter-projects=projects/482910573001,projects/482910573002,projects/482910573003,projects/482910573004 \
#       --credit-types-treatment=include-all-credits \
#       --threshold-rule=percent=0.5 \
#       --threshold-rule=percent=0.9 \
#       --threshold-rule=percent=1.0 \
#       --threshold-rule=percent=1.0,basis=forecasted-spend \
#       --all-updates-rule-pubsub-topic=projects/acme-billing-admin/topics/budget-alerts \
#       --all-updates-rule-monitoring-notification-channels=projects/acme-billing-admin/notificationChannels/1187456320991 \
#       --no-all-updates-rule-disable-default-iam-recipients
#     https://cloud.google.com/sdk/gcloud/reference/billing/budgets/update
#     https://cloud.google.com/billing/docs/how-to/budgets
#
#   The four defects, and what each one teaches:
#     * Wrong scope - a budget observes exactly what budgetFilter selects. Point
#       it at a dead project number and it is permanently at 0%, forever green.
#       Scope by billing account, folder, project, service or label; the safest
#       default is one account-wide budget nobody can accidentally scope away
#       plus per-team budgets on top.
#     * No threshold rules - the budget amount alone notifies nobody. Rules are
#       the alert, not the amount.
#     * Dead Pub/Sub topic - notifications are published, not delivered with a
#       receipt. A deleted topic fails silently. Pub/Sub is also the hook for
#       automation (a Cloud Function that stops instances or, in a real
#       emergency, detaches the billing account) - see
#       https://cloud.google.com/billing/docs/how-to/budgets-programmatic-notifications
#     * disableDefaultIamRecipients=true with an empty channel list - the "stop
#       the noise" change that removes the last human from the loop.
#
#   And the point students most often miss on this objective: ${B}a budget never
#   stops spending.${Z} It is an observability control. Nothing in Cloud Billing
#   turns your resources off when a threshold is crossed unless you build that
#   automation yourself on the Pub/Sub notification.
#
# ---------------------------------------------------------------------------
# STEP 4 — FAULT C: put the hard ceilings back.
# ---------------------------------------------------------------------------
#   costctl quota-set --project acme-lab-sandbox \
#       --metric compute.googleapis.com/cpus --value 24 \
#       --justification "sandbox blast radius cap approved by FinOps"
#   costctl quota-set --project acme-data-lake \
#       --metric bigquery.googleapis.com/quota/query/usage --value 2000 \
#       --justification "on-demand query cap, GiB scanned per day"
#   costctl quota-check       # no UNLIMITED rows; ceilings priced in dollars
#
#   Real Google Cloud:
#     Console > IAM & Admin > Quotas & System Limits, filter by service and
#     metric, then Edit Quotas. From the CLI:
#       gcloud alpha services quota update \
#         --service=compute.googleapis.com \
#         --consumer=projects/acme-lab-sandbox \
#         --metric=compute.googleapis.com/cpus \
#         --unit='1/{project}/{region}' --dimensions=region=us-central1 --value=24
#     BigQuery on-demand daily ceilings are custom quotas, set per project or
#     per user:
#       https://cloud.google.com/bigquery/docs/custom-quotas
#       https://cloud.google.com/docs/quotas/view-manage
#     (The quota command surface has moved between release tracks; check
#      `gcloud services quota --help` for the current form.)
#
#   Quotas are the only control in this lab that can say no. Budgets observe,
#   labels attribute, exports record - quotas refuse the API call. Set them per
#   project so the hierarchy gives you an actual blast radius: a sandbox project
#   capped at 24 vCPUs cannot become a \$2M incident no matter what runs in it.
#   Note also the second, quieter benefit of a low quota: it converts an
#   accidental cost event into an immediate, loud API error at deploy time
#   instead of a surprise on next month's invoice.
#
# ---------------------------------------------------------------------------
# STEP 5 — Verify, then look at what is still true but not broken.
# ---------------------------------------------------------------------------
#   costctl verify                          # 4/4 PASS, exit 0
#   costctl report --group-by cost-center    # every dollar has an owner
#   costctl report --group-by service        # the same money by SKU family
#   costctl discounts                        # SUD applied, CUD coverage
#
#   Nothing above touched the price of a single vCPU-hour - only who can spend,
#   how much, and who finds out. The remaining levers are the pricing ones the
#   exam guide pairs with them:
#     * Sustained use discounts (SUD): automatic on eligible Compute Engine
#       usage, applied as a credit, no commitment, nothing to configure.
#       https://cloud.google.com/compute/docs/sustained-use-discounts
#     * Committed use discounts (CUD): a 1- or 3-year commitment for a lower
#       rate. Size them against the trailing steady-state baseline that the
#       export now lets you measure - never against the peak, and never before
#       attribution works, because an unattributed baseline is a guess.
#       https://cloud.google.com/docs/cuds
#     * Active Assist / Recommender: idle VM, idle disk, idle IP and rightsizing
#       recommendations, plus CUD recommendations, delivered per project.
#       https://cloud.google.com/recommender/docs/whatis-activeassist
#     * Pricing calculator and billing reports for forecasting before you build.
#       https://cloud.google.com/products/calculator
#
#   The through-line for exam objective 6.1: Google Cloud gives an organization
#   four distinct cost-control capabilities, and they are not interchangeable.
#   The resource hierarchy and labels decide WHO owns a cost. The BigQuery
#   billing export and Cloud Billing reports decide WHETHER YOU CAN SEE it.
#   Budgets and alerts decide WHO FINDS OUT, and only after the fact. Quotas
#   decide WHAT IS EVEN POSSIBLE. Discounts and recommendations then reduce the
#   rate on what remains. An organization that has only budgets configured has
#   an alarm with no lock on the door - which is exactly the incident you just
#   worked.
#
# ---------------------------------------------------------------------------
#   Cleanup:  rm -rf "$HOME/gcp-cost-lab-6.1"
#   Restart:  ./<this-script> --reset --yes
# ---------------------------------------------------------------------------