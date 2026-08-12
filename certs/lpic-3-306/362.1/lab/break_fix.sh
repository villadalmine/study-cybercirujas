#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-3 306 (exam 306-300, v3.0)  ::  Topic 362.1 DRBD  ::  weight 10
#  Break & Fix lab  ::  "Corrupted DRBD internal metadata / Diskless resource"
# ============================================================================
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It builds a fully self-contained, single-node DRBD resource on top of a
#  loopback file (nothing real is touched), writes a known file into it, and
#  then BREAKS it in a controlled way by:
#     1. unmounting and detaching the backing disk, and
#     2. overwriting the last 4 KiB of the backing device, where DRBD keeps the
#        internal meta-data superblock ("magic" signature).
#  The result is a resource stuck in disk:Diskless that REFUSES to re-attach.
#  Your job is to bring it back to disk:UpToDate WITHOUT losing the file that is
#  stored on it. The step-by-step solution is at the very end, commented out.
#
#  WHY THIS IS SAFE
#  ----------------
#  * Everything lives under /var/tmp/drbd-lab-362.1 on a loopback device.
#  * A dedicated resource name (labr0) and minor (/dev/drbd10) are used so this
#    never collides with a real r0/drbd0 you may already have.
#  * The peer is an intentionally unreachable placeholder: this is a one-node
#    lab, so there is NO second copy to fall back to. That is the whole point:
#    you must recover the LOCAL copy, exactly as you would after metadata damage.
#  * RUN ONLY ON A DISPOSABLE VM. It needs root and loads the drbd kernel module.
#
#  USAGE
#  -----
#     sudo ./drbd_break_fix_362_1.sh            # setup + break + briefing (default)
#     sudo ./drbd_break_fix_362_1.sh setup      # only build the working lab
#     sudo ./drbd_break_fix_362_1.sh break      # only apply the fault
#     sudo ./drbd_break_fix_362_1.sh status     # show current DRBD state
#     sudo ./drbd_break_fix_362_1.sh solve      # run the reference fix (instructor)
#     sudo ./drbd_break_fix_362_1.sh cleanup    # tear the whole lab down
#
#  Official references (verify against your installed DRBD version):
#    - LPI 306-300 objectives ...... https://www.lpi.org/our-certifications/exam-306-objectives/
#    - DRBD 9 User's Guide ......... https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
#    - Metadata / create-md ........ https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-metadata
#    - drbdadm(8), drbdmeta(8), drbdsetup(8) man pages
# ============================================================================

set -o pipefail

# ----------------------------- configuration --------------------------------
LAB_DIR="/var/tmp/drbd-lab-362.1"
IMG="${LAB_DIR}/labr0.img"
STATE="${LAB_DIR}/loopdev"
IMG_SIZE="256M"
RES="labr0"
RESFILE="/etc/drbd.d/${RES}.res"
MINOR="10"
DEV="/dev/drbd${MINOR}"
MNT="/mnt/drbd-lab"
PORT="7799"
SECRET="lpic3-306-362-1-lab"
PEER_LABEL="drbd-lab-peer"
PEER_ADDR="10.255.255.254"          # RFC5737-style unreachable placeholder peer
SENTINEL="${MNT}/SENTINEL.txt"
SENTINEL_TEXT="LPIC-3 306 :: topic 362.1 DRBD lab :: this file must survive recovery"

# ------------------------------- helpers ------------------------------------
if [[ -t 1 ]]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else C_R=; C_G=; C_Y=; C_B=; C_0=; fi
log()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo). This lab loads the drbd module and edits /etc/drbd.d/."; }

