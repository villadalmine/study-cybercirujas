#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-3 306  (exam 306-300, version 3.0)
#  Topic 363.2 — Ceph Storage Clusters      (exam weight: 13.33)
#
#  BREAK & FIX lab exercise
#  ------------------------------------------------------------------------
#  This script injects ONE controlled, fully reversible fault into a running
#  Ceph cluster so you can practise diagnosing and repairing an OSD-level
#  outage the way it happens in production.
#
#  NOTHING IS DESTROYED. No pool is deleted, no OSD is purged, no object is
#  removed, no CRUSH rule is rewritten. The break is two operations that a
#  Ceph administrator issues (and undoes) every day:
#
#     1. it sets the cluster-wide OSDMap 'noup' flag, and
#     2. it stops one OSD daemon.
#
#  The pairing is deliberately instructive: while 'noup' is set, the reflex
#  "just restart the OSD" does NOT bring the cluster back to health. You are
#  forced to read the OSDMap flags first — exactly the reasoning the exam
#  expects around 'ceph osd set/unset' and 'ceph health detail'.
#
#  RUN THIS ONLY ON A DISPOSABLE LAB VM.
#  It expects a throwaway single-host cephadm or package-based cluster and a
#  working admin keyring (i.e. 'ceph -s' already succeeds as this user).
#
#  Usage:
#     sudo ./break_fix.sh              # inject the fault (default)
#     sudo ./break_fix.sh break        # same as above
#     sudo ./break_fix.sh status       # show current cluster health
#     sudo ./break_fix.sh restore      # auto-undo the fault (use only after
#                                       # you have solved it yourself!)
#
#  Reference (official sources):
#     LPI exam 306 objectives ....... https://www.lpi.org/our-certifications/exam-306-objectives/
#     OSD troubleshooting ........... https://docs.ceph.com/en/latest/rados/troubleshooting/troubleshooting-osd/
#     OSDMap flags / health checks .. https://docs.ceph.com/en/latest/rados/operations/health-checks/#osdmap-flags
#     Operating the cluster ......... https://docs.ceph.com/en/latest/rados/operations/operating/
#     ceph osd command reference .... https://docs.ceph.com/en/latest/man/8/ceph/
# =============================================================================

set -euo pipefail

STATE_DIR="/var/tmp/lpic3-363.2-breakfix"
BROKEN_FLAG="noup"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "----------------------------------------------------------------------"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_ceph() {
    command -v ceph >/dev/null 2>&1 || die "the 'ceph' CLI is not installed on this host."
    if ! ceph -s >/dev/null 2>&1; then
        die "'ceph -s' failed. Run as a user with a valid admin keyring (usually root)."
    fi
}

# Locate the systemd unit that runs a given OSD id, covering both the
# cephadm layout (ceph-<fsid>@osd.<id>.service) and the package layout
# (ceph-osd@<id>.service).
osd_unit() {
    local id="$1" fsid unit
    fsid="$(ceph fsid 2>/dev/null || true)"
    for unit in "ceph-${fsid}@osd.${id}.service" "ceph-osd@${id}.service"; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            printf '%s\n' "$unit"; return 0
        fi
    done
    # Last resort: match any loaded service whose name ends in osd.<id>.service
    unit="$(systemctl list-units --all --type=service --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -E "osd\.${id}\.service$" | head -n1 || true)"
    [[ -n "$unit" ]] && { printf '%s\n' "$unit"; return 0; }
    return 1
}

# Print the ids of every OSD currently 'up', one per line.
up_osds() {
    ceph osd dump 2>/dev/null \
        | awk '$1 ~ /^osd\.[0-9]+$/ && $2 == "up" { split($1,a,"."); print a[2] }'
}

show_status() {
    hr; say "Current cluster status:"; hr
    ceph -s || true
    say ""
    say "OSD tree:"
    ceph osd tree || true
    say ""
    say "OSDMap flags in effect:"
    ceph osd dump 2>/dev/null | grep -E '^flags' || say "flags (none)"
}

