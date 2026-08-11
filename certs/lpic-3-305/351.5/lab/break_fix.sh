#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-3 305-300  (Exam 305-300, version 3.0)
#  Topic 351.5: Virtual Machine Disk Image Management  (exam weight 5.0)
#
#  BREAK & FIX LAB — "The orphaned qcow2 overlay"
#
#  What this drills:
#    - qcow2 copy-on-write overlays and backing-file chains
#    - qemu-img create / info / check / rebase
#    - How a moved or renamed base image detaches every overlay above it
#    - The difference between a SAFE rebase (rewrites data) and an
#      UNSAFE rebase '-u' (rewrites only the header pointer)
#
#  SAFETY:
#    - Everything happens inside a throwaway mktemp directory.
#    - No real block device, no host filesystem, no root required.
#    - qemu-img and libguestfs run entirely in userspace on sparse files.
#    - Meant for a disposable lab VM. Delete the lab dir when finished.
#
#  Sources (official):
#    - qemu-img manual:   https://qemu.readthedocs.io/en/latest/tools/qemu-img.html
#    - libguestfs / guestfish: https://libguestfs.org/guestfish.1.html
#    - LPI 305 objectives: https://www.lpi.org/our-certifications/exam-305-objectives/
# ============================================================================

set -euo pipefail

# --- Dependency check --------------------------------------------------------
# qemu-img is mandatory; guestfish only makes the data proof tangible.
require() { command -v "$1" >/dev/null 2>&1; }

if ! require qemu-img; then
    echo "FATAL: qemu-img not found. Install qemu-utils / qemu-img and re-run." >&2
    exit 1
fi

HAVE_GUESTFISH=0
if require guestfish; then
    HAVE_GUESTFISH=1
else
    echo "NOTE: guestfish (libguestfs) not found — the backing-chain break/fix" >&2
    echo "      still works fully; only the in-image data proof is skipped." >&2
fi

# --- Disposable lab directory ------------------------------------------------
LAB="${LAB_DIR:-$(mktemp -d /tmp/lpic305-351.5-breakfix.XXXXXX)}"
cd "$LAB"
# Backing filenames are stored in the qcow2 header RELATIVE to the overlay's
# own directory, so staying inside $LAB keeps the demonstration deterministic.

echo "=== Lab directory: $LAB ==="
echo

# --- Build the scenario ------------------------------------------------------
echo "[build] Creating base image (base.qcow2, 1 GiB virtual, sparse)..."
qemu-img create -f qcow2 base.qcow2 1G >/dev/null

if [ "$HAVE_GUESTFISH" -eq 1 ]; then
    echo "[build] Partitioning + ext4 + a marker file inside the base image..."
    guestfish -a base.qcow2 >/dev/null <<'EOF'
run
part-disk /dev/sda mbr
mkfs ext4 /dev/sda1
mount /dev/sda1 /
write /from-base.txt "This file lives in the BASE layer."
umount /
EOF
fi

echo "[build] Creating overlay.qcow2 backed by base.qcow2 (copy-on-write)..."
qemu-img create -f qcow2 -F qcow2 -b base.qcow2 overlay.qcow2 >/dev/null

if [ "$HAVE_GUESTFISH" -eq 1 ]; then
    echo "[build] Writing a second marker file into the OVERLAY layer only..."
    guestfish -a overlay.qcow2 >/dev/null <<'EOF'
run
mount /dev/sda1 /
write /from-overlay.txt "This file lives in the OVERLAY layer."
umount /
EOF
fi

echo "[build] Healthy backing chain, as the guest sees it:"
qemu-img info --backing-chain overlay.qcow2
echo

# --- BREAK -------------------------------------------------------------------
# The classic real-world failure: someone "tidies up" or moves the base image
# (backup, storage migration, rename) and every overlay above it is orphaned.
echo "[break] Relocating the base image out from under the overlay..."
mv base.qcow2 base-relocated.qcow2
echo "[break] Done. The overlay's header still points at 'base.qcow2'."
echo

# --- Student briefing --------------------------------------------------------
cat <<BRIEF
============================================================================
                         >>> YOUR TASK, STUDENT <<<
============================================================================

WORKING DIRECTORY:
    $LAB
    (files present now: overlay.qcow2 , base-relocated.qcow2)

THE SYMPTOM YOU WILL SEE:
    Try to inspect or open the overlay:

        \$ cd $LAB
        \$ qemu-img info overlay.qcow2

    It fails with something like:

        qemu-img: Could not open 'overlay.qcow2': Could not open backing
        file: Could not open 'base.qcow2': No such file or directory

    'qemu-img check overlay.qcow2' fails the same way, and any VM configured
    with overlay.qcow2 as its disk will refuse to start. The overlay's data
    is intact — it is simply pointing at a backing file that no longer exists
    at the recorded path.

