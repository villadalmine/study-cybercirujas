#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02) - Break & Fix Lab
#  Domain 1, Task Statement 1.4: Understand concepts of cloud economics
#  Exam weight of the parent domain: 6.0
#
#  Reference (official):
#    - CLF-C02 Exam Guide
#      https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#    - Cost allocation tags
#      https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
#    - Savings Plans / Reserved Instances / Spot
#      https://aws.amazon.com/savingsplans/compute-pricing/
#      https://aws.amazon.com/ec2/pricing/reserved-instances/pricing/
#      https://aws.amazon.com/ec2/spot/pricing/
#    - AWS Pricing Calculator (TCO modelling)
#      https://calculator.aws/
#
#  WHAT THIS SCRIPT DOES
#    Builds a self-contained, OFFLINE FinOps lab under $LAB_ROOT (default
#    /opt/finops-lab, falling back to $HOME/finops-lab): a resource inventory,
#    a rate card, a tagging policy, an on-premises cost baseline, and a small
#    reporting tool (bin/costreport). It first shows you the healthy reports,
#    then deliberately corrupts THREE pieces of cost data and hands you the
#    broken lab to repair.
#
#  SAFETY
#    - No AWS account, no credentials, no API calls, no real spend. Ever.
#    - Every write is confined to $LAB_ROOT. Nothing outside it is touched:
#      no packages, no systemd units, no networking, no /etc.
#    - $LAB_ROOT is refused if it exists and was not created by this script.
#    - Still: run this on a DISPOSABLE lab VM, as the exercise intends.
#
#  USAGE
#    ./cloud-economics-break-fix.sh            # setup + show healthy + break
#    ./cloud-economics-break-fix.sh setup      # build the healthy lab only
#    ./cloud-economics-break-fix.sh break      # (re)apply the faults
#    ./cloud-economics-break-fix.sh verify     # grade your repair (exit 0 = fixed)
#    ./cloud-economics-break-fix.sh hints      # progressive hints, no answers
#    ./cloud-economics-break-fix.sh reset      # destroy and rebuild the lab
#
#  The full step-by-step solution is at the bottom of this file, commented out.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Presentation helpers
# ------------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
  C_RST=""; C_B=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
rule() { printf '%s\n' "------------------------------------------------------------------------"; }
head1(){ rule; printf '%s%s%s\n' "$C_B" "$*" "$C_RST"; rule; }

# ------------------------------------------------------------------------------
# Lab location and guard rails
# ------------------------------------------------------------------------------
MARKER=".finops-lab-marker"

resolve_lab_root() {
  if [[ -n "${LAB_ROOT:-}" ]]; then
    return 0
  fi
  if mkdir -p /opt/finops-lab 2>/dev/null; then
    LAB_ROOT=/opt/finops-lab
  else
    LAB_ROOT="$HOME/finops-lab"
  fi
  export LAB_ROOT
}

guard_lab_root() {
  case "$LAB_ROOT" in
    ""|"/"|"$HOME"|"/home"|"/root"|"/etc"|"/usr"|"/var"|"/opt")
      die "refusing to use LAB_ROOT='$LAB_ROOT' - pick a dedicated directory" ;;
  esac
  if [[ -e "$LAB_ROOT" && ! -d "$LAB_ROOT" ]]; then
    die "LAB_ROOT='$LAB_ROOT' exists and is not a directory"
  fi
  if [[ -d "$LAB_ROOT" ]] && [[ -n "$(ls -A "$LAB_ROOT" 2>/dev/null || true)" ]] \
     && [[ ! -f "$LAB_ROOT/$MARKER" ]]; then
    die "LAB_ROOT='$LAB_ROOT' is not empty and was not created by this script"
  fi
}

need_deps() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required (stdlib only, no pip installs)"
}

need_lab() {
  [[ -f "$LAB_ROOT/$MARKER" ]] || die "no lab at '$LAB_ROOT' - run: $0 setup"
}

