#!/usr/bin/env bash
#
# ==============================================================================
# LPIC-3 306 (Exam 306-300, v3.0) — Topic 362.2: Cluster Storage Access
# Break & Fix lab: GFS2 shared-storage volume that will not mount
# ==============================================================================
#
# WHAT THIS TEACHES
# -----------------
# A GFS2 file system does not carry its own locking. At mkfs time you bind it to
# a *lock protocol* and a *lock table* written into the superblock:
#
#     lockproto = lock_dlm         -> coordinate access through the kernel DLM,
#                                     driven by dlm_controld, fed by the cluster
#                                     membership layer (corosync/pacemaker).
#     locktable = <cluster>:<fs>   -> e.g. "labcluster:shared". The part before
#                                     the colon MUST equal the corosync cluster
#                                     name, or the mount is refused.
#     lockproto = lock_nolock      -> no distributed locking; single mounter only.
#
# In production a GFS2 volume is lock_dlm and is mounted by every node while the
# DLM (dlm_controld + the `dlm` kernel module) and cluster membership are up.
# When those are absent — a rescue box, a maintenance VM, a node evicted from the
# cluster — a lock_dlm mount fails hard, because there is no lock manager to talk
# to. Recovering the data from such a volume on a single, cluster-less host is a
# real operational skill and the subject of this exercise.
#
# This lab reproduces that exact failure on ONE disposable VM using a loopback
# block device, so no corosync/pacemaker stack and no second node are required.
#
# SAFETY
# ------
#   * Run ONLY on a throwaway lab VM. You must be root.
#   * Everything lives under /root/lab-362.2 on a private loop device.
#   * It never touches real disks, real LVM volume groups, /etc, or fstab.
#   * `--clean` tears the whole thing down so the VM returns to a clean state.
#
# USAGE
# -----
#   ./362.2-break.sh --break     # arm the failure (default)
#   ./362.2-break.sh --verify    # check whether you solved it
#   ./362.2-break.sh --clean     # remove all lab artifacts
#
# Reference sources (official):
#   - LPI 306-300 objectives: https://www.lpi.org/our-certifications/exam-306-objectives/
#   - Configuring GFS2 File Systems (Red Hat):
#       https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_gfs2_file_systems/
#   - man 8 mkfs.gfs2 ; man 8 mount.gfs2 ; man 8 tunegfs2 ; man 8 dlm_tool
# ==============================================================================

set -euo pipefail

LAB_DIR="/root/lab-362.2"
IMG="${LAB_DIR}/gfs2-shared.img"
MNT="${LAB_DIR}/mnt"
STATE="${LAB_DIR}/state.env"
LOCKTABLE="labcluster:shared"
SENTINEL="IMPORTANT-BACKUP.txt"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This lab must run as root."
}

confirm_lab() {
    # Refuse to run unattended on anything that is not obviously disposable.
    if [ "${LAB_FORCE:-0}" != "1" ]; then
        warn "This will load kernel modules and create a loop device under ${LAB_DIR}."
        warn "Run this ONLY on a disposable lab VM."
        read -r -p "Type 'lab' to continue: " reply
        [ "$reply" = "lab" ] || die "Aborted by user."
    fi
}

ensure_tools() {
    # Best-effort dependency setup. On a real exam-style lab you would have
    # gfs2-utils installed already; here we try, but never fail silently.
    if ! command -v mkfs.gfs2 >/dev/null 2>&1; then
        log "mkfs.gfs2 not found — attempting to install gfs2-utils..."
        if   command -v dnf     >/dev/null 2>&1; then dnf install -y gfs2-utils || true
        elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y gfs2-utils || true
        elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install gfs2-utils || true
        fi
    fi
    command -v mkfs.gfs2 >/dev/null 2>&1 || die "gfs2-utils is required (package 'gfs2-utils')."
    command -v losetup   >/dev/null 2>&1 || die "util-linux 'losetup' is required."

    # The gfs2 module is mandatory. Note we deliberately do NOT start the DLM
    # cluster stack — its absence is precisely what breaks the mount.
    if ! modprobe gfs2 2>/dev/null; then
        die "Cannot load the 'gfs2' kernel module (install the matching kernel modules)."
    fi
}

