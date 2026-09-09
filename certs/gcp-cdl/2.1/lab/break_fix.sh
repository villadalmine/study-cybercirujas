#!/usr/bin/env bash
#
# ============================================================================
#  Google Cloud Digital Leader (gcp-cdl) - exam version 2026-08-12
#  Section 2.1 - "Describe the intrinsic role that data plays in an
#                 organization's digital transformation" (exam weight: 6.0)
#
#  BREAK & FIX LAB - "The revenue that vanished"
#
#  Why a Cloud Digital Leader topic gets a hands-on lab
#  ----------------------------------------------------
#  Objective 2.1 is examined as concepts - data as a strategic asset, the data
#  value chain (generate -> collect -> process -> analyse -> activate), data
#  silos, data quality, data governance, and the difference between a company
#  that *has* data and one that *decides* with it. Those concepts are abstract
#  until you watch a board-level KPI report the wrong number because one
#  department's extract was never wired into the pipeline. This lab reproduces
#  exactly that failure on a disposable VM, with no Google Cloud project, no
#  billing account and no network access required.
#
#  What is simulated, and what it maps to in Google Cloud
#  -----------------------------------------------------
#    landing/<source>/*.csv .... Cloud Storage landing zone (raw layer),
#                                the output of Pub/Sub + Storage Transfer
#    bin/load.py ............... a Dataflow / Dataproc batch transform
#    warehouse/warehouse.db .... BigQuery (curated layer, the single source
#                                of truth for analytics)
#    etc/pipeline.conf ......... the pipeline's registry of sources
#    etc/catalog.yaml .......... Dataplex Universal Catalog metadata:
#                                owner, classification, PII flags
#    mask_pii() ................ Sensitive Data Protection (Cloud DLP)
#                                de-identification, done here with SHA-256
#    bin/report.sh ............. the Looker Studio executive dashboard
#    docs/finance_close.txt .... the CFO's closed books: business truth,
#                                produced OUTSIDE the pipeline
#
#  Official references
#    - Cloud Digital Leader exam guide:
#      https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#    - Data lifecycle on Google Cloud:
#      https://cloud.google.com/architecture/data-lifecycle-cloud-platform
#    - Dataplex Universal Catalog overview:
#      https://cloud.google.com/dataplex/docs/introduction
#    - Sensitive Data Protection (de-identification):
#      https://cloud.google.com/sensitive-data-protection/docs/deidentify-sensitive-data
#    - BigQuery introduction:
#      https://cloud.google.com/bigquery/docs/introduction
#
#  SAFETY CONTRACT
#    - Writes ONLY inside the lab directory (default: ~/cdl-lab/gcp-cdl-2.1).
#    - Installs nothing, needs no root, opens no ports, touches no system file,
#      makes no network call, and never runs a destructive command outside the
#      lab directory. --reset deletes only a directory carrying this lab's
#      marker file.
#    - Requires python3 with the sqlite3 stdlib module (present on any stock
#      Debian/Ubuntu/RHEL/Rocky/COS-adjacent image with python3 installed).
#    - Still: run it on a DISPOSABLE VM, e.g. a preemptible e2-micro you can
#      delete afterwards. Never on a machine you care about.
# ============================================================================

set -euo pipefail

LAB_ROOT="${CDL_LAB_ROOT:-$HOME/cdl-lab/gcp-cdl-2.1}"
MARKER=".cdl-lab-2.1"
ASSUME_YES=0
DO_RESET=0
BRIEF_ONLY=0

usage() {
    cat <<'USAGE'
Usage: cdl-2.1-break-fix.sh [options]

  -y, --yes        do not ask for interactive confirmation
      --path DIR   lab directory (default: $HOME/cdl-lab/gcp-cdl-2.1)
      --reset      delete an existing lab (marker-checked) and rebuild it broken
      --brief      re-print the student briefing of an existing lab and exit
  -h, --help       this text
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)   ASSUME_YES=1 ;;
        --reset)    DO_RESET=1 ;;
        --brief)    BRIEF_ONLY=1 ;;
        --path)     shift; LAB_ROOT="${1:?--path needs a directory}" ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "python3 is required (dnf install python3 / apt-get install python3)."
python3 -c 'import sqlite3, csv, hashlib' >/dev/null 2>&1 \
    || die "python3 is missing the sqlite3/csv stdlib modules (apt-get install python3-full)."

if [ "$BRIEF_ONLY" -eq 1 ]; then
    [ -f "$LAB_ROOT/docs/BRIEFING.txt" ] || die "no briefing at $LAB_ROOT/docs/BRIEFING.txt - build the lab first."
    cat "$LAB_ROOT/docs/BRIEFING.txt"
    exit 0
fi

if [ -e "$LAB_ROOT" ]; then
    if [ ! -f "$LAB_ROOT/$MARKER" ]; then
        die "$LAB_ROOT exists and is not one of this lab's directories. Refusing to touch it. Use --path."
    fi
    if [ "$DO_RESET" -eq 0 ]; then
        die "a lab already exists at $LAB_ROOT. Re-run with --reset to rebuild it, or --brief to re-read the briefing."
    fi
fi

rule
say "  gcp-cdl 2.1 - break & fix lab: 'The revenue that vanished'"
rule
say "  host          : $(hostname)"
say "  lab directory : $LAB_ROOT"
say "  action        : $([ "$DO_RESET" -eq 1 ] && echo 'DELETE and rebuild (broken state)' || echo 'build (broken state)')"
say "  side effects  : none outside the lab directory"
rule

if [ "$ASSUME_YES" -eq 0 ]; then
    if [ ! -t 0 ]; then
        die "non-interactive shell: pass --yes to confirm you are on a disposable VM."
    fi
    printf 'This VM is disposable and you accept the above. Continue? [y/N] '
    read -r reply
    case "$reply" in
        y|Y|yes|YES) : ;;
        *) say "aborted, nothing was written."; exit 0 ;;
    esac
fi

if [ "$DO_RESET" -eq 1 ] && [ -f "$LAB_ROOT/$MARKER" ]; then
    say "[reset] removing $LAB_ROOT"
    rm -rf -- "$LAB_ROOT"
fi