WHAT SUCCESS LOOKS LIKE (your goal):
    1. 'qemu-img info --backing-chain overlay.qcow2' lists BOTH images again,
       with the backing file resolving to its NEW location.
    2. 'qemu-img check overlay.qcow2' reports: "No errors were found on the image."
    3. If libguestfs is present, both markers are visible through the overlay:
           /from-base.txt      (base layer)
           /from-overlay.txt   (overlay layer)
    4. You did NOT lose or overwrite the overlay's own writes.

CONSTRAINTS / TRAPS:
    - You may NOT simply delete the overlay and start over — the overlay data
      must survive.
    - Do NOT run a *safe* rebase against an empty or wrong base: a safe rebase
      rewrites overlay clusters to preserve the *visible* content relative to
      the new base, and pointing it at the wrong base will silently corrupt
      what the guest reads. Understand -u before you use it.

Fix it, then verify with the three checks above.
The full step-by-step solution is in the comments at the bottom of this script.
============================================================================
BRIEF

exit 0

# ============================================================================
#                          >>> SOLUTION (spoiler) <<<
#      Do not read until you have attempted the fix. Step by step below.
# ============================================================================
#
# ROOT CAUSE
# ----------
# A qcow2 overlay stores, in its header, the path of its backing file. Moving
# or renaming that backing file does not touch the overlay's data — it only
# invalidates the recorded pointer. qemu-img must open the whole chain top to
# bottom, so a missing link at the bottom makes the top image unopenable.
#
#
# STEP 1 — Read the recorded (now-stale) backing path.
# ----------------------------------------------------
# The error message already names it, but you can also read the header field
# without trying to open the backing file:
#
#     qemu-img info -U overlay.qcow2 | grep -i 'backing file'
#     #   backing file: base.qcow2
#     #   backing file format: qcow2
#
# ( -U / --force-share reads the header even if the chain can't be fully
#   opened; the value confirms the overlay expects 'base.qcow2'. )
#
#
# STEP 2 — Locate where the base image actually is now.
# -----------------------------------------------------
#     ls -l base-relocated.qcow2
#     qemu-img info base-relocated.qcow2      # confirm it is the intact qcow2 base
#
#
# STEP 3 — Repoint the overlay with an UNSAFE rebase.
# ---------------------------------------------------
# Because the underlying data has NOT changed — only its location — you want to
# rewrite ONLY the header pointer and leave every overlay cluster untouched.
# That is exactly what 'qemu-img rebase -u' (unsafe) does. It does not open the
# old or new backing file and does not copy any clusters:
#
#     qemu-img rebase -u -f qcow2 -F qcow2 -b base-relocated.qcow2 overlay.qcow2
#
#   -u                 unsafe: update the pointer only, no cluster rewrite
#   -f qcow2           format of the overlay being modified
#   -F qcow2           format of the new backing file (avoids a probe warning)
#   -b base-relocated.qcow2   the new backing file (relative to the overlay dir)
#
# ALTERNATIVE (equally valid): if you are free to restore the original path,
# just move the base image back to the name the overlay expects:
#
#     mv base-relocated.qcow2 base.qcow2
#
# Both restore the chain; the rebase is the right tool when the base legitimately
# now lives somewhere else (storage migration) and you cannot keep the old path.
#
#
# STEP 4 — Verify the chain and integrity.
# ----------------------------------------
#     qemu-img info --backing-chain overlay.qcow2
#     #   image: overlay.qcow2 ... backing file: base-relocated.qcow2
#     #   image: base-relocated.qcow2 ...
#
#     qemu-img check overlay.qcow2
#     #   No errors were found on the image.
#
#
# STEP 5 — Prove the data survived (requires libguestfs).
# -------------------------------------------------------
#     guestfish --ro -a overlay.qcow2 <<'EOF'
#     run
#     mount /dev/sda1 /
#     ls /
#     cat /from-base.txt
#     cat /from-overlay.txt
#     EOF
#     # Both files must be present: base layer + overlay layer read through
#     # the reconnected chain.
#
#
# WHY '-u' AND NOT A PLAIN 'qemu-img rebase -b'
# ---------------------------------------------
# A SAFE rebase (no -u) opens BOTH the old and the new backing file, then, for
# every cluster, copies data as needed so the guest-visible content stays
# identical relative to the new base. That is the correct choice when the new
# base has DIFFERENT contents. Here the base is byte-for-byte the same file that
# simply moved, so a safe rebase would be wasteful and — if the old backing is
# unreadable — impossible. '-u' assumes "the new backing has the same contents
# the overlay was built on" and only fixes the pointer. Using it against a base
# whose contents differ would corrupt what the guest reads: know the difference.
#
#
# CLEANUP
# -------
#     rm -rf "$LAB"      # the whole lab is a single throwaway directory
#
# ============================================================================