#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-3 306 (Exam 306-300, v3.0)
#  Topic 364.2: Advanced RAID  —  BREAK & FIX lab
# ============================================================================
#
#  Objective source:
#    https://www.lpi.org/our-certifications/exam-306-objectives/
#
#  Knowledge exercised by this lab:
#    - Software RAID with mdadm (create, examine, assemble, monitor)
#    - RAID5 mechanics: parity, minimum devices, degraded operation
#    - Superblock event counters and why they matter on re-assembly
#    - Recovering an array that refuses to start after an unclean,
#      multi-device drop  ->  `mdadm --assemble --force`
#    - Rebuilding redundancy with a hot-added member and /proc/mdstat
#
#  SAFETY MODEL — READ BEFORE RUNNING
#    This script NEVER touches a real disk. It builds the entire array on
#    file-backed loop devices under a scratch directory, uses a private
#    --homehost so your host's udev/mdadm will not auto-assemble it, and
#    picks a NAMED array (/dev/md/<name>) that must not already exist.
#    Even so: run it ONLY on a disposable lab VM you can throw away.
#
#  USAGE
#    sudo ./break_fix.sh            # build the lab and break it (default)
#    sudo ./break_fix.sh break      # same as above
#    sudo ./break_fix.sh status     # show current mdstat / examine
#    sudo ./break_fix.sh cleanup    # stop array, detach loops, delete files
#
#  The step-by-step SOLUTION is at the very bottom of this file, commented out.
# ============================================================================

set -euo pipefail

# ----------------------------- Configuration --------------------------------
LAB_DIR="${LAB_DIR:-/var/tmp/raid364-lab}"     # everything lives here
MP="${LAB_DIR}/mnt"                            # mountpoint for the array
STATE="${LAB_DIR}/lab.state"                   # records loops + md device
LOOP_COUNT=4                                   # 4-member RAID5 (min 3 active)
LOOP_SIZE_MB=256                               # per-member backing file size
ARRAY_NAME="${ARRAY_NAME:-raid364lab}"         # -> /dev/md/raid364lab
HOMEHOST="${HOMEHOST:-raid364lab}"             # keep it off the host's radar
RAID_LEVEL=5
CHUNK_KB=512
SENTINEL_REL="DO_NOT_LOSE_ME.txt"

# ------------------------------- Utilities ----------------------------------
c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'
c_blu=$'\033[1;34m'; c_rst=$'\033[0m'
info(){ printf '%s[*]%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok(){   printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$c_yel" "$c_rst" "$*"; }
err(){  printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }

require_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "This lab manipulates loop devices and md arrays; run it as root."
    exit 1
  fi
}

need_cmd(){
  local missing=0 c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      err "Required command not found: $c"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || { err "Install the missing tools and retry."; exit 1; }
}

mdstat(){ cat /proc/mdstat 2>/dev/null || true; }

md_device(){
  # Resolve the real /dev/mdN behind the named array, if present.
  if [ -e "/dev/md/${ARRAY_NAME}" ]; then
    readlink -f "/dev/md/${ARRAY_NAME}"
  elif [ -f "$STATE" ]; then
    awk -F= '/^md=/{print $2}' "$STATE"
  fi
}

# --------------------------------- Cleanup ----------------------------------
cleanup(){
  info "Tearing down the RAID 364.2 lab ..."
  local md; md="$(md_device || true)"

  # Unmount if mounted (either by mountpoint or by md device).
  if mountpoint -q "$MP" 2>/dev/null; then umount "$MP" || umount -l "$MP" || true; fi
  if [ -n "${md:-}" ] && findmnt -no TARGET "$md" >/dev/null 2>&1; then
    umount "$md" 2>/dev/null || true
  fi

  # Stop the array (by name and by resolved device, best effort).
  mdadm --stop "/dev/md/${ARRAY_NAME}" 2>/dev/null || true
  [ -n "${md:-}" ] && mdadm --stop "$md" 2>/dev/null || true

  # Detach every loop device that backs a file in this lab dir.
  local f lp
  for f in "${LAB_DIR}"/disk*.img; do
    [ -e "$f" ] || continue
    for lp in $(losetup -j "$f" 2>/dev/null | cut -d: -f1); do
      mdadm --zero-superblock "$lp" 2>/dev/null || true
      losetup -d "$lp" 2>/dev/null || true
    done
  done

  # Also drop any loops recorded in the state file (covers renamed files).
  if [ -f "$STATE" ]; then
    while IFS= read -r lp; do
      [ -b "$lp" ] || continue
      mdadm --zero-superblock "$lp" 2>/dev/null || true
      losetup -d "$lp" 2>/dev/null || true
    done < <(awk -F= '/^loop=/{print $2}' "$STATE")
  fi

  rm -rf "$LAB_DIR"
  ok "Lab removed. Nothing on the host was modified."
}

