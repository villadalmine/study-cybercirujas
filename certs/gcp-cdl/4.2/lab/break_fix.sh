#!/usr/bin/env bash
#
# =============================================================================
#  break-and-fix-lab.sh
# =============================================================================
#
#  Certification : Google Cloud Digital Leader (gcp-cdl)
#  Exam version  : 2026-08-12
#  Domain 4      : Trust and security / Scaling and operations
#  Topic     4.2 : Describe the functionality, business use cases, and business
#                  value of Google Cloud's infrastructure offerings
#  Exam weight   : 6.0
#
#  Reference     : Cloud Digital Leader exam guide (official)
#                  https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
#                  Compute Engine machine families
#                  https://cloud.google.com/compute/docs/machine-resource
#                  Sustained use / committed use discounts
#                  https://cloud.google.com/compute/docs/instances/signing-up-committed-use-discounts
#                  Spot VMs
#                  https://cloud.google.com/compute/docs/instances/spot
#                  Regions and zones
#                  https://cloud.google.com/compute/docs/regions-zones
#                  Managed instance groups / autohealing
#                  https://cloud.google.com/compute/docs/instance-groups/autohealing-instances-in-migs
#                  Google Cloud VMware Engine
#                  https://cloud.google.com/vmware-engine/docs/overview
#                  Bare Metal Solution
#                  https://cloud.google.com/bare-metal/docs/bms-overview
#
# -----------------------------------------------------------------------------
#  WHAT THIS LAB IS
# -----------------------------------------------------------------------------
#
#  Topic 4.2 is a *business value* objective, not a hands-on Compute Engine
#  objective. The exam does not ask you to type `gcloud compute instances
#  create`. It asks you to look at a workload and say: which Google Cloud
#  infrastructure offering fits it, and why does that choice cost less, fail
#  less, or migrate faster than the alternative.
#
#  So this lab does not break a real cloud resource. It breaks a *local
#  simulation* of an infrastructure decision engine: a small Bash "advisor"
#  that maps workload characteristics onto Google Cloud infrastructure
#  offerings (machine families, VM provisioning models, regional footprint,
#  lift-and-shift targets). The simulation runs entirely inside a throwaway
#  lab VM, touches nothing outside its own working directory, spends zero
#  cloud credits, and needs no GCP project, no billing account and no network.
#
#  What breaks is the *decision logic and its reference data* — exactly the
#  place where a Digital Leader candidate's understanding breaks in the exam.
#  Repairing it forces you to reason about the same trade-offs the exam tests:
#  Spot vs on-demand vs CUD, general-purpose vs compute-optimized vs
#  memory-optimized, zonal vs regional vs multi-regional, VMware Engine vs
#  Bare Metal Solution vs plain VMs.
#
# -----------------------------------------------------------------------------
#  SAFETY CONTRACT — read this before running
# -----------------------------------------------------------------------------
#
#    * Runs as a normal, unprivileged user. It refuses to run as root.
#    * Writes ONLY under a single lab directory (default: ~/gcdl-lab-4.2).
#      Nothing is written to /etc, /usr, /var or anywhere else.
#    * Issues NO gcloud calls, NO API calls, NO network traffic at all.
#    * Creates NO cloud resources, so it cannot generate a bill.
#    * Installs nothing. Uses only bash, coreutils, grep, sed, awk.
#    * `--reset` restores the lab to its pristine broken state.
#    * `--destroy` removes the lab directory and nothing else.
#
#  It is still designed for a DISPOSABLE lab VM. Do not run it on a machine
#  you care about, and do not run it in a home directory that holds work you
#  have not backed up.
#
# -----------------------------------------------------------------------------
#  USAGE
# -----------------------------------------------------------------------------
#
#    ./break-and-fix-lab.sh            # break the lab and print the briefing
#    ./break-and-fix-lab.sh --verify   # grade your repair
#    ./break-and-fix-lab.sh --hint     # progressive hints, one rung at a time
#    ./break-and-fix-lab.sh --reset    # back to the pristine broken state
#    ./break-and-fix-lab.sh --destroy  # delete the lab directory
#
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

LAB_ROOT="${GCDL_LAB_ROOT:-$HOME/gcdl-lab-4.2}"
ADVISOR="$LAB_ROOT/bin/infra-advisor.sh"
CATALOG="$LAB_ROOT/data/offerings.csv"
WORKLOADS="$LAB_ROOT/data/workloads.csv"
EXPECTED="$LAB_ROOT/data/expected.csv"
STATE="$LAB_ROOT/.lab-state"
HINT_COUNTER="$LAB_ROOT/.hint-count"

# --- presentation ------------------------------------------------------------

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; RESET=''
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s[PASS]%s %s\n' "$GREEN" "$RESET" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
info() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }

die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# --- guard rails -------------------------------------------------------------

