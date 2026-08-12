#!/usr/bin/env bash
#
# break_fix.sh — LPIC-3 306 (exam 306-300) · Topic 364.3: Advanced LVM
# ---------------------------------------------------------------------------
# Controlled "break & fix" drill for a DISPOSABLE lab VM.
#
# Scenario: an over-provisioned LVM *thin pool* that runs OUT OF DATA SPACE.
# This is one of the most common (and most dangerous) production incidents
# with thin provisioning: you advertise 4 GiB of thin volumes on top of a
# 256 MiB physical data area, a workload writes real blocks, the pool hits
# 100 % Data%, and every thin volume backed by it starts throwing I/O errors
# and remounts read-only. The student must recognise DATA exhaustion (vs
# METADATA exhaustion), grow the pool, and bring the volume + filesystem back
# online WITHOUT losing the data already written.
#
# Everything runs on a loopback-backed PV inside a dedicated directory. NO
# real block device is ever touched. A single VG name ("labvg") is used and
# the teardown only removes that VG and only the loop devices whose backing
# file lives under our lab directory.
#
# Reference (official objectives):
#   https://www.lpi.org/our-certifications/exam-306-objectives/
# LVM thin provisioning is documented in lvmthin(7):
#   https://man7.org/linux/man-pages/man7/lvmthin.7.html
#
# Usage:
#   sudo I_HAVE_A_DISPOSABLE_LAB=yes ./break_fix.sh setup   # build + break it
#   sudo ./break_fix.sh teardown                            # remove everything
#   sudo ./break_fix.sh status                              # show current state
#
# The step-by-step SOLUTION is at the very bottom of this file, commented out.
# Do not read it until you have tried to fix the lab yourself.
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Lab configuration ------------------------------------------------------
LAB_DIR="/var/tmp/lvm-lab-3643"
IMG="${LAB_DIR}/pv0.img"
PV_SIZE="1G"          # sparse backing file for the single PV
VG="labvg"
POOL="thinpool"
POOL_DATA="256M"      # real, physical data capacity of the pool
POOL_META="16M"       # thin pool metadata area
THIN="thinvol"
THIN_SIZE="4G"        # advertised (virtual) size — 16x over-provisioned
MNT="${LAB_DIR}/mnt"
FILL_MB="400"         # MiB we try to write: far more than POOL_DATA -> boom

