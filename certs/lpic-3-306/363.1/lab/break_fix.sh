#!/usr/bin/env bash
#
# lpic-3-306 :: Topic 363.1 — GlusterFS Storage Clusters
# Break & Fix lab :: reproduce and resolve a REPLICA-2 SPLIT-BRAIN
#
# WHAT THIS SCRIPT DOES
#   1. Builds a self-contained single-node GlusterFS lab: a replicated
#      (replica 2) volume "gv0" with both bricks on this host, FUSE-mounted
#      at /mnt/gv0.
#   2. Deliberately disables client/server quorum and the self-heal daemon,
#      then writes divergent data to each replica while the *other* brick is
#      down. The two copies end up blaming each other: a classic split-brain.
#   3. Leaves you with a broken file and asks you to repair it by hand.
#
# It is DESTRUCTIVE by design and must ONLY run on a disposable lab VM.
# There is no production data on a GlusterFS volume this script created.
#
# Objective 363.1 topics exercised: bricks, replicated volumes, the AFR
# translator, trusted.afr.* extended attributes, client/server quorum,
# the self-heal daemon (glustershd), and manual split-brain resolution.
#
# Source (official exam objectives):
#   https://www.lpi.org/our-certifications/exam-306-objectives/
# GlusterFS split-brain reference (upstream docs):
#   https://docs.gluster.org/en/latest/Troubleshooting/resolving-splitbrain/
#   https://docs.gluster.org/en/latest/Administrator-Guide/arbiter-volumes-and-quorum/
#
# Usage:
#   sudo I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes ./break_fix.sh          # break
#   sudo I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes ./break_fix.sh --cleanup # tear down

set -uo pipefail

VOL="gv0"
HOSTREF="127.0.0.1"
BRICK_ROOT="/srv/glusterfs/${VOL}"
BRICK1="${BRICK_ROOT}/brick1"          # AFR subvolume index 0 -> trusted.afr.gv0-client-0
BRICK2="${BRICK_ROOT}/brick2"          # AFR subvolume index 1 -> trusted.afr.gv0-client-1
MNT="/mnt/${VOL}"
FILE="data.txt"                         # target file, seen as ${MNT}/${FILE}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo)."; }

require_lab_guard() {
    [[ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB:-}" == "yes" ]] || die \
        "Refusing to run. Set I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes to confirm this is a throwaway lab VM."
}

svc_glusterd() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now glusterd >/dev/null 2>&1 || systemctl start glusterd
    else
        pgrep -x glusterd >/dev/null 2>&1 || glusterd
    fi
    for _ in $(seq 1 15); do gluster --version >/dev/null 2>&1 && gluster peer status >/dev/null 2>&1 && return 0; sleep 1; done
    return 0
}

ensure_packages() {
    command -v gluster >/dev/null 2>&1 && command -v mount.glusterfs >/dev/null 2>&1 && return 0
    say "Installing glusterfs-server + FUSE client"
    if   command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y glusterfs-server glusterfs-client
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y glusterfs-server glusterfs-fuse || dnf install -y centos-release-gluster && dnf install -y glusterfs-server glusterfs-fuse
    elif command -v yum     >/dev/null 2>&1; then yum install -y glusterfs-server glusterfs-fuse
    else warn "Unknown package manager; install GlusterFS server + FUSE client manually."; fi
    command -v gluster >/dev/null 2>&1 || die "gluster CLI still not present."
}

# Online state of a brick from 'gluster volume status': prints Y or N
brick_online() {
    gluster volume status "$VOL" 2>/dev/null | awk -v b="$1" 'index($0,b){print $(NF-1); exit}'
}

# PID of a brick process as tracked by glusterd
brick_pid() {
    gluster volume status "$VOL" 2>/dev/null | awk -v b="$1" 'index($0,b){print $NF; exit}'
}

wait_state() { # <brick_path> <Y|N> <timeout_s>
    local b="$1" want="$2" t="${3:-30}" now
    for _ in $(seq 1 "$t"); do
        now="$(brick_online "$b")"
        [[ "$now" == "$want" ]] && return 0
        sleep 1
    done
    warn "Timed out waiting for brick $b to reach state=$want (last=$now)"
    return 1
}

kill_brick() { # <brick_path>
    local pid; pid="$(brick_pid "$1")"
    if [[ -n "${pid:-}" && "$pid" != "N/A" ]]; then
        kill -9 "$pid" 2>/dev/null || true
    else
        # Fallback: match the glusterfsd process by its --brick-name argument
        pkill -9 -f -- "--brick-name ${1}" 2>/dev/null || true
    fi
}

restart_bricks() { gluster volume start "$VOL" force >/dev/null 2>&1 || true; }