need_cmds() {
    local m=()
    for c in drbdadm losetup blockdev dd mount umount mkfs.ext4 awk sha256sum modprobe; do
        command -v "$c" >/dev/null 2>&1 || m+=("$c")
    done
    ((${#m[@]}==0)) || die "Missing tools: ${m[*]}  (install 'drbd-utils'/'drbd-tools' and coreutils/e2fsprogs)."
}

ensure_module() {
    modprobe drbd 2>/dev/null || true
    grep -qw drbd /proc/modules 2>/dev/null || die "The 'drbd' kernel module is not loaded and could not be loaded. Install the DRBD kernel module for your kernel."
}

loop_dev() {  # print the loop device backing $IMG, (re)creating the association if needed
    local l=""
    [[ -f "$STATE" ]] && l="$(cat "$STATE" 2>/dev/null || true)"
    if [[ -n "$l" ]] && losetup "$l" >/dev/null 2>&1 && [[ "$(losetup -nO BACK-FILE "$l" 2>/dev/null)" == "$IMG" ]]; then
        printf '%s\n' "$l"; return 0
    fi
    l="$(losetup -j "$IMG" -nO NAME 2>/dev/null | head -n1)"
    if [[ -z "$l" ]]; then
        l="$(losetup --find --show "$IMG")" || die "losetup failed for $IMG"
    fi
    printf '%s\n' "$l" > "$STATE"
    printf '%s\n' "$l"
}

wait_state() {  # wait_state <field:value> [tries]   e.g. wait_state disk:UpToDate 30
    local want="$1" tries="${2:-30}" i
    for ((i=0;i<tries;i++)); do
        drbdadm status "$RES" 2>/dev/null | grep -q "$want" && return 0
        sleep 1
    done
    return 1
}

# ------------------------------- setup --------------------------------------
setup() {
    need_root; need_cmds; ensure_module
    mkdir -p "$LAB_DIR" "$MNT" /etc/drbd.d

    local host; host="$(uname -n)"
    [[ "$host" != "$PEER_LABEL" ]] || die "This host is literally named '$PEER_LABEL'; change PEER_LABEL and retry."

    # Idempotency: if the resource already exists and has a disk, keep it.
    if drbdadm status "$RES" >/dev/null 2>&1 && drbdadm status "$RES" 2>/dev/null | grep -q 'disk:UpToDate'; then
        ok "Resource '$RES' already up and UpToDate; skipping build."
        return 0
    fi

    log "Creating ${IMG_SIZE} backing image and loop device ..."
    [[ -f "$IMG" ]] || { : > "$IMG"; fallocate -l "$IMG_SIZE" "$IMG" 2>/dev/null || dd if=/dev/zero of="$IMG" bs=1M count=256 status=none; }
    local loop; loop="$(loop_dev)"
    ok "Backing store: $IMG  ->  $loop"

    log "Writing $RESFILE ..."
    cat > "$RESFILE" <<EOF
# Managed by the LPIC-3 306 / 362.1 break-fix lab. Single-node, disposable.
resource ${RES} {
    protocol C;
    net {
        cram-hmac-alg sha1;
        shared-secret "${SECRET}";
    }
    on ${host} {
        device    ${DEV} minor ${MINOR};
        disk      ${loop};
        address   127.0.0.1:${PORT};
        meta-disk internal;
    }
    on ${PEER_LABEL} {
        device    ${DEV} minor ${MINOR};
        disk      /dev/null;
        address   ${PEER_ADDR}:${PORT};
        meta-disk internal;
    }
}
EOF

    log "Initialising DRBD internal metadata ..."
    drbdadm -- --force create-md "$RES" || die "create-md failed"

    log "Bringing the resource up ..."
    drbdadm up "$RES" || die "drbdadm up failed"

    log "Forcing this node to be the good copy (no peer exists in a one-node lab) ..."
    drbdadm primary --force "$RES" || die "primary --force failed"
    wait_state "disk:UpToDate" 30 || warn "Disk is not UpToDate yet; continuing anyway."

    log "Creating a filesystem and writing the sentinel file ..."
    mkfs.ext4 -q -F "$DEV" || die "mkfs.ext4 on $DEV failed"
    mount "$DEV" "$MNT" || die "mount failed"
    printf '%s\n' "$SENTINEL_TEXT" > "$SENTINEL"
    sync
    ok "Sentinel written: $SENTINEL"
    ok "Working baseline established. Current state:"
    drbdadm status "$RES" || true
    printf '  sha256(sentinel) = %s\n' "$(sha256sum "$SENTINEL" | awk '{print $1}')"
}

# ----------------------------- the fault ------------------------------------
break_it() {
    need_root; need_cmds; ensure_module
    drbdadm status "$RES" >/dev/null 2>&1 || die "Resource '$RES' is not up. Run '$0 setup' first."

    local loop; loop="$(loop_dev)"

    log "Flushing and unmounting the filesystem ..."
    sync
    umount "$MNT" 2>/dev/null || true

    log "Detaching the backing disk (simulates DRBD dropping a faulty disk) ..."
    drbdadm detach "$RES" || warn "detach returned non-zero (may already be detached)."
    wait_state "disk:Diskless" 15 || warn "Did not observe disk:Diskless; continuing."

    log "Corrupting the DRBD internal meta-data signature on $loop ..."
    local bytes seek
    bytes="$(blockdev --getsize64 "$loop")" || die "cannot size $loop"
    seek=$(( bytes / 4096 - 1 ))            # last 4 KiB block = where the MD superblock lives
    dd if=/dev/urandom of="$loop" bs=4096 count=1 seek="$seek" conv=notrunc status=none \
        || die "failed to scribble metadata"
    sync
    ok "Fault injected."
    briefing "$loop"
}

# --------------------------- student briefing -------------------------------
briefing() {
    local loop="${1:-$(loop_dev)}"
    cat <<EOF

${C_Y}========================= BREAK & FIX BRIEFING =========================${C_0}
Topic 362.1 DRBD — controlled fault: corrupted internal meta-data (Diskless).

WHAT YOU HAVE
  Resource ......... ${RES}
  Device ........... ${DEV}
  Backing disk ..... ${loop}  (loopback file ${IMG})
  Mount point ...... ${MNT}   (currently NOT mounted)
  Peer ............. ${PEER_LABEL} @ ${PEER_ADDR}  — intentionally UNREACHABLE.
                     This is a ONE-NODE lab: there is no healthy replica to
                     copy from. You must recover THIS node's data.

SYMPTOMS YOU WILL SEE
  * 'drbdadm status ${RES}' shows        ->  disk:Diskless
  * 'drbdadm attach ${RES}' FAILS with a meta-data error such as:
        "No valid meta-data signature found"
        "drbdmeta ... apply-al terminated with exit code 255"
  * 'dmesg | tail' shows DRBD meta-data / open() errors on ${loop}
  * You cannot mount ${DEV} — there is no disk behind it.

YOUR GOAL
  Bring ${RES} back to  role:Primary  disk:UpToDate, re-mount it at ${MNT},
  and prove the file ${SENTINEL##*/} survived (its content must be intact).

HINTS
  * DRBD internal meta-data lives at the END of the backing device; your
    filesystem data lives at the beginning. Damaging the tail does NOT
    necessarily destroy the file — but the resource can no longer read its
    generation identifiers, so it refuses to attach.
  * Re-initialising meta-data with 'create-md' rewrites only that tail region.
  * With no peer, a freshly-attached disk is 'Inconsistent'; something has to
    declare "trust this copy" to make it 'UpToDate'.
  * Relevant tools: drbdadm status/dump-md/create-md/attach/up/down/primary.

  When you are done (or stuck), the reference solution is at the bottom of this
  script, commented out. Instructors can auto-fix with:  $0 solve
${C_Y}=======================================================================${C_0}

EOF
}

# --------------------- reference fix (executable) ---------------------------
solve() {
    need_root; need_cmds; ensure_module
    local loop; loop="$(loop_dev)"
    log "Step 1/6 — inspect the damage"
    drbdadm status "$RES" 2>/dev/null || true
    drbdadm attach "$RES" 2>&1 | sed 's/^/    /' || true   # expected to FAIL with a signature error

    log "Step 2/6 — take the resource fully down to release the backing device"
    drbdadm down "$RES" || true

    log "Step 3/6 — re-create the internal meta-data (rewrites only the tail)"
    drbdadm -- --force create-md "$RES" || die "create-md failed"

    log "Step 4/6 — bring it back up (disk will come up Inconsistent)"
    drbdadm up "$RES" || die "up failed"

    log "Step 5/6 — declare this node the authoritative copy -> UpToDate"
    drbdadm primary --force "$RES" || die "primary --force failed"
    wait_state "disk:UpToDate" 30 || warn "disk not UpToDate yet"

    log "Step 6/6 — re-mount and verify the sentinel survived"
    mount "$DEV" "$MNT" || die "mount failed"
    local want got
    want="$(printf '%s\n' "$SENTINEL_TEXT" | sha256sum | awk '{print $1}')"
    got="$(sha256sum "$SENTINEL" 2>/dev/null | awk '{print $1}')"
    drbdadm status "$RES" || true
    if [[ "$want" == "$got" ]]; then
        ok "RECOVERED: ${SENTINEL##*/} is intact (sha256 matches). Data survived metadata loss."
    else
        warn "Resource is UpToDate but the sentinel checksum does not match (expected=$want got=$got)."
    fi
}

# ------------------------------ cleanup -------------------------------------
cleanup() {
    need_root
    log "Tearing the lab down ..."
    umount "$MNT" 2>/dev/null || true
    drbdadm down "$RES" 2>/dev/null || true
    if [[ -f "$STATE" ]]; then
        local l; l="$(cat "$STATE")"; losetup -d "$l" 2>/dev/null || true
    fi
    losetup -j "$IMG" -nO NAME 2>/dev/null | while read -r l; do losetup -d "$l" 2>/dev/null || true; done
    rm -f "$RESFILE"
    rm -rf "$LAB_DIR"
    rmdir "$MNT" 2>/dev/null || true
    ok "Lab removed (resource '$RES', $RESFILE, $LAB_DIR)."
}

status() { drbdadm status "$RES" 2>/dev/null || warn "Resource '$RES' is not defined/up."; }

# ------------------------------ dispatch ------------------------------------
case "${1:-run}" in
    setup)          setup ;;
    break|break_it) break_it ;;
    briefing)       briefing ;;
    solve|fix)      solve ;;
    status)         status ;;
    cleanup|teardown) cleanup ;;
    run|"")         setup && break_it ;;
    *)              die "Unknown action '$1'. Use: setup | break | status | solve | cleanup" ;;