preflight() {
    [[ "${EUID:-$(id -u)}" -ne 0 ]] || die "refusing to run as root. Use an unprivileged lab user."

    local b
    for b in awk sed grep sort mktemp; do
        command -v "$b" >/dev/null 2>&1 || die "missing required tool: $b"
    done

    # The lab must live under the invoking user's home, never anywhere system-wide.
    case "$LAB_ROOT" in
        "$HOME"/*) : ;;
        *) die "LAB_ROOT ($LAB_ROOT) must live under \$HOME. Refusing." ;;
    esac
    case "$LAB_ROOT" in
        */..*|"$HOME") die "LAB_ROOT ($LAB_ROOT) is unsafe. Refusing." ;;
    esac
}

# =============================================================================
#  LAB FIXTURE
# =============================================================================
#
#  data/offerings.csv is the reference table of Google Cloud infrastructure
#  offerings the advisor consults. Columns:
#
#    id            offering key used by the advisor
#    family        machine family or service class
#    profile       the workload shape it is built for
#    footprint     zonal | regional | multi-regional | dedicated
#    pricing       on-demand | spot | cud-1y | cud-3y | subscription
#    discount_pct  headline discount vs on-demand list price
#    interruptible yes|no  (can Google reclaim the capacity?)
#    sla_class     none | zonal | regional
#    note          one-line business rationale
#
#  Everything in this table is a *simulation fixture* with rounded, illustrative
#  figures. Real discounts, SLAs and machine-family specs change; the
#  authoritative numbers are always on cloud.google.com. The exam tests the
#  shape of the trade-off, not the third decimal place.

write_catalog_pristine() {
    cat > "$CATALOG" <<'CSV'
id,family,profile,footprint,pricing,discount_pct,interruptible,sla_class,note
e2-ondemand,E2 general-purpose,balanced day-to-day compute,zonal,on-demand,0,no,zonal,Lowest-cost general purpose; the default starting point
n2-ondemand,N2 general-purpose,balanced with higher per-core performance,zonal,on-demand,0,no,zonal,Step up from E2 when single-thread speed matters
n2-cud3y,N2 general-purpose,steady 24x7 baseline capacity,regional,cud-3y,55,no,regional,Committed use discount trades flexibility for price on predictable load
c3-ondemand,C3 compute-optimized,CPU-bound batch and HPC,zonal,on-demand,0,no,zonal,Highest per-core performance for compute-bound work
c3-spot,C3 compute-optimized,fault-tolerant CPU-bound batch,zonal,spot,70,yes,none,Spot VMs are preemptible; use only when work can be re-run
m3-ondemand,M3 memory-optimized,large in-memory databases like SAP HANA,zonal,on-demand,0,no,zonal,Memory-optimized for very large RAM-to-core ratios
a3-ondemand,A3 accelerator-optimized,GPU training and inference,zonal,on-demand,0,no,zonal,Attached GPUs for ML training and heavy inference
vmware-engine,Google Cloud VMware Engine,lift-and-shift of an existing VMware estate,dedicated,subscription,0,no,regional,Move VMware workloads unchanged; keep vSphere tooling and skills
bare-metal,Bare Metal Solution,licence-bound legacy engines such as Oracle,dedicated,subscription,0,no,regional,Dedicated hardware close to Google Cloud for workloads that cannot virtualize
CSV
}

#  data/workloads.csv is the set of business scenarios the advisor is asked to
#  place. These are written in the register the exam uses: a business outcome
#  and a constraint, not a list of vCPUs.

write_workloads() {
    cat > "$WORKLOADS" <<'CSV'
id,description,cpu_bound,memory_heavy,gpu,restartable,steady_24x7,vmware_estate,cannot_virtualize
w1,Nightly risk-model batch that can be re-run if a node disappears,yes,no,no,yes,no,no,no
w2,SAP HANA production database with a very large in-memory dataset,no,yes,no,no,yes,no,no
w3,Corporate intranet portal with flat predictable traffic all year,no,no,no,no,yes,no,no
w4,Datacenter exit: 400 existing VMware VMs must move in one quarter,no,no,no,no,yes,yes,no
w5,Legacy Oracle engine whose licence forbids running virtualized,no,no,no,no,yes,no,yes
w6,Model training job for the recommendations team,no,no,yes,no,no,no,no
CSV
}

#  data/expected.csv is the grader's answer key. The student never edits this;
#  --verify compares the advisor's output against it.

write_expected() {
    cat > "$EXPECTED" <<'CSV'
w1,c3-spot
w2,m3-ondemand
w3,n2-cud3y
w4,vmware-engine
w5,bare-metal
w6,a3-ondemand
CSV
}

#  bin/infra-advisor.sh is the program under repair. It reads a workload row and
#  emits the recommended offering id plus a one-line business justification.

