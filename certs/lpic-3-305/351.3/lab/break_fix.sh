#!/usr/bin/env bash
#
# lpic-3-305 :: 351.3 QEMU :: Break & Fix Lab
# -----------------------------------------------------------------------------
# Scenario: "The overlay disk that lost its backing file"
#
# This script builds a small qcow2 backing chain (base image + copy-on-write
# overlay), then BREAKS it in a controlled, fully reversible way by rewriting
# the overlay's recorded backing-file pointer so it references a path that does
# not exist. No host device, no root privilege and no persistent state outside
# the lab directory are touched: everything lives under a throwaway directory
# and the break is pure qcow2 header metadata.
#
# Run this ONLY inside a disposable lab VM. It is designed to be safe, but the
# whole point of a break & fix is that you then have to repair it yourself.
#
# References (official):
#   - QEMU disk images / qemu-img:      https://qemu-project.gitlab.io/qemu/system/images.html
#   - qemu-img manual (rebase, check):  https://qemu-project.gitlab.io/qemu/tools/qemu-img.html
#   - QEMU invocation (system emu):     https://qemu-project.gitlab.io/qemu/system/invocation.html
# -----------------------------------------------------------------------------

set -euo pipefail

# ------------------------------- configuration -------------------------------
LAB_DIR="${LAB_DIR:-/tmp/qemu-breakfix-351.3}"
BASE_IMG="base.qcow2"                 # read-only golden image (the backing file)
OVERLAY_IMG="overlay.qcow2"           # copy-on-write layer the "VM" boots from
BROKEN_BACKING="base-MISSING.qcow2"   # the dangling path we will point the overlay at
VIRTUAL_SIZE="1G"                     # virtual size only; files stay sparse/tiny

# ------------------------------- safety rails --------------------------------
require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "FATAL: '$1' not found in PATH. Install the qemu tools first" >&2
        echo "       (Debian/Ubuntu: qemu-utils qemu-system-x86 ; Fedora: qemu-img qemu-system-x86)" >&2
        exit 1
    }
}
require qemu-img

# Guard against running on something that is not a throwaway lab box.
if [[ -z "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB_VM:-}" ]]; then
    cat <<'WARN'
------------------------------------------------------------------------------
This script deliberately breaks a QEMU disk image. It only writes under a
throwaway lab directory, but you must confirm you are on a disposable VM.

Re-run with the guard set, e.g.:

    I_UNDERSTAND_THIS_IS_A_DISPOSABLE_LAB_VM=1 ./breakfix-351.3-qemu.sh

------------------------------------------------------------------------------
WARN
    exit 2
fi

# --------------------------- build the lab fixture ---------------------------
echo "==> Preparing lab directory: ${LAB_DIR}"
rm -rf -- "${LAB_DIR}"
mkdir -p -- "${LAB_DIR}"
cd -- "${LAB_DIR}"

echo "==> Creating base (golden) image: ${BASE_IMG}"
qemu-img create -f qcow2 "${BASE_IMG}" "${VIRTUAL_SIZE}" >/dev/null

echo "==> Creating copy-on-write overlay backed by the base image: ${OVERLAY_IMG}"
qemu-img create -f qcow2 -F qcow2 -b "${BASE_IMG}" "${OVERLAY_IMG}" >/dev/null

echo "==> Healthy backing chain, as it should look:"
qemu-img info --backing-chain "${OVERLAY_IMG}"
echo

# ------------------------------- the sabotage --------------------------------
# 'qemu-img rebase -u' (UNSAFE mode) rewrites ONLY the backing-file pointer in
# the overlay header. It does not read or copy a single cluster of data, so it
# is instantaneous and, crucially, non-destructive: the overlay's own clusters
# are untouched. We aim that pointer at a file that does not exist.
echo "==> BREAKING the overlay: repointing its backing file to a nonexistent path"
qemu-img rebase -u -F qcow2 -b "${BROKEN_BACKING}" "${OVERLAY_IMG}"

# ------------------------------- student brief -------------------------------
cat <<EOF

==============================================================================
                        BREAK & FIX — 351.3 QEMU
              "The overlay disk that lost its backing file"
==============================================================================

WHAT HAPPENED
  You have a qcow2 backing chain in:  ${LAB_DIR}
    - ${BASE_IMG}      : the golden/base image (present, healthy)
    - ${OVERLAY_IMG}   : the copy-on-write layer your VM boots from
  The overlay's recorded backing-file pointer has been changed to
  '${BROKEN_BACKING}', a file that does not exist.