esac

# ============================================================================
#  STEP-BY-STEP SOLUTION (commented). Try it yourself before reading this.
# ============================================================================
#
#  0) CONFIRM THE SYMPTOM. The resource is up but has no disk, and it will not
#     take the backing device back because the meta-data signature is gone.
#
#         drbdadm status labr0
#         # labr0 role:Primary
#         #   disk:Diskless                      <-- no local storage
#         #   drbd-lab-peer connection:Connecting
#
#         drbdadm attach labr0
#         # ... "No valid meta-data signature found in ..."
#         # ... drbdmeta ... apply-al terminated with exit code 255   <-- attach refused
#
#         dmesg | tail
#         # drbd labr0/0 drbd10: open("/dev/loopN") ... meta-data IO error / no signature
#
#  1) UNDERSTAND WHAT IS LOST. DRBD internal meta-data (the generation UUIDs,
#     the activity log, the sync bitmap and the magic superblock) sits in the
#     LAST few KiB of the backing device. Your ext4 data sits at the FRONT.
#     Only the meta-data was destroyed, so the file is (probably) still there —
#     but DRBD cannot start without valid meta-data.
#
#         drbdadm dump-md labr0        # will error: no valid meta-data to dump
#
#  2) TAKE THE RESOURCE DOWN so the backing device is released cleanly:
#
#         drbdadm down labr0
#
#  3) RE-CREATE THE INTERNAL META-DATA. This rewrites ONLY the tail region; it
#     does not touch the filesystem blocks in front of it. '--force' answers the
#     "this may destroy data" prompt (in this lab the tail is already garbage):
#
#         drbdadm -- --force create-md labr0
#         # writing meta data...
#         # New drbd meta data block successfully created.
#
#  4) BRING THE RESOURCE BACK UP. With fresh meta-data and no reachable peer,
#     the local disk comes up as Inconsistent (day-0 state, role Secondary):
#
#         drbdadm up labr0
#         drbdadm status labr0
#         # labr0 role:Secondary
#         #   disk:Inconsistent
#         #   drbd-lab-peer connection:Connecting
#
#  5) DECLARE THIS NODE AUTHORITATIVE. In a one-node situation there is no peer
#     to sync from, so YOU assert that this copy is good. Forcing primary
#     promotes the node AND marks the disk UpToDate:
#
#         drbdadm primary --force labr0
#         drbdadm status labr0
#         # labr0 role:Primary
#         #   disk:UpToDate                      <-- recovered
#
#     (On DRBD 8.4 the equivalent is: drbdadm -- --overwrite-data-of-peer primary labr0)
#
#  6) RE-MOUNT AND VERIFY THE DATA SURVIVED. Because only the meta-data tail was
#     re-initialised, the ext4 filesystem and SENTINEL.txt are intact:
#
#         mount /dev/drbd10 /mnt/drbd-lab
#         cat /mnt/drbd-lab/SENTINEL.txt
#         # LPIC-3 306 :: topic 362.1 DRBD lab :: this file must survive recovery
#
#     Done: role:Primary, disk:UpToDate, filesystem mounted, sentinel intact.
#
#  KEY EXAM TAKEAWAYS (362.1)
#    * disk:Diskless means DRBD lost its backing store; disk:Inconsistent means
#      it has one but the data cannot yet be trusted; disk:UpToDate is healthy.
#    * Internal meta-data is stored at the END of the backing device and is
#      required to attach — losing it strands the resource even though the
#      application data is untouched.
#    * 'drbdadm create-md' re-initialises meta-data; 'primary --force'
#      (a.k.a. --overwrite-data-of-peer) is how you nominate a copy as the
#      authoritative one when there is nothing to resynchronise from.
#    * NEXT LAB: the classic DRBD failure is split-brain (both nodes Primary at
#      once), recovered with 'drbdadm disconnect/connect --discard-my-data' on
#      the victim node — that one needs two nodes, so it is out of scope here.
# ============================================================================