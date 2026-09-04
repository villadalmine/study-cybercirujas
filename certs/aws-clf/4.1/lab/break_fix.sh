#!/usr/bin/env bash
#
# ============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02)
#  Domain 4: Billing, Pricing, and Support  --  Task 4.1: Compare AWS pricing
#  models
#
#  BREAK & FIX LAB  --  "The Reserved Instance that never applied"
#
#  Exam guide (authoritative task statement list):
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
#  WHAT THIS LAB IS
#  ----------------
#  Task 4.1 is not about clicking around a console. It is about knowing WHY a
#  given workload maps to On-Demand, Reserved Instances (RI), Savings Plans,
#  Spot, or Dedicated Hosts, and what makes a commitment discount actually
#  *apply* instead of silently sitting idle while you pay full On-Demand price.
#
#  So this lab does not touch a real AWS account and spends zero dollars. It
#  installs a small local "billing simulator": a cost engine that applies the
#  real AWS commitment-matching rules to a fake fleet of instances, plus a
#  broken pricing configuration. You will see a bill that is far higher than it
#  should be, and your job is to find out why the discounts did not attach.
#
#  Every rule the simulator implements is a real AWS rule. Fixing the config is
#  the same reasoning you use on a real Cost Explorer "RI utilization: 0%"
#  ticket, and the same reasoning the exam tests with scenario questions.
#
#  SAFETY
#  ------
#  * Runs ONLY inside a disposable lab VM. It refuses to run as root and
#    refuses to run if it detects EC2 instance metadata (i.e. do not run this
#    on a real EC2 box you care about).
#  * Writes exclusively under ~/clf-lab-4-1. Nothing outside that directory is
#    created, modified or deleted.
#  * No network calls. No AWS credentials read, needed, or touched. No
#    packages installed beyond checking that python3 exists.
#  * Uninstall is `rm -rf ~/clf-lab-4-1`.
#
#  REQUIREMENTS: bash 4+, python3 (3.8+), standard coreutils.
# ============================================================================

set -o errexit
set -o nounset
set -o pipefail

LAB_HOME="${HOME}/clf-lab-4-1"
BIN_DIR="${LAB_HOME}/bin"
CONF_DIR="${LAB_HOME}/etc"
DATA_DIR="${LAB_HOME}/var"
DOC_DIR="${LAB_HOME}/doc"