# ------------------------------- Build phase --------------------------------
setup(){
  if [ -e "/dev/md/${ARRAY_NAME}" ] || [ -f "$STATE" ]; then
    err "A lab array named '${ARRAY_NAME}' already exists."
    err "Run: sudo $0 cleanup   (then re-run) to start fresh."
    exit 1
  fi

  modprobe loop        2>/dev/null || true
  modprobe raid456     2>/dev/null || true
  modprobe md_mod      2>/dev/null || true

  mkdir -p "$LAB_DIR" "$MP"
  : > "$STATE"
  # From here on, a failure during construction must not leak devices.
  trap 'err "Construction failed — cleaning up."; cleanup; exit 1' ERR

  info "Creating ${LOOP_COUNT} backing files of ${LOOP_SIZE_MB}M and loop devices ..."
  local i f lp
  local -a LOOPS=()
  for i in $(seq 0 $((LOOP_COUNT-1))); do
    f="${LAB_DIR}/disk${i}.img"
    # Sparse file: costs almost no real disk until written.
    truncate -s "${LOOP_SIZE_MB}M" "$f"
    lp="$(losetup --find --show "$f")"
    LOOPS+=("$lp")
    echo "loop=${lp}" >> "$STATE"
    printf '   %s  ->  %s\n' "$f" "$lp"
  done

  info "Creating a clean RAID${RAID_LEVEL} across ${LOOP_COUNT} devices ..."
  # --run    : don't prompt; --homehost keeps the host from adopting the array.
  mdadm --create "/dev/md/${ARRAY_NAME}" \
        --name="${ARRAY_NAME}" --homehost="${HOMEHOST}" \
        --level="${RAID_LEVEL}" --chunk="${CHUNK_KB}" \
        --raid-devices="${LOOP_COUNT}" \
        --metadata=1.2 --run "${LOOPS[@]}" >/dev/null

  local md; md="$(readlink -f "/dev/md/${ARRAY_NAME}")"
  echo "md=${md}" >> "$STATE"
  ok "Array assembled as ${md}"

  info "Waiting for the initial resync to finish ..."
  mdadm --wait "$md" 2>/dev/null || true
  while grep -Eq 'resync|recovery' /proc/mdstat; do sleep 2; done

  info "Formatting ext4 and writing a payload the student must not lose ..."
  mkfs.ext4 -q -F "$md"
  mount "$md" "$MP"
  echo "This file proves the RAID5 data survived recovery. Keep it." > "${MP}/${SENTINEL_REL}"
  dd if=/dev/urandom of="${MP}/payload.bin" bs=1M count=64 status=none
  sync
  local csum; csum="$(sha256sum "${MP}/${SENTINEL_REL}" | awk '{print $1}')"
  echo "sentinel_sha256=${csum}" >> "$STATE"
  umount "$MP"
  ok "Healthy array populated. Baseline redundancy is intact."
}