do_break() {
    require_root
    [ -f "$STATE" ] && die "Lab already armed. Run '--clean' first to reset it."
    confirm_lab
    ensure_tools

    mkdir -p "$LAB_DIR" "$MNT"

    # --- Build a private block device ----------------------------------------
    log "Creating a 512 MiB backing image and attaching a loop device..."
    truncate -s 512M "$IMG"
    local loop
    loop="$(losetup --find --show "$IMG")"
    echo "LOOP=${loop}" > "$STATE"
    ok "Loop device: ${loop}"

    # --- Format as a *clustered* GFS2 volume ---------------------------------
    # -p lock_dlm  : bind the fs to the DLM (needs a running cluster to mount).
    # -t <table>   : cluster:fsname stamped into the superblock.
    # -j 2 -J 32   : two 32 MiB journals (one per would-be node).
    log "Formatting ${loop} as GFS2 with lockproto=lock_dlm, locktable=${LOCKTABLE}..."
    mkfs.gfs2 -O -p lock_dlm -t "$LOCKTABLE" -j 2 -J 32 "$loop" >/dev/null

    # --- Seed data the student must recover ----------------------------------
    # We use the single-node override here purely as the instructor's setup, so
    # that after you solve the challenge there is verifiable data to read back.
    log "Seeding data onto the volume (instructor setup)..."
    mount -t gfs2 -o lockproto=lock_nolock,noatime "$loop" "$MNT"
    cat > "${MNT}/${SENTINEL}" <<EOF
Quarterly billing export — DO NOT DELETE.
If you can read this file, you recovered the GFS2 volume on a single node.
EOF
    sync
    umount "$MNT"
    ok "Data written. Volume superblock still says lockproto=lock_dlm."

    # --- Demonstrate the failure the student inherits -------------------------
    echo
    warn "Reproducing the fault a normal mount would hit on this cluster-less VM:"
    echo  "    # mount -t gfs2 ${loop} ${MNT}"
    if mount -t gfs2 "$loop" "$MNT" 2>/tmp/362.2-mount.err; then
        # Extremely unlikely here (no DLM), but stay honest if it somehow works.
        umount "$MNT" || true
        warn "Unexpected: the mount succeeded. Is a DLM stack running on this host?"
    else
        sed 's/^/        /' /tmp/362.2-mount.err || true
        echo "        (kernel ring buffer:)"
        dmesg | tail -n 4 | sed 's/^/        /' || true
    fi
    rm -f /tmp/362.2-mount.err

    # --- The challenge briefing ----------------------------------------------
    cat <<EOF

==============================================================================
                          >>> YOUR CHALLENGE <<<
==============================================================================
SCENARIO
  A colleague built the GFS2 volume now on ${loop} for a Pacemaker cluster
  named "labcluster". That cluster is gone; THIS box has no corosync, no
  pacemaker, and no running DLM. You have been handed the disk to pull a
  backup off it before it is wiped.

SYMPTOM YOU WILL SEE
  * 'mount -t gfs2 ${loop} ${MNT}' exits non-zero.
  * 'mount' reports: "wrong fs type, bad option, bad superblock ...".
  * 'dmesg' shows a line such as:
        gfs2: can't find locking protocol lock_dlm
    or  gfs2: ... no cluster infrastructure / DLM not available.
  The superblock demands the DLM, but nothing here can provide it.

WHAT YOU MUST ACHIEVE
  1. Mount the volume READ-WRITE at ${MNT} on THIS single node.
  2. Read the file '${SENTINEL}' from the volume.
  3. (Bonus) Make the volume mountable normally on a standalone node so a
     plain 'mount -t gfs2' no longer fails.

USEFUL TOOLS
  losetup -a | blkid | tunegfs2 -l ${loop} | dmesg | man 8 mount.gfs2

CHECK YOUR WORK
  ./$(basename "$0") --verify
==============================================================================
EOF
}

do_verify() {
    require_root
    [ -f "$STATE" ] || die "Nothing to verify — the lab is not armed."
    # shellcheck disable=SC1090
    . "$STATE"
    if mountpoint -q "$MNT" && [ -f "${MNT}/${SENTINEL}" ]; then
        ok "SOLVED — ${LOOP} is mounted at ${MNT} and the backup file is readable:"
        echo "----------------------------------------------------------------------"
        cat "${MNT}/${SENTINEL}"
        echo "----------------------------------------------------------------------"
    else
        warn "Not solved yet: ${MNT} is not a mounted GFS2 volume exposing ${SENTINEL}."
        warn "Re-read the challenge and inspect the superblock with: tunegfs2 -l ${LOOP}"
        exit 1
    fi
}

do_clean() {
    require_root
    if [ -f "$STATE" ]; then
        # shellcheck disable=SC1090
        . "$STATE"
        mountpoint -q "$MNT" && { log "Unmounting ${MNT}..."; umount "$MNT" || umount -l "$MNT"; }
        if [ -n "${LOOP:-}" ] && losetup "$LOOP" >/dev/null 2>&1; then
            log "Detaching ${LOOP}..."; losetup -d "$LOOP" || true
        fi
    fi
    log "Removing ${LAB_DIR}..."
    rm -rf "$LAB_DIR"
    ok "Lab environment removed. VM is back to a clean state."
}