# --- Small helpers ----------------------------------------------------------
say()  { printf '\033[1;36m[lab]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This drill manages LVM/loop devices; run as root (sudo)."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

preflight() {
  need_cmd losetup; need_cmd truncate
  need_cmd pvcreate; need_cmd vgcreate; need_cmd lvcreate
  need_cmd lvs;      need_cmd vgs;      need_cmd lvextend
  need_cmd mkfs.ext4
  # Thin pools need the dm-thin-pool target and thin-provisioning-tools.
  modprobe dm-thin-pool 2>/dev/null || true
  command -v thin_check >/dev/null 2>&1 \
    || warn "thin_check not found (package thin-provisioning-tools / device-mapper-persistent-data)."
  if [ ! -e /sys/module/dm_thin_pool ] && ! grep -qw thin-pool /proc/misc 2>/dev/null; then
    warn "dm-thin-pool target may be unavailable; thin pool creation could fail."
  fi
}

safety_gate() {
  # This script DELIBERATELY breaks a storage stack. Refuse to run unless the
  # operator has explicitly declared this is a throwaway lab machine.
  if [ "${I_HAVE_A_DISPOSABLE_LAB:-}" != "yes" ]; then
    die "Refusing to run. Export I_HAVE_A_DISPOSABLE_LAB=yes ONLY on a disposable lab VM."
  fi
}

# --- Loop-device management (scoped to our backing file only) ---------------
loop_for_img() { losetup -j "$IMG" 2>/dev/null | awk -F: 'NR==1{print $1}'; }

# ---------------------------------------------------------------------------
# TEARDOWN — idempotent; safe to run any number of times.
# ---------------------------------------------------------------------------
teardown() {
  require_root
  say "Tearing the lab down ..."
  # Unmount if mounted.
  if mountpoint -q "$MNT" 2>/dev/null; then
    umount -f "$MNT" 2>/dev/null || true
  fi
  # Remove ONLY our VG (this also removes its LVs and thin pool).
  if vgs "$VG" >/dev/null 2>&1; then
    vgchange -an "$VG" >/dev/null 2>&1 || true
    vgremove -f -y "$VG" >/dev/null 2>&1 || true
  fi
  # Detach ONLY the loop device backing OUR image file.
  local loop; loop="$(loop_for_img || true)"
  if [ -n "${loop:-}" ]; then
    pvremove -ff -y "$loop" >/dev/null 2>&1 || true
    losetup -d "$loop" 2>/dev/null || true
  fi
  # Drop stale dm nodes that reference our VG, just in case.
  if command -v dmsetup >/dev/null 2>&1; then
    dmsetup ls 2>/dev/null | awk -v vg="$VG" '$1 ~ "^"vg"-"{print $1}' \
      | while read -r dev; do dmsetup remove "$dev" 2>/dev/null || true; done
  fi
  rm -rf "$LAB_DIR"
  say "Teardown complete. Nothing outside ${LAB_DIR} was touched."
}

# ---------------------------------------------------------------------------
# STATUS — quick look at the current lab state.
# ---------------------------------------------------------------------------
status() {
  require_root
  echo "== loop device ==";  losetup -j "$IMG" 2>/dev/null || echo "(none)"
  echo "== vgs =="; vgs "$VG" 2>/dev/null || echo "(no ${VG})"
  echo "== lvs =="; lvs -a -o+devices,data_percent,metadata_percent "$VG" 2>/dev/null || true
  echo "== mount =="; findmnt "$MNT" 2>/dev/null || echo "(not mounted)"
  echo "== recent dm/thin kernel messages =="
  dmesg 2>/dev/null | grep -iE "thin|out of data|read-only|I/O error" | tail -n 8 || true
}

# ---------------------------------------------------------------------------
# SETUP — build a healthy over-provisioned thin pool, then break it.
# ---------------------------------------------------------------------------
build_stack() {
  say "Building loopback PV, VG, thin pool and thin volume ..."
  mkdir -p "$LAB_DIR" "$MNT"

  if vgs "$VG" >/dev/null 2>&1; then
    die "VG '${VG}' already exists. Run './break_fix.sh teardown' first (idempotency)."
  fi

  # 1) Backing file + loop device (the "physical disk").
  truncate -s "$PV_SIZE" "$IMG"
  local loop; loop="$(losetup --find --show "$IMG")"
  say "Loop device: ${loop} (backing ${IMG})"

  # 2) PV + VG.
  pvcreate -ff -y "$loop" >/dev/null
  vgcreate "$VG" "$loop" >/dev/null

  # 3) Thin pool with a SMALL real data area, big metadata margin.
  #    --errorwhenfull y makes the failure deterministic and immediate
  #    (instead of queueing writes for 60 s), which is what we want in a drill.
  lvcreate --type thin-pool \
           -L "$POOL_DATA" --poolmetadatasize "$POOL_META" \
           --errorwhenfull y \
           -n "$POOL" "$VG" >/dev/null

  # 4) Grossly over-provisioned thin volume (4 GiB advertised over 256 MiB).
  lvcreate --type thin -V "$THIN_SIZE" --thinpool "$POOL" -n "$THIN" "$VG" >/dev/null

  # 5) Filesystem (ext4 lazy init -> almost no blocks allocated at mkfs time).
  mkfs.ext4 -q -F "/dev/${VG}/${THIN}"
  mount "/dev/${VG}/${THIN}" "$MNT"

  say "Healthy state built:"
  lvs -o+data_percent,metadata_percent "$VG"
}

break_stack() {
  say "Injecting the fault: writing ${FILL_MB} MiB into a ${POOL_DATA} pool ..."
  # Write far more real data than the pool can hold. Expected to fail partway
  # with ENOSPC / EIO once the pool's data area is exhausted.
  dd if=/dev/zero of="${MNT}/payload.bin" bs=1M count="$FILL_MB" \
     conv=fsync 2>"${LAB_DIR}/dd.log" || true
  sync 2>/dev/null || true
  say "Fault injected."
}

briefing() {
  cat <<EOF

============================================================================
 LAB 364.3 — ADVANCED LVM · THIN POOL OUT OF DATA SPACE
============================================================================

WHAT WAS DONE
  * A single loopback PV (${PV_SIZE}) holds VG '${VG}'.
  * Thin pool '${VG}/${POOL}' has only ${POOL_DATA} of REAL data space.
  * Thin volume '${VG}/${THIN}' advertises ${THIN_SIZE} (heavy over-commit),
    is formatted ext4 and mounted at ${MNT}.
  * A workload just tried to write ${FILL_MB} MiB of real blocks into it.

SYMPTOMS YOU WILL OBSERVE
  * 'lvs -a ${VG}' shows the pool's Data% pinned at or near 100.00.
  * Writes to ${MNT} fail; the filesystem has likely gone READ-ONLY.
      Try:  touch ${MNT}/test   ->  "Read-only file system" or I/O error
  * 'dmesg | tail' shows lines such as:
      device-mapper: thin: ... reached low water mark for data device
      device-mapper: thin: ... no free data space
      EXT4-fs error ... Remounting filesystem read-only
  * Check the injected failure:  cat ${LAB_DIR}/dd.log

YOUR MISSION
  Bring '${VG}/${THIN}' back to a writable, healthy state WITHOUT destroying
  the data already written. Specifically:
    1. Prove it is DATA exhaustion, not METADATA exhaustion
       (Data% vs Meta% — they are fixed independently and repaired differently).
    2. Give the thin pool more real space so it is no longer full.
    3. Clear the pool's error/needs-refresh condition and reactivate the volume.
    4. Repair and remount the filesystem; confirm you can write again and that
       payload.bin is still present.
    5. State how you would PREVENT a recurrence in production.

USEFUL STARTING POINTS
    lvs -a -o+data_percent,metadata_percent,seg_monitor ${VG}
    vgs ${VG}            # is there free space in the VG to grow the pool?
    dmesg | grep -i thin
    man lvmthin

When you are done (or stuck), the full solution is at the bottom of this
script file, commented out. Reset the whole lab at any time with:
    sudo ./break_fix.sh teardown
============================================================================
EOF
}

setup() {
  require_root
  safety_gate
  preflight
  build_stack
  break_stack
  briefing
}

# --- Dispatch ---------------------------------------------------------------
case "${1:-setup}" in
  setup)    setup ;;
  break)    require_root; break_stack; briefing ;;   # re-break without rebuild
  teardown|clean|cleanup) teardown ;;
  status)   status ;;
  *) cat >&2 <<EOF