write_advisor_pristine() {
    cat > "$ADVISOR" <<'ADV'
#!/usr/bin/env bash
#
# infra-advisor.sh — map a workload profile onto a Google Cloud infrastructure
# offering. Educational simulation for gcp-cdl topic 4.2; no cloud calls.
#
#   usage: infra-advisor.sh <workload-id>
#          infra-advisor.sh --all
#
set -o errexit
set -o nounset
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA="$(dirname -- "$HERE")/data"
CATALOG="$DATA/offerings.csv"
WORKLOADS="$DATA/workloads.csv"

lookup_field() {
    # lookup_field <csv> <key> <column-index>
    awk -F, -v key="$2" -v col="$3" '$1 == key { print $col }' "$1"
}

catalog_note() {
    awk -F, -v key="$1" '$1 == key { print $9 }' "$CATALOG"
}

catalog_has() {
    awk -F, -v key="$1" '$1 == key { found = 1 } END { exit !found }' "$CATALOG"
}

recommend() {
    local wid="$1" row
    row="$(awk -F, -v key="$wid" '$1 == key { print }' "$WORKLOADS")"
    [[ -n "$row" ]] || { printf 'unknown workload: %s\n' "$wid" >&2; return 2; }

    local cpu_bound memory_heavy gpu restartable steady vmware novirt
    IFS=, read -r _ _ cpu_bound memory_heavy gpu restartable steady vmware novirt <<< "$row"

    # ---- decision ladder ---------------------------------------------------
    # Order matters. The most constraining requirement wins first: a workload
    # that cannot virtualize has exactly one home, and a GPU requirement cannot
    # be satisfied by a cheaper family no matter how attractive the discount.

    if [[ "$novirt" == "yes" ]]; then
        printf '%s\n' "bare-metal"; return 0
    fi
    if [[ "$vmware" == "yes" ]]; then
        printf '%s\n' "vmware-engine"; return 0
    fi
    if [[ "$gpu" == "yes" ]]; then
        printf '%s\n' "a3-ondemand"; return 0
    fi
    if [[ "$memory_heavy" == "yes" ]]; then
        printf '%s\n' "m3-ondemand"; return 0
    fi
    if [[ "$cpu_bound" == "yes" && "$restartable" == "yes" ]]; then
        printf '%s\n' "c3-spot"; return 0
    fi
    if [[ "$cpu_bound" == "yes" ]]; then
        printf '%s\n' "c3-ondemand"; return 0
    fi
    if [[ "$steady" == "yes" ]]; then
        printf '%s\n' "n2-cud3y"; return 0
    fi
    printf '%s\n' "e2-ondemand"
}

explain() {
    local wid="$1" pick desc
    pick="$(recommend "$wid")"
    desc="$(lookup_field "$WORKLOADS" "$wid" 2)"
    if catalog_has "$pick"; then
        printf '%-4s %-16s %s\n' "$wid" "$pick" "$(catalog_note "$pick")"
    else
        printf '%-4s %-16s %s\n' "$wid" "$pick" "!! not present in offerings.csv"
    fi
    printf '     %s\n' "$desc"
}

main() {
    [[ $# -ge 1 ]] || { printf 'usage: %s <workload-id>|--all\n' "${0##*/}" >&2; exit 64; }
    if [[ "$1" == "--all" ]]; then
        awk -F, 'NR > 1 { print $1 }' "$WORKLOADS" | while read -r w; do explain "$w"; done
    else
        explain "$1"
    fi
}

main "$@"
ADV
    chmod 0755 "$ADVISOR"
}

# =============================================================================
#  BUILD
# =============================================================================

build_lab() {
    mkdir -p "$LAB_ROOT/bin" "$LAB_ROOT/data"
    write_catalog_pristine
    write_workloads
    write_expected
    write_advisor_pristine
    chmod 0444 "$EXPECTED"
}

# =============================================================================
#  THE BREAKAGE
# =============================================================================
#
#  Three independent faults are injected. Each one corresponds to a distinct
#  business-value misconception that the exam probes.
#
#    FAULT 1 — the Spot row is deleted from the catalog.
#              Business meaning: the organization has no cheap, interruptible
#              tier on its menu, so fault-tolerant batch gets billed at
#              on-demand rates forever. Symptom: w1 is recommended an offering
#              the catalog does not contain.
#
#    FAULT 2 — the committed-use row is rewritten as if a 3-year commitment
#              were interruptible with no SLA and no discount.
#              Business meaning: CUD and Spot have been conflated. They are
#              opposite instruments — one buys a *price* by promising steady
#              spend, the other buys a *discount* by surrendering
#              availability. Symptom: the advisor recommends a "discount"
#              that is 0% and carries no SLA.
#
#    FAULT 3 — the decision ladder is reordered so the discount rule fires
#              before the hard capability rules.
#              Business meaning: cost optimization has been placed above
#              technical feasibility. Symptom: the memory-optimized and
#              lift-and-shift workloads are all pushed onto a committed
#              general-purpose SKU that physically cannot host them.

inject_faults() {
    # FAULT 1 — remove the Spot offering entirely.
    sed -i '/^c3-spot,/d' "$CATALOG"

    # FAULT 2 — corrupt the committed-use row into a Spot-shaped lie.
    sed -i 's|^n2-cud3y,.*$|n2-cud3y,N2 general-purpose,steady 24x7 baseline capacity,zonal,spot,0,yes,none,Committed use is basically the same as Spot; both just make VMs cheaper|' "$CATALOG"

    # FAULT 3 — hoist the steady/CUD branch above every capability branch.
    #           Done by rewriting the ladder region of the advisor.
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/advisor.XXXXXX")"
    awk '
        /^    if \[\[ "\$novirt" == "yes" \]\]; then$/ && !done {
            print "    if [[ \"$steady\" == \"yes\" ]]; then"
            print "        printf '\''%s\\n'\'' \"n2-cud3y\"; return 0"
            print "    fi"
            done = 1
        }
        { print }
    ' "$ADVISOR" > "$tmp"
    cat "$tmp" > "$ADVISOR"
    rm -f "$tmp"

    printf 'broken\n' > "$STATE"
    printf '0\n' > "$HINT_COUNTER"
}

# =============================================================================
#  BRIEFING
# =============================================================================

print_briefing() {
    head1 "Google Cloud Digital Leader — topic 4.2 break & fix"
    say "  Infrastructure offerings: functionality, business use cases, business value"
    say "  Exam guide: https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf"

    head1 "Scenario"
    cat <<'EOF'
  You have inherited a small internal tool your platform team calls the
  "infra advisor". Given a workload's business characteristics, it recommends
  which Google Cloud infrastructure offering the team should place it on, and
  prints the one-line justification finance will see in the design review.

  It used to be correct. Someone edited it after a cost-cutting meeting, and
  now the recommendations are wrong in ways that would be expensive, or in one
  case simply impossible to deploy.
EOF

    head1 "Lab location"
    info "$LAB_ROOT"
    info "  bin/infra-advisor.sh   <- the decision engine (you may edit)"
    info "  data/offerings.csv     <- the offering catalog  (you may edit)"
    info "  data/workloads.csv     <- the scenarios         (do not edit)"
    info "  data/expected.csv      <- the answer key        (read-only)"

    head1 "Symptoms you will see"
    cat <<'EOF'
  Run the advisor over every workload:

      $LAB_ROOT/bin/infra-advisor.sh --all

  Three things are visibly wrong:

    1. Almost every steady-state workload — including the SAP HANA database,
       the VMware datacenter exit and the Oracle bare-metal workload — comes
       back recommending the same committed general-purpose SKU. A memory-
       optimized database cannot run on it, and a VMware estate cannot be
       lifted onto it at all.

    2. The nightly re-runnable batch job is recommended an offering that is
       flagged "!! not present in offerings.csv". The advisor is naming an
       offering the catalog no longer knows about.

    3. The committed-use row in the catalog now claims a 0% discount, marks
       itself interruptible, and carries sla_class "none" — while its own
       justification text tells the reader that committed use and Spot are
       "basically the same".
EOF

    head1 "What you must achieve"
    cat <<'EOF'
  Repair the catalog and the decision logic until, for all six workloads,
  the advisor recommends the offering the business case actually calls for:

    w1  re-runnable CPU-bound nightly batch      -> the interruptible, deeply
                                                    discounted compute-optimized tier
    w2  SAP HANA, very large in-memory dataset   -> memory-optimized
    w3  flat, predictable 24x7 intranet portal   -> committed-use discount
    w4  400 VMware VMs, one-quarter deadline     -> the lift-and-shift service
                                                    that keeps vSphere tooling
    w5  Oracle engine that cannot virtualize     -> dedicated hardware
    w6  ML training job                          -> accelerator-optimized

  And the catalog must once again describe those instruments honestly:
  the interruptible tier marked interruptible with no SLA, the committed tier
  marked non-interruptible with a real discount and a real SLA class.

  Grade yourself:   ./break-and-fix-lab.sh --verify
  Stuck:            ./break-and-fix-lab.sh --hint
  Start over:       ./break-and-fix-lab.sh --reset
EOF

    head1 "The business question underneath"
    cat <<'EOF'
  Every fault here is one sentence of exam reasoning:

    * Spot VMs buy a discount by surrendering availability. Google can reclaim
      the capacity at any time. That is acceptable for a batch job that can be
      re-run and unacceptable for a production database.

    * Committed use discounts buy a lower price by promising steady spend over
      one or three years. Availability is untouched; flexibility is what you
      give up. They are the correct instrument for the workload whose demand
      curve is flat.

    * Machine families encode a physical shape — cores, memory ratio,
      accelerators. No pricing instrument can make a general-purpose SKU hold
      an in-memory database it does not have the memory for.

    * VMware Engine and Bare Metal Solution exist because some workloads move
      faster, or only move at all, when they do not have to be rewritten. Their
      business value is time-to-exit from a datacenter and preserved licensing,
      not the per-hour price.
EOF
    printf '\n'
}

# =============================================================================
#  VERIFY
# =============================================================================

verify() {
    [[ -f "$STATE" ]] || die "no lab found at $LAB_ROOT. Run without arguments first."

    head1 "Verification"

    local failures=0

    # --- part 1: routing correctness ----------------------------------------
    say "  Routing — does each workload land on the right offering?"
    local wid want got
    while IFS=, read -r wid want; do
        [[ -n "$wid" ]] || continue
        if ! got="$("$ADVISOR" "$wid" 2>/dev/null | awk 'NR == 1 { print $2 }')"; then
            bad "$wid — advisor exited non-zero"
            failures=$((failures + 1))
            continue
        fi
        if [[ "$got" == "$want" ]]; then
            ok "$wid -> $got"
        else
            bad "$wid -> $got   (expected $want)"
            failures=$((failures + 1))
        fi
    done < "$EXPECTED"

    # --- part 2: catalog integrity ------------------------------------------
    say ""
    say "  Catalog — do the offerings describe themselves honestly?"

    local spot_row cud_row
    spot_row="$(awk -F, '$1 == "c3-spot"' "$CATALOG" || true)"
    cud_row="$(awk -F, '$1 == "n2-cud3y"' "$CATALOG" || true)"

    if [[ -z "$spot_row" ]]; then
        bad "c3-spot is missing from offerings.csv"
        failures=$((failures + 1))
    else
        local s_pricing s_disc s_int s_sla
        s_pricing="$(cut -d, -f5 <<< "$spot_row")"
        s_disc="$(cut -d, -f6 <<< "$spot_row")"
        s_int="$(cut -d, -f7 <<< "$spot_row")"
        s_sla="$(cut -d, -f8 <<< "$spot_row")"
        [[ "$s_pricing" == "spot" ]] \
            && ok "c3-spot pricing model is spot" \
            || { bad "c3-spot pricing should be 'spot', found '$s_pricing'"; failures=$((failures + 1)); }
        [[ "$s_int" == "yes" ]] \
            && ok "c3-spot is correctly marked interruptible" \
            || { bad "c3-spot must be interruptible=yes — Google can reclaim Spot capacity"; failures=$((failures + 1)); }
        [[ "$s_sla" == "none" ]] \
            && ok "c3-spot carries no availability SLA" \
            || { bad "c3-spot sla_class must be 'none'"; failures=$((failures + 1)); }
        if [[ "$s_disc" =~ ^[0-9]+$ ]] && (( s_disc >= 60 )); then
            ok "c3-spot discount reflects the Spot trade-off (${s_disc}%)"
        else
            bad "c3-spot discount_pct should express a deep discount (>=60), found '$s_disc'"
            failures=$((failures + 1))
        fi
    fi

    if [[ -z "$cud_row" ]]; then
        bad "n2-cud3y is missing from offerings.csv"
        failures=$((failures + 1))
    else
        local c_pricing c_disc c_int c_sla c_note
        c_pricing="$(cut -d, -f5 <<< "$cud_row")"
        c_disc="$(cut -d, -f6 <<< "$cud_row")"
        c_int="$(cut -d, -f7 <<< "$cud_row")"
        c_sla="$(cut -d, -f8 <<< "$cud_row")"
        c_note="$(cut -d, -f9 <<< "$cud_row")"
        [[ "$c_pricing" == "cud-3y" ]] \
            && ok "n2-cud3y pricing model is a 3-year commitment" \
            || { bad "n2-cud3y pricing should be 'cud-3y', found '$c_pricing'"; failures=$((failures + 1)); }
        [[ "$c_int" == "no" ]] \
            && ok "n2-cud3y is correctly NOT interruptible" \
            || { bad "a committed-use VM is not interruptible — set interruptible=no"; failures=$((failures + 1)); }
        [[ "$c_sla" != "none" ]] \
            && ok "n2-cud3y carries an availability SLA class ($c_sla)" \
            || { bad "committing spend does not remove the SLA — sla_class must not be 'none'"; failures=$((failures + 1)); }
        if [[ "$c_disc" =~ ^[0-9]+$ ]] && (( c_disc > 0 )); then
            ok "n2-cud3y expresses a real discount (${c_disc}%)"
        else
            bad "n2-cud3y discount_pct must be greater than 0 — that is the whole point of a commitment"
            failures=$((failures + 1))
        fi
        if grep -qi 'same as spot' <<< "$c_note"; then
            bad "the n2-cud3y justification still tells the reader CUD and Spot are the same thing"
            failures=$((failures + 1))
        else
            ok "n2-cud3y justification no longer conflates commitment with preemption"
        fi
    fi

    # --- part 3: precedence -------------------------------------------------
    say ""
    say "  Decision order — does capability outrank cost?"
    if awk '/\$steady/ { s = NR } /\$novirt/ { n = NR } END { exit !(s > n) }' "$ADVISOR"; then
        ok "the cost/commitment branch is evaluated after the capability branches"
    else
        bad "the steady/CUD branch still fires before the hard capability checks"
        failures=$((failures + 1))
    fi

    say ""
    if (( failures == 0 )); then
        printf '%s  All checks pass. The advisor is sound again.%s\n\n' "$GREEN$BOLD" "$RESET"
        printf 'fixed\n' > "$STATE"
        cat <<'EOF'
  Say back, in one sentence each, before you move on:

    - Which instrument do you use for a workload with flat 24x7 demand,
      and what exactly did you give up to get the discount?
    - Which instrument do you use for a re-runnable nightly job, and what
      exactly did you give up?
    - Why can neither instrument rescue a workload placed on the wrong
      machine family?
    - What is the business value of VMware Engine that a cheaper VM cannot
      deliver?

EOF
        return 0
    fi

    printf '%s  %d check(s) still failing.%s Run --hint if you want a nudge.\n\n' \
        "$RED$BOLD" "$failures" "$RESET"
    return 1
}

# =============================================================================
#  HINTS
# =============================================================================

hint() {
    [[ -f "$HINT_COUNTER" ]] || die "no lab found at $LAB_ROOT. Run without arguments first."
    local n
    n="$(cat "$HINT_COUNTER")"
    n=$((n + 1))
    printf '%s\n' "$n" > "$HINT_COUNTER"

    head1 "Hint $n"
    case "$n" in
        1) cat <<'EOF'
  Read the advisor's decision ladder top to bottom and ask, at each rung:
  "is this a question about what the workload CAN run on, or about what it
  SHOULD cost?" One of those two categories has to be settled first. The
  current order gets it backwards.
EOF
        ;;
        2) cat <<'EOF'
  Diff the two rows in offerings.csv that describe discounted capacity.
  One of them is claiming both properties at once: an interruptible VM with
  no SLA *and* a commitment-shaped id. Those are two different products.

    - Spot         : deep discount, Google may reclaim it, no SLA.
    - Committed use: moderate discount, normal availability, you owe the
                     spend for 1 or 3 years whether you use it or not.
EOF
        ;;
        3) cat <<'EOF'
  The advisor names an offering for w1 that the catalog cannot resolve — look
  at the "!! not present in offerings.csv" marker. Something was deleted from
  offerings.csv rather than fixed. Restore that row with honest values:
  pricing 'spot', interruptible 'yes', sla_class 'none', and a discount deep
  enough to justify accepting preemption.
