#!/usr/bin/env bash
#
# break_fix.sh — LPIC-3 306 (exam 306-300, version 3.0)
# Topic 362.3: Clustered File Systems  ·  exam weight: 6.67
#
# PURPOSE
#   A self-contained "break & fix" drill for GFS2, the Distributed Lock Manager
#   (DLM) and the on-disk lock protocol of a cluster file system. It builds an
#   isolated GFS2 image on a loopback device, then CONTROLLED-BREAKS it by
#   rewriting the superblock lock protocol to lock_dlm and pointing it at a
#   cluster/lock-table that does not exist. Mounting then fails exactly the way a
#   real GFS2 volume fails when the cluster stack (corosync/pacemaker + DLM) is
#   down or misconfigured. The student must diagnose and repair it.
#
#   Everything lives in a sparse file + loop device + a scratch mountpoint. It
#   touches NO real disk, NO LVM, NO cluster daemons. It is designed to be run,
#   broken, fixed and destroyed on a DISPOSABLE lab VM.
#
#   Objectives exercised: GFS2 principles, lock protocols (lock_dlm vs
#   lock_nolock), the DLM dependency, and the GFS2 tooling: mkfs.gfs2,
#   tunegfs2, mount.gfs2, fsck.gfs2.
#
# SOURCES (official)
#   LPI 306-300 objectives: https://www.lpi.org/our-certifications/exam-306-objectives/
#   gfs2-utils man pages:   https://man7.org/linux/man-pages/man8/tunegfs2.8.html
#                           https://man7.org/linux/man-pages/man8/mkfs.gfs2.8.html
#   RHEL GFS2 guide:        https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_gfs2_file_systems/index
#   The Linux DLM:          https://pagure.io/dlm  ·  https://man7.org/linux/man-pages/man8/dlm_tool.8.html
#
# !!  WARNING  !!  Run ONLY on a throwaway lab VM. Requires root. Uses modprobe,
#                  losetup and mount. Do NOT run on a machine you care about.
#
# USAGE
#   sudo ./break_fix.sh            # build the lab, then break it (default)
#   sudo ./break_fix.sh build      # only build a healthy GFS2 image + verify
#   sudo ./break_fix.sh break      # only break an already-built image
#   sudo ./break_fix.sh status     # show current on-disk lock config + mounts
#   sudo ./break_fix.sh clean      # unmount, detach loop, delete the image
#   Add --yes to skip the disposable-VM confirmation prompt.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (all disposable)
# ---------------------------------------------------------------------------
IMG="${IMG:-/var/tmp/gfs2-lab.img}"
MNT="${MNT:-/mnt/gfs2lab}"
SIZE_MB="${SIZE_MB:-512}"          # sparse; real cost is only what GFS2 writes
JOURNAL_MB="${JOURNAL_MB:-32}"     # small journal keeps the image tiny
FS_NAME="gfs2lab"                  # the "filesystem" part of the lock table
BAD_CLUSTER="labcluster"           # a cluster name that is NOT running anywhere
BAD_LOCKTABLE="${BAD_CLUSTER}:${FS_NAME}"
MARKER="/var/tmp/.gfs2-lab.loop"   # remembers which loop device we allocated

# ---------------------------------------------------------------------------
# Pretty logging
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YLW=$(tput setaf 3)
  C_BLU=$(tput setaf 4); C_BLD=$(tput bold);    C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi
info()  { printf '%s[*]%s %s\n'  "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n'  "$C_YLW" "$C_RST" "$*"; }
err()   { printf '%s[x]%s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_root() { [ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."; }

confirm_lab() {
  case " $* " in *" --yes "*) return 0 ;; esac
  [ "${LAB:-0}" = "1" ] && return 0
  warn "This modifies loop devices and mounts filesystems as root."
  warn "Run it ONLY on a disposable lab VM."
  read -r -p "Type 'lab' to continue: " ans
  [ "$ans" = "lab" ] || die "Aborted."
}

install_prereqs() {
  modprobe gfs2 2>/dev/null || true
  if command -v mkfs.gfs2 >/dev/null 2>&1 && command -v tunegfs2 >/dev/null 2>&1; then
    return 0
  fi
  info "Installing gfs2-utils ..."
  if   command -v dnf     >/dev/null 2>&1; then dnf install -y gfs2-utils
  elif command -v yum     >/dev/null 2>&1; then yum install -y gfs2-utils
  elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y gfs2-utils
  elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install gfs2-utils
  elif command -v pacman  >/dev/null 2>&1; then pacman -Sy --noconfirm gfs2-utils
  else die "Install gfs2-utils manually (mkfs.gfs2/tunegfs2 not found)."
  fi
  command -v tunegfs2 >/dev/null 2>&1 || die "gfs2-utils still missing after install."
  modprobe gfs2 2>/dev/null || warn "Could not load the gfs2 kernel module — check your kernel."
}

# ---------------------------------------------------------------------------
# Loop device helpers
# ---------------------------------------------------------------------------
current_loop() {
  # Prefer the association the kernel actually reports over our marker file.
  local dev
  dev="$(losetup -j "$IMG" -O NAME --noheadings 2>/dev/null | awk 'NF{print $1; exit}')"
  if [ -n "$dev" ]; then printf '%s\n' "$dev"; return 0; fi
  [ -f "$MARKER" ] && { cat "$MARKER"; return 0; }
  return 1
}

ensure_loop() {
  local dev
  if dev="$(current_loop)"; then printf '%s\n' "$dev"; return 0; fi
  dev="$(losetup --find --show "$IMG")"
  printf '%s\n' "$dev" > "$MARKER"
  printf '%s\n' "$dev"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_build() {
  install_prereqs
  if [ -f "$IMG" ] && current_loop >/dev/null 2>&1; then
    info "Image already present at $IMG — reusing (idempotent)."
  else
    info "Creating ${SIZE_MB} MB sparse backing image at $IMG ..."
    rm -f "$IMG"
    truncate -s "${SIZE_MB}M" "$IMG"
  fi

  local loop; loop="$(ensure_loop)"
  ok "Backing image attached to $loop"

  # Build a HEALTHY, single-node-mountable GFS2: lock_nolock needs no cluster.
  if ! blkid -o value -s TYPE "$loop" 2>/dev/null | grep -qx gfs2; then
    info "Formatting $loop as GFS2 (lock_nolock, 1 journal) ..."
    mkfs.gfs2 -p lock_nolock -j 1 -J "$JOURNAL_MB" -O "$loop"
  else
    info "GFS2 already present — leaving it in place."
  fi

  mkdir -p "$MNT"
  if ! mountpoint -q "$MNT"; then
    info "Mounting the healthy filesystem to prove it works ..."
    mount -t gfs2 "$loop" "$MNT"
  fi
  echo "student-data written before the break at $(date -u +%FT%TZ)" > "$MNT/README.txt"
  sync
  ok "Healthy GFS2 mounted at $MNT:"
  df -hT "$MNT" | sed 's/^/    /'
  umount "$MNT"
  ok "Build complete and verified. On-disk lock config now:"
  tunegfs2 -l "$loop" | sed 's/^/    /'
}

do_break() {
  install_prereqs
  local loop
  loop="$(current_loop)" || die "No lab found. Run: sudo $0 build"

  mountpoint -q "$MNT" && umount "$MNT" || true

  info "Rewriting the GFS2 superblock lock configuration (the controlled break) ..."
  tunegfs2 -o lockproto=lock_dlm "$loop"
  tunegfs2 -o locktable="$BAD_LOCKTABLE" "$loop"
  ok "Superblock now advertises a clustered lock protocol:"
  tunegfs2 -l "$loop" | sed 's/^/    /'

  info "Demonstrating the failure the student will encounter ..."
  mkdir -p "$MNT"
  set +e
  timeout 20 mount -t gfs2 "$loop" "$MNT" 2> /var/tmp/gfs2-lab.err
  local rc=$?
  set -e
  mountpoint -q "$MNT" && umount "$MNT" || true

  printf '\n%s%s================  BROKEN LAB READY  ================%s\n' "$C_BLD" "$C_RED" "$C_RST"
  cat <<EOF

  WHAT WAS DONE
    The GFS2 volume on ${loop} was reconfigured on-disk from lock_nolock to
    lock_dlm with lock table '${BAD_LOCKTABLE}'. lock_dlm makes GFS2 a CLUSTER
    file system: before it will mount, the kernel must join the named DLM
    lockspace, which requires a running cluster stack (corosync + pacemaker +
    dlm_controld) whose cluster name matches. None of that exists on this VM.

  SYMPTOM YOU WILL SEE  (mount returned exit code ${rc})
    A plain mount now fails or hangs. Captured error:
$( sed 's/^/        /' /var/tmp/gfs2-lab.err 2>/dev/null || true )
    Exact wording varies by kernel/gfs2-utils, but it is always a DLM/cluster
    failure, e.g.:
        mount.gfs2: can't connect to the DLM control daemon (dlm_controld)
        mount: /mnt/gfs2lab: Transport endpoint is not connected.
        mount.gfs2: error mounting lockproto lock_dlm
    'dmesg' will show gfs2 unable to join lockspace '${BAD_LOCKTABLE}'.

  REPRODUCE IT YOURSELF
        sudo mount -t gfs2 ${loop} ${MNT}
        dmesg | tail -n 20
        sudo tunegfs2 -l ${loop}

  YOUR OBJECTIVE
    Get the filesystem mounted read/write at ${MNT} again, WITHOUT reformatting
    (the file ${MNT}/README.txt must still be there afterwards). You must:
      1. Identify from the superblock that the lock protocol is the problem.
      2. Understand WHY lock_dlm cannot mount on a single node with no cluster.
      3. Restore a working mount — either by fixing the on-disk lock protocol
         for this standalone lab, or (production reasoning) by bringing up the
         cluster stack so the DLM lockspace can actually be joined.

  Verify success with:
        mountpoint -q ${MNT} && cat ${MNT}/README.txt && echo "FIXED"
  Tear the lab down when finished with:
        sudo $0 clean

EOF
  printf '%s%s====================================================%s\n\n' "$C_BLD" "$C_RED" "$C_RST"
}

do_status() {
  local loop
  if loop="$(current_loop)"; then
    info "Loop device: $loop"
    command -v tunegfs2 >/dev/null 2>&1 && tunegfs2 -l "$loop" | sed 's/^/    /' || true
  else
    warn "No loop device is attached to $IMG."
  fi
  info "Mount state of $MNT:"
  mountpoint -q "$MNT" && df -hT "$MNT" | sed 's/^/    /' || echo "    not mounted"
}

do_clean() {
  mountpoint -q "$MNT" && umount "$MNT" || true
  local dev
  if dev="$(current_loop)"; then
    losetup -d "$dev" 2>/dev/null || true
    ok "Detached $dev"
  fi
  rm -f "$IMG" "$MARKER" /var/tmp/gfs2-lab.err
  rmdir "$MNT" 2>/dev/null || true
  ok "Lab destroyed. Nothing persistent remains."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
  require_root
  local action="${1:-all}"
  case "$action" in
    all)     confirm_lab "$@"; do_build; do_break ;;
    build)   confirm_lab "$@"; do_build ;;
    break)   confirm_lab "$@"; do_break ;;
    status)  do_status ;;
    clean)   confirm_lab "$@"; do_clean ;;
    -h|--help|help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "Unknown action '$action'. Try: all | build | break | status | clean" ;;
  esac
}
main "$@"