THE SYMPTOM YOU WILL SEE
  1) Inspecting the overlay reports a broken chain, e.g.:

       $ qemu-img info --backing-chain ${OVERLAY_IMG}
       qemu-img: Could not open '${OVERLAY_IMG}': Could not open backing file:
       Could not open '${LAB_DIR}/${BROKEN_BACKING}': No such file or directory

  2) Consistency check refuses to open it:

       $ qemu-img check ${OVERLAY_IMG}
       qemu-img: Could not open '${OVERLAY_IMG}': Could not open backing file: ...

  3) Booting a VM from the overlay fails immediately at disk-open time:

       $ qemu-system-x86_64 -machine accel=kvm:tcg -m 256 -display none \\
             -drive file=${OVERLAY_IMG},if=virtio,format=qcow2
       qemu-system-x86_64: -drive file=${OVERLAY_IMG},...: Could not open backing file: ...

YOUR GOAL
  Repair the backing chain WITHOUT destroying the overlay's own data, so that:

       $ qemu-img check ${OVERLAY_IMG}
       No errors were found on the image.

  and 'qemu-img info --backing-chain ${OVERLAY_IMG}' again lists BOTH images,
  with the overlay backed by '${BASE_IMG}'.

HINTS
  - The real base image is still sitting right next to the overlay. Nothing was
    deleted — only a pointer was rewritten.
  - 'qemu-img info' tells you which backing file an image *thinks* it needs.
  - Read the qemu-img manual for the tool that rewrites a backing pointer, and
    note the difference between its SAFE and UNSAFE (-u) modes.
  - You are only fixing metadata; the overlay's clusters are intact. Which mode
    matches "just fix the pointer, don't touch the data"?

Work in: ${LAB_DIR}
When you think it is fixed, prove it with 'qemu-img check' and '--backing-chain'.
==============================================================================
EOF

# =============================================================================
# SOLUTION — do not read until you have tried it yourself
# =============================================================================
#
# Step 1 — Confirm the symptom and read what the overlay is asking for.
#   The error already names the missing file, but confirm the overlay's
#   recorded pointer directly. '-U'/'--force-share' lets you inspect even when
#   the backing file is unopenable in some qemu-img builds; if your build still
#   errors, the message itself is the diagnosis.
#
#     cd ${LAB_DIR}
#     qemu-img info ${OVERLAY_IMG} 2>&1 | sed -n '1,20p'
#     # -> "backing file: base-MISSING.qcow2" (a path that does not exist)
#
# Step 2 — Locate the real backing file.
#   It is intact, in the same directory, under its correct name:
#
#     ls -l ${BASE_IMG}
#     qemu-img info ${BASE_IMG}        # healthy qcow2, no backing file of its own
#
# Step 3 — Repair the pointer with an UNSAFE rebase.
#   'rebase -u' rewrites ONLY the backing-file field in the overlay header. It
#   does NOT read the (currently broken) old backing file and does NOT copy
#   data — exactly right here, because the overlay's own clusters never changed;
#   only the pointer was wrong. A SAFE rebase (without -u) would try to
#   reconcile clusters against the old backing file and fail, since that file
#   does not exist. Always pass -F to record the backing FORMAT explicitly
#   (qcow2), avoiding raw/qcow2 auto-probing warnings.
#
#     qemu-img rebase -u -F qcow2 -b ${BASE_IMG} ${OVERLAY_IMG}
#
#   Note on paths: qemu stores the backing name as given. A bare filename is
#   resolved relative to the overlay's own directory, which is what we want so
#   the chain stays portable. Use an absolute path only if base and overlay
#   live in different directories.
#
# Step 4 — Verify the repair.
#
#     qemu-img check ${OVERLAY_IMG}
#     # -> No errors were found on the image.
#
#     qemu-img info --backing-chain ${OVERLAY_IMG}
#     # -> overlay.qcow2  (backing file: base.qcow2)
#     # -> base.qcow2     (no backing file)
#
# Step 5 — Prove it boots far enough to open the disk.
#   With the chain repaired, qemu opens the drive; it now fails later with
#   "No bootable device" (there is no OS installed) instead of at disk-open
#   time. Reaching "No bootable device" IS success for this lab.
#
#     timeout 10 qemu-system-x86_64 -machine accel=kvm:tcg -m 256 \
#         -display none -serial stdio -no-reboot \
#         -drive file=${OVERLAY_IMG},if=virtio,format=qcow2 || true
#
# Alternative fix — restore by moving/copying the file to the expected name.
#   If you cannot or do not want to rewrite the header, you can instead satisfy
#   the pointer as it stands by providing the file it is looking for:
#
#     cp --reflink=auto ${BASE_IMG} ${BROKEN_BACKING}   # now base-MISSING.qcow2 exists
#     qemu-img check ${OVERLAY_IMG}                       # passes
#
#   The rebase in Step 3 is the cleaner, canonical repair; this alternative
#   just illustrates that qemu resolves the chain by NAME at open time.
#
# Cleanup — the whole lab is disposable:
#
#     rm -rf ${LAB_DIR}
# =============================================================================