# ------------------------------- Break phase --------------------------------
break_array(){
  local md; md="$(md_device)"
  [ -n "$md" ] || { err "No lab array found. Did setup run?"; exit 1; }

  # Load the loop list in the same order used at creation time.
  local -a LOOPS=()
  while IFS= read -r lp; do LOOPS+=("$lp"); done < <(awk -F= '/^loop=/{print $2}' "$STATE")
  local L0="${LOOPS[0]}" L1="${LOOPS[1]}" L2="${LOOPS[2]}" L3="${LOOPS[3]}"

  info "Simulating disk #4 (${L3}) dying first, days ago ..."
  mdadm "$md" --fail "$L3" >/dev/null
  mdadm "$md" --remove "$L3" >/dev/null      # its superblock freezes: STALE-OLD

  info "Array kept running DEGRADED and MORE writes landed (events advance) ..."
  mount "$md" "$MP"
  dd if=/dev/urandom of="${MP}/late-writes.bin" bs=1M count=32 status=none
  sync
  umount "$MP"

  info "Now simulating an unclean crash: disk #3 (${L2}) drops, then power loss ..."
  mdadm "$md" --fail "$L2" >/dev/null        # 2/4 active -> array fails
  mdadm --stop "$md" >/dev/null              # dirty stop, superblocks left as-is
  ok "Damage done. The array is stopped with mismatched event counters."

  info "Attempting a NORMAL re-assembly the way a boot/udev would ..."
  # This is expected to FAIL to start — that is the symptom the student sees.
  set +e
  mdadm --assemble "/dev/md/${ARRAY_NAME}" "$L0" "$L1" "$L2" "$L3" 2>&1 | sed 's/^/    /'
  set -e

  cat <<EOF

${c_red}=================  YOUR RAID IS DOWN  =================${c_rst}

WHAT HAPPENED (the scenario)
  A 4-device RAID5 lost one member ${L3} a while ago and kept serving
  data in DEGRADED mode, so writes continued and its superblock event
  counter advanced past the removed disk. Then a second member ${L2}
  dropped and the machine went down uncleanly. On the next assembly mdadm
  finds three different "event" generations and refuses to start the array,
  because it cannot prove the data would be consistent.

THE SYMPTOM YOU WILL SEE
  * 'cat /proc/mdstat' shows /dev/md/${ARRAY_NAME} as inactive (no [UUUU]
    line, members marked "(S)") or missing entirely.
  * 'mdadm --assemble' prints something like:
        "assembled from 2 drives - not enough to start the array"
  * 'dmesg | tail' shows md "kicking non-fresh <dev>" messages.
  * 'mdadm --examine ${L0} ${L1} ${L2} ${L3} | grep -E "loop|Events"'
    shows THREE different Events values — that is the whole story.
  * Your filesystem cannot be mounted; ${SENTINEL_REL} appears lost.

YOUR GOAL (what "fixed" means)
  1. Bring /dev/md/${ARRAY_NAME} back ONLINE (degraded is acceptable) without
     reformatting — using force-assembly with the freshest members only.
  2. Mount it and prove ${SENTINEL_REL} is intact (its sha256 must match
     the one recorded in ${STATE}).
  3. Restore FULL redundancy by re-adding the evicted disk and watching the
     rebuild reach a clean [UUUU] in /proc/mdstat.

Investigate with:
    cat /proc/mdstat
    mdadm --examine ${L0} ${L1} ${L2} ${L3} | grep -E 'loop|Events|State'
    dmesg | tail -n 20

Reset the whole lab at any time with:  sudo $0 cleanup
${c_red}======================================================${c_rst}

EOF
}

# --------------------------------- Status -----------------------------------
show_status(){
  local md; md="$(md_device || true)"
  info "/proc/mdstat:"; mdstat | sed 's/^/    /'
  echo
  if [ -f "$STATE" ]; then
    info "Superblock event counters per member:"
    local lp
    while IFS= read -r lp; do
      [ -b "$lp" ] || continue
      printf '    %s  ' "$lp"
      mdadm --examine "$lp" 2>/dev/null | awk -F: '/Events/{gsub(/ /,"",$2);print "Events="$2}'
    done < <(awk -F= '/^loop=/{print $2}' "$STATE")
  fi
}

# ---------------------------------- Main ------------------------------------
require_root
need_cmd mdadm losetup mkfs.ext4 truncate dd sha256sum awk

case "${1:-break}" in
  break)
    setup
    trap - ERR           # keep the broken array on purpose from here on
    break_array
    ;;
  status)  show_status ;;
  cleanup) cleanup ;;
  *) err "Unknown command: $1"; echo "Usage: $0 {break|status|cleanup}"; exit 2 ;;
esac