EOF
        ;;
        *) cat <<'EOF'
  You have taken every hint. The full worked solution is at the bottom of
  break-and-fix-lab.sh, in the commented SOLUTION block. Read it, apply it,
  then run --verify and make sure you can explain each edit in business terms
  rather than as a text substitution.
EOF
        ;;
    esac
    printf '\n'
}

# =============================================================================
#  ENTRY POINT
# =============================================================================

main() {
    preflight

    case "${1:-}" in
        --verify)  verify ;;
        --hint)    hint ;;
        --reset)
            [[ -d "$LAB_ROOT" ]] || die "nothing to reset at $LAB_ROOT"
            build_lab
            inject_faults
            say ""
            ok "lab reset to the pristine broken state at $LAB_ROOT"
            say ""
            ;;
        --destroy)
            if [[ -d "$LAB_ROOT" ]]; then
                chmod u+w "$EXPECTED" 2>/dev/null || true
                rm -rf -- "$LAB_ROOT"
                ok "removed $LAB_ROOT"
            else
                info "nothing to remove at $LAB_ROOT"
            fi
            ;;
        --help|-h)
            sed -n '2,60p' "$0"
            ;;
        "")
            if [[ -f "$STATE" ]]; then
                warn "a lab already exists at $LAB_ROOT — leaving your work in place"
                info "use --reset to start over, --verify to grade, --destroy to remove"
                print_briefing
            else
                build_lab
                inject_faults
                print_briefing
            fi
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac
}