# ----------------------------------------------------------------------------
# break — inject the fault
# ----------------------------------------------------------------------------
do_break() {
    require_ceph
    mkdir -p "$STATE_DIR"

    # Refuse to run twice in a row.
    if [[ -f "$STATE_DIR/broken_osd.id" ]]; then
        die "a break is already active (see $STATE_DIR). Solve it, or run: $0 restore"
    fi

    # Safety confirmation.
    if [[ "${LAB_CONFIRM:-}" != "I-KNOW-THIS-IS-A-DISPOSABLE-LAB" ]]; then
        say "This will degrade a live Ceph cluster on THIS host."
        say "Type the word DISPOSABLE to confirm this is a throwaway lab VM."
        read -r -p "> " answer
        [[ "$answer" == "DISPOSABLE" ]] || die "aborted by user."
    fi

    # Choose a victim OSD (the first one that is up).
    mapfile -t CANDIDATES < <(up_osds)
    [[ "${#CANDIDATES[@]}" -ge 1 ]] || die "no OSD is currently 'up' — nothing to break."
    if [[ "${#CANDIDATES[@]}" -eq 1 ]]; then
        say "NOTE: this cluster has a single up OSD; some PGs will go inactive"
        say "      until you repair it. That is expected in this exercise."
    fi
    local OSD_ID="${CANDIDATES[0]}"

    # Record pre-break state so the fault is auditable and reversible.
    ceph -s        > "$STATE_DIR/ceph-s.before.txt"    2>&1 || true
    ceph osd tree  > "$STATE_DIR/osd-tree.before.txt"  2>&1 || true
    ceph osd dump  > "$STATE_DIR/osd-dump.before.txt"  2>&1 || true
    printf '%s\n' "$OSD_ID" > "$STATE_DIR/broken_osd.id"

    local UNIT
    UNIT="$(osd_unit "$OSD_ID")" \
        || die "could not locate the systemd unit for osd.${OSD_ID}."
    printf '%s\n' "$UNIT" > "$STATE_DIR/broken_osd.unit"

    hr; say "Injecting fault..."; hr
    say "[1/2] Setting the cluster-wide OSDMap flag '${BROKEN_FLAG}'."
    ceph osd set "$BROKEN_FLAG"
    say "[2/2] Stopping daemon for osd.${OSD_ID}  (unit: ${UNIT})."
    systemctl stop "$UNIT"

    # Give the MONs a moment to notice the daemon is gone.
    sleep 5

    hr
    say "############################  BROKEN  ############################"
    hr
    say "SCENARIO"
    say "  Overnight your monitoring paged: the Ceph cluster left HEALTH_OK."
    say "  One OSD is down and, critically, it will NOT rejoin on its own."
    say ""
    say "SYMPTOMS YOU SHOULD OBSERVE  (run these to confirm):"
    say "  \$ ceph -s"
    say "      health: HEALTH_WARN"
    say "        - 1 osds down"
    say "        - <flag(s)> set"
    say "        - Degraded data redundancy: ... pgs undersized/degraded"
    say "  \$ ceph health detail"
    say "      OSD_DOWN         osd.${OSD_ID} is down"
    say "      OSDMAP_FLAGS     <one or more> flag(s) set"
    say "  \$ ceph osd tree"
    say "      osd.${OSD_ID}   ... down"
    say ""
    say "YOUR GOAL"
    say "  Return the cluster to HEALTH_OK with all OSDs 'up' and 'in',"
    say "  and no lingering OSDMap flags. Beware: simply restarting the"
    say "  daemon is NOT enough — inspect the OSDMap flags first and reason"
    say "  about why a restarted OSD would still refuse to boot."
    say ""
    say "  Verify success with:   ceph -s   (expect: HEALTH_OK)"
    say ""
    say "  When you want to compare against the reference procedure, read the"
    say "  commented SOLUTION block at the bottom of this script, or run:"
    say "     $0 restore"
    hr
}