Usage: $0 {setup|teardown|status}
  setup     Build the thin pool lab and inject the out-of-space fault.
            Requires: sudo and  I_HAVE_A_DISPOSABLE_LAB=yes
  teardown  Remove the VG, loop device and lab directory (idempotent).
  status    Show loop/VG/LV/mount/kernel state.
EOF
    exit 2 ;;
esac

# ===========================================================================
# ============================  SOLUTION  ===================================
# ===========================================================================
# Do not read past here until you have attempted the fix.
#
# ---------------------------------------------------------------------------
# STEP 0 — Understand the failure mode
# ---------------------------------------------------------------------------
# A thin pool has TWO independent capacities:
#     * the DATA area   (real blocks handed out to thin volumes)
#     * the METADATA area (the B-tree mapping thin blocks -> pool blocks)
# Either can fill. The recovery is different:
#     * Data full     -> grow data:      lvextend -L +<size>   labvg/thinpool
#     * Metadata full -> grow metadata:  lvextend --poolmetadatasize +<size> \
#                                                              labvg/thinpool
# Growing the wrong one does nothing. Always read BOTH percentages first.
#
# ---------------------------------------------------------------------------
# STEP 1 — Diagnose: which resource is exhausted?
# ---------------------------------------------------------------------------
#   lvs -a -o+data_percent,metadata_percent,seg_monitor labvg
#
#   Expected (abridged):
#     LV               VG     Attr       LSize  Pool     Data%  Meta%
#     thinpool         labvg  twi-aotz-- 256.00m           100.00  1.20
#     [thinpool_tdata] labvg  Twi-ao---- 256.00m
#     [thinpool_tmeta] labvg  ewi-ao----  16.00m
#     thinvol          labvg  Vwi-aotz--   4.00g thinpool  100.00
#
#   Data% = 100.00, Meta% low  ->  this is DATA exhaustion.
#
#   dmesg | grep -i thin
#     device-mapper: thin: 253:3: reached low water mark for data device: ...
#     device-mapper: thin: 253:3: switching pool to out-of-data-space mode
#     device-mapper: thin: 253:3: no free data space
#
# ---------------------------------------------------------------------------
# STEP 2 — Confirm the VG can supply more space
# ---------------------------------------------------------------------------
#   vgs labvg
#     VG    #PV #LV #SN Attr   VSize   VFree
#     labvg   1   2   0 wz--n- 1020.00m 748.00m   <-- plenty of free extents
#
#   If VFree were 0 you would first add capacity to the VG, e.g.:
#     truncate -s 1G /var/tmp/lvm-lab-3643/pv1.img
#     loop=$(losetup --find --show /var/tmp/lvm-lab-3643/pv1.img)
#     pvcreate "$loop" && vgextend labvg "$loop"
#
# ---------------------------------------------------------------------------
# STEP 3 — Grow the pool's DATA area
# ---------------------------------------------------------------------------
#   lvextend -L +512M labvg/thinpool
#     Size of logical volume labvg/thinpool_tdata changed from 256.00 MiB
#     to 768.00 MiB. Logical volume labvg/thinpool successfully resized.
#
#   (For a metadata shortage you would instead run:
#      lvextend --poolmetadatasize +16M labvg/thinpool )
#
# ---------------------------------------------------------------------------
# STEP 4 — Clear the pool error state and reactivate the thin volume
# ---------------------------------------------------------------------------
# After out-of-data-space, the pool sat in error mode. Refresh it so the
# kernel target picks up the new size and leaves error mode, then re-activate
# the thin volume:
#   lvchange --refresh labvg/thinpool
#   lvchange -an labvg/thinvol
#   lvchange -ay labvg/thinvol
#
#   Verify the pool is no longer full:
#     lvs -o+data_percent labvg
#       thinpool  ... 768.00m   33.33   <-- Data% back under 100
#
# ---------------------------------------------------------------------------
# STEP 5 — Repair and remount the filesystem, verify data survived
# ---------------------------------------------------------------------------
# The ext4 fs was forced read-only during the I/O errors; check it clean:
#   umount /var/tmp/lvm-lab-3643/mnt 2>/dev/null || true
#   fsck.ext4 -y /dev/labvg/thinvol
#   mount /dev/labvg/thinvol /var/tmp/lvm-lab-3643/mnt
#
#   Prove it is writable again and the earlier payload is intact:
#     ls -lh /var/tmp/lvm-lab-3643/mnt/payload.bin
#     echo ok > /var/tmp/lvm-lab-3643/mnt/test && cat /var/tmp/lvm-lab-3643/mnt/test
#
# ---------------------------------------------------------------------------
# STEP 6 — Prevent a recurrence (production hygiene)
# ---------------------------------------------------------------------------
# Never let a thin pool reach 100 % silently. Enable autoextend via dmeventd
# in /etc/lvm/lvm.conf (activation section):
#     thin_pool_autoextend_threshold = 80     # extend when 80% full
#     thin_pool_autoextend_percent   = 20     # grow by 20% each time
# and make sure the pool is monitored:
#     lvchange --monitor y labvg/thinpool
# Autoextend only fires if the VG has free extents, so also alert on VFree and
# on 'lvs -o data_percent,metadata_percent'. Decide policy explicitly with
# --errorwhenfull: 'y' fails fast (data integrity first), 'n' queues writes for
# ~60 s hoping autoextend saves them. Reference: man lvmthin.
#
# ---------------------------------------------------------------------------
# One-liner recovery (once diagnosis confirms DATA exhaustion):
#   lvextend -L +512M labvg/thinpool && \
#   lvchange --refresh labvg/thinpool && \
#   lvchange -an labvg/thinvol && lvchange -ay labvg/thinvol && \
#   fsck.ext4 -y /dev/labvg/thinvol && \
#   mount /dev/labvg/thinvol /var/tmp/lvm-lab-3643/mnt
# ===========================================================================