# ------------------------------------------------------------------------------
# setup: write the healthy lab
# ------------------------------------------------------------------------------
write_tool() {
  mkdir -p "$LAB_ROOT/bin"
  cat > "$LAB_ROOT/bin/costreport" <<'PY'
#!/usr/bin/env python3
"""costreport - offline FinOps reporting instrument for the cloud-economics lab.

Joins inventory.csv against pricing.json, applies the commitment factor of each
purchase option, and reports what a Cost Explorer / Cost and Usage Report view
would show you:

  chargeback  spend grouped by cost allocation tag (showback / chargeback)
  monthly     billed spend per service, commitment coverage, blended rate
  tco         3-year total cost of ownership: on-premises baseline vs AWS
  detail      per-resource cost lines
  check       lab acceptance criteria (exit 0 = repaired)
  all         chargeback + monthly + tco

No credentials, no network calls, no spend. The rates in pricing.json are an
illustrative snapshot for training only - live prices: https://calculator.aws/
"""

import csv
import json
import os
import re
import sys

ROOT = os.environ.get("LAB_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))

WARNINGS = []


def _json(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return json.load(fh)


def _csv(rel):
    with open(os.path.join(ROOT, rel), newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _money(x):
    return "{:>12,.2f}".format(x)


def priced_rows():
    """Return every inventory line with its On-Demand and effective cost."""
    pricing = _json("pricing.json")
    rates = pricing["rates"]
    factors = pricing.get("commitment_factor", {}) or {}
    rows = []
    for r in _csv("inventory.csv"):
        key = "{}:{}".format(r["service"], r["item"])
        if key in rates:
            rate = float(rates[key])
        else:
            rate = 0.0
            WARNINGS.append(
                "no rate for '{}' ({}) - counted as $0.00".format(key, r["resource_id"]))
        po = (r["purchase_option"] or "OnDemand").strip()
        if po in factors:
            factor = float(factors[po])
        else:
            factor = 1.0
            WARNINGS.append(
                "no commitment factor for '{}' - resource {} billed at On-Demand"
                .format(po, r["resource_id"]))
        qty = float(r["quantity"])
        r["_ondemand"] = qty * rate
        r["_cost"] = qty * rate * factor
        r["_factor"] = factor
        r["_po"] = po
        rows.append(r)
    return rows


def tag_findings(rows):
    """Validate tags against tagging_policy.json and assign a chargeback bucket."""
    pol = _json("tagging_policy.json")
    cc_pat = re.compile(pol["CostCenter"]["pattern"])
    ow_pat = re.compile(pol["Owner"]["pattern"])
    allowed_cc = pol["CostCenter"]["allowed"]
    allowed_env = pol["Environment"]["allowed"]
    findings = []
    for r in rows:
        cc = (r.get("tag_CostCenter") or "")
        env = (r.get("tag_Environment") or "")
        own = (r.get("tag_Owner") or "")
        problems = []
        if not cc.strip():
            problems.append("CostCenter tag missing")
        elif not cc_pat.match(cc):
            problems.append("CostCenter '{}' does not match {}".format(
                cc, pol["CostCenter"]["pattern"]))
        elif cc not in allowed_cc:
            problems.append("CostCenter '{}' is not in the chart of accounts".format(cc))
        if not env.strip():
            problems.append("Environment tag missing")
        elif env not in allowed_env:
            problems.append("Environment '{}' not one of {}".format(
                env, "|".join(allowed_env)))
        if not own.strip():
            problems.append("Owner tag missing")
        elif not ow_pat.match(own):
            problems.append("Owner '{}' does not match {}".format(
                own, pol["Owner"]["pattern"]))
        r["_cc"] = cc if (cc_pat.match(cc) and cc in allowed_cc) else "UNALLOCATED"
        if problems:
            findings.append((r["resource_id"], problems))
    return findings


def flush_warnings():
    if not WARNINGS:
        return
    print("")
    print("WARNINGS")
    for w in list(dict.fromkeys(WARNINGS)):
        print("  ! {}".format(w))


def cmd_chargeback(rows):
    pol = _json("tagging_policy.json")
    names = dict(pol["CostCenter"]["allowed"])
    names["UNALLOCATED"] = "*** no valid CostCenter tag ***"
    findings = tag_findings(rows)
    buckets = {}
    counts = {}
    for r in rows:
        buckets[r["_cc"]] = buckets.get(r["_cc"], 0.0) + r["_cost"]
        counts[r["_cc"]] = counts.get(r["_cc"], 0) + 1
    total = sum(buckets.values())
    print("CHARGEBACK BY COST ALLOCATION TAG (CostCenter)")
    print("{:<14}{:<38}{:>12}{:>9}{:>7}".format(
        "COST CENTER", "OWNER TEAM", "USD/MONTH", "SHARE", "RES"))
    for cc in sorted(buckets, key=lambda k: (-buckets[k], k)):
        share = (buckets[cc] / total * 100.0) if total else 0.0
        print("{:<14}{:<38}{}{:>8.1f}%{:>7}".format(
            cc, names.get(cc, "?"), _money(buckets[cc]), share, counts[cc]))
    print("{:<52}{}".format("TOTAL", _money(total)))
    unalloc = buckets.get("UNALLOCATED", 0.0)
    pct = (unalloc / total * 100.0) if total else 0.0
    print("")
    print("Unallocated spend        : {} ({:.1f}% of billed spend)".format(
        _money(unalloc).strip(), pct))
    print("Tag policy violations    : {} resource(s)".format(len(findings)))
    for rid, problems in findings:
        print("  - {:<24} {}".format(rid, "; ".join(problems)))
    flush_warnings()


def cmd_monthly(rows):
    per_service = {}
    for r in rows:
        per_service.setdefault(r["service"], [0.0, 0.0])
        per_service[r["service"]][0] += r["_ondemand"]
        per_service[r["service"]][1] += r["_cost"]
    od_total = sum(v[0] for v in per_service.values())
    bill_total = sum(v[1] for v in per_service.values())
    print("MONTHLY BILL SIMULATION")
    print("{:<12}{:>16}{:>16}{:>12}".format(
        "SERVICE", "ON-DEMAND USD", "BILLED USD", "SAVING"))
    for svc in sorted(per_service):
        od, bill = per_service[svc]
        sav = (1 - bill / od) * 100.0 if od else 0.0
        print("{:<12}{}{}{:>11.1f}%".format(svc, _money(od), _money(bill), sav))
    sav = (1 - bill_total / od_total) * 100.0 if od_total else 0.0
    print("{:<12}{}{}{:>11.1f}%".format("TOTAL", _money(od_total), _money(bill_total), sav))

    ec2 = [r for r in rows if r["service"] == "ec2"]
    committed = [r for r in ec2 if r["_po"].startswith(("SavingsPlan", "ReservedInstance"))]
    ec2_od = sum(r["_ondemand"] for r in ec2)
    cov = (sum(r["_ondemand"] for r in committed) / ec2_od * 100.0) if ec2_od else 0.0
    hours = sum(float(r["quantity"]) for r in ec2 if r["unit"] == "hours")
    ec2_bill = sum(r["_cost"] for r in ec2)
    print("")
    print("EC2 commitment coverage  : {:.1f}% of On-Demand-equivalent compute spend".format(cov))
    print("EC2 blended rate         : ${:.4f}/hour over {:,.0f} instance-hours".format(
        (ec2_bill / hours) if hours else 0.0, hours))
    print("Spot usage               : {} resource(s) (interruptible, no commitment)".format(
        len([r for r in ec2 if r["_po"] == "Spot"])))
    print("Monthly billed spend     : ${:,.2f}   (annualised ${:,.2f})".format(
        bill_total, bill_total * 12))
    flush_warnings()


def cmd_tco(rows):
    b = _json("onprem_baseline.json")
    years = float(b.get("amortization_years") or 0)
    if years <= 0:
        print("ERROR: onprem_baseline.json has no usable amortization_years")
        return 1
    capex = {k: float(v) for k, v in (b.get("capex_usd") or {}).items()}
    opex = {k: float(v) for k, v in (b.get("opex_annual_usd") or {}).items()}
    capex_total = sum(capex.values())
    opex_total = sum(opex.values())
    onprem_annual = capex_total / years + opex_total
    cloud_month = sum(r["_cost"] for r in rows)
    cloud_annual = cloud_month * 12
    horizon = 3

    print("3-YEAR TOTAL COST OF OWNERSHIP")
    print("Footprint: {}".format(b.get("footprint", "n/a")))
    print("")
    print("ON-PREMISES (CapEx + OpEx)")
    for k in sorted(capex):
        print("  capex  {:<32}{}  (amortised over {:.0f} yr)".format(k, _money(capex[k]), years))
    print("  {:<39}{}".format("capex subtotal, per year", _money(capex_total / years)))
    if opex:
        for k in sorted(opex):
            print("  opex   {:<32}{}  per year".format(k, _money(opex[k])))
    else:
        print("  opex   {:<32}{}  <-- no operating expenses in the model".format(
            "(none declared)", _money(0.0)))
    print("  {:<39}{}".format("opex subtotal, per year", _money(opex_total)))
    print("  {:<39}{}".format("ON-PREM ANNUAL RUN RATE", _money(onprem_annual)))
    print("")
    print("AWS (OpEx only, pay-as-you-go + commitments)")
    print("  {:<39}{}".format("billed per month", _money(cloud_month)))
    print("  {:<39}{}".format("AWS ANNUAL RUN RATE", _money(cloud_annual)))
    print("")
    onprem_3y = onprem_annual * horizon
    cloud_3y = cloud_annual * horizon
    print("  {:<39}{}".format("on-premises, {} years".format(horizon), _money(onprem_3y)))
    print("  {:<39}{}".format("AWS, {} years".format(horizon), _money(cloud_3y)))
    delta = onprem_3y - cloud_3y
    if delta >= 0:
        pct = (delta / onprem_3y * 100.0) if onprem_3y else 0.0
        print("")
        print("  VERDICT: AWS is cheaper by ${:,.2f} over {} years ({:.1f}%).".format(
            delta, horizon, pct))
        print("           Recommendation: migrate; convert CapEx into variable OpEx.")
    else:
        pct = (-delta / cloud_3y * 100.0) if cloud_3y else 0.0
        print("")
        print("  VERDICT: on-premises is cheaper by ${:,.2f} over {} years ({:.1f}%).".format(
            -delta, horizon, pct))
        print("           Recommendation: STAY ON-PREMISES, cancel the migration.")
    flush_warnings()
    return 0


def cmd_detail(rows):
    print("PER-RESOURCE COST LINES")
    print("{:<24}{:<10}{:<14}{:>10}{:<10}{:<36}{:>10}{:>7}{:>12}".format(
        "RESOURCE", "SERVICE", "ITEM", "QTY", "UNIT", "PURCHASE OPTION",
        "ON-DEMAND", "FACTOR", "BILLED"))
    for r in rows:
        print("{:<24}{:<10}{:<14}{:>10}{:<10}{:<36}{:>10.2f}{:>7.3f}{:>12.2f}".format(
            r["resource_id"][:23], r["service"], r["item"], r["quantity"],
            r["unit"], r["_po"][:35], r["_ondemand"], r["_factor"], r["_cost"]))
    flush_warnings()


def cmd_check(rows):
    print("LAB ACCEPTANCE CRITERIA")
    failures = 0

    # C1 - cost allocation integrity
    findings = tag_findings(rows)
    total = sum(r["_cost"] for r in rows)
    unalloc = sum(r["_cost"] for r in rows if r["_cc"] == "UNALLOCATED")
    pct = (unalloc / total * 100.0) if total else 0.0
    if not findings and pct <= 1.0:
        print("  PASS  C1 cost allocation: 0 policy violations, {:.1f}% unallocated".format(pct))
    else:
        failures += 1
        print("  FAIL  C1 cost allocation: {} policy violation(s), {:.1f}% unallocated "
              "(target: 0 violations and <= 1.0%)".format(len(findings), pct))
        print("        evidence: tagging_policy.json, inventory.csv")

    # C2 - the rate model matches the signed rate card
    factors = (_json("pricing.json").get("commitment_factor") or {})
    bad = []
    for c in _csv("docs/rate_card.csv"):
        po = c["purchase_option"]
        want = float(c["effective_factor"])
        got = factors.get(po)
        if got is None or abs(float(got) - want) > 1e-6:
            bad.append("{} (have {}, rate card says {:.3f})".format(
                po, "nothing" if got is None else "{:.3f}".format(float(got)), want))
    if not bad:
        print("  PASS  C2 rate model: pricing.json matches docs/rate_card.csv")
    else:
        failures += 1
        print("  FAIL  C2 rate model: {} purchase option(s) wrong or missing".format(len(bad)))
        for b in bad:
            print("        - {}".format(b))
        print("        evidence: docs/rate_card.csv")

    # C3 - the on-premises baseline is complete and honestly amortised
    inv = _csv("docs/datacenter_invoices.csv")
    want_capex = {r["line_item"]: float(r["amount_usd"]) for r in inv if r["kind"] == "capex"}
    want_opex = {r["line_item"]: float(r["amount_usd"]) for r in inv if r["kind"] == "opex"}
    b = _json("onprem_baseline.json")
    got_capex = {k: float(v) for k, v in (b.get("capex_usd") or {}).items()}
    got_opex = {k: float(v) for k, v in (b.get("opex_annual_usd") or {}).items()}
    want_years = float(_json("docs/asset_policy.json")["hardware_refresh_months"]) / 12.0
    problems = []
    for label, want, got in (("capex", want_capex, got_capex), ("opex", want_opex, got_opex)):
        for k in sorted(set(want) - set(got)):
            problems.append("{} line item '{}' missing from the model".format(label, k))
        for k in sorted(set(got) - set(want)):
            problems.append("{} line item '{}' is not on any invoice".format(label, k))
        for k in sorted(set(want) & set(got)):
            if abs(want[k] - got[k]) > 1.0:
                problems.append("{} '{}' is {:,.2f}, invoices say {:,.2f}".format(
                    label, k, got[k], want[k]))
    if abs(float(b.get("amortization_years") or 0) - want_years) > 1e-6:
        problems.append("amortization_years is {} but the asset policy refresh cycle is "
                        "{:.0f} year(s)".format(b.get("amortization_years"), want_years))
    if not problems:
        print("  PASS  C3 TCO baseline: complete and amortised over the real refresh cycle")
    else:
        failures += 1
        print("  FAIL  C3 TCO baseline: {} problem(s)".format(len(problems)))
        for p in problems:
            print("        - {}".format(p))
        print("        evidence: docs/datacenter_invoices.csv, docs/asset_policy.json")

    print("")
    if failures:
        print("RESULT: {} criterion/criteria still failing. Keep going.".format(failures))
        return 1
    print("RESULT: all criteria met. The cost model is trustworthy again.")
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    rows = priced_rows()
    if cmd == "chargeback":
        cmd_chargeback(rows); return 0
    if cmd == "monthly":
        cmd_monthly(rows); return 0
    if cmd == "tco":
        return cmd_tco(rows)
    if cmd == "detail":
        cmd_detail(rows); return 0
    if cmd == "check":
        return cmd_check(rows)
    if cmd == "all":
        cmd_chargeback(rows); print(""); cmd_monthly(rows); print(""); return cmd_tco(rows)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
PY
  chmod +x "$LAB_ROOT/bin/costreport"
}

write_healthy_data() {
  mkdir -p "$LAB_ROOT/docs"

  cat > "$LAB_ROOT/inventory.csv" <<'CSV'
resource_id,service,item,quantity,unit,purchase_option,tag_CostCenter,tag_Environment,tag_Owner
i-0a1b2c3d4e5f60001,ec2,m6i.large,730,hours,SavingsPlan1yrNoUpfront,CC-1001,prod,platform@example.internal
i-0a1b2c3d4e5f60002,ec2,m6i.xlarge,730,hours,SavingsPlan1yrNoUpfront,CC-1001,prod,platform@example.internal
i-0a1b2c3d4e5f60003,ec2,c6i.2xlarge,730,hours,ReservedInstance3yrPartialUpfront,CC-2002,prod,data@example.internal
i-0a1b2c3d4e5f60004,ec2,r6i.xlarge,730,hours,OnDemand,CC-2002,prod,data@example.internal
i-0a1b2c3d4e5f60005,ec2,t3.medium,730,hours,OnDemand,CC-3003,dev,sandbox@example.internal
i-0a1b2c3d4e5f60006,ec2,c6i.2xlarge,180,hours,Spot,CC-3003,dev,sandbox@example.internal
i-0a1b2c3d4e5f60007,ec2,m6i.large,730,hours,SavingsPlan1yrNoUpfront,CC-1001,prod,platform@example.internal
vol-0aa11bb22cc33d01,ebs,gp3,2000,gb-month,OnDemand,CC-1001,prod,platform@example.internal
vol-0aa11bb22cc33d02,ebs,gp3,800,gb-month,OnDemand,CC-2002,prod,data@example.internal
s3-app-logs-archive,s3,standard,5000,gb-month,OnDemand,CC-3003,dev,sandbox@example.internal
dto-egress-prod-01,transfer,data-out,3000,gb,OnDemand,CC-1001,prod,platform@example.internal
CSV

  cat > "$LAB_ROOT/pricing.json" <<'JSON'
{
  "currency": "USD",
  "region": "us-east-1",
  "snapshot_date": "2026-09-01",
  "disclaimer": "Illustrative training snapshot. Live prices: https://calculator.aws/ and https://aws.amazon.com/ec2/pricing/",
  "rates": {
    "ec2:m6i.large": 0.096,
    "ec2:m6i.xlarge": 0.192,
    "ec2:c6i.2xlarge": 0.34,
    "ec2:r6i.xlarge": 0.252,
    "ec2:t3.medium": 0.0416,
    "ebs:gp3": 0.08,
    "s3:standard": 0.023,
    "transfer:data-out": 0.09
  },
  "commitment_factor": {
    "OnDemand": 1.0,
    "SavingsPlan1yrNoUpfront": 0.72,
    "ReservedInstance3yrPartialUpfront": 0.48,
    "Spot": 0.3
  }
}
JSON

  cat > "$LAB_ROOT/tagging_policy.json" <<'JSON'
{
  "required_tags": ["CostCenter", "Environment", "Owner"],
  "CostCenter": {
    "pattern": "^CC-[0-9]{4}$",
    "allowed": {
      "CC-1001": "Platform Engineering",
      "CC-2002": "Data Services",
      "CC-3003": "Developer Sandbox"
    }
  },
  "Environment": { "allowed": ["prod", "staging", "dev"] },
  "Owner": { "pattern": "^[a-z0-9._-]+@example\\.internal$" },
  "note": "Applying a tag is not enough: it must also be activated as a cost allocation tag in Billing before it appears in Cost Explorer or the CUR. See https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html",
  "enforcement": "Tag policies in AWS Organizations + AWS Config rule required-tags; budgets are created per CostCenter in AWS Budgets."
}
JSON

  cat > "$LAB_ROOT/onprem_baseline.json" <<'JSON'
{
  "footprint": "3x 2U dual-socket hosts, 1x 24-port ToR switch, 1x 30 TB hybrid array - sized to serve the same workload as the AWS inventory at peak",
  "amortization_years": 3,
  "capex_usd": {
    "compute_servers": 24000,
    "network_switching": 6000,
    "storage_array": 14000
  },
  "opex_annual_usd": {
    "power": 2400,
    "cooling": 1600,
    "colocation_rack_space": 4800,
    "transit_bandwidth": 3600,
    "hardware_support_contracts": 4400,
    "sysadmin_labor": 9600,
    "backup_and_dr_site": 2400
  }
}
JSON

  cat > "$LAB_ROOT/docs/rate_card.csv" <<'CSV'
purchase_option,term,payment,discount_vs_on_demand_pct,effective_factor,source
OnDemand,none,none,0,1.000,https://aws.amazon.com/ec2/pricing/on-demand/
SavingsPlan1yrNoUpfront,1yr,No Upfront,28,0.720,https://aws.amazon.com/savingsplans/compute-pricing/
ReservedInstance3yrPartialUpfront,3yr,Partial Upfront,52,0.480,https://aws.amazon.com/ec2/pricing/reserved-instances/pricing/
Spot,none,none,70,0.300,https://aws.amazon.com/ec2/spot/pricing/
CSV

  cat > "$LAB_ROOT/docs/datacenter_invoices.csv" <<'CSV'
line_item,kind,amount_usd,period,vendor_ref
compute_servers,capex,24000,one_time,PO-4471
network_switching,capex,6000,one_time,PO-4472
storage_array,capex,14000,one_time,PO-4473
power,opex,2400,annual,UTIL-2026
cooling,opex,1600,annual,UTIL-2026
colocation_rack_space,opex,4800,annual,COLO-88
transit_bandwidth,opex,3600,annual,ISP-31
hardware_support_contracts,opex,4400,annual,SUP-19
sysadmin_labor,opex,9600,annual,HR-008FTE
backup_and_dr_site,opex,2400,annual,DR-07
CSV

  cat > "$LAB_ROOT/docs/asset_policy.json" <<'JSON'
{
  "hardware_refresh_months": 36,
  "note": "Finance depreciates server, network and storage assets over the 36-month refresh cycle. Stretching the schedule beyond the cycle understates the annual cost of running our own hardware.",
  "signed_off_by": "CFO office, fiscal year 2026"
}
JSON

  cat > "$LAB_ROOT/docs/EXAM_NOTES.md" <<'MD'
# CLF-C02 1.4 - Cloud economics: what the exam actually asks

- Fixed cost (CapEx) vs variable cost (OpEx). Buying servers is CapEx: you pay
  up front for peak capacity you may never use. AWS is OpEx: you pay for what
  you consume, per second/hour/GB, and stop paying when you stop using it.
- Total Cost of Ownership is NOT the hardware invoice. It includes power,
  cooling, rack space, transit bandwidth, support contracts, backup/DR site and
  the labour to run all of it. Omitting operations is the classic way to make
  on-premises look cheap.
- Economies of scale: AWS aggregates demand across millions of customers, so
  the unit price falls over time - a saving an individual data centre cannot
  reproduce.
- Purchase options, cheapest commitment-free first:
  On-Demand (no commitment, highest rate) < Savings Plans / Reserved Instances
  (1 or 3 year commitment, up to ~72% off) < Spot (spare capacity, up to ~90%
  off, can be interrupted with a 2-minute notice - only for fault-tolerant work).
- Right-sizing: matching instance type and size to observed utilisation. The
  cheapest instance is the one you turned off.
- Cost allocation tags let you attribute spend to a team, product or
  environment. Untagged spend cannot be charged back, budgeted or optimised.
  Tags must be ACTIVATED in Billing to appear in Cost Explorer / the CUR.
- Tools you should be able to name: AWS Pricing Calculator (estimate before you
  build), Cost Explorer (analyse what you spent), AWS Budgets (alert before you
  overspend), AWS Cost and Usage Report (line-item detail), Compute Optimizer
  (right-sizing recommendations), Cost Anomaly Detection.

Source: CLF-C02 Exam Guide
https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
MD

  touch "$LAB_ROOT/$MARKER"
}

do_setup() {
  guard_lab_root
  need_deps
  mkdir -p "$LAB_ROOT"
  touch "$LAB_ROOT/$MARKER"
  write_healthy_data
  write_tool
  ok "healthy lab written to $LAB_ROOT"
}

# ------------------------------------------------------------------------------
# break: apply the three faults
# ------------------------------------------------------------------------------
snapshot_good_report() {
  {
    say "AWS Cost Explorer export - previous billing period (kept by your predecessor)"
    say "Generated before the incident. This is the last known good state."
    say ""
    LAB_ROOT="$LAB_ROOT" "$LAB_ROOT/bin/costreport" all
  } > "$LAB_ROOT/docs/last_month_cost_explorer_export.txt" 2>&1
  ok "last known good report saved to docs/last_month_cost_explorer_export.txt"
}

do_break() {
  need_lab
  need_deps
  warn "applying faults - your edits to the lab data files will be overwritten"

  # FAULT A - cost allocation tags: three resources lose CostCenter entirely,
  # two carry values that violate the naming standard, one loses its Owner.
  cat > "$LAB_ROOT/inventory.csv" <<'CSV'
resource_id,service,item,quantity,unit,purchase_option,tag_CostCenter,tag_Environment,tag_Owner
i-0a1b2c3d4e5f60001,ec2,m6i.large,730,hours,SavingsPlan1yrNoUpfront,CC-1001,prod,platform@example.internal
i-0a1b2c3d4e5f60002,ec2,m6i.xlarge,730,hours,SavingsPlan1yrNoUpfront,,prod,platform@example.internal
i-0a1b2c3d4e5f60003,ec2,c6i.2xlarge,730,hours,ReservedInstance3yrPartialUpfront,CC2002,prod,data@example.internal
i-0a1b2c3d4e5f60004,ec2,r6i.xlarge,730,hours,OnDemand,CC-2002,prod,data@example.internal
i-0a1b2c3d4e5f60005,ec2,t3.medium,730,hours,OnDemand,cc-3003 ,dev,sandbox@example.internal
i-0a1b2c3d4e5f60006,ec2,c6i.2xlarge,180,hours,Spot,CC-3003,dev,
i-0a1b2c3d4e5f60007,ec2,m6i.large,730,hours,SavingsPlan1yrNoUpfront,CC-1001,prod,platform@example.internal
vol-0aa11bb22cc33d01,ebs,gp3,2000,gb-month,OnDemand,,prod,platform@example.internal
vol-0aa11bb22cc33d02,ebs,gp3,800,gb-month,OnDemand,CC-2002,prod,data@example.internal
s3-app-logs-archive,s3,standard,5000,gb-month,OnDemand,CC-3003,dev,sandbox@example.internal
dto-egress-prod-01,transfer,data-out,3000,gb,OnDemand,,prod,platform@example.internal
CSV

  # FAULT B - the commitment rate model is gutted: only On-Demand survives, so
  # every Savings Plan, Reserved Instance and Spot resource is priced at list.
  # FAULT C - the on-premises baseline loses all operating expenses and the
  # depreciation schedule is stretched past the real refresh cycle.
  python3 - "$LAB_ROOT" <<'PY'
import json, os, sys

root = sys.argv[1]

p = os.path.join(root, "pricing.json")
with open(p, encoding="utf-8") as fh:
    pricing = json.load(fh)
pricing["commitment_factor"] = {"OnDemand": 1.0}
with open(p, "w", encoding="utf-8") as fh:
    json.dump(pricing, fh, indent=2)
    fh.write("\n")

b = os.path.join(root, "onprem_baseline.json")
with open(b, encoding="utf-8") as fh:
    base = json.load(fh)
base["amortization_years"] = 5
base["opex_annual_usd"] = {}
with open(b, "w", encoding="utf-8") as fh:
    json.dump(base, fh, indent=2)
    fh.write("\n")
PY
  ok "faults applied"
}

# ------------------------------------------------------------------------------
# Student-facing brief
# ------------------------------------------------------------------------------
print_brief() {
  head1 "SCENARIO"
  cat <<EOF
You are the FinOps engineer for a company that has just moved a small production
workload to AWS. Finance is about to decide whether the migration continues or
is rolled back to the data centre.

Overnight, three changes were made to the cost model by someone who is no longer
reachable. Nobody edited the reporting tool - only the data it reads.

Lab root : ${LAB_ROOT}
Tool     : ${LAB_ROOT}/bin/costreport  (chargeback | monthly | tco | detail | check)
Evidence : ${LAB_ROOT}/docs/  (rate card, data centre invoices, asset policy,
           tagging policy, and last month's Cost Explorer export)

Nothing in this lab talks to AWS. There are no credentials and no spend.
EOF

  head1 "SYMPTOMS YOU WILL SEE"
  cat <<'EOF'
1) bin/costreport chargeback
   About 60% of the monthly bill lands in a bucket called UNALLOCATED, and the
   tool lists 6 tag policy violations. Three cost centres that used to add up to
   100% of spend now account for less than half of it. Finance cannot charge
   back what it cannot attribute, so every team says the bill is not theirs.

2) bin/costreport monthly
   The bill has jumped roughly +21% month over month with no new resources, and
   the report warns that it has "no commitment factor" for the Savings Plan,
   Reserved Instance and Spot purchase options. Commitment coverage reads 0.0%
   and the EC2 blended rate equals the On-Demand list rate - as if the
   commitments the company already paid for did not exist.

3) bin/costreport tco
   The 3-year comparison now concludes that on-premises is about 37% CHEAPER
   than AWS and prints "Recommendation: STAY ON-PREMISES, cancel the migration."
   The on-premises side of the model shows hardware purchases only, and the
   invoices in docs/ contain line items that appear nowhere in it.
EOF

  head1 "YOUR MISSION"
  cat <<EOF
Repair the cost model so that all three acceptance criteria pass:

  C1  Every resource complies with tagging_policy.json and unallocated spend is
      at most 1% of billed spend.
  C2  pricing.json prices every purchase option exactly as docs/rate_card.csv
      states, to three decimals.
  C3  onprem_baseline.json contains every CapEx and OpEx line item from
      docs/datacenter_invoices.csv, at the invoiced amounts, and amortises the
      hardware over the refresh cycle in docs/asset_policy.json - no longer.

Rules of engagement:
  - Do not edit bin/costreport. The instrument is fine; the data is not.
  - Every correct value is discoverable inside ${LAB_ROOT}/docs/. Do not guess.
  - Grade yourself at any time:   $0 verify
  - Stuck? Progressive hints:     $0 hints

Suggested first move:
  cd ${LAB_ROOT}
  ./bin/costreport chargeback
  ./bin/costreport monthly
  ./bin/costreport tco
  diff <(./bin/costreport all) docs/last_month_cost_explorer_export.txt | head -40

WARNING: '$0 reset' rebuilds the lab from scratch in the healthy state. That is
also, effectively, the answer key - use it only to start over.
EOF
}

do_hints() {
  cat <<'EOF'
HINT 1 (all faults)
  The reporting tool tells you which file holds the evidence for each failing
  criterion. Run: ./bin/costreport check   and read the "evidence:" lines.

HINT 2 (C1 - allocation)
  Two of the broken rows are not empty at all - they are the wrong SHAPE. Read
  the regular expression in tagging_policy.json character by character and
  compare it against the value, including leading and trailing whitespace.
  Ask yourself what the AWS equivalent of "the tag exists but is wrong" is,
  and what a Tag Policy in AWS Organizations would have prevented.

HINT 3 (C2 - rate model)
  The tool never invents prices; it looks up the purchase option string from
  inventory.csv in pricing.json. If the key is absent, it falls back to list
  price and says so. docs/rate_card.csv has one row per purchase option and a
  column named effective_factor. That column is the answer.

HINT 4 (C3 - TCO)
  A total cost of ownership model that contains only purchase orders is not a
  TCO model. Group docs/datacenter_invoices.csv by its 'kind' column: what is
  in the file that is not in onprem_baseline.json? Then check how many years
  finance actually depreciates hardware over (docs/asset_policy.json) versus
  what the model claims.

HINT 5 (sanity)
  When repaired, the monthly billed spend returns to the figure in
  docs/last_month_cost_explorer_export.txt, unallocated spend is 0.0%, and the
  3-year verdict flips back to AWS.
EOF
}

do_verify() {
  need_lab
  need_deps
  head1 "VERIFICATION"
  set +e
  LAB_ROOT="$LAB_ROOT" "$LAB_ROOT/bin/costreport" check
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    ok "lab repaired - cost model is trustworthy again"
  else
    warn "not there yet - run '$0 hints' for a nudge"
  fi
  return $rc
}

do_reset() {
  guard_lab_root
  if [[ -d "$LAB_ROOT" ]]; then
    [[ -f "$LAB_ROOT/$MARKER" ]] || die "refusing to delete '$LAB_ROOT': not a lab directory"
    rm -rf -- "$LAB_ROOT"
    info "removed $LAB_ROOT"
  fi
  do_setup
  snapshot_good_report
  do_break
  ok "lab reset and re-broken"
}

do_status() {
  need_lab
  LAB_ROOT="$LAB_ROOT" "$LAB_ROOT/bin/costreport" all || true
}

usage() {
  cat <<EOF
Usage: $0 [run|setup|break|verify|hints|status|reset]

  run     (default) build the lab, show the healthy baseline, then break it
  setup   build the healthy lab only
  break   (re)apply the faults
  verify  grade the repair; exit 0 when all criteria pass
  hints   progressive hints, no answers
  status  print the current chargeback / monthly / TCO reports
  reset   destroy and rebuild the lab in its broken state

Environment:
  LAB_ROOT   where the lab lives (default: /opt/finops-lab, else \$HOME/finops-lab)
  NO_COLOR   set to disable colour
EOF
}

main() {
  resolve_lab_root
  local cmd="${1:-run}"
  case "$cmd" in
    run)
      do_setup
      head1 "HEALTHY BASELINE - this is what a trustworthy cost model looks like"
      LAB_ROOT="$LAB_ROOT" "$LAB_ROOT/bin/costreport" all
      snapshot_good_report
      say ""
      do_break
      say ""
      print_brief
      ;;
    setup)  do_setup ;;
    break)  do_break; say ""; print_brief ;;
    verify) do_verify ;;
    hints)  do_hints ;;
    status) do_status ;;
    reset)  do_reset; say ""; print_brief ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"