mkdir -p "$LAB_ROOT"/{bin,etc,docs,logs,warehouse,landing/retail-web,landing/retail-pos,landing/partner-mktg}
: > "$LAB_ROOT/$MARKER"
: > "$LAB_ROOT/logs/ingest.log"

# ===========================================================================
# 1. The source systems: three departments, three formats, zero coordination
# ===========================================================================
cat > "$LAB_ROOT/bin/source_systems.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Simulates the three operational systems that generate the company's data.

They are deliberately inconsistent, because in a real organisation they were
bought (or written) years apart by three different departments:

  retail-web    modern e-commerce platform  -> CSV, ISO-8601 timestamps, USD
                                                as a bare number, customer
                                                e-mail attached to every order
  retail-pos    in-store point of sale      -> pipe-delimited export,
                                                MM/DD/YYYY dates, no e-mail
                                                (the till never asks for one)
  partner-mktg  partner marketing platform  -> CSV, MM/DD/YYYY dates, amounts
                                                formatted for humans ($1,234.50)

Nothing here is random: the data is fully deterministic, so the CFO's closed
books and the warehouse can be compared to the cent.
"""
import csv
import os

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DAYS = ["2026-08-06", "2026-08-07", "2026-08-08", "2026-08-09",
        "2026-08-10", "2026-08-11", "2026-08-12"]


def us_date(iso):
    y, m, d = iso.split("-")
    return "%s/%s/%s" % (m, d, y)


def write(path, rows, header, delimiter=","):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh, delimiter=delimiter)
        w.writerow(header)
        w.writerows(rows)


def generate():
    for di, day in enumerate(DAYS):
        # --- retail-web: 6 orders/day -------------------------------------
        rows = []
        for i in range(6):
            amount = round(19.99 + 3.50 * i + 1.10 * di, 2)
            rows.append([
                "W-%s-%03d" % (day.replace("-", ""), i),
                "%s %02d:%02d:00" % (day, 8 + i, 15 + i),
                "customer%02d@example.com" % ((di * 6 + i) % 11),
                "%.2f" % amount,
                "web",
            ])
        write(os.path.join(LAB, "landing", "retail-web", "orders_%s.csv" % day),
              rows, ["order_id", "order_ts", "customer_email", "amount_usd", "channel"])

        # --- retail-pos: 4 transactions/day -------------------------------
        rows = []
        for i in range(4):
            amount = round(45.00 + 2.25 * i + 0.75 * di, 2)
            rows.append([
                "P-%s-%03d" % (day.replace("-", ""), i),
                us_date(day),
                "%.2f" % amount,
                "S-0%d" % (1 + i % 2),
            ])
        write(os.path.join(LAB, "landing", "retail-pos", "till_export_%s.csv" % day),
              rows, ["txn_id", "txn_date", "gross_amount", "store_id"], delimiter="|")

        # --- partner-mktg: 2 closed leads/day -----------------------------
        rows = []
        for i in range(2):
            amount = round(500.00 + 25.00 * i + 12.50 * di, 2)
            rows.append([
                "M-%s-%03d" % (day.replace("-", ""), i),
                us_date(day),
                "lead%02d@example.net" % ((di * 2 + i) % 7),
                "${:,.2f}".format(amount),
                "campaign-q3",
            ])
        write(os.path.join(LAB, "landing", "partner-mktg", "closed_%s.csv" % day),
              rows, ["lead_id", "close_date", "contact_email", "amount_usd", "campaign"])


if __name__ == "__main__":
    generate()
    print("source systems produced 7 days of extracts for 3 systems")
PYEOF

# ===========================================================================
# 2. The pipeline (written HEALTHY here - it is broken further down on purpose)
# ===========================================================================
cat > "$LAB_ROOT/bin/load.py" <<'PYEOF'
#!/usr/bin/env python3
"""
The batch transform that turns raw landing files into the curated fact table.

In Google Cloud this is a Dataflow job (or a Dataproc Spark job, or a BigQuery
scheduled query over external tables). Here it is 150 lines of Python so that
you can read every rule that governs your company's numbers.

The job is a FULL REFRESH: fact_orders is rebuilt from the landing zone on
every run, so re-running it as many times as you like is safe and idempotent.

    ./bin/ingest.sh        run the job
    ./bin/report.sh        read the dashboard it feeds
    ./bin/verify.sh        grade the state of the platform