# ----------------------------------------------------------------------------
# restore — automatic fix (for verification / reset between attempts)
# ----------------------------------------------------------------------------
do_restore() {
    require_ceph
    [[ -f "$STATE_DIR/broken_osd.id" ]] || die "no active break recorded in $STATE_DIR."

    local OSD_ID UNIT
    OSD_ID="$(cat "$STATE_DIR/broken_osd.id")"
    UNIT="$(cat "$STATE_DIR/broken_osd.unit" 2>/dev/null || osd_unit "$OSD_ID")"

    hr; say "Restoring..."; hr
    say "[1/2] Clearing the OSDMap flag '${BROKEN_FLAG}'."
    ceph osd unset "$BROKEN_FLAG" || true
    say "[2/2] Starting daemon for osd.${OSD_ID}  (unit: ${UNIT})."
    systemctl start "$UNIT" || true

    say "Waiting for the OSD to boot and PGs to recover..."
    for _ in $(seq 1 30); do
        if ceph health 2>/dev/null | grep -q HEALTH_OK; then break; fi
        sleep 5
    done

    rm -f "$STATE_DIR/broken_osd.id" "$STATE_DIR/broken_osd.unit"
    show_status
    hr
    say "Restore attempted. If health is not yet HEALTH_OK, allow recovery"
    say "I/O to finish and re-check with:  ceph -s"
    hr
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
case "${1:-break}" in
    break)   do_break   ;;
    restore) do_restore ;;
    status)  require_ceph; show_status ;;
    *)       die "unknown action '$1' (use: break | restore | status)" ;;
esac

# =============================================================================
#  SOLUTION — step-by-step (do not read until you have tried it yourself)
# =============================================================================
#
#  1. Confirm the overall picture. Never fix blind.
#
#        ceph -s
#
#     You will see HEALTH_WARN with three distinct signals:
#        - "1 osds down"                              -> a daemon is gone
#        - "noup flag(s) set"                         -> an OSDMap flag is set
#        - "Degraded data redundancy: ... pgs ..."    -> the consequence
#
#  2. Read the detailed health checks. This is the step most students skip,
#     and it is exactly what separates a correct fix from guesswork.
#
#        ceph health detail
#
#     Expected lines:
#        [WRN] OSD_DOWN: 1 osds down
#              osd.<id> (root=default,host=<host>) is down
#        [WRN] OSDMAP_FLAGS: noup flag(s) set
#
#  3. Identify WHICH OSD is down and on which host it lives.
#
#        ceph osd tree
#        # look for the line whose STATUS column reads 'down'
#        ceph osd find <id>          # host + CRUSH location of that OSD
#
#  4. Understand the trap. 'noup' tells the monitors to refuse to mark any
#     OSD 'up', even a perfectly healthy one that (re)starts. So if you only
#     restart the daemon now, it will boot, try to join, and stay 'down' —
#     you would wrongly conclude the disk is dead. Clear the flag FIRST:
#
#        ceph osd unset noup
#
#     Confirm the flag is gone:
#
#        ceph osd dump | grep flags
#
#  5. Now bring the OSD daemon back. The unit name depends on the deployment:
#
#        # cephadm / containerized (fsid-scoped instance unit):
#        ceph fsid                                   # note the cluster fsid
#        systemctl start ceph-<fsid>@osd.<id>.service
#        #   or, the orchestrator-native way:
#        ceph orch daemon start osd.<id>
#
#        # package-based (legacy) deployment:
#        systemctl start ceph-osd@<id>.service
#
#  6. Watch it rejoin and recover. The OSD should transition to 'up'/'in'
#     and the degraded/undersized PGs should heal as data re-replicates.
#
#        ceph osd tree                 # STATUS should now read 'up'
#        ceph -w                       # live event stream; Ctrl-C to exit
#        ceph -s                       # repeat until: health: HEALTH_OK
#
#  7. If the OSD boots but immediately goes 'down' again, the fault was NOT
#     the flag alone — inspect the daemon itself:
#
#        systemctl status ceph-*@osd.<id>.service
#        journalctl -u ceph-*@osd.<id>.service --no-pager -n 100
#        ceph daemon osd.<id> status          # from the OSD's own host
#
#     (In THIS exercise that will not happen: the disk is intact, so once the
#      flag is cleared and the daemon is started the cluster returns to
#      HEALTH_OK.)
#
#  ONE-LINER EQUIVALENT of the fix performed here:
#
#        ceph osd unset noup && systemctl start "$(systemctl list-units \
#            --all -t service --no-legend | awk '/osd\.<id>\.service/{print $1}')"
#
#  KEY TAKEAWAY: OSDMap flags (noup, nodown, noout, noin, norecover,
#  nobackfill, norebalance, pause, ...) are cluster-wide overrides that
#  silently change how the monitors treat OSDs. Always read 'ceph -s' and
#  'ceph health detail' for a "flag(s) set" line BEFORE touching any daemon —
#  restarting a service can never clear a flag, and a set flag will happily
#  defeat an otherwise correct repair.
# =============================================================================