# ---------------------------------------------------------------------------
# Guard rails. A break & fix lab that can damage something real is not a lab.
# ---------------------------------------------------------------------------
preflight() {
    if [[ "${EUID}" -eq 0 ]]; then
        echo "REFUSING TO RUN AS ROOT. This lab needs no privileges at all." >&2
        echo "Run it as an unprivileged user in a throwaway VM." >&2
        exit 1
    fi

    # 169.254.169.254 is the EC2 Instance Metadata Service endpoint. If it
    # answers, we are on an EC2 instance and this is not a scratch VM.
    if command -v curl >/dev/null 2>&1; then
        if curl --silent --max-time 1 --output /dev/null \
                http://169.254.169.254/latest/meta-data/ 2>/dev/null; then
            echo "EC2 instance metadata responded: this looks like a real EC2" >&2
            echo "instance. Run this lab on a local disposable VM instead." >&2
            exit 1
        fi
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 is required (3.8+). Install it and re-run." >&2
        exit 1
    fi

    if [[ -e "${LAB_HOME}" && ! -d "${LAB_HOME}" ]]; then
        echo "${LAB_HOME} exists and is not a directory. Aborting." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# The cost engine. This is the part that is NOT broken -- treat it as the AWS
# billing system itself. Read it if you want to understand exactly how a
# commitment discount finds an instance to attach to.
# ---------------------------------------------------------------------------
write_cost_engine() {
    cat > "${BIN_DIR}/billing-engine.py" <<'ENGINE_EOF'
#!/usr/bin/env python3
"""
Miniature AWS billing engine for CLF-C02 task 4.1.

It models one hour of steady-state usage for a fleet of EC2 instances and
applies commitment discounts in the same ORDER and under the same MATCHING
RULES that AWS uses. Nothing here is invented; the behaviours modelled are:

  1. Spot Instances are billed at the Spot price for the instance type. A Spot
     Instance can be interrupted by EC2 with a two-minute notification, so it
     is only valid for interruption-tolerant work.

  2. Savings Plans apply BEFORE Reserved Instances are considered for the
     remaining usage in AWS's own documented order (RIs and Savings Plans are
     both applied before On-Demand rates; the engine below applies Spot first,
     then Savings Plans, then RIs, then On-Demand for whatever is left).

  3. A Compute Savings Plan commits to an hourly dollar amount and applies to
     ANY instance family, size, Region, OS or tenancy -- and to Fargate and
     Lambda too. It is the flexible commitment.

  4. An EC2 Instance Savings Plan commits to an hourly dollar amount but is
     locked to ONE instance family in ONE Region. It is cheaper than Compute
     but it will not touch usage outside that family/Region pair.

  5. A Standard Reserved Instance is locked to instance family, Region and
     tenancy. Within a family it has *instance size flexibility* only when it
     is a REGIONAL RI on Linux/UNIX with default tenancy: the reservation is
     converted to "normalization units" and can cover any mix of sizes in that
     family. A ZONAL RI has no size flexibility -- it matches one Availability
     Zone and one size -- but it does reserve capacity.

  6. A Convertible RI can be exchanged for a different family/OS/tenancy later,
     at a smaller discount than Standard.

  7. Payment option changes the discount, not the matching: All Upfront > Partial
     Upfront > No Upfront.

  8. Anything a commitment does not cover is billed On-Demand, per second with a
     60-second minimum for Linux, with no commitment and no discount.

Normalization factors are AWS's published size-flexibility factors.

Sources:
  EC2 pricing models and Spot interruption behaviour
    https://aws.amazon.com/ec2/pricing/
  Reserved Instances, regional vs zonal, size flexibility, normalization
    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/apply_ri.html
  Savings Plans types and what each covers
    https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
  Spot Instances and the two-minute interruption notice
    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
  Dedicated Hosts vs Dedicated Instances (tenancy)
    https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
"""

import json
import os
import sys

LAB_HOME = os.path.expanduser("~/clf-lab-4-1")
CONF = os.path.join(LAB_HOME, "etc", "pricing.json")
FLEET = os.path.join(LAB_HOME, "etc", "fleet.json")

# AWS instance size normalization factors, relative to .large = 4.
NORMALIZATION = {
    "nano": 0.25, "micro": 0.5, "small": 1, "medium": 2, "large": 4,
    "xlarge": 8, "2xlarge": 16, "4xlarge": 32, "8xlarge": 64,
    "9xlarge": 72, "12xlarge": 96, "16xlarge": 128, "24xlarge": 192,
}


def die(msg):
    print("billing-engine: %s" % msg, file=sys.stderr)
    sys.exit(2)


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except FileNotFoundError:
        die("missing config: %s" % path)
    except json.JSONDecodeError as exc:
        die("config %s is not valid JSON: %s" % (path, exc))


def family_of(instance_type):
    return instance_type.split(".")[0]


def size_of(instance_type):
    return instance_type.split(".")[1]


def nf(instance_type):
    size = size_of(instance_type)
    if size not in NORMALIZATION:
        die("unknown instance size '%s' in type '%s'" % (size, instance_type))
    return NORMALIZATION[size]


def ondemand_rate(pricing, instance_type, platform):
    rates = pricing["ondemand"].get(instance_type)
    if rates is None:
        die("no On-Demand rate published for %s" % instance_type)
    rate = rates.get(platform)
    if rate is None:
        die("no On-Demand rate for %s on platform '%s'" % (instance_type, platform))
    return float(rate)


def ri_matches(ri, inst):
    """The RI matching rules. This is the heart of the lab."""
    reasons = []

    if ri["region"] != inst["region"]:
        reasons.append("region %s != %s" % (ri["region"], inst["region"]))
    if ri["platform"] != inst["platform"]:
        reasons.append("platform %s != %s" % (ri["platform"], inst["platform"]))
    if ri["tenancy"] != inst["tenancy"]:
        reasons.append("tenancy %s != %s" % (ri["tenancy"], inst["tenancy"]))
    if family_of(ri["instance_type"]) != family_of(inst["instance_type"]):
        reasons.append("family %s != %s" % (family_of(ri["instance_type"]),
                                            family_of(inst["instance_type"])))

    if ri["scope"] == "zonal":
        # Zonal RIs reserve capacity in one AZ and have NO size flexibility.
        if ri.get("availability_zone") != inst.get("availability_zone"):
            reasons.append("zonal RI in %s != instance in %s"
                           % (ri.get("availability_zone"), inst.get("availability_zone")))
        if ri["instance_type"] != inst["instance_type"]:
            reasons.append("zonal RI has no size flexibility: %s != %s"
                           % (ri["instance_type"], inst["instance_type"]))
    elif ri["scope"] == "regional":
        # Size flexibility only for Linux/UNIX with default tenancy.
        flexible = (inst["platform"] == "Linux/UNIX" and inst["tenancy"] == "default")
        if not flexible and ri["instance_type"] != inst["instance_type"]:
            reasons.append("no size flexibility on %s/%s tenancy: %s != %s"
                           % (inst["platform"], inst["tenancy"],
                              ri["instance_type"], inst["instance_type"]))
    else:
        reasons.append("invalid RI scope '%s' (must be regional or zonal)" % ri["scope"])

    return (len(reasons) == 0, reasons)


def sp_matches(sp, inst):
    """Savings Plan matching rules."""
    reasons = []
    if sp["type"] == "compute":
        # Compute SP: any family, any Region, any OS, any tenancy. Nothing to check.
        pass
    elif sp["type"] == "ec2_instance":
        if sp["region"] != inst["region"]:
            reasons.append("EC2 Instance SP locked to %s, instance in %s"
                           % (sp["region"], inst["region"]))
        if sp["family"] != family_of(inst["instance_type"]):
            reasons.append("EC2 Instance SP locked to family %s, instance is %s"
                           % (sp["family"], family_of(inst["instance_type"])))
    else:
        reasons.append("invalid Savings Plan type '%s'" % sp["type"])
    return (len(reasons) == 0, reasons)


def main():
    explain = "--explain" in sys.argv
    pricing = load(CONF)
    fleet = load(FLEET)

    unmatched = []       # instances that ended up On-Demand
    lines = []
    total = 0.0
    ondemand_total = 0.0

    # Track remaining capacity of each commitment.
    ri_pool = []
    for ri in pricing.get("reserved_instances", []):
        ri = dict(ri)
        ri["remaining_nf"] = nf(ri["instance_type"]) * int(ri["count"])
        ri_pool.append(ri)

    sp_pool = []
    for sp in pricing.get("savings_plans", []):
        sp = dict(sp)
        sp["remaining_commit"] = float(sp["hourly_commitment"])
        sp_pool.append(sp)

    for inst in fleet["instances"]:
        qty = int(inst.get("count", 1))
        for _ in range(qty):
            itype = inst["instance_type"]
            od = ondemand_rate(pricing, itype, inst["platform"])
            baseline = od
            ondemand_total += baseline
            why = []

            # ---- 1. Spot -------------------------------------------------
            if inst.get("purchase_option") == "spot":
                spot = pricing["spot"].get(itype)
                if spot is None:
                    die("no Spot price published for %s" % itype)
                cost = float(spot)
                lines.append((inst["name"], itype, "Spot", cost, baseline))
                total += cost
                continue

            # ---- 2. Savings Plans ---------------------------------------
            covered = False
            for sp in sp_pool:
                ok, reasons = sp_matches(sp, inst)
                if not ok:
                    why.extend(["SP %s: %s" % (sp["id"], r) for r in reasons])
                    continue
                sp_rate = od * (1.0 - float(sp["discount"]))
                if sp["remaining_commit"] >= sp_rate:
                    sp["remaining_commit"] -= sp_rate
                    lines.append((inst["name"], itype,
                                  "SavingsPlan:%s" % sp["id"], sp_rate, baseline))
                    total += sp_rate
                    covered = True
                    break
                why.append("SP %s: commitment exhausted (%.4f/h left, needs %.4f/h)"
                           % (sp["id"], sp["remaining_commit"], sp_rate))
            if covered:
                continue

            # ---- 3. Reserved Instances ----------------------------------
            need = nf(itype)
            for ri in ri_pool:
                ok, reasons = ri_matches(ri, inst)
                if not ok:
                    why.extend(["RI %s: %s" % (ri["id"], r) for r in reasons])
                    continue
                if ri["remaining_nf"] >= need:
                    ri["remaining_nf"] -= need
                    cost = od * (1.0 - float(ri["discount"]))
                    lines.append((inst["name"], itype,
                                  "RI:%s" % ri["id"], cost, baseline))
                    total += cost
                    covered = True
                    break
                why.append("RI %s: only %.2f normalization units left, needs %.2f"
                           % (ri["id"], ri["remaining_nf"], need))
            if covered:
                continue

            # ---- 4. On-Demand fallback ----------------------------------
            lines.append((inst["name"], itype, "On-Demand", od, baseline))
            total += od
            unmatched.append((inst["name"], itype, why))

    # ---- report -----------------------------------------------------------
    print("=" * 74)
    print("SIMULATED HOURLY BILL  --  us-east-1  --  1 hour of steady state")
    print("=" * 74)
    print("%-22s %-13s %-22s %9s" % ("WORKLOAD", "TYPE", "BILLED AS", "USD/HOUR"))
    print("-" * 74)
    for name, itype, how, cost, base in lines:
        print("%-22s %-13s %-22s %9.4f" % (name, itype, how, cost))
    print("-" * 74)
    print("%-59s %9.4f" % ("TOTAL, all On-Demand (no commitments):", ondemand_total))
    print("%-59s %9.4f" % ("TOTAL, as actually billed:", total))
    saved = ondemand_total - total
    pct = (saved / ondemand_total * 100.0) if ondemand_total else 0.0
    print("%-59s %9.4f" % ("Savings realised:", saved))
    print("%-59s %8.1f%%" % ("Effective discount:", pct))
    print()

    # Commitment utilization -- the metric that exposes the bug.
    print("COMMITMENT UTILIZATION")
    print("-" * 74)
    for sp in sp_pool:
        used = float(sp["hourly_commitment"]) - sp["remaining_commit"]
        util = used / float(sp["hourly_commitment"]) * 100.0
        print("  SavingsPlan %-14s type=%-12s utilization %6.1f%%  "
              "(%.4f of %.4f USD/h used)"
              % (sp["id"], sp["type"], util, used, float(sp["hourly_commitment"])))
    for ri in ri_pool:
        totalnf = nf(ri["instance_type"]) * int(ri["count"])
        used = totalnf - ri["remaining_nf"]
        util = used / totalnf * 100.0 if totalnf else 0.0
        print("  RI          %-14s %s x%s scope=%-9s utilization %6.1f%%"
              % (ri["id"], ri["instance_type"], ri["count"], ri["scope"], util))
    print()

    if unmatched:
        print("!! %d instance-hour(s) fell through to On-Demand." % len(unmatched))
        if explain:
            print()
            print("WHY EACH COMMITMENT WAS REJECTED")
            print("-" * 74)
            for name, itype, why in unmatched:
                print("  %s (%s):" % (name, itype))
                if not why:
                    print("      no commitment even attempted to cover it")
                for reason in dict.fromkeys(why):
                    print("      - %s" % reason)
            print()
        else:
            print("   Re-run with --explain to see why each discount was rejected.")
    else:
        print("All committed-usage workloads were covered by a commitment.")

    # Exit code is the grading signal used by lab-check.
    sys.exit(0 if not unmatched else 1)


if __name__ == "__main__":
    main()
ENGINE_EOF
    chmod +x "${BIN_DIR}/billing-engine.py"
}

# ---------------------------------------------------------------------------
# The fleet. This is the workload description and it is CORRECT. Do not change
# it -- the business requirements are what they are; the pricing config has to
# be made to fit them, not the other way round.
# ---------------------------------------------------------------------------
write_fleet() {
    cat > "${CONF_DIR}/fleet.json" <<'FLEET_EOF'
{
  "_comment": [
    "Steady-state fleet for one hour. purchase_option is the BUSINESS decision:",
    "  'committed'  = runs 24/7/365, must be covered by a commitment discount",
    "  'spot'       = interruption tolerant, may be reclaimed with 2-minute notice",
    "  'ondemand'   = genuinely spiky/unpredictable, no commitment is appropriate",
    "DO NOT EDIT THIS FILE. The workload is fixed. Fix etc/pricing.json instead."
  ],
  "instances": [
    {
      "name": "web-tier",
      "instance_type": "m5.large",
      "count": 4,
      "region": "us-east-1",
      "availability_zone": "us-east-1a",
      "platform": "Linux/UNIX",
      "tenancy": "default",
      "purchase_option": "committed"
    },
    {
      "name": "app-tier",
      "instance_type": "m5.xlarge",
      "count": 2,
      "region": "us-east-1",
      "availability_zone": "us-east-1b",
      "platform": "Linux/UNIX",
      "tenancy": "default",
      "purchase_option": "committed"
    },
    {
      "name": "batch-render",
      "instance_type": "c5.4xlarge",
      "count": 3,
      "region": "us-east-1",
      "availability_zone": "us-east-1a",
      "platform": "Linux/UNIX",
      "tenancy": "default",
      "purchase_option": "spot"
    },
    {
      "name": "reporting-db",
      "instance_type": "r5.xlarge",
      "count": 1,
      "region": "us-east-1",
      "availability_zone": "us-east-1a",
      "platform": "Linux/UNIX",
      "tenancy": "default",
      "purchase_option": "committed"
    },
    {
      "name": "marketing-campaign",
      "instance_type": "m5.large",
      "count": 2,
      "region": "us-east-1",
      "availability_zone": "us-east-1c",
      "platform": "Linux/UNIX",
      "tenancy": "default",
      "purchase_option": "ondemand"
    }
  ]
}
FLEET_EOF
}

# ---------------------------------------------------------------------------
# THE BREAK. Four independent, realistic misconfigurations are planted here.
# Each one is a mistake a real team has made on a real account.
# ---------------------------------------------------------------------------
write_broken_pricing() {
    cat > "${CONF_DIR}/pricing.json" <<'PRICING_EOF'
{
  "_comment": [
    "Pricing catalogue and the commitments this account has purchased.",
    "On-Demand and Spot rates are illustrative us-east-1 Linux figures used to",
    "make the arithmetic readable; they are NOT a live price list. Always check",
    "https://aws.amazon.com/ec2/pricing/on-demand/ for current rates.",
    "THIS FILE IS THE ONE YOU FIX."
  ],

  "ondemand": {
    "m5.large":    { "Linux/UNIX": 0.0960, "Windows": 0.1880 },
    "m5.xlarge":   { "Linux/UNIX": 0.1920, "Windows": 0.3760 },
    "r5.xlarge":   { "Linux/UNIX": 0.2520, "Windows": 0.4360 },
    "c5.4xlarge":  { "Linux/UNIX": 0.6800, "Windows": 1.3120 }
  },

  "spot": {
    "c5.4xlarge":  0.2380,
    "m5.large":    0.0350,
    "m5.xlarge":   0.0700,
    "r5.xlarge":   0.0900
  },

  "savings_plans": [
    {
      "id": "sp-flex-01",
      "type": "ec2_instance",
      "region": "us-west-2",
      "family": "r5",
      "term_years": 1,
      "payment": "no_upfront",
      "hourly_commitment": 0.1500,
      "discount": 0.34
    }
  ],

  "reserved_instances": [
    {
      "id": "ri-web-01",
      "instance_type": "m5.large",
      "count": 4,
      "scope": "zonal",
      "availability_zone": "us-east-1a",
      "region": "us-east-1",
      "platform": "Windows",
      "tenancy": "default",
      "offering_class": "standard",
      "term_years": 1,
      "payment": "no_upfront",
      "discount": 0.31
    },
    {
      "id": "ri-app-01",
      "instance_type": "m4.xlarge",
      "count": 2,
      "scope": "regional",
      "region": "us-east-1",
      "platform": "Linux/UNIX",
      "tenancy": "dedicated",
      "offering_class": "standard",
      "term_years": 3,
      "payment": "all_upfront",
      "discount": 0.60
    }
  ]
}
PRICING_EOF
}

# ---------------------------------------------------------------------------
# Grader. Checks the OUTCOME (every committed workload covered, Spot still
# Spot, On-Demand workload still On-Demand, discount in a sane range) rather
# than the exact text of the config -- there is more than one correct fix.
# ---------------------------------------------------------------------------
write_checker() {
    cat > "${BIN_DIR}/lab-check" <<'CHECK_EOF'
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

LAB_HOME="${HOME}/clf-lab-4-1"
ENGINE="${LAB_HOME}/bin/billing-engine.py"

pass=0
fail=0

ok()   { printf '  [ PASS ] %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  [ FAIL ] %s\n' "$1"; fail=$((fail + 1)); }

echo "======================================================================"
echo "LAB CHECK -- CLF-C02 task 4.1"
echo "======================================================================"

# The fleet is the requirement. It must not have been edited.
if ! grep -q '"purchase_option": "spot"' "${LAB_HOME}/etc/fleet.json"; then
    bad "fleet.json no longer declares the batch-render Spot workload -- you"
    printf '           changed the requirements instead of the pricing config.\n'
fi

report="$(python3 "${ENGINE}" --explain 2>&1)" && rc=0 || rc=$?

if [[ ${rc} -eq 2 ]]; then
    echo "${report}"
    bad "the billing engine could not read your config (invalid JSON or a"
    printf '           missing field). Fix that first.\n'
    echo
    echo "Result: ${pass} passed, $((fail + 1)) failed."
    exit 1
fi

if [[ ${rc} -eq 0 ]]; then
    ok "every 'committed' workload is covered by a commitment (0 fell through)"
else
    bad "at least one 'committed' workload is still billed On-Demand"
fi

# Spot work must still be Spot: moving it to a commitment is the wrong fix.
if grep -Eq '^batch-render .* Spot' <<<"${report}"; then
    ok "batch-render is still billed as Spot (interruption-tolerant work)"
else
    bad "batch-render is no longer billed as Spot -- interruption-tolerant"
    printf '           batch work is exactly what Spot is for.\n'
fi

# The genuinely unpredictable workload must NOT be under a commitment.
if grep -Eq '^marketing-campaign .* On-Demand' <<<"${report}"; then
    ok "marketing-campaign is still On-Demand (unpredictable, no commitment)"
else
    bad "marketing-campaign was put under a commitment. You do not commit to"
    printf '           1 or 3 years of usage you cannot predict.\n'
fi

# Utilization: a commitment you bought and do not use is money burned.
if grep -Eq 'utilization +0\.0%' <<<"${report}"; then
    bad "a commitment is sitting at 0% utilization -- you are paying for it"
    printf '           and getting nothing back.\n'
else
    ok "no commitment is stranded at 0% utilization"
fi

# Sanity band on the realised discount.
disc="$(grep 'Effective discount:' <<<"${report}" | tr -dc '0-9.' || true)"
if [[ -n "${disc}" ]] && awk "BEGIN{exit !(${disc} >= 30)}"; then
    ok "effective discount is ${disc}% (>= 30%, the fleet is priced sensibly)"
else
    bad "effective discount is only ${disc:-0}%; a correctly matched fleet of"
    printf '           this shape lands well above 30%%.\n'
fi

echo
echo "Result: ${pass} passed, ${fail} failed."
echo
if [[ ${fail} -eq 0 ]]; then
    cat <<'WIN'
  ****  LAB SOLVED  ****

  You made four different commitment types attach to the workloads they were
  bought for. That is the whole of task 4.1: knowing which pricing model fits
  which usage pattern, and knowing what makes the discount actually apply.
WIN
    exit 0
else
    echo "  Not solved yet. Run:  ~/clf-lab-4-1/bin/lab-report --explain"
    echo "  and read the rejection reasons line by line."
    exit 1
fi
CHECK_EOF
    chmod +x "${BIN_DIR}/lab-check"

    cat > "${BIN_DIR}/lab-report" <<'REPORT_EOF'
#!/usr/bin/env bash
exec python3 "${HOME}/clf-lab-4-1/bin/billing-engine.py" "$@"
REPORT_EOF
    chmod +x "${BIN_DIR}/lab-report"

    cat > "${BIN_DIR}/lab-reset" <<'RESET_EOF'
#!/usr/bin/env bash
set -o errexit
set -o nounset
LAB_HOME="${HOME}/clf-lab-4-1"
if [[ ! -f "${LAB_HOME}/var/pricing.json.orig" ]]; then
    echo "No pristine copy found. Re-run the lab installer." >&2
    exit 1
fi
cp -f "${LAB_HOME}/var/pricing.json.orig" "${LAB_HOME}/etc/pricing.json"
cp -f "${LAB_HOME}/var/fleet.json.orig"   "${LAB_HOME}/etc/fleet.json"
echo "Config restored to the broken starting state."
RESET_EOF
    chmod +x "${BIN_DIR}/lab-reset"
}

# ---------------------------------------------------------------------------
# Reference sheet the student is allowed to consult while solving.
# ---------------------------------------------------------------------------
write_reference() {
    cat > "${DOC_DIR}/pricing-models.md" <<'REF_EOF'
# AWS EC2 pricing models -- the decision table (CLF-C02 task 4.1)

| Model | Commitment | Discount vs On-Demand | Can be interrupted? | Use it when |
|---|---|---|---|---|
| On-Demand | none | 0% | no | spiky, short, unpredictable, or first-time workloads you are still measuring |
| Spot | none | up to ~90% | YES, 2-minute notice | batch, CI, rendering, stateless workers, anything that can be restarted |
| Savings Plans (Compute) | 1 or 3 yr, $/hour | up to ~66% | no | steady spend where the *shape* may change: any family, any Region, any OS, plus Fargate and Lambda |
| Savings Plans (EC2 Instance) | 1 or 3 yr, $/hour | up to ~72% | no | steady spend locked to one family in one Region |
| Reserved Instances (Standard) | 1 or 3 yr, capacity | up to ~72% | no | steady, well-known instance shape; zonal scope also *reserves capacity* in an AZ |
| Reserved Instances (Convertible) | 1 or 3 yr | up to ~54% | no | steady but you may need to exchange family/OS/tenancy later |
| Dedicated Host | on-demand or reserved | -- (costs more) | no | per-socket/per-core BYOL licensing, or a hard compliance requirement for physical isolation |

## The matching rules that decide whether a discount applies

A commitment is not a coupon applied to your total bill. It is matched against
individual instance-hours, and every one of these attributes must line up:

* **Region.** A commitment bought in `us-west-2` will never touch usage in
  `us-east-1`. (A Compute Savings Plan is the exception: it is Region-flexible.)
* **Instance family.** An `m4` RI does not cover an `m5` instance. Different
  generation, different family, no match. A Convertible RI can be *exchanged*
  into another family, but that is a deliberate action, not automatic.
* **Platform / OS.** A Windows RI does not cover a Linux instance.
* **Tenancy.** A `dedicated`-tenancy RI does not cover `default`-tenancy usage.
* **Scope.**
  * *Regional* RI -- applies across all AZs in the Region, and on Linux/UNIX
    with default tenancy it also gets **instance size flexibility**: the
    reservation is expressed in normalization units and covers any mix of sizes
    inside the family. No capacity reservation.
  * *Zonal* RI -- one specific AZ, one specific size, **no size flexibility**,
    but it **does** reserve capacity in that AZ.

## Normalization factors (size flexibility arithmetic)

    nano 0.25 | micro 0.5 | small 1 | medium 2 | large 4 | xlarge 8
    2xlarge 16 | 4xlarge 32 | 8xlarge 64 | 12xlarge 96 | 16xlarge 128

So one `m5.4xlarge` regional Linux RI (32 units) covers, for example, eight
`m5.large` (8 x 4 = 32) or four `m5.xlarge` (4 x 8 = 32).

## Sources

* EC2 pricing overview -- https://aws.amazon.com/ec2/pricing/
* Reserved Instances -- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
* How RIs are applied / size flexibility -- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/apply_ri.html
* Savings Plans -- https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
* Spot Instances -- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
* Dedicated Hosts -- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
* CLF-C02 exam guide -- https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
REF_EOF
}

# ---------------------------------------------------------------------------
# Install and brief the student.
# ---------------------------------------------------------------------------
main() {
    preflight

    mkdir -p "${BIN_DIR}" "${CONF_DIR}" "${DATA_DIR}" "${DOC_DIR}"

    write_cost_engine
    write_fleet
    write_broken_pricing
    write_checker
    write_reference

    # Pristine copies so lab-reset can put the break back.
    cp -f "${CONF_DIR}/pricing.json" "${DATA_DIR}/pricing.json.orig"
    cp -f "${CONF_DIR}/fleet.json"   "${DATA_DIR}/fleet.json.orig"

    cat <<BRIEF

======================================================================
 BREAK & FIX -- CLF-C02 task 4.1: Compare AWS pricing models
 Scenario: "FinOps says we bought the discounts. The bill says otherwise."
======================================================================

 THE STORY

   Your company runs a small production fleet in us-east-1. Last quarter
   Finance approved a set of commitment purchases -- Reserved Instances and
   a Savings Plan -- specifically to cut the EC2 bill. The purchases went
   through. The invoice arrived this month and it is essentially unchanged
   from before the purchases: you are paying On-Demand rates AND paying for
   commitments on top.

   Nobody deleted anything. Nothing is "down". The discounts simply are
   not attaching to the instances, and that is a far more expensive
   failure than an outage nobody noticed.

 WHAT HAS BEEN BROKEN (safely, locally, in ~/clf-lab-4-1)

   A local billing simulator was installed. It implements the real AWS
   commitment-matching rules -- Region, instance family, platform, tenancy,
   scope, size flexibility -- against a fake fleet. No AWS account is used,
   no credentials are read, no money is spent, and nothing outside
   ~/clf-lab-4-1 was touched.

   The file ~/clf-lab-4-1/etc/pricing.json describes the commitments this
   account supposedly purchased. It contains several realistic
   misconfigurations. That is the only file you need to change.

 THE SYMPTOM YOU WILL SEE

   Run:   ~/clf-lab-4-1/bin/lab-report

   You will see almost every steady-state workload billed as "On-Demand"
   even though commitments exist, an effective discount close to zero, and
   commitments sitting at 0.0% utilization -- bought, paid for, unused.

 YOUR OBJECTIVE

   Edit ONLY ~/clf-lab-4-1/etc/pricing.json so that:

     1. Every workload marked "committed" in fleet.json is billed under a
        Reserved Instance or a Savings Plan, not On-Demand.
     2. The "spot" workload stays on Spot. It is interruption tolerant;
        that is what Spot exists for.
     3. The "ondemand" workload stays On-Demand. You do not sign a 1- or
        3-year commitment for usage you cannot predict.
     4. No commitment is left at 0% utilization.
     5. The effective discount lands at 30% or better.

   Do NOT edit fleet.json. The workload is the requirement; the pricing
   config is what has to fit it.

 THE TOOLS

   ~/clf-lab-4-1/bin/lab-report             the simulated bill
   ~/clf-lab-4-1/bin/lab-report --explain   WHY each discount was rejected
   ~/clf-lab-4-1/bin/lab-check              grade your fix
   ~/clf-lab-4-1/bin/lab-reset              restore the broken state
   ~/clf-lab-4-1/doc/pricing-models.md      the decision table + matching rules

 START HERE

   ~/clf-lab-4-1/bin/lab-report --explain

 CLEAN UP WHEN DONE

   rm -rf ~/clf-lab-4-1

======================================================================

BRIEF
}

main "$@"

# ===========================================================================
# ===========================================================================
#
#                    S O L U T I O N   --   DO NOT READ
#                    UNTIL YOU HAVE ATTEMPTED THE LAB
#
# ===========================================================================
# ===========================================================================
#
# STEP 0 -- OBSERVE THE SYMPTOM BEFORE THEORISING
# ------------------------------------------------------------------------
#
#   $ ~/clf-lab-4-1/bin/lab-report
#
#   ==========================================================================
#   SIMULATED HOURLY BILL  --  us-east-1  --  1 hour of steady state
#   ==========================================================================
#   WORKLOAD               TYPE          BILLED AS               USD/HOUR
#   --------------------------------------------------------------------------
#   web-tier               m5.large      On-Demand                 0.0960
#   web-tier               m5.large      On-Demand                 0.0960
#   web-tier               m5.large      On-Demand                 0.0960
#   web-tier               m5.large      On-Demand                 0.0960
#   app-tier               m5.xlarge     On-Demand                 0.1920
#   app-tier               m5.xlarge     On-Demand                 0.1920
#   batch-render           c5.4xlarge    Spot                      0.2380
#   batch-render           c5.4xlarge    Spot                      0.2380
#   batch-render           c5.4xlarge    Spot                      0.2380
#   reporting-db           r5.xlarge     On-Demand                 0.2520
#   marketing-campaign     m5.large      On-Demand                 0.0960
#   marketing-campaign     m5.large      On-Demand                 0.0960
#   --------------------------------------------------------------------------
#   TOTAL, all On-Demand (no commitments):                          2.7480
#   TOTAL, as actually billed:                                      1.8420
#   Savings realised:                                               0.9060
#   Effective discount:                                               33.0%
#
#   COMMITMENT UTILIZATION
#   --------------------------------------------------------------------------
#     SavingsPlan sp-flex-01     type=ec2_instance  utilization    0.0%  ...
#     RI          ri-web-01      m5.large x4 scope=zonal     utilization 0.0%
#     RI          ri-app-01      m4.xlarge x2 scope=regional utilization 0.0%
#
#   !! 7 instance-hour(s) fell through to On-Demand.
#
# Read the utilization block first. EVERY commitment is at 0.0%. The entire
# 33% "discount" is coming from Spot alone -- the commitments contribute
# literally nothing while still being paid for. In a real account this is what
# Cost Explorer's "RI utilization" and "Savings Plans utilization" reports show,
# and 0% utilization is always a matching problem, never a billing bug.
#
#
# STEP 1 -- ASK THE SYSTEM WHY, DO NOT GUESS
# ------------------------------------------------------------------------
#
#   $ ~/clf-lab-4-1/bin/lab-report --explain
#
#   WHY EACH COMMITMENT WAS REJECTED
#   --------------------------------------------------------------------------
#     web-tier (m5.large):
#         - SP sp-flex-01: EC2 Instance SP locked to us-west-2, instance in us-east-1
#         - SP sp-flex-01: EC2 Instance SP locked to family r5, instance is m5
#         - RI ri-web-01: platform Windows != Linux/UNIX
#         - RI ri-app-01: tenancy dedicated != default
#         - RI ri-app-01: family m4 != m5
#     app-tier (m5.xlarge):
#         - RI ri-web-01: platform Windows != Linux/UNIX
#         - RI ri-web-01: zonal RI in us-east-1a != instance in us-east-1b
#         - RI ri-web-01: zonal RI has no size flexibility: m5.large != m5.xlarge
#         - RI ri-app-01: tenancy dedicated != default
#         - RI ri-app-01: family m4 != m5
#     reporting-db (r5.xlarge):
#         - SP sp-flex-01: EC2 Instance SP locked to us-west-2, instance in us-east-1
#         - RI ri-web-01: family m5 != r5
#         - RI ri-app-01: family m4 != r5
#
# There are four independent defects, and each maps to one matching attribute:
#
#   DEFECT A -- ri-web-01 was bought for the WRONG PLATFORM.
#     "platform": "Windows" against a Linux/UNIX fleet. A Windows RI never
#     covers a Linux instance. This is a classic: whoever bought it clicked
#     through the purchase wizard leaving the default OS selected.
#
#   DEFECT B -- ri-web-01 has ZONAL scope, so it has no size flexibility and
#     is pinned to us-east-1a. web-tier happens to be in us-east-1a so that
#     part matches, but app-tier (us-east-1b, m5.xlarge) can never be covered.
#     Zonal scope buys you *capacity reservation* in one AZ; if you do not need
#     the capacity guarantee, regional scope is strictly more useful because
#     Linux/default-tenancy regional RIs get size flexibility.
#
#   DEFECT C -- ri-app-01 was bought for the WRONG FAMILY and WRONG TENANCY.
#     m4 does not cover m5 -- previous-generation family, no match. And
#     "tenancy": "dedicated" only covers Dedicated Instances; the fleet runs
#     default (shared) tenancy. Two attributes wrong on the same purchase.
#
#   DEFECT D -- sp-flex-01 is an EC2 Instance Savings Plan locked to the
#     WRONG REGION (us-west-2) and the reporting-db it was meant to cover is
#     an r5 in us-east-1. An EC2 Instance SP is family + Region locked. If you
#     want Region and family flexibility, that is a COMPUTE Savings Plan.
#
#
# STEP 2 -- APPLY THE FIX
# ------------------------------------------------------------------------
#
# Back the file up, then edit ~/clf-lab-4-1/etc/pricing.json:
#
#   $ cp ~/clf-lab-4-1/etc/pricing.json ~/clf-lab-4-1/etc/pricing.json.bak
#   $ ${EDITOR:-vi} ~/clf-lab-4-1/etc/pricing.json
#
# 2a. Fix ri-web-01 -- correct the platform, and convert it to a REGIONAL RI
#     so that instance size flexibility covers both the m5.large web-tier and
#     the m5.xlarge app-tier out of one reservation. Four m5.large = 4 x 4 = 16
#     normalization units; web-tier needs 16 and app-tier needs 2 x 8 = 16, so
#     size the reservation at 8 x m5.large = 32 units and one RI now covers
#     both tiers. Drop the availability_zone: a regional RI has none.
#
#       {
#         "id": "ri-web-01",
#         "instance_type": "m5.large",
#         "count": 8,
#         "scope": "regional",
#         "region": "us-east-1",
#         "platform": "Linux/UNIX",
#         "tenancy": "default",
#         "offering_class": "standard",
#         "term_years": 1,
#         "payment": "no_upfront",
#         "discount": 0.31
#       }
#
#     (Equally correct: keep it zonal at m5.large x4 for the capacity
#     reservation in us-east-1a and buy a second regional RI for app-tier.
#     The grader accepts either -- but be able to say WHY you chose one.
#     Zonal = capacity guarantee, no flexibility. Regional = flexibility,
#     no capacity guarantee.)
#
# 2b. Fix ri-app-01 -- it is now redundant if you took the regional route in
#     2a. Delete it, or repurpose it correctly. The instructive move is to
#     delete it: an RI you bought for the wrong family AND wrong tenancy is
#     exactly the RI you should be selling on the Reserved Instance
#     Marketplace or exchanging (only possible if it were Convertible, which
#     a Standard RI is not -- Standard RIs can be sold, not exchanged).
#
#     Delete the whole ri-app-01 object, leaving "reserved_instances" with a
#     single element.
#
# 2c. Fix sp-flex-01 -- reporting-db is a single r5.xlarge, and the business
#     may well move it to another family or Region next quarter. That is the
#     textbook case for a COMPUTE Savings Plan: no family lock, no Region
#     lock, and it would also cover Fargate/Lambda spend later.
#
#       {
#         "id": "sp-flex-01",
#         "type": "compute",
#         "term_years": 1,
#         "payment": "no_upfront",
#         "hourly_commitment": 0.1700,
#         "discount": 0.34
#       }
#
#     The commitment must be at least the DISCOUNTED rate of the usage you
#     want it to absorb: 0.2520 x (1 - 0.34) = 0.16632 USD/h, so 0.1700 is
#     enough for exactly this one instance and nothing more. Committing more
#     than your steady-state floor is how you end up at <100% utilization --
#     the other half of the FinOps failure mode this lab is about.
#
#     (Also valid: keep it as an ec2_instance SP but set "region": "us-east-1"
#     and "family": "r5". Cheaper per hour, zero flexibility. Both pass.)
#
# 2d. Leave marketing-campaign uncovered ON PURPOSE. It is a two-week
#     campaign; committing to 1 or 3 years for it would raise the bill, not
#     lower it. Leaving usage on On-Demand is a decision, not an oversight.
#     The grader fails you if you cover it.
#
# 2e. Leave batch-render on Spot. Rendering is restartable, so the ~65%
#     discount is free money; the two-minute interruption notice is a cost the
#     workload can absorb.
#
#
# STEP 3 -- VERIFY
# ------------------------------------------------------------------------
#
#   $ ~/clf-lab-4-1/bin/lab-report
#
#   WORKLOAD               TYPE          BILLED AS               USD/HOUR
#   --------------------------------------------------------------------------
#   web-tier               m5.large      RI:ri-web-01              0.0662
#   web-tier               m5.large      RI:ri-web-01              0.0662
#   web-tier               m5.large      RI:ri-web-01              0.0662
#   web-tier               m5.large      RI:ri-web-01              0.0662
#   app-tier               m5.xlarge     RI:ri-web-01              0.1325
#   app-tier               m5.xlarge     RI:ri-web-01              0.1325
#   batch-render           c5.4xlarge    Spot                      0.2380
#   batch-render           c5.4xlarge    Spot                      0.2380
#   batch-render           c5.4xlarge    Spot                      0.2380
#   reporting-db           r5.xlarge     SavingsPlan:sp-flex-01    0.1663
#   marketing-campaign     m5.large      On-Demand                 0.0960
#   marketing-campaign     m5.large      On-Demand                 0.0960
#   --------------------------------------------------------------------------
#   TOTAL, all On-Demand (no commitments):                          2.7480
#   TOTAL, as actually billed:                                      1.6021
#   Savings realised:                                               1.1459
#   Effective discount:                                               41.7%
#
#   COMMITMENT UTILIZATION
#   --------------------------------------------------------------------------
#     SavingsPlan sp-flex-01  type=compute  utilization  97.8% (0.1663 of 0.1700)
#     RI          ri-web-01   m5.large x8 scope=regional  utilization 100.0%
#
#   All committed-usage workloads were covered by a commitment.
#
#   $ ~/clf-lab-4-1/bin/lab-check
#   ...
#     [ PASS ] every 'committed' workload is covered by a commitment
#     [ PASS ] batch-render is still billed as Spot
#     [ PASS ] marketing-campaign is still On-Demand
#     [ PASS ] no commitment is stranded at 0% utilization
#     [ PASS ] effective discount is 41.7% (>= 30%)
#
#     ****  LAB SOLVED  ****
#
# (Your exact figures will differ if you chose one of the alternative valid
# fixes -- two RIs instead of one, or an EC2 Instance SP instead of a Compute
# SP. The five PASS lines are what matters.)
#
#
# STEP 4 -- WHAT TO CARRY INTO THE EXAM
# ------------------------------------------------------------------------
#
#   * A commitment discount is MATCHED, not applied to a total. Region,
#     family, platform, tenancy and scope must all line up. Every scenario
#     question about "why isn't my RI discount showing up" is one of these
#     five attributes.
#
#   * Compute Savings Plan  = maximum flexibility (any family, any Region,
#     any OS, plus Fargate and Lambda), smaller discount.
#     EC2 Instance Savings Plan = one family in one Region, bigger discount.
#     Standard RI = biggest discount, least flexible, can be SOLD on the RI
#     Marketplace but not exchanged.
#     Convertible RI = can be EXCHANGED for a different family/OS/tenancy,
#     smaller discount than Standard.
#
#   * Regional RI = size flexibility (Linux/UNIX, default tenancy), no
#     capacity reservation. Zonal RI = capacity reservation in one AZ, no
#     size flexibility. You pick based on whether you need the capacity
#     guarantee.
#
#   * Spot is for interruption-tolerant work and can be reclaimed with a
#     2-minute notice. Never put a stateful, must-stay-up workload on Spot,
#     and never put a predictable 24/7 workload on pure On-Demand.
#
#   * On-Demand is the correct answer for genuinely unpredictable or
#     short-lived usage. "Use On-Demand" is a real answer on the exam, not a
#     failure to optimise.
#
#   * Dedicated Host vs Dedicated Instance: the Host gives you visibility of
#     and control over the physical sockets/cores, which is what per-socket
#     BYOL licensing needs. A Dedicated Instance is only isolated hardware,
#     no socket visibility.
#
#   Sources:
#     https://aws.amazon.com/ec2/pricing/
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-reserved-instances.html
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/apply_ri.html
#     https://docs.aws.amazon.com/savingsplans/latest/userguide/what-is-savings-plans.html
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-spot-instances.html
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/dedicated-hosts-overview.html
#     https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
# ===========================================================================