# ==============================================================================
#  S O L U T I O N   -   step by step
#  (Do not read until you have tried. Every command below is safe and confined
#   to $LAB_ROOT. All of them are run from inside the lab root:  cd $LAB_ROOT )
# ==============================================================================
#
# ------------------------------------------------------------------------------
# STEP 0 - Reproduce and measure before touching anything
# ------------------------------------------------------------------------------
#   cd "${LAB_ROOT:-/opt/finops-lab}"
#   ./bin/costreport check
#   diff <(./bin/costreport all) docs/last_month_cost_explorer_export.txt | head -60
#
#   'check' names the failing criterion AND the evidence file for each one. The
#   diff against last month's export is the FinOps reflex: a bill that moves
#   without a corresponding change in resources is a pricing or attribution
#   problem, not a consumption problem.
#
# ------------------------------------------------------------------------------
# STEP 1 - FAULT A: restore cost allocation (criterion C1)
# ------------------------------------------------------------------------------
#   List exactly what is wrong:
#
#     ./bin/costreport chargeback | sed -n '/violations/,$p'
#
#   Six resources are non-compliant, in three different ways:
#     - i-0a1b2c3d4e5f60002, vol-0aa11bb22cc33d01, dto-egress-prod-01
#         CostCenter tag missing entirely  -> spend cannot be attributed at all
#     - i-0a1b2c3d4e5f60003  CostCenter "CC2002"   -> missing the hyphen, fails ^CC-[0-9]{4}$
#     - i-0a1b2c3d4e5f60005  CostCenter "cc-3003 " -> wrong case + trailing space;
#         tag keys and values in AWS are CASE SENSITIVE, so "cc-3003" and
#         "CC-3003" are two different cost allocation values in Cost Explorer
#     - i-0a1b2c3d4e5f60006  Owner tag missing     -> required by the policy
#
#   Recover the correct owners from the resources that are still tagged: the
#   two m6i instances and the 2000 GB volume and the egress line belong to the
#   same prod platform stack (CC-1001, platform@example.internal); the
#   c6i.2xlarge prod instance sits beside the other CC-2002 data resources; the
#   t3.medium and the Spot batch node are the CC-3003 sandbox.
#
#   Apply the fix (idempotent - rerunning it changes nothing):
#
#     python3 - <<'PY'
#     import csv, os
#     root = os.environ.get("LAB_ROOT", "/opt/finops-lab")
#     path = os.path.join(root, "inventory.csv")
#     fixes = {
#         "i-0a1b2c3d4e5f60002": ("CC-1001", "prod", "platform@example.internal"),
#         "i-0a1b2c3d4e5f60003": ("CC-2002", "prod", "data@example.internal"),
#         "i-0a1b2c3d4e5f60005": ("CC-3003", "dev",  "sandbox@example.internal"),
#         "i-0a1b2c3d4e5f60006": ("CC-3003", "dev",  "sandbox@example.internal"),
#         "vol-0aa11bb22cc33d01": ("CC-1001", "prod", "platform@example.internal"),
#         "dto-egress-prod-01":   ("CC-1001", "prod", "platform@example.internal"),
#     }
#     with open(path, newline="", encoding="utf-8") as fh:
#         reader = csv.DictReader(fh)
#         fields = reader.fieldnames
#         rows = list(reader)
#     for r in rows:
#         # normalise every row: strip whitespace, then apply the known-good tags
#         for k in ("tag_CostCenter", "tag_Environment", "tag_Owner"):
#             r[k] = (r[k] or "").strip()
#         if r["resource_id"] in fixes:
#             r["tag_CostCenter"], r["tag_Environment"], r["tag_Owner"] = fixes[r["resource_id"]]
#     with open(path, "w", newline="", encoding="utf-8") as fh:
#         w = csv.DictWriter(fh, fieldnames=fields)
#         w.writeheader()
#         w.writerows(rows)
#     print("inventory.csv normalised and retagged")
#     PY
#
#     ./bin/costreport chargeback
#
#   Expected: 0 policy violations, UNALLOCATED disappears from the table, and
#   the three cost centres again sum to 100% of billed spend.
#
#   WHAT THIS IS IN AWS
#     Tags are key/value metadata on resources. To appear in Cost Explorer, the
#     AWS Cost and Usage Report or a budget, a tag key must additionally be
#     ACTIVATED as a cost allocation tag in the Billing console
#     (https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html).
#     Activation is not retroactive: spend billed before activation stays
#     unallocated forever, which is why an untagged month is money you can never
#     charge back. Prevent recurrence with Tag Policies in AWS Organizations, an
#     AWS Config 'required-tags' rule, and one AWS Budget per cost centre.
#
# ------------------------------------------------------------------------------
# STEP 2 - FAULT B: restore the commitment rate model (criterion C2)
# ------------------------------------------------------------------------------
#   Confirm what the tool is missing:
#
#     ./bin/costreport monthly | tail -20
#     python3 -c "import json;print(json.load(open('pricing.json'))['commitment_factor'])"
#     cat docs/rate_card.csv
#
#   pricing.json only knows "OnDemand": 1.0, so every Savings Plan, Reserved
#   Instance and Spot resource silently falls back to list price. The signed
#   rate card is the source of truth - rebuild the map FROM the card so the two
#   can never drift again:
#
#     python3 - <<'PY'
#     import csv, json, os
#     root = os.environ.get("LAB_ROOT", "/opt/finops-lab")
#     with open(os.path.join(root, "docs/rate_card.csv"), newline="", encoding="utf-8") as fh:
#         card = {r["purchase_option"]: float(r["effective_factor"]) for r in csv.DictReader(fh)}
#     p = os.path.join(root, "pricing.json")
#     with open(p, encoding="utf-8") as fh:
#         pricing = json.load(fh)
#     pricing["commitment_factor"] = card
#     with open(p, "w", encoding="utf-8") as fh:
#         json.dump(pricing, fh, indent=2); fh.write("\n")
#     print("commitment_factor rebuilt from the rate card:", card)
#     PY
#
#     ./bin/costreport monthly
#
#   Expected after the fix:
#     On-Demand-equivalent spend   $1,413.05 / month
#     Billed spend                 $1,162.65 / month   (17.7% saved overall,
#                                                       31.1% on EC2 alone)
#     EC2 commitment coverage      65.7%
#     EC2 blended rate             $0.1214/hour over 4,560 instance-hours
#                                  (list rate would be $0.1763/hour)
#     No "no commitment factor" warnings.
#
#   WHAT THIS IS IN AWS
#     On-Demand: no commitment, highest per-second rate, ideal for spiky or
#       unknown demand.
#     Savings Plans: commit to a $/hour of compute spend for 1 or 3 years and
#       receive up to ~72% off; Compute Savings Plans stay valid across instance
#       family, size, region, and even across EC2, Fargate and Lambda.
#     Reserved Instances: commit to a specific instance configuration for 1 or 3
#       years, up to ~72% off, with No / Partial / All Upfront payment options -
#       more upfront means a deeper discount.
#     Spot Instances: spare EC2 capacity at up to ~90% off, reclaimed with a
#       2-minute interruption notice - correct for batch, CI, stateless and
#       fault-tolerant work, never for a stateful single-node database.
#     Two different metrics, and the exam blurs them: COVERAGE is how much of
#       your usage a commitment applies to; UTILISATION is how much of the
#       commitment you actually consumed. High coverage with low utilisation
#       means you over-committed and are paying for hours you never used.
#
# ------------------------------------------------------------------------------
# STEP 3 - FAULT C: rebuild an honest TCO baseline (criterion C3)
# ------------------------------------------------------------------------------
#   See the gap between the model and the invoices:
#
#     cat docs/datacenter_invoices.csv
#     cat docs/asset_policy.json
#     python3 -c "import json;b=json.load(open('onprem_baseline.json'));print(b['amortization_years'], b['opex_annual_usd'])"
#
#   The model kept the three purchase orders (44,000 USD of CapEx) and dropped
#   every operating cost: power, cooling, colocation rack space, transit
#   bandwidth, hardware support contracts, sysadmin labour and the backup/DR
#   site - 28,800 USD per year that the company is demonstrably paying. It also
#   stretched depreciation to 5 years while finance refreshes hardware every 36
#   months, understating the annual capital charge by a further 40%.
#
#     python3 - <<'PY'
#     import csv, json, os
#     root = os.environ.get("LAB_ROOT", "/opt/finops-lab")
#     with open(os.path.join(root, "docs/datacenter_invoices.csv"), newline="", encoding="utf-8") as fh:
#         inv = list(csv.DictReader(fh))
#     capex = {r["line_item"]: float(r["amount_usd"]) for r in inv if r["kind"] == "capex"}
#     opex  = {r["line_item"]: float(r["amount_usd"]) for r in inv if r["kind"] == "opex"}
#     policy = json.load(open(os.path.join(root, "docs/asset_policy.json"), encoding="utf-8"))
#     p = os.path.join(root, "onprem_baseline.json")
#     with open(p, encoding="utf-8") as fh:
#         base = json.load(fh)
#     base["capex_usd"] = capex
#     base["opex_annual_usd"] = opex
#     base["amortization_years"] = policy["hardware_refresh_months"] / 12
#     with open(p, "w", encoding="utf-8") as fh:
#         json.dump(base, fh, indent=2); fh.write("\n")
#     print("baseline restored:", len(capex), "capex +", len(opex), "opex line items,",
#           base["amortization_years"], "year amortisation")
#     PY
#
#     ./bin/costreport tco
#
#   Expected after the fix:
#     CapEx 44,000 USD amortised over 3 years    ->  14,666.67 USD/year
#     OpEx                                       ->  28,800.00 USD/year
#     On-premises annual run rate                ->  43,466.67 USD/year
#     AWS annual run rate (1,162.65 x 12)        ->  13,951.85 USD/year
#     3 years: on-premises 130,400.00 vs AWS 41,855.56
#     VERDICT: AWS is cheaper by 88,544.44 USD over 3 years (67.9%).
#
#   Before the fix the same tool concluded the opposite (26,400.00 vs 41,855.56,
#   "on-premises cheaper by 36.9%") purely because two categories of real money
#   were missing from one side of the comparison. That is the single most common
#   way a migration business case is wrong, and it is exactly what task
#   statement 1.4 is testing.
#
#   WHAT THIS IS IN AWS
#     CapEx is money spent up front on assets you own and must depreciate; OpEx
#     is money spent on consumption you can stop. A TCO comparison must put the
#     FULL on-premises cost - facilities, power, cooling, network, licences,
#     support, staff, spare capacity for peak, and the DR site you would need
#     but probably do not have - against the AWS bill, over the same horizon and
#     for the same delivered capacity. Cloud economics adds three effects the
#     data centre cannot reproduce: economies of scale (AWS aggregates demand,
#     so unit prices fall over time), the elimination of capacity guessing (you
#     no longer buy for a peak that arrives twice a year), and the ability to
#     stop paying by turning things off. Model the AWS side with the AWS Pricing
#     Calculator (https://calculator.aws/) before committing, then track reality
#     with Cost Explorer, alert with AWS Budgets, and right-size continuously
#     with AWS Compute Optimizer.
#
# ------------------------------------------------------------------------------
# STEP 4 - Verify
# ------------------------------------------------------------------------------
#   ./bin/costreport check     # or:  <this-script> verify
#
#   Expected:
#     PASS  C1 cost allocation: 0 policy violations, 0.0% unallocated
#     PASS  C2 rate model: pricing.json matches docs/rate_card.csv
#     PASS  C3 TCO baseline: complete and amortised over the real refresh cycle
#     RESULT: all criteria met. The cost model is trustworthy again.
#
#   And the regression check against the archived export:
#     diff <(./bin/costreport all) docs/last_month_cost_explorer_export.txt
#   should report no differences in the numbers.
#
# ------------------------------------------------------------------------------
# STEP 5 - Exam takeaways mapped to CLF-C02 task statement 1.4
# ------------------------------------------------------------------------------
#   - Fixed cost vs variable cost / CapEx vs OpEx ................ STEP 3
#   - What belongs in a Total Cost of Ownership .................. STEP 3
#   - Economies of scale, no capacity guessing, stop paying ...... STEP 3
#   - On-Demand vs Savings Plans vs Reserved vs Spot ............. STEP 2
#   - Commitment coverage vs commitment utilisation .............. STEP 2
#   - Cost allocation tags, activation, chargeback / showback .... STEP 1
#   - Right-sizing and the value of turning resources off ........ docs/EXAM_NOTES.md
#   - Tooling: Pricing Calculator, Cost Explorer, Budgets, CUR,
#     Compute Optimizer, Cost Anomaly Detection ................... docs/EXAM_NOTES.md
#
#   Exam-style trap to remember: a question that offers you a cheaper monthly
#   figure for on-premises is almost always omitting power, cooling, space,
#   support or staff. If the answer choice compares a hardware invoice with an
#   AWS bill, it is comparing CapEx with TCO, and it is wrong.
#
#   Prices in this lab are an illustrative snapshot for training and will drift.
#   Authoritative pricing, always: https://calculator.aws/ and the per-service
#   pricing pages under https://aws.amazon.com/pricing/
# ==============================================================================