main "$@"

# =============================================================================
#  SOLUTION — worked, step by step
# =============================================================================
#
#  Do not read this until you have run --verify at least twice and taken the
#  hints. The value of the lab is in reasoning about the trade-offs, not in
#  applying the diff.
#
# -----------------------------------------------------------------------------
#  STEP 0 — see the damage
# -----------------------------------------------------------------------------
#
#      cd ~/gcdl-lab-4.2
#      ./bin/infra-advisor.sh --all
#
#  Broken output looks like this. Note that five of six workloads collapse onto
#  the same recommendation, and w1 names an offering that does not resolve:
#
#      w1   c3-spot          !! not present in offerings.csv
#           Nightly risk-model batch that can be re-run if a node disappears
#      w2   n2-cud3y         Committed use is basically the same as Spot; both just make VMs cheaper
#           SAP HANA production database with a very large in-memory dataset
#      w3   n2-cud3y         Committed use is basically the same as Spot; both just make VMs cheaper
#           Corporate intranet portal with flat predictable traffic all year
#      w4   n2-cud3y         Committed use is basically the same as Spot; both just make VMs cheaper
#           Datacenter exit: 400 existing VMware VMs must move in one quarter
#      w5   n2-cud3y         Committed use is basically the same as Spot; both just make VMs cheaper
#           Legacy Oracle engine whose licence forbids running virtualized
#      w6   n2-cud3y         Committed use is basically the same as Spot; both just make VMs cheaper
#           Model training job for the recommendations team
#
#  Read that as a business failure, not a bug report: the tool is telling the
#  design review to put an SAP HANA database, a VMware estate and an Oracle
#  bare-metal workload on the same committed general-purpose SKU, because
#  someone taught it that the cheapest answer is always the answer.
#
# -----------------------------------------------------------------------------
#  STEP 1 — restore the Spot offering to the catalog  (FAULT 1)
# -----------------------------------------------------------------------------
#
#  Why it matters: w1 is a nightly risk model that "can be re-run if a node
#  disappears". That single clause is the whole Spot business case. Spot VMs
#  are excess Compute Engine capacity sold at a deep discount on the condition
#  that Google may reclaim them with 30 seconds' notice and no availability
#  SLA. A workload that can absorb an interruption converts that condition into
#  money; a workload that cannot must never be placed there.
#  https://cloud.google.com/compute/docs/instances/spot
#
#  Append the row back to data/offerings.csv:
#
#      cat >> data/offerings.csv <<'ROW'
#      c3-spot,C3 compute-optimized,fault-tolerant CPU-bound batch,zonal,spot,70,yes,none,Spot VMs are preemptible; use only when work can be re-run
#      ROW
#
#  Verify the row parses into the columns you expect:
#
#      awk -F, '$1 == "c3-spot" { print "pricing="$5, "disc="$6, "interruptible="$7, "sla="$8 }' data/offerings.csv
#      pricing=spot disc=70 interruptible=yes sla=none
#
# -----------------------------------------------------------------------------
#  STEP 2 — un-conflate committed use with Spot  (FAULT 2)
# -----------------------------------------------------------------------------
#
#  Why it matters: this is the single most common Digital Leader confusion in
#  the cost-optimization area. Both instruments lower the bill, so candidates
#  file them together. They are opposites in what they cost you:
#
#      Spot            you surrender AVAILABILITY.  Price falls sharply.
#                      Google may reclaim the VM. No SLA. Right for batch,
#                      CI runners, render farms, stateless scale-out tiers.
#
#      Committed use   you surrender FLEXIBILITY.   Price falls moderately.
#                      You commit to a level of spend for 1 or 3 years and owe
#                      it whether or not you consume it. Availability and SLA
#                      are unchanged. Right for the flat 24x7 baseline you
#                      already know you will run.
#      https://cloud.google.com/compute/docs/instances/signing-up-committed-use-discounts
#
#      Sustained use   applied automatically, no commitment, for instances that
#                      run a large share of the month. Nothing to sign.
#
#  Rewrite the n2-cud3y row so it states its own terms honestly:
#
#      sed -i 's|^n2-cud3y,.*$|n2-cud3y,N2 general-purpose,steady 24x7 baseline capacity,regional,cud-3y,55,no,regional,Committed use discount trades flexibility for price on predictable load|' data/offerings.csv
#
#  Confirm:
#
#      awk -F, '$1 == "n2-cud3y" { print "pricing="$5, "disc="$6, "interruptible="$7, "sla="$8 }' data/offerings.csv
#      pricing=cud-3y disc=55 interruptible=no sla=regional
#
# -----------------------------------------------------------------------------
#  STEP 3 — put capability back above cost in the ladder  (FAULT 3)
# -----------------------------------------------------------------------------
#
#  Why it matters: pricing instruments are modifiers on a placement decision;
#  they cannot be the placement decision. A committed-use discount on an N2
#  general-purpose SKU does not give that SKU the memory ratio SAP HANA needs,
#  does not give it an attached GPU, does not make it a vSphere cluster, and
#  does not make it dedicated hardware for a licence that forbids
#  virtualization. Evaluating "is this workload steady?" before "can this
#  workload physically run here?" produces recommendations that are not merely
#  expensive but undeployable.
#
#  Open bin/infra-advisor.sh and find the injected block at the top of the
#  ladder:
#
#      if [[ "$steady" == "yes" ]]; then
#          printf '%s\n' "n2-cud3y"; return 0
#      fi
#      if [[ "$novirt" == "yes" ]]; then
#      ...
#
#  Delete those three lines from the top. The steady/CUD branch already exists
#  further down, in its correct position — second to last, just above the
#  general-purpose default. The repaired ladder reads:
#
#      novirt        -> bare-metal          # licence forbids virtualization: one option only
#      vmware_estate -> vmware-engine       # lift and shift, keep vSphere tooling
#      gpu           -> a3-ondemand         # accelerator requirement is physical
#      memory_heavy  -> m3-ondemand         # memory ratio is physical
#      cpu_bound + restartable -> c3-spot   # now cost may speak: interruption is affordable
#      cpu_bound     -> c3-ondemand         # CPU-bound but must not be interrupted
#      steady        -> n2-cud3y            # flat demand: buy the commitment
#      (default)     -> e2-ondemand         # start cheap and general purpose
#
#  A one-liner that removes exactly the injected block:
#
#      perl -0pi -e 's|    if \[\[ "\$steady" == "yes" \]\]; then\n        printf .%s\\n. "n2-cud3y"; return 0\n    fi\n(?=    if \[\[ "\$novirt")||' bin/infra-advisor.sh
#
#  If perl is not available, edit the file by hand — it is three lines. Then
#  check the syntax before running it:
#
#      bash -n bin/infra-advisor.sh && echo "syntax ok"
#      syntax ok
#
# -----------------------------------------------------------------------------
#  STEP 4 — confirm
# -----------------------------------------------------------------------------
#
#      ./bin/infra-advisor.sh --all
#
#      w1   c3-spot          Spot VMs are preemptible; use only when work can be re-run
#           Nightly risk-model batch that can be re-run if a node disappears
#      w2   m3-ondemand      Memory-optimized for very large RAM-to-core ratios
#           SAP HANA production database with a very large in-memory dataset
#      w3   n2-cud3y         Committed use discount trades flexibility for price on predictable load
#           Corporate intranet portal with flat predictable traffic all year
#      w4   vmware-engine    Move VMware workloads unchanged; keep vSphere tooling and skills
#           Datacenter exit: 400 existing VMware VMs must move in one quarter
#      w5   bare-metal       Dedicated hardware close to Google Cloud for workloads that cannot virtualize
#           Legacy Oracle engine whose licence forbids running virtualized
#      w6   a3-ondemand      Attached GPUs for ML training and heavy inference
#           Model training job for the recommendations team
#
#      ./break-and-fix-lab.sh --verify
#
#      Verification
#        Routing — does each workload land on the right offering?
#        [PASS] w1 -> c3-spot
#        [PASS] w2 -> m3-ondemand
#        [PASS] w3 -> n2-cud3y
#        [PASS] w4 -> vmware-engine
#        [PASS] w5 -> bare-metal
#        [PASS] w6 -> a3-ondemand
#
#        Catalog — do the offerings describe themselves honestly?
#        [PASS] c3-spot pricing model is spot
#        [PASS] c3-spot is correctly marked interruptible
#        [PASS] c3-spot carries no availability SLA
#        [PASS] c3-spot discount reflects the Spot trade-off (70%)
#        [PASS] n2-cud3y pricing model is a 3-year commitment
#        [PASS] n2-cud3y is correctly NOT interruptible
#        [PASS] n2-cud3y carries an availability SLA class (regional)
#        [PASS] n2-cud3y expresses a real discount (55%)
#        [PASS] n2-cud3y justification no longer conflates commitment with preemption
#
#        Decision order — does capability outrank cost?
#        [PASS] the cost/commitment branch is evaluated after the capability branches
#
#        All checks pass. The advisor is sound again.
#
# -----------------------------------------------------------------------------
#  STEP 5 — the exam-level takeaways
# -----------------------------------------------------------------------------
#
#  1. Machine families are a statement about physics. General-purpose (E2, N2)
#     for balanced everyday work; compute-optimized (C3) for CPU-bound batch
#     and HPC; memory-optimized (M3) for very large in-memory datasets such as
#     SAP HANA; accelerator-optimized (A3) for GPU training and inference.
#     Choosing the family is the first decision and no discount overrides it.
#     https://cloud.google.com/compute/docs/machine-resource
#
#  2. Provisioning model is a statement about risk tolerance. Spot trades
#     availability for a deep discount and suits anything re-runnable.
#     On-demand pays full price for full flexibility.
#     https://cloud.google.com/compute/docs/instances/spot
#
#  3. Commitment is a statement about forecasting confidence. Committed use
#     discounts trade flexibility for a lower price over 1 or 3 years and suit
#     a baseline you are certain of; sustained use discounts arrive
#     automatically for instances that run most of the month, with nothing to
#     sign. The exam phrasing to watch for is "predictable", "steady",
#     "always on", "flat".
#     https://cloud.google.com/compute/docs/instances/signing-up-committed-use-discounts
#
#  4. Footprint is a statement about blast radius. A zone is one failure
#     domain; a region spans zones; multi-regional spans regions. Spreading a
#     managed instance group across zones and letting autohealing replace
#     unhealthy VMs is how availability is bought at the infrastructure layer —
#     not by buying a bigger VM.
#     https://cloud.google.com/compute/docs/regions-zones
#     https://cloud.google.com/compute/docs/instance-groups/autohealing-instances-in-migs
#
#  5. Some offerings exist to buy TIME, not cycles. Google Cloud VMware Engine
#     runs your existing VMware estate on Google Cloud infrastructure so a
#     datacenter exit does not become a rewrite project, preserving vSphere
#     tooling, runbooks and staff skills. Bare Metal Solution provides
#     dedicated, non-virtualized hardware adjacent to Google Cloud for engines
#     whose licensing or support terms forbid virtualization — typically
#     Oracle. In both cases the business value is migration speed and
#     preserved licensing, and a per-hour price comparison against a plain VM
#     measures the wrong thing.
#     https://cloud.google.com/vmware-engine/docs/overview
#     https://cloud.google.com/bare-metal/docs/bms-overview
#
#  6. The recurring exam pattern: a scenario gives you one hard constraint
#     (cannot virtualize, must move in 90 days, holds 12 TB in memory, needs
#     GPUs) and one soft preference (reduce cost). Satisfy the hard constraint
#     first, then apply the cheapest pricing instrument compatible with it.
#     Answers that lead with the discount are the distractors.
#
#  Clean up when you are done:
#
#      ./break-and-fix-lab.sh --destroy
#
# =============================================================================