# ============================================================================
#  SOLUTION — step by step (do not peek until you have tried it)
# ============================================================================
#
#  The array will not start because three members carry three different
#  superblock "Events" counters. RAID5 needs at least N-1 = 3 devices whose
#  metadata agrees. The trick is to force-assemble from the FRESHEST members
#  only, letting mdadm pull a near-fresh straggler up to the current event
#  count, then rebuild the truly stale one from parity.
#
#  --------------------------------------------------------------------------
#  STEP 0 — Identify the members and read the evidence
#  --------------------------------------------------------------------------
#    # The four backing loop devices, in creation order:
#    awk -F= '/^loop=/{print $2}' /var/tmp/raid364-lab/lab.state
#
#    # Compare event counters — this tells you who is fresh and who is stale:
#    mdadm --examine /dev/loopN ... | grep -E 'loop|Events|Update Time|State'
#
#    Expect roughly:
#      loop0, loop1  -> highest Events   (the two that were up at crash time)
#      loop2         -> Events - a few   (dropped at the crash; NEAR-fresh)
#      loop3         -> Events - many    (removed days ago; FAR-stale)
#
#  --------------------------------------------------------------------------
#  STEP 1 — Make sure the array is fully stopped
#  --------------------------------------------------------------------------
#    mdadm --stop /dev/md/raid364lab 2>/dev/null || true
#
#  --------------------------------------------------------------------------
#  STEP 2 — Force-assemble from the freshest set only (OMIT the far-stale disk)
#  --------------------------------------------------------------------------
#    # Include loop0, loop1 (fresh) and loop2 (near-fresh). Do NOT feed loop3;
#    # --force would otherwise be tempted to trust a wildly out-of-date member.
#    mdadm --assemble --force /dev/md/raid364lab /dev/loop0 /dev/loop1 /dev/loop2
#
#    # --force rewrites loop2's event counter to match loop0/loop1 and starts
#    # the array DEGRADED. Confirm:
#    cat /proc/mdstat        # expect: active raid5 ... [4/3] [UUU_]
#
#  --------------------------------------------------------------------------
#  STEP 3 — Prove the data survived
#  --------------------------------------------------------------------------
#    mount /dev/md/raid364lab /var/tmp/raid364-lab/mnt
#    sha256sum /var/tmp/raid364-lab/mnt/DO_NOT_LOSE_ME.txt
#    grep sentinel_sha256 /var/tmp/raid364-lab/lab.state   # the two must match
#
#  --------------------------------------------------------------------------
#  STEP 4 — Restore full redundancy with the evicted disk
#  --------------------------------------------------------------------------
#    # loop3 is stale and was marked removed; wipe its old superblock and re-add
#    # it as a fresh member so md rebuilds it from parity:
#    mdadm --zero-superblock /dev/loop3
#    mdadm --add /dev/md/raid364lab /dev/loop3
#
#    # Watch the recovery run to completion:
#    watch -n2 cat /proc/mdstat        # recovery -> [4/4] [UUUU]
#    mdadm --wait /dev/md/raid364lab
#
#  --------------------------------------------------------------------------
#  STEP 5 — Persist the good configuration (real-world follow-up)
#  --------------------------------------------------------------------------
#    # On a real host you would record the array so it assembles cleanly at boot:
#    mdadm --detail --scan /dev/md/raid364lab   # -> append to /etc/mdadm/mdadm.conf
#    # (Skipped here on purpose: the lab uses a private --homehost so it never
#    #  touches your host's mdadm.conf.)
#
#  WHY THIS WORKS
#    - RAID5 tolerates ONE missing member; force-assembling 3 of 4 is safe.
#    - --force only bridges SMALL event gaps (loop2), which is why loop3 was
#      excluded: trusting a far-stale member could serve corrupt parity.
#    - Re-adding loop3 triggers a parity rebuild, not a trust of its old data,
#      so redundancy is restored from known-good stripes.
#
#  KEY COMMANDS FOR 364.2
#    mdadm --examine <dev>              # per-device superblock (Events!)
#    mdadm --detail   <md>             # array-level state
#    mdadm --assemble --force <md> ... # recover mismatched-event arrays
#    mdadm --add / --re-add <md> <dev> # restore/rebuild a member
#    cat /proc/mdstat ; mdadm --wait   # monitor resync/recovery/reshape
#
#  Sources:
#    https://www.lpi.org/our-certifications/exam-306-objectives/
#    man 8 mdadm ; man 5 mdadm.conf ; man 4 md
# ============================================================================