# ----------------------------------------------------------------------------
# Cleanup mode
# ----------------------------------------------------------------------------
do_cleanup() {
    require_root
    say "Tearing down the lab volume and bricks"
    umount "$MNT" 2>/dev/null || true
    if gluster volume info "$VOL" >/dev/null 2>&1; then
        gluster --mode=script volume stop "$VOL"   >/dev/null 2>&1 || true
        gluster --mode=script volume delete "$VOL" >/dev/null 2>&1 || true
    fi
    rm -rf "$BRICK_ROOT" "$MNT"
    say "Done. Lab removed."
    exit 0
}

# ----------------------------------------------------------------------------
# Lab construction (idempotent)
# ----------------------------------------------------------------------------
build_lab() {
    say "Preparing bricks and starting glusterd"
    mkdir -p "$BRICK1" "$BRICK2" "$MNT"
    svc_glusterd

    if ! gluster volume info "$VOL" >/dev/null 2>&1; then
        say "Creating replica-2 volume ${VOL}"
        # 'force' allows two bricks on the same node / on the root filesystem (lab only)
        gluster --mode=script volume create "$VOL" replica 2 \
            "${HOSTREF}:${BRICK1}" "${HOSTREF}:${BRICK2}" force \
            || die "volume create failed"
        gluster --mode=script volume start "$VOL" || die "volume start failed"
    fi

    say "Mounting ${VOL} at ${MNT} (FUSE)"
    mountpoint -q "$MNT" || {
        for _ in $(seq 1 10); do
            mount -t glusterfs "${HOSTREF}:/${VOL}" "$MNT" && break
            sleep 2
        done
    }
    mountpoint -q "$MNT" || die "Could not FUSE-mount the volume."

    say "Writing a healthy baseline file and confirming replication"
    echo "baseline: written while both replicas were online" > "${MNT}/${FILE}"
    sync; sleep 1
    restart_bricks
    wait_state "$BRICK1" Y 30; wait_state "$BRICK2" Y 30
}

# ----------------------------------------------------------------------------
# The break: manufacture a split-brain
# ----------------------------------------------------------------------------
do_break() {
    require_root
    require_lab_guard
    ensure_packages
    build_lab

    say "Disabling quorum and self-heal so the two replicas can diverge"
    # In real life quorum is what PREVENTS this. We turn it off to expose the failure mode.
    gluster volume set "$VOL" cluster.quorum-type        none >/dev/null 2>&1 || true
    gluster volume set "$VOL" cluster.server-quorum-type none >/dev/null 2>&1 || true
    gluster volume set "$VOL" cluster.self-heal-daemon    off >/dev/null 2>&1 || true
    gluster volume set "$VOL" cluster.data-self-heal      off >/dev/null 2>&1 || true
    gluster volume set "$VOL" cluster.metadata-self-heal  off >/dev/null 2>&1 || true
    gluster volume set "$VOL" cluster.entry-self-heal     off >/dev/null 2>&1 || true

    say "Phase A: brick2 down -> write version A (lands only on brick1)"
    kill_brick "$BRICK2"; wait_state "$BRICK2" N 30
    echo "VERSION-A: edited on $(date -u +%FT%TZ) while brick2 was offline" > "${MNT}/${FILE}"
    sync; sleep 1

    say "Phase B: brick2 back, brick1 down -> write version B (lands only on brick2)"
    restart_bricks; wait_state "$BRICK2" Y 30
    kill_brick "$BRICK1"; wait_state "$BRICK1" N 30
    echo "VERSION-B: edited on $(date -u +%FT%TZ) while brick1 was offline" > "${MNT}/${FILE}"
    sync; sleep 1

    say "Restoring both bricks — the replicas now blame each other"
    restart_bricks; wait_state "$BRICK1" Y 30; wait_state "$BRICK2" Y 30

    # Re-enable the self-heal daemon so it *tries* to heal and logs its failure,
    # which is exactly what you would observe on a real cluster.
    gluster volume set "$VOL" cluster.self-heal-daemon on >/dev/null 2>&1 || true
    gluster volume heal "$VOL" >/dev/null 2>&1 || true
    stat "${MNT}/${FILE}" >/dev/null 2>&1 || true   # trigger a lookup so AFR flags the file
    sleep 3

    cat <<EOF

################################################################################
#  BREAK COMPLETE — the volume "${VOL}" now has a file stuck in SPLIT-BRAIN.
################################################################################

WHAT YOU WILL SEE (the symptom)
  * Reading the file returns an I/O error, even though both bricks are online:

      \$ cat ${MNT}/${FILE}
      cat: ${MNT}/${FILE}: Input/output error

  * The self-heal daemon cannot fix it on its own:

      \$ gluster volume heal ${VOL} info
      Brick ${HOSTREF}:${BRICK1}
      /${FILE}  - Is in split-brain
      Brick ${HOSTREF}:${BRICK2}
      /${FILE}  - Is in split-brain

  * /var/log/glusterfs/glustershd.log repeats lines like:
      "Unable to self-heal contents of '/${FILE}' (possible split-brain)."

WHY IT HAPPENED
  Each replica was written to while the other was offline, so both carry a
  nonzero trusted.afr.${VOL}-client-* attribute pointing at the peer. AFR sees
  two "authoritative" copies and refuses to guess — because we had turned
  quorum OFF, nothing stopped the divergence in the first place.

YOUR OBJECTIVE
  Repair the file so that:
    (a) 'gluster volume heal ${VOL} info' reports 0 entries (no split-brain),
    (b) 'cat ${MNT}/${FILE}' succeeds and returns ONE chosen version,
    (c) you did NOT delete/recreate the volume to do it.

  Diagnose with getfattr on both bricks, pick a winning copy on purpose, and
  drive the resolution through the 'gluster volume heal ... split-brain' CLI.
  Then think about which quorum setting would have prevented this entirely.

  When finished experimenting, tear the lab down with:
    sudo I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB=yes $0 --cleanup

################################################################################
EOF
}

case "${1:-}" in
    --cleanup|-c) do_cleanup ;;
    ""|--break)   do_break   ;;
    *) die "Unknown argument '$1' (use --break or --cleanup)" ;;
esac

# ============================================================================
#  SOLUTION — step by step (read only after you have tried it yourself)
# ============================================================================
#
# 0) Confirm the diagnosis. The file is unreadable but both bricks are UP.
#
#    # gluster volume status gv0
#    #   -> both bricks show Online = Y  (this is NOT a "brick down" problem)
#    # gluster volume heal gv0 info
#    #   -> /data.txt "Is in split-brain" under BOTH bricks
#    # gluster volume heal gv0 info split-brain
#    #   -> lists only the entries that are genuinely in split-brain
#
# 1) Look at the divergence directly on the backend bricks. The AFR change-log
#    xattrs prove the mutual blame; a nonzero value means "this copy recorded
#    pending operations against the peer".
#
#    # getfattr -d -m . -e hex /srv/glusterfs/gv0/brick1/data.txt
#    #   trusted.afr.gv0-client-1=0x000000010000000000000000   <- brick1 blames brick2
#    # getfattr -d -m . -e hex /srv/glusterfs/gv0/brick2/data.txt
#    #   trusted.afr.gv0-client-0=0x000000010000000000000000   <- brick2 blames brick1
#    #
#    # Read each backend copy to decide which content you actually want:
#    # cat /srv/glusterfs/gv0/brick1/data.txt   -> VERSION-A ...
#    # cat /srv/glusterfs/gv0/brick2/data.txt   -> VERSION-B ...
#
# 2) Resolve it. Pick ONE policy (do not mix); all are non-destructive to the
#    volume — they only tell AFR which replica is authoritative:
#
#    a) By newest modification time (good default when unsure):
#       # gluster volume heal gv0 split-brain latest-mtime /data.txt
#
#    b) By an explicit good copy (you decided brick2/VERSION-B wins):
#       # gluster volume heal gv0 split-brain source-brick 127.0.0.1:/srv/glusterfs/gv0/brick2 /data.txt
#
#    c) By size, keeping the larger file:
#       # gluster volume heal gv0 split-brain bigger-file /data.txt
#
#    (For a whole tree at once you may use:
#       # gluster volume heal gv0 split-brain source-brick 127.0.0.1:/srv/glusterfs/gv0/brick2 )
#
# 3) Complete and verify the heal.
#
#    # gluster volume heal gv0
#    # gluster volume heal gv0 info          -> "Number of entries: 0" on both bricks
#    # cat /mnt/gv0/data.txt                 -> now returns the chosen version, no EIO
#
# 4) Close the door that let this happen. On a replica-2 volume, enabling
#    client-side quorum makes writes fail (instead of silently diverging) once
#    a replica is missing — no quorum, no split-brain:
#
#    # gluster volume set gv0 cluster.quorum-type auto
#    # gluster volume set gv0 cluster.self-heal-daemon on
#    #
#    # Production-grade fix: convert to replica 3 or add an arbiter brick
#    # (replica 2 arbiter 1) so the cluster always has a tie-breaker:
#    #   gluster volume add-brick gv0 replica 3 arbiter 1 127.0.0.1:/srv/glusterfs/gv0/arbiter force
#
# KEY TAKEAWAYS
#   * "Brick online" and "file healthy" are different questions — split-brain
#     happens with every brick UP.
#   * The self-heal daemon will not choose for you; a human must pick the
#     authoritative copy, and 'heal ... split-brain' is how you record that.
#   * The real cure is prevention: quorum and/or an arbiter, not manual repair.
# ============================================================================