"""
import csv
import glob
import hashlib
import os
import sqlite3
from datetime import datetime

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(LAB, "warehouse", "warehouse.db")
CONF = os.path.join(LAB, "etc", "pipeline.conf")
LOGF = os.path.join(LAB, "logs", "ingest.log")
LANDING = os.path.join(LAB, "landing")

SCHEMA = """
CREATE TABLE IF NOT EXISTS fact_orders (
    order_id      TEXT NOT NULL,
    source_system TEXT NOT NULL,
    order_date    TEXT,
    customer_key  TEXT,
    amount_usd    REAL NOT NULL,
    channel       TEXT,
    PRIMARY KEY (order_id, source_system)
);
"""


def log(msg, level="INFO"):
    line = "%s %-5s %s" % (datetime.now().strftime("%Y-%m-%dT%H:%M:%S"), level, msg)
    with open(LOGF, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    print(line)


def mask_pii(value):
    """
    Pseudonymise a direct identifier before it reaches the analytics layer.

    This is the local stand-in for Sensitive Data Protection (Cloud DLP)
    de-identification with a CRYPTO_HASH transformation. Analysts keep a
    stable join key per customer; nobody in the reporting layer ever reads an
    e-mail address.
    https://cloud.google.com/sensitive-data-protection/docs/transformations-reference
    """
    value = (value or "").strip().lower()
    if not value:
        return ""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def parse_date(value, fmt):
    """Normalise a source-specific date string to ISO-8601, or None."""
    try:
        return datetime.strptime((value or "").strip(), fmt).strftime("%Y-%m-%d")
    except ValueError:
        return None


def parse_money(value):
    """Accept 1234.50, $1,234.50 and 1,234.50 alike."""
    return float((value or "0").replace("$", "").replace(",", "").strip() or 0)


# --- one parser profile per source system ---------------------------------
def profile_web(path):
    out = []
    with open(path, newline="", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            out.append({
                "order_id": r["order_id"],
                "order_date": parse_date(r["order_ts"][:10], "%Y-%m-%d"),
                "customer_key": mask_pii(r["customer_email"]),
                "amount_usd": parse_money(r["amount_usd"]),
                "channel": r["channel"],
            })
    return out


def profile_pos(path):
    out = []
    with open(path, newline="", encoding="utf-8") as fh:
        for r in csv.DictReader(fh, delimiter="|"):
            out.append({
                "order_id": r["txn_id"],
                "order_date": parse_date(r["txn_date"], "%m/%d/%Y"),
                "customer_key": "",              # the till never collects one
                "amount_usd": parse_money(r["gross_amount"]),
                "channel": "store:" + r["store_id"],
            })
    return out


def profile_mktg(path):
    out = []
    with open(path, newline="", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            out.append({
                "order_id": r["lead_id"],
                "order_date": parse_date(r["close_date"], "%m/%d/%Y"),
                "customer_key": mask_pii(r["contact_email"]),
                "amount_usd": parse_money(r["amount_usd"]),
                "channel": r["campaign"],
            })
    return out


PROFILES = {"web": profile_web, "pos": profile_pos, "mktg": profile_mktg}


def read_conf():
    """
    pipeline.conf is the pipeline's registry of sources. One line per source:

        SOURCE <name> <path-relative-to-lab-root> <profile>
    """
    sources = []
    with open(CONF, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 4 or parts[0] != "SOURCE":
                log("malformed pipeline.conf line ignored: %r" % line, "WARN")
                continue
            sources.append({"name": parts[1], "path": parts[2], "profile": parts[3]})
    return sources


def discovery_check(sources):
    """
    What Dataplex does automatically: compare what physically exists in the
    landing zone against what the pipeline has been told to read.
    """
    on_disk = sorted(d for d in os.listdir(LANDING)
                     if os.path.isdir(os.path.join(LANDING, d)))
    registered = sorted(s["name"] for s in sources)
    log("landing zone holds %d dataset(s): %s" % (len(on_disk), ", ".join(on_disk)))
    log("pipeline.conf registers %d dataset(s): %s" % (len(registered), ", ".join(registered) or "-"))
    for name in on_disk:
        if name not in registered:
            log("dataset '%s' exists in the landing zone but no pipeline reads it "
                "(unmanaged data - a silo)" % name, "WARN")


def main():
    conn = sqlite3.connect(DB)
    conn.executescript(SCHEMA)
    conn.execute("DELETE FROM fact_orders")        # full refresh = idempotent

    sources = read_conf()
    discovery_check(sources)

    grand_rows, grand_amount, grand_nulls = 0, 0.0, 0
    for src in sources:
        parser = PROFILES.get(src["profile"])
        if parser is None:
            log("source '%s' declares unknown profile '%s' - skipped"
                % (src["name"], src["profile"]), "ERROR")
            continue
        files = sorted(glob.glob(os.path.join(LAB, src["path"], "*.csv")))
        if not files:
            log("source '%s' matched no files under %s" % (src["name"], src["path"]), "WARN")
            continue
        rows = []
        for path in files:
            rows.extend(parser(path))
        nulls = sum(1 for r in rows if not r["order_date"])
        conn.executemany(
            "INSERT OR REPLACE INTO fact_orders "
            "(order_id, source_system, order_date, customer_key, amount_usd, channel) "
            "VALUES (?,?,?,?,?,?)",
            [(r["order_id"], src["name"], r["order_date"], r["customer_key"],
              r["amount_usd"], r["channel"]) for r in rows])
        amount = round(sum(r["amount_usd"] for r in rows), 2)
        log("source '%s': %d file(s), %d row(s), %.2f USD" %
            (src["name"], len(files), len(rows), amount))
        if nulls:
            log("source '%s': %d row(s) landed with an unparsable date and will be "
                "invisible to every date-filtered report" % (src["name"], nulls), "WARN")
        grand_rows += len(rows)
        grand_amount += amount
        grand_nulls += nulls

    conn.commit()
    exposed = conn.execute(
        "SELECT COUNT(*) FROM fact_orders WHERE customer_key LIKE '%@%'").fetchone()[0]
    if exposed:
        log("%d row(s) carry a raw e-mail address in the curated layer "
            "(de-identification was not applied)" % exposed, "WARN")
    log("load finished: %d row(s), %.2f USD, %d row(s) without a usable date"
        % (grand_rows, grand_amount, grand_nulls))
    conn.close()


if __name__ == "__main__":
    main()
PYEOF

cat > "$LAB_ROOT/bin/ingest.sh" <<'EOF'
#!/usr/bin/env bash
# Runs the batch transform (the "Dataflow job") and shows the last warnings.
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$LAB/bin/load.py"
echo
echo "warnings and errors from this run:"
grep -E ' (WARN|ERROR) ' "$LAB/logs/ingest.log" | tail -n 12 || echo "  (none)"
EOF

# ===========================================================================
# 3. The pipeline registry and the governance catalog (written COMPLETE here)
# ===========================================================================
cat > "$LAB_ROOT/etc/pipeline.conf" <<'EOF'
# Source registry for the curated warehouse.
#
#   SOURCE <name>  <path relative to the lab root>  <parser profile>
#
# Profiles implemented in bin/load.py: web | pos | mktg
# A dataset that is not listed here is not read by anything. It still exists,
# it still costs storage, and it still holds revenue - it is simply invisible
# to the business. That is the textbook definition of a data silo.

SOURCE retail-web    landing/retail-web     web
SOURCE retail-pos    landing/retail-pos     pos
SOURCE partner-mktg  landing/partner-mktg   mktg
EOF

cat > "$LAB_ROOT/etc/catalog.yaml" <<'EOF'
# Data catalog - the local stand-in for Dataplex Universal Catalog.
# https://cloud.google.com/dataplex/docs/introduction
#
# Every dataset must declare:
#   owner           a person or team accountable for it (an address, not a name)
#   classification  one of: public | internal | confidential | restricted
#   contains_pii    whether it carries direct identifiers
#   masking         required | not-required
#
# A dataset with no owner has no one to call when the number is wrong, and no
# one to approve access to it. Governance metadata is not paperwork: it is what
# makes data usable by people who did not produce it.

datasets:
  - name: retail-web
    domain: ecommerce
    owner: ecommerce-data@example.com
    classification: confidential
    contains_pii: true
    masking: required
  - name: retail-pos
    domain: retail-stores
    owner: store-ops-data@example.com
    classification: internal
    contains_pii: false
    masking: not-required
  - name: partner-mktg
    domain: marketing
    owner: marketing-analytics@example.com
    classification: confidential
    contains_pii: true
    masking: required
EOF

# ===========================================================================
# 4. The dashboard (Looker Studio) and the grader
# ===========================================================================
cat > "$LAB_ROOT/bin/report.sh" <<'EOF'
#!/usr/bin/env bash
# The executive dashboard. This is what the CEO looks at on Monday morning.
set -euo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$LAB" <<'PY'
import os, sqlite3, sys

LAB = sys.argv[1]
DB = os.path.join(LAB, "warehouse", "warehouse.db")
TRUTH = os.path.join(LAB, "docs", "finance_close.txt")

def load_truth():
    t = {"days": {}, "sources": {}}
    with open(TRUTH, encoding="utf-8") as fh:
        for line in fh:
            p = line.split()
            if not p or p[0].startswith("#"):
                continue
            if p[0] == "PERIOD_START":          t["start"] = p[1]
            elif p[0] == "PERIOD_END":          t["end"] = p[1]
            elif p[0] == "TOTAL_REVENUE_USD":   t["total"] = float(p[1])
            elif p[0] == "DAY":                 t["days"][p[1]] = float(p[2])
            elif p[0] == "SOURCE":              t["sources"][p[1]] = float(p[2])
    return t

t = load_truth()
conn = sqlite3.connect(DB)
q = conn.execute

rows_total = q("SELECT COUNT(*) FROM fact_orders").fetchone()[0]
in_period = "order_date BETWEEN ? AND ?"
args = (t["start"], t["end"])
total = q("SELECT COALESCE(SUM(amount_usd),0) FROM fact_orders WHERE " + in_period, args).fetchone()[0]
nulls = q("SELECT COUNT(*) FROM fact_orders WHERE order_date IS NULL OR order_date=''").fetchone()[0]
fresh = q("SELECT MAX(order_date) FROM fact_orders").fetchone()[0] or "(none)"
exposed = q("SELECT COUNT(*) FROM fact_orders WHERE customer_key LIKE '%@%'").fetchone()[0]

bar = "=" * 70
print(bar)
print("  QUARTERLY REVENUE DASHBOARD - period %s .. %s" % (t["start"], t["end"]))
print(bar)
print("  Reported revenue (warehouse) : %12s USD" % ("{:,.2f}".format(total)))
print("  Finance close (CFO)          : %12s USD" % ("{:,.2f}".format(t["total"])))
delta = total - t["total"]
pct = (delta / t["total"] * 100.0) if t["total"] else 0.0
print("  Variance                     : %12s USD  (%+.1f%%)" % ("{:,.2f}".format(delta), pct))
print()

print("  Revenue by source system")
print("  %-14s %14s %14s   %s" % ("source", "warehouse", "finance", "status"))
for name in sorted(t["sources"]):
    got = q("SELECT COALESCE(SUM(amount_usd),0) FROM fact_orders "
            "WHERE source_system=? AND " + in_period, (name,) + args).fetchone()[0]
    want = t["sources"][name]
    status = "ok" if abs(got - want) < 0.05 else ("MISSING" if got == 0 else "UNDER-REPORTED")
    print("  %-14s %14s %14s   %s" % (name, "{:,.2f}".format(got), "{:,.2f}".format(want), status))
print()

print("  Daily revenue (warehouse)")
day_rows = q("SELECT order_date, SUM(amount_usd) FROM fact_orders WHERE " + in_period +
             " GROUP BY order_date ORDER BY order_date", args).fetchall()
have = dict(day_rows)
scale = max(list(t["days"].values()) + [1.0])
for day in sorted(t["days"]):
    v = have.get(day, 0.0)
    width = int(round(v / scale * 44))
    print("  %s %12s |%s" % (day, "{:,.2f}".format(v), "#" * width))
print()

print("  Data health")
print("    rows in fact_orders ............ %d" % rows_total)
print("    rows with no usable date ....... %d %s" % (nulls, "<-- excluded from every chart above" if nulls else ""))
print("    freshness (max order_date) ..... %s (expected %s)" % (fresh, t["end"]))
print("    rows exposing a raw e-mail ..... %d %s" % (exposed, "<-- PII IN THE REPORTING LAYER" if exposed else ""))
print(bar)
conn.close()
PY
EOF

cat > "$LAB_ROOT/bin/verify.sh" <<'EOF'
#!/usr/bin/env bash
# Grader. Exit code 0 means the platform is fixed.
# Do not edit this file, docs/finance_close.txt, or anything under landing/.
set -uo pipefail
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$LAB" <<'PY'
import csv, glob, hashlib, os, sqlite3, sys

LAB = sys.argv[1]
DB = os.path.join(LAB, "warehouse", "warehouse.db")
TRUTH = os.path.join(LAB, "docs", "finance_close.txt")
CONF = os.path.join(LAB, "etc", "pipeline.conf")
CATALOG = os.path.join(LAB, "etc", "catalog.yaml")
TOL = 0.05
EXPECTED_SOURCES = {"retail-web", "retail-pos", "partner-mktg"}
CLASSES = {"public", "internal", "confidential", "restricted"}

results = []
def check(name, ok, detail=""):
    results.append((name, ok, detail))

def truth():
    t = {"days": {}, "sources": {}}
    with open(TRUTH, encoding="utf-8") as fh:
        for line in fh:
            p = line.split()
            if not p or p[0].startswith("#"):
                continue
            if p[0] == "PERIOD_START":        t["start"] = p[1]
            elif p[0] == "PERIOD_END":        t["end"] = p[1]
            elif p[0] == "TOTAL_REVENUE_USD": t["total"] = float(p[1])
            elif p[0] == "DAY":               t["days"][p[1]] = float(p[2])
            elif p[0] == "SOURCE":            t["sources"][p[1]] = float(p[2])
    return t

def mask(v):
    v = (v or "").strip().lower()
    return hashlib.sha256(v.encode("utf-8")).hexdigest()[:16] if v else ""

def parse_catalog():
    out, cur = [], None
    for raw in open(CATALOG, encoding="utf-8"):
        line = raw.rstrip("\n")
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("- name:"):
            cur = {"name": s.split(":", 1)[1].strip().strip('"').strip("'")}
            out.append(cur)
        elif cur is not None and ":" in s and not s.startswith("-"):
            k, v = s.split(":", 1)
            cur[k.strip()] = v.strip().strip('"').strip("'")
    return out

t = truth()
if not os.path.exists(DB):
    print("no warehouse yet - run ./bin/ingest.sh first")
    sys.exit(1)
conn = sqlite3.connect(DB)
q = conn.execute
period = "order_date BETWEEN ? AND ?"
args = (t["start"], t["end"])

# 1 - source coverage: is every dataset in the landing zone actually used?
got_sources = {r[0] for r in q("SELECT DISTINCT source_system FROM fact_orders").fetchall()}
missing = sorted(EXPECTED_SOURCES - got_sources)
check("1. source coverage - every landing dataset reaches the warehouse",
      not missing, "missing: %s" % ", ".join(missing) if missing else "3/3 datasets loaded")

# 2 - revenue completeness against the CFO's closed books
total = q("SELECT COALESCE(SUM(amount_usd),0) FROM fact_orders WHERE " + period, args).fetchone()[0]
ok_total = abs(total - t["total"]) < TOL
per_src_bad = []
for name, want in t["sources"].items():
    got = q("SELECT COALESCE(SUM(amount_usd),0) FROM fact_orders WHERE source_system=? AND "
            + period, (name,) + args).fetchone()[0]
    if abs(got - want) >= TOL:
        per_src_bad.append("%s %.2f!=%.2f" % (name, got, want))
check("2. revenue completeness - warehouse matches the finance close",
      ok_total and not per_src_bad,
      ("%.2f vs %.2f; %s" % (total, t["total"], "; ".join(per_src_bad))) if (not ok_total or per_src_bad)
      else "%.2f USD, all sources reconcile" % total)

# 3 - time-series integrity: no row silently outside the date filter
nulls = q("SELECT COUNT(*) FROM fact_orders WHERE order_date IS NULL OR order_date=''").fetchone()[0]
day_bad = []
for day, want in t["days"].items():
    got = q("SELECT COALESCE(SUM(amount_usd),0) FROM fact_orders WHERE order_date=?",
            (day,)).fetchone()[0]
    if abs(got - want) >= TOL:
        day_bad.append(day)
fresh = q("SELECT MAX(order_date) FROM fact_orders").fetchone()[0]
check("3. time-series integrity - dates parsed, daily series complete",
      nulls == 0 and not day_bad and fresh == t["end"],
      "null dates=%d, wrong days=%s, freshness=%s" % (nulls, ",".join(sorted(day_bad)) or "none", fresh))

# 4 - governance: no direct identifier in the analytics layer
exposed = q("SELECT COUNT(*) FROM fact_orders WHERE customer_key LIKE '%@%'").fetchone()[0]
expected_keys = {"retail-web": set(), "partner-mktg": set()}
for path in sorted(glob.glob(os.path.join(LAB, "landing", "retail-web", "*.csv"))):
    for r in csv.DictReader(open(path, newline="", encoding="utf-8")):
        expected_keys["retail-web"].add(mask(r["customer_email"]))
for path in sorted(glob.glob(os.path.join(LAB, "landing", "partner-mktg", "*.csv"))):
    for r in csv.DictReader(open(path, newline="", encoding="utf-8")):
        expected_keys["partner-mktg"].add(mask(r["contact_email"]))
key_bad = []
for name, want in expected_keys.items():
    got = {r[0] for r in q("SELECT DISTINCT customer_key FROM fact_orders WHERE source_system=?",
                           (name,)).fetchall()}
    if got != want:
        key_bad.append(name)
check("4. governance / PII - identifiers pseudonymised before analytics",
      exposed == 0 and not key_bad,
      "raw e-mails=%d, wrong pseudonyms in: %s" % (exposed, ",".join(key_bad) or "none"))

# 5 - governance: the catalog describes every dataset the pipeline reads
cat_entries = {d["name"]: d for d in parse_catalog()}
conf_names = [l.split()[1] for l in open(CONF, encoding="utf-8")
              if l.strip().startswith("SOURCE")]
cat_bad = []
for name in sorted(set(conf_names) | EXPECTED_SOURCES):
    d = cat_entries.get(name)
    if d is None:
        cat_bad.append("%s:absent" % name); continue
    if not d.get("owner") or "@" not in d.get("owner", ""):
        cat_bad.append("%s:no-owner" % name)
    if d.get("classification", "") not in CLASSES:
        cat_bad.append("%s:no-classification" % name)
check("5. governance / catalog - owner and classification on every dataset",
      not cat_bad, ", ".join(cat_bad) if cat_bad else "%d dataset(s) fully described" % len(cat_entries))

print("=" * 70)
print("  VERIFICATION - gcp-cdl 2.1")
print("=" * 70)
for name, ok, detail in results:
    print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
    if detail:
        print("         %s" % detail)
print("=" * 70)
failed = [r for r in results if not r[1]]
if failed:
    print("  %d of %d checks failing. Run ./bin/report.sh and read logs/ingest.log." % (len(failed), len(results)))
    sys.exit(1)
print("  All checks pass. The dashboard now tells the truth.")
conn.close()
PY
EOF

chmod +x "$LAB_ROOT"/bin/*.sh "$LAB_ROOT"/bin/*.py

# ===========================================================================
# 5. Produce the data, run the HEALTHY pipeline once, and close the books.
#    The CFO's ground truth is generated from a correct run and is therefore
#    genuinely reachable - the answer is never stored anywhere else.
# ===========================================================================
say "[build] generating source-system extracts..."
python3 "$LAB_ROOT/bin/source_systems.py" >/dev/null

say "[build] running the healthy pipeline once to close the books..."
python3 "$LAB_ROOT/bin/load.py" >/dev/null

python3 - "$LAB_ROOT" <<'PYEOF'
import os, sqlite3, sys
LAB = sys.argv[1]
conn = sqlite3.connect(os.path.join(LAB, "warehouse", "warehouse.db"))
q = conn.execute
start, end = q("SELECT MIN(order_date), MAX(order_date) FROM fact_orders").fetchone()
total = q("SELECT ROUND(SUM(amount_usd),2) FROM fact_orders").fetchone()[0]
lines = [
    "# Finance close - the business truth for this period.",
    "# Produced by the finance team from the operational systems themselves,",
    "# independently of the data platform. When the dashboard disagrees with",
    "# this file, the dashboard is wrong.",
    "PERIOD_START %s" % start,
    "PERIOD_END %s" % end,
    "TOTAL_REVENUE_USD %.2f" % total,
]
for day, amount in q("SELECT order_date, ROUND(SUM(amount_usd),2) FROM fact_orders "
                     "GROUP BY order_date ORDER BY order_date").fetchall():
    lines.append("DAY %s %.2f" % (day, amount))
for name, amount in q("SELECT source_system, ROUND(SUM(amount_usd),2) FROM fact_orders "
                      "GROUP BY source_system ORDER BY source_system").fetchall():
    lines.append("SOURCE %s %.2f" % (name, amount))
with open(os.path.join(LAB, "docs", "finance_close.txt"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
conn.close()
print("finance close written: %.2f USD over %s .. %s" % (total, start, end))
PYEOF

# ===========================================================================
# 6. THE BREAK - three faults, each a textbook failure mode of objective 2.1.
#    Every patch is asserted, so a silent no-op cannot produce a fake lab.
# ===========================================================================
say "[break] introducing three controlled faults..."
python3 - "$LAB_ROOT" <<'PYEOF'
import os, sys

LAB = sys.argv[1]

def patch(path, old, new, expected=1):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    found = text.count(old)
    if found != expected:
        sys.exit("break aborted: expected %d occurrence(s) of %r in %s, found %d"
                 % (expected, old[:60], os.path.basename(path), found))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text.replace(old, new))

load = os.path.join(LAB, "bin", "load.py")
conf = os.path.join(LAB, "etc", "pipeline.conf")
cat = os.path.join(LAB, "etc", "catalog.yaml")

# FAULT 1 - the silo. During a "temporary" migration two quarters ago, the POS
# source was dropped from the pipeline registry. Nobody noticed, because the
# dashboard never showed a gap - it simply showed a smaller number.
with open(conf, encoding="utf-8") as fh:
    lines = fh.readlines()
kept = [l for l in lines if not l.strip().startswith("SOURCE retail-pos")]
if len(kept) != len(lines) - 1:
    sys.exit("break aborted: the retail-pos SOURCE line was not found in pipeline.conf")
with open(conf, "w", encoding="utf-8") as fh:
    fh.writelines(kept)

# FAULT 2 - schema drift. The marketing partner changed its export from
# ISO-8601 to MM/DD/YYYY. The loader still expects the old format, so every
# marketing row lands with a NULL date and disappears from every date filter.
patch(load,
      'parse_date(r["close_date"], "%m/%d/%Y")',
      'parse_date(r["close_date"], "%Y-%m-%d")')

# FAULT 3 - governance regression. A "quick fix" removed de-identification, so
# raw customer e-mail addresses now sit in the curated analytics table; and the
# catalog entries for two datasets were emptied during an export/import.
patch(load,
      '"customer_key": mask_pii(r["customer_email"]),',
      '"customer_key": r["customer_email"],')
patch(load,
      '"customer_key": mask_pii(r["contact_email"]),',
      '"customer_key": r["contact_email"],')

out, current = [], None
blanked = 0
for raw in open(cat, encoding="utf-8"):
    s = raw.strip()
    if s.startswith("- name:"):
        current = s.split(":", 1)[1].strip()
    if current in ("retail-pos", "partner-mktg") and (
            s.startswith("owner:") or s.startswith("classification:")):
        key = s.split(":", 1)[0]
        indent = raw[:len(raw) - len(raw.lstrip())]
        out.append('%s%s: ""\n' % (indent, key))
        blanked += 1
        continue
    out.append(raw)
if blanked != 4:
    sys.exit("break aborted: expected to blank 4 catalog fields, blanked %d" % blanked)
with open(cat, "w", encoding="utf-8") as fh:
    fh.writelines(out)

print("three faults applied")
PYEOF

rm -f "$LAB_ROOT/warehouse/warehouse.db"
: > "$LAB_ROOT/logs/ingest.log"
say "[break] rebuilding the warehouse from the broken pipeline..."
python3 "$LAB_ROOT/bin/load.py" >/dev/null 2>&1 || true

# ===========================================================================
# 7. Student briefing
# ===========================================================================
cat > "$LAB_ROOT/docs/BRIEFING.txt" <<EOF
======================================================================
  gcp-cdl 2.1 - BREAK & FIX: "The revenue that vanished"
  Describe the intrinsic role that data plays in an organization's
  digital transformation
  Lab root: $LAB_ROOT
======================================================================

THE SITUATION
  You have just joined the data platform team of a retailer that sells
  through three channels: an e-commerce site, physical stores, and a
  marketing partner that closes deals on the company's behalf. Each
  channel writes its extracts into the landing zone (Cloud Storage), a
  batch job (Dataflow) curates them into the warehouse (BigQuery), and
  an executive dashboard (Looker Studio) reads that warehouse.

  This morning the CFO closed the books for the week and the number does
  not match the dashboard. The CEO now trusts a spreadsheet more than the
  platform - which is precisely how a digital transformation dies: not
  when the data is missing, but when the organisation stops believing it.

THE SYMPTOMS YOU WILL SEE
  Run  ./bin/report.sh  and you will observe:

    1. Reported revenue is materially BELOW the finance close, with a
       large negative variance.
    2. At least one source system reports 0.00 USD while its extracts are
       sitting in the landing zone, untouched. Nothing errored.
    3. The daily bar chart has revenue for the period, but the row count
       in fact_orders is higher than what the chart accounts for - rows
       exist that no date-filtered query can see.
    4. The data-health block reports rows carrying a raw e-mail address
       in the reporting layer.

  Run  ./bin/verify.sh  and five checks are graded; several are FAILing.
  Run  grep -E ' (WARN|ERROR) ' logs/ingest.log  - the pipeline told you
  about all of this. Nobody was reading.

YOUR MISSION
  Make  ./bin/verify.sh  exit 0 with all five checks PASS:

    1. source coverage ....... every dataset in landing/ reaches the
                               warehouse
    2. revenue completeness .. the warehouse total and every per-source
                               total reconcile with docs/finance_close.txt
                               to within 0.05 USD
    3. time-series integrity . zero rows with a NULL/empty order_date,
                               every day of the period matching the close,
                               freshness equal to the period end date
    4. governance / PII ...... no raw e-mail anywhere in fact_orders, and
                               customer_key equal to the pseudonym produced
                               by mask_pii() - i.e. the first 16 hex chars
                               of the SHA-256 of the lowercased address
                               (empty for the POS, which has no e-mail)
    5. governance / catalog .. every dataset in etc/catalog.yaml carries a
                               non-empty owner containing '@' and a
                               classification in
                               {public, internal, confidential, restricted}

RULES OF ENGAGEMENT
  - You may edit: etc/pipeline.conf, etc/catalog.yaml, bin/load.py.
  - You may NOT edit: bin/verify.sh, docs/finance_close.txt, or anything
    under landing/. Rewriting the source data or the grader is the
    real-world equivalent of changing the KPI definition until the chart
    looks good - the exact anti-pattern this objective warns about.
  - bin/load.py is a full refresh; re-run ./bin/ingest.sh as often as you
    want. Fix, ingest, report, verify, repeat.

WHERE TO LOOK
  ./bin/report.sh              the dashboard (the symptom)
  ./bin/ingest.sh              re-run the pipeline
  ./bin/verify.sh              the grader (the definition of done)
  logs/ingest.log              what the pipeline already warned you about
  ls landing/*/                what physically exists in the landing zone
  head -3 landing/*/*.csv      three systems, three formats
  etc/pipeline.conf            what the pipeline was told to read
  etc/catalog.yaml             what the organisation knows about its data

THE EXAM POINT
  Each fault is one bullet of objective 2.1:
    - a DATA SILO: data that exists, costs money to store, and is invisible
      to decision-making because no pipeline was ever pointed at it
    - DATA QUALITY / schema drift: an upstream format change that produces
      no error, only a quietly smaller number - the most expensive kind of
      failure, because it looks like a business result
    - DATA GOVERNANCE: ownership, classification and de-identification are
      what make data shareable across an organisation; without them a
      company either exposes its customers or freezes its own analysts out
  A digital transformation is not the migration - it is the moment the
  organisation can act on a number it trusts.

REFERENCES
  Cloud Digital Leader exam guide
    https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
  Data lifecycle on Google Cloud
    https://cloud.google.com/architecture/data-lifecycle-cloud-platform
  Dataplex Universal Catalog
    https://cloud.google.com/dataplex/docs/introduction
  Sensitive Data Protection - de-identification
    https://cloud.google.com/sensitive-data-protection/docs/deidentify-sensitive-data
  BigQuery introduction
    https://cloud.google.com/bigquery/docs/introduction

CLEAN-UP
  rm -rf "$LAB_ROOT"      (or just delete the VM)
======================================================================
EOF

cat "$LAB_ROOT/docs/BRIEFING.txt"
say ""
say "The broken dashboard, as the CEO sees it right now:"
say ""
"$LAB_ROOT/bin/report.sh" || true
say ""
say "Start here:  cd $LAB_ROOT && ./bin/verify.sh"
say "Re-read the briefing at any time:  $0 --brief --path $LAB_ROOT"

exit 0

# ===========================================================================
#
#  S O L U T I O N   -   do not read until you have tried
#  =====================================================
#
#  cd "$HOME/cdl-lab/gcp-cdl-2.1"
#
#  ---------------------------------------------------------------------
#  STEP 0 - Read the evidence before touching anything
#  ---------------------------------------------------------------------
#    ./bin/report.sh
#    grep -E ' (WARN|ERROR) ' logs/ingest.log
#
#  Expected warnings, and what each one means:
#
#    WARN  dataset 'retail-pos' exists in the landing zone but no pipeline
#          reads it (unmanaged data - a silo)
#          -> fault 1. Dataplex-style discovery already compared the bucket
#             against the registry.
#    WARN  source 'partner-mktg': 14 row(s) landed with an unparsable date
#          and will be invisible to every date-filtered report
#          -> fault 2. The rows loaded; the dashboard cannot see them.
#    WARN  N row(s) carry a raw e-mail address in the curated layer
#          -> fault 3.
#
#  Confirm the silo physically:
#    ls landing/                      # three directories
#    grep '^SOURCE' etc/pipeline.conf # two entries
#    head -3 landing/retail-pos/till_export_2026-08-12.csv
#      txn_id|txn_date|gross_amount|store_id
#      P-20260812-000|08/12/2026|49.50|S-01
#
#  ---------------------------------------------------------------------
#  FIX 1 - Break the silo: register the POS dataset
#  ---------------------------------------------------------------------
#  The parser profile 'pos' already exists in bin/load.py (grep it:
#  `grep -n 'PROFILES' bin/load.py`). The only thing missing is the line
#  telling the pipeline that the dataset exists:
#
#    cat >> etc/pipeline.conf <<'CONF'
#    SOURCE retail-pos    landing/retail-pos     pos
#    CONF
#
#    ./bin/ingest.sh
#    # -> source 'retail-pos': 7 file(s), 28 row(s), <amount> USD
#    # -> the "dataset exists but no pipeline reads it" WARN is gone
#
#  In Google Cloud terms: you added the Cloud Storage prefix as an input to
#  the Dataflow job (or created the BigLake/external table over it). Note
#  that no code changed - the silo was a registration problem, which is why
#  silos survive for years without anyone filing a bug.
#
#  ---------------------------------------------------------------------
#  FIX 2 - Schema drift: parse the partner's real date format
#  ---------------------------------------------------------------------
#    head -2 landing/partner-mktg/closed_2026-08-12.csv
#      lead_id,close_date,contact_email,amount_usd,campaign
#      M-20260812-000,08/12/2026,lead00@example.net,"$575.00",campaign-q3
#
#  The partner sends MM/DD/YYYY; profile_mktg() still asks for %Y-%m-%d, so
#  parse_date() returns None and the row lands with a NULL order_date:
#
#    grep -n 'close_date' bin/load.py
#
#  Fix the format string (the same one profile_pos already uses):
#
#    python3 - <<'PY'
#    p = "bin/load.py"
#    s = open(p).read()
#    s = s.replace('parse_date(r["close_date"], "%Y-%m-%d")',
#                  'parse_date(r["close_date"], "%m/%d/%Y")')
#    open(p, "w").write(s)
#    PY
#
#    ./bin/ingest.sh
#    # -> the "unparsable date" WARN disappears
#
#  Optional hardening (what you would actually ship): make the failure loud
#  instead of silent - a NULL rate above a threshold should fail the job,
#  not quietly shrink the KPI. In BigQuery this is a data-quality rule in
#  Dataplex; here it would be `if nulls: sys.exit(1)`.
#
#  ---------------------------------------------------------------------
#  FIX 3a - Governance: de-identify before the analytics layer
#  ---------------------------------------------------------------------
#  mask_pii() is defined in bin/load.py and called by nobody:
#
#    grep -n 'mask_pii' bin/load.py
#
#  Restore both call sites:
#
#    python3 - <<'PY'
#    p = "bin/load.py"
#    s = open(p).read()
#    s = s.replace('"customer_key": r["customer_email"],',
#                  '"customer_key": mask_pii(r["customer_email"]),')
#    s = s.replace('"customer_key": r["contact_email"],',
#                  '"customer_key": mask_pii(r["contact_email"]),')
#    open(p, "w").write(s)
#    PY
#
#    ./bin/ingest.sh
#    sqlite3 warehouse/warehouse.db \
#      "SELECT source_system, COUNT(*) FROM fact_orders WHERE customer_key LIKE '%@%' GROUP BY 1;"
#    # -> no rows
#    # (no sqlite3 CLI on the VM? use:
#    #  python3 -c "import sqlite3;print(sqlite3.connect('warehouse/warehouse.db').execute(
#    #  \"SELECT COUNT(*) FROM fact_orders WHERE customer_key LIKE '%@%'\").fetchone())" )
#
#  Because the full refresh rebuilds fact_orders from the landing zone, the
#  raw addresses are gone from the curated layer after one run. The analyst
#  keeps a stable per-customer join key and loses nothing they needed.
#
#  ---------------------------------------------------------------------
#  FIX 3b - Governance: give every dataset an owner and a classification
#  ---------------------------------------------------------------------
#    grep -n -A5 'name: retail-pos'   etc/catalog.yaml
#    grep -n -A5 'name: partner-mktg' etc/catalog.yaml
#
#  Both have owner: "" and classification: "". Fill them in - the owner must
#  be an address (something you can page), the classification one of
#  public | internal | confidential | restricted:
#
#    python3 - <<'PY'
#    p = "etc/catalog.yaml"
#    out, cur = [], None
#    want = {"retail-pos":   ("store-ops-data@example.com",   "internal"),
#            "partner-mktg": ("marketing-analytics@example.com", "confidential")}
#    for raw in open(p):
#        s = raw.strip()
#        if s.startswith("- name:"):
#            cur = s.split(":", 1)[1].strip()
#        if cur in want and s.startswith("owner:"):
#            raw = '    owner: %s\n' % want[cur][0]
#        elif cur in want and s.startswith("classification:"):
#            raw = '    classification: %s\n' % want[cur][1]
#        out.append(raw)
#    open(p, "w").writelines(out)
#    PY
#
#  Classification rationale, which is the examinable part: retail-pos holds
#  no direct identifier, so 'internal' is proportionate - over-classifying is
#  itself a failure, because analysts then cannot reach the data and go build
#  a private copy, creating the next silo. partner-mktg carries e-mail
#  addresses at source, so it is 'confidential' with masking required.
#
#  ---------------------------------------------------------------------
#  STEP 4 - Verify
#  ---------------------------------------------------------------------
#    ./bin/ingest.sh
#    ./bin/verify.sh ; echo "exit=$?"
#
#    [PASS] 1. source coverage - every landing dataset reaches the warehouse
#    [PASS] 2. revenue completeness - warehouse matches the finance close
#    [PASS] 3. time-series integrity - dates parsed, daily series complete
#    [PASS] 4. governance / PII - identifiers pseudonymised before analytics
#    [PASS] 5. governance / catalog - owner and classification on every dataset
#    All checks pass. The dashboard now tells the truth.
#    exit=0
#
#    ./bin/report.sh
#    # Variance: 0.00 USD (+0.0%), every source 'ok', freshness = period end,
#    # 0 rows without a usable date, 0 rows exposing a raw e-mail.
#
#  ---------------------------------------------------------------------
#  WHAT THE EXAM WANTS YOU TO TAKE AWAY
#  ---------------------------------------------------------------------
#  * Data is an ASSET only once it is discoverable, trusted and governed.
#    Three faults, zero crashes, and the company was making decisions on a
#    number that was wrong by double digits. Availability of data and
#    usability of data are different properties.
#  * The DATA VALUE CHAIN is only as strong as its weakest link:
#      generate (the POS was generating fine)
#      -> collect (the files landed fine)
#      -> process (the pipeline never read them; and it misparsed dates)
#      -> analyse (the dashboard rendered a confident wrong number)
#      -> activate (the business acted on it)
#    A break anywhere upstream is invisible downstream unless you measure it.
#  * SILOS are usually organisational, not technical: one line of config, two
#    quarters of wrong reporting. Automated discovery (Dataplex) exists to
#    surface exactly this - "what is in my landing zone that nothing reads?"
#  * DATA QUALITY failures that raise no error are the expensive ones. Assert
#    freshness, row counts and null rates as job-failing conditions, and
#    reconcile against a source of truth produced outside the platform.
#  * GOVERNANCE (ownership, classification, de-identification) is what makes
#    data shareable. It is not the brake on a data-driven culture - it is the
#    precondition for one, because it is what lets you say yes to access.
#  * The transformation is not the pipeline. It is the day the CEO stops
#    opening the spreadsheet.
#
#  Google Cloud services that implement each control used above:
#    Cloud Storage / Pub/Sub ......... landing and streaming ingestion
#    Dataflow / Dataproc ............. the transform
#    BigQuery ........................ the curated single source of truth
#    Dataplex Universal Catalog ...... discovery, ownership, classification,
#                                      data-quality rules and lineage
#    Sensitive Data Protection (DLP) . inspection and de-identification
#    Looker / Looker Studio .......... the governed semantic layer and reports
#
# ===========================================================================