# ###########################################################################
# #                    SOLUTION — step by step (spoiler)                    #
# ###########################################################################
#
# The problem is NOT data corruption: fsck.gfs2 would find the filesystem
# structurally sound. The problem is the LOCK PROTOCOL recorded in the GFS2
# superblock. GFS2 supports two:
#     lock_nolock  -> single-node, no external locking, mounts anywhere.
#     lock_dlm     -> multi-node, coordinates through the kernel Distributed
#                     Lock Manager (DLM). Before mounting, the node must JOIN
#                     the DLM lockspace named by the lock table
#                     "<cluster_name>:<fs_name>". That requires corosync +
#                     pacemaker + dlm_controld to be running, and the cluster
#                     name to match. On a lone lab VM none of that exists, so
#                     the join never completes and the mount fails/hangs.
#
# ---------------------------------------------------------------------------
# STEP 1 — Diagnose: read the on-disk lock configuration
# ---------------------------------------------------------------------------
#   sudo tunegfs2 -l /dev/loop0        # substitute your loop dev (see below)
#   # Expected output includes:
#   #     Lock Protocol: lock_dlm
#   #     Lock Table: labcluster:gfs2lab
#   #
#   # Find the loop device if unsure:
#   #     sudo losetup -j /var/tmp/gfs2-lab.img
#   #
#   # Confirm the cluster genuinely is not there (in production these are the
#   # tools you would reach for first):
#   #     dlm_tool ls                    # lists DLM lockspaces — empty/absent here
#   #     corosync-cfgtool -s            # ring status — no cluster
#   #     systemctl status pacemaker corosync dlm 2>/dev/null
#   #     dmesg | tail                   # "gfs2: can't join lockspace ..."
#
# ---------------------------------------------------------------------------
# STEP 2A — Fix for THIS lab (single node, no cluster): use lock_nolock
# ---------------------------------------------------------------------------
#   # Option 1 — one-shot mount override, leaves the superblock untouched:
#   sudo mount -t gfs2 -o lockproto=lock_nolock /dev/loop0 /mnt/gfs2lab
#
#   # Option 2 — permanently correct the superblock, then mount normally:
#   sudo umount /mnt/gfs2lab 2>/dev/null || true
#   sudo tunegfs2 -o lockproto=lock_nolock /dev/loop0
#   sudo tunegfs2 -l /dev/loop0                 # verify: Lock Protocol lock_nolock
#   sudo mount -t gfs2 /dev/loop0 /mnt/gfs2lab
#
#   # Verify the data survived (no reformat happened):
#   cat /mnt/gfs2lab/README.txt
#   mountpoint -q /mnt/gfs2lab && echo "FIXED"
#
# ---------------------------------------------------------------------------
# STEP 2B — Fix for PRODUCTION (real shared LUN, must stay lock_dlm)
# ---------------------------------------------------------------------------
#   # On genuinely shared storage you do NOT downgrade to lock_nolock — mounting
#   # a lock_nolock filesystem on two nodes at once destroys it. Instead you make
#   # the DLM lockspace joinable:
#   sudo systemctl enable --now corosync pacemaker
#   sudo systemctl enable --now dlm            # or the pacemaker 'ocf:pacemaker:controld' resource
#   sudo pcs status                            # cluster is quorate and DLM up
#   sudo dlm_tool ls                           # lockspace can now be created/joined
#   # Ensure the lock table's cluster name equals corosync's cluster_name:
#   sudo corosync-cmapctl | grep cluster_name  # must match 'labcluster' half of the lock table
#   # Fix a mismatch with:  sudo tunegfs2 -o locktable=<realcluster>:gfs2lab /dev/loop0
#   sudo mount -t gfs2 /dev/loop0 /mnt/gfs2lab # now the DLM join succeeds
#
# ---------------------------------------------------------------------------
# WHY THIS MATTERS (362.3 takeaways)
# ---------------------------------------------------------------------------
#   * A cluster file system's superblock records HOW it locks, not just how it
#     stores. lock_dlm hard-couples the filesystem to a live DLM + cluster stack.
#   * tunegfs2 edits that lock metadata offline; mount -o lockproto overrides it
#     for one mount without rewriting the disk — invaluable for recovery.
#   * The same class of failure hits OCFS2 (its o2cb/pcmk cluster stack must run:
#     "mount.ocfs2: Cluster stack has not been started") and clustered LVM
#     (lvmlockd/CLVM must be up before shared VGs activate). Ceph, being a
#     distributed object/file system, replaces this local-DLM model entirely.
#   * Golden rule: never mount a clustered FS lock_nolock on shared storage that
#     another node can also mount — concurrent lock_nolock writers corrupt it.
# ###########################################################################