case "${1:---break}" in
    --break|break) do_break  ;;
    --verify|verify) do_verify ;;
    --clean|clean) do_clean  ;;
    -h|--help|help)
        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *) die "Unknown option '$1' (use --break | --verify | --clean)";;
esac

# ==============================================================================
# ============================ SOLUTION (spoiler) ==============================
# ==============================================================================
# Do not read this until you have tried it. Every command below is unprivileged
# to reason about but must be run as root.
#
# ---- Step 0: Understand what you are looking at ------------------------------
#   losetup -a
#   blkid /dev/loopX                 # -> TYPE="gfs2"
#   tunegfs2 -l /dev/loopX           # -> Lock Protocol: lock_dlm
#                                    #    Lock Table:    labcluster:shared
#   dmesg | tail                     # the failed mount logged "lock_dlm not found"
#
#   The on-disk superblock says "use the DLM". This host has no DLM
#   (no dlm_controld, no corosync membership), so mount_gfs2 cannot proceed.
#
# ---- Step 1: Immediate recovery — override the lock protocol at mount --------
#   The mount.gfs2 helper accepts 'lockproto=' to override the superblock value
#   for this mount only. lock_nolock means "I am the sole mounter, skip the DLM".
#   This does NOT alter the disk; it is the correct, minimally invasive way to
#   read a clustered volume from one node.
#
#     mkdir -p /root/lab-362.2/mnt
#     mount -t gfs2 -o lockproto=lock_nolock,noatime /dev/loopX /root/lab-362.2/mnt
#
#   *** SAFETY RULE: only ever mount lock_nolock when you are ABSOLUTELY certain
#       no other node has this volume mounted. Two nolock mounters = corruption,
#       because each believes it owns the file system exclusively. ***
#
# ---- Step 2: Recover the data ------------------------------------------------
#     cat /root/lab-362.2/mnt/IMPORTANT-BACKUP.txt
#     # ...copy it off, then: umount /root/lab-362.2/mnt
#
#   Verify with: ./362.2-break.sh --verify
#
# ---- Step 3 (bonus): Make it a true standalone volume ------------------------
#   To let a plain 'mount -t gfs2' succeed forever on a single node, rewrite the
#   lock protocol in the superblock (volume MUST be unmounted first):
#
#     umount /root/lab-362.2/mnt 2>/dev/null || true
#     tunegfs2 -o lockproto=lock_nolock /dev/loopX      # modern gfs2-utils
#     # legacy equivalent on older systems:
#     #   gfs2_tool sb /dev/loopX proto lock_nolock
#     tunegfs2 -l /dev/loopX                            # confirm: Lock Protocol lock_nolock
#     mount -t gfs2 /dev/loopX /root/lab-362.2/mnt      # now works with no override
#
# ---- How you would REALLY fix this inside a cluster --------------------------
#   The single-node trick is for rescue only. In production the mount fails
#   because the storage stack is down, and the fix is to bring the stack up so
#   lock_dlm has something to talk to:
#
#     systemctl start corosync pacemaker      # membership + resource manager
#     pcs status                              # confirm the node is a member
#     dlm_tool ls ; dlm_tool status           # DLM lockspaces are present
#     # ensure the cluster's name matches the locktable prefix ("labcluster"):
#     #   corosync-cmapctl | grep cluster_name   (or 'pcs property' / cluster.conf)
#     mount -t gfs2 /dev/loopX /mnt/shared    # normal clustered mount, all nodes
#
#   Related 362.2 building blocks the exam expects you to recognise:
#     * DLM         : dlm_controld, the 'dlm' kernel module, dlm_tool ls/status,
#                     lockspaces exposed under /sys/kernel/config/dlm.
#     * Clustered LVM (shared VG): lvmlockd + 'use_lvmlockd = 1' in lvm.conf;
#                     vgcreate --shared, then per node 'vgchange --lockstart',
#                     and 'lvchange -a sy <vg>/<lv>' for shared activation.
#     * Growing GFS2 online: gfs2_grow (fs), gfs2_jadd (add a journal per new node).
#     * OCFS2 analogue: mkfs.ocfs2 / mount.ocfs2 with the o2cb stack and
#                       /etc/ocfs2/cluster.conf; the same "no cluster = no mount"
#                       failure mode applies.
#
# ---- Reset the lab -----------------------------------------------------------
#     ./362.2-break.sh --clean
# ==============================================================================