#!/usr/bin/env bash
# =============================================================================
#  LPIC-1 v5.0 — Exam 101-500 — Topic 103.3 "Perform basic file management"
#  Exam weight: 6.25                                    Lab type: break & fix
#
#  Objective source (official):
#    https://www.lpi.org/our-certifications/exam-101-objectives/
#
#  WHAT THIS LAB IS
#    It builds a small production-shaped deployment tree for a fictional
#    service ("invoicer") and then breaks it in six controlled ways. Every
#    fault is repairable ONLY with the command set listed in objective 103.3:
#
#      cp  find  mkdir  mv  ls  rm  rmdir  touch  tar  cpio  dd  file
#      gzip  gunzip  bzip2  bunzip2  xz  unxz  and shell globbing
#
#    The faults are the ones that actually bite in production: archives whose
#    extension lies about their compression, filenames that weaponise the
#    shell, tarballs with a build-directory prefix, a legacy cpio payload, a
#    block device header destroyed by a careless dd, and a log directory that
#    must be pruned by age instead of by name.
#
#  SAFETY CONTRACT
#    * Run ONLY on a disposable lab VM, container or snapshot you can throw
#      away. It must be run as root.
#    * Everything created or destroyed lives in exactly three paths:
#          /opt/lab/lpic1-103.3          (the lab tree)
#          /var/lib/lpic1-103.3          (expected-state manifests)
#          /usr/local/bin/lab-103.3-check (the grader)
#      Nothing else on the system is read, written, moved or deleted.
#    * No service is installed, no unit is enabled, no network call is made,
#      no package is installed, no real device node is touched. The only
#      "block device" in the lab is a 64 KiB regular file.
#    * `sudo ./break-fix-103.3.sh --reset` removes those three paths and
#      leaves the machine exactly as it was.
#
#  USAGE
#    sudo ./break-fix-103.3.sh            # build the lab and break it
#    sudo ./break-fix-103.3.sh --force    # rebuild from scratch over an old run
#         lab-103.3-check                 # grade your repair (run as yourself)
#    sudo ./break-fix-103.3.sh --reset    # remove every trace of the lab
#
#  The full step-by-step solution is at the bottom of this file, commented out.
#  Do not read it until the grader has beaten you at least twice.
# =============================================================================

set -Eeuo pipefail
export LC_ALL=C

readonly LAB_ID="lpic1-103.3"
readonly LAB_ROOT="/opt/lab/${LAB_ID}"
readonly STATE_DIR="/var/lib/${LAB_ID}"
readonly CHECKER="/usr/local/bin/lab-103.3-check"

readonly SRV="${LAB_ROOT}/srv/invoicer"
readonly APP="${SRV}/app"
readonly DATA="${SRV}/data"
readonly TPL="${SRV}/templates"
readonly SPOOL="${LAB_ROOT}/spool/incoming"
readonly BACKUPS="${LAB_ROOT}/backups"
readonly RELEASES="${LAB_ROOT}/releases"
readonly LEGACY="${LAB_ROOT}/legacy"
readonly IMAGES="${LAB_ROOT}/images"
readonly LOGDIR="${LAB_ROOT}/var/log/invoicer"

WORK=""
ACTION="break"
FORCE=0

# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'die "aborted on line $LINENO"' ERR

usage() {
    sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "this script must run as root (try: sudo $0 $*)"
}

require_tools() {
    local missing=() t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if ((${#missing[@]})); then
        warn "missing required tools: ${missing[*]}"
        say  "  Debian/Ubuntu : apt-get install -y tar cpio gzip bzip2 xz-utils file coreutils findutils"
        say  "  RHEL/Fedora   : dnf install -y tar cpio gzip bzip2 xz file coreutils findutils"
        die  "install them and run this script again"
    fi
}

confirm_disposable() {
    (( FORCE )) && return 0
    [[ "${LAB_I_UNDERSTAND:-}" == "yes" ]] && return 0

    cat <<EOF
${C_YEL}
  This script deliberately destroys files. It is a teaching lab.

  It will create and later mangle content under:
      ${LAB_ROOT}
      ${STATE_DIR}
      ${CHECKER}

  It touches NOTHING else. Even so: run it on a throw-away VM, container
  or snapshot only — never on a machine whose state you care about.
${C_OFF}
EOF
    if [[ ! -t 0 ]]; then
        die "no TTY to confirm on; re-run with --force or LAB_I_UNDERSTAND=yes"
    fi
    local ans
    read -r -p "Type exactly: break my lab VM  > " ans
    [[ "$ans" == "break my lab VM" ]] || die "confirmation not given, nothing was changed"
}

# --------------------------------------------------------------------------
# reset
# --------------------------------------------------------------------------
do_reset() {
    # Defensive: never let these variables degrade into "/" or "".
    [[ "$LAB_ROOT"  == /opt/lab/lpic1-103.3 ]] || die "refusing to delete '$LAB_ROOT'"
    [[ "$STATE_DIR" == /var/lib/lpic1-103.3 ]] || die "refusing to delete '$STATE_DIR'"
    rm -rf -- "$LAB_ROOT" "$STATE_DIR"
    rm -f  -- "$CHECKER"
    ok "lab removed: ${LAB_ROOT}, ${STATE_DIR}, ${CHECKER}"
}

# --------------------------------------------------------------------------
# manifest helpers (used at build time; mirrored inside the grader)
# --------------------------------------------------------------------------
relpaths() { ( cd "$1" && find . -type f | sort ); }
hashes()   { find "$1" -type f -exec sha256sum {} + | sed 's/^\\//' | cut -c1-64 | sort; }
names1()   { find "$1" -maxdepth 1 -type f -printf '%f\0' | sort -z; }

# --------------------------------------------------------------------------
# build the pristine deployment, then break it
# --------------------------------------------------------------------------
build_and_break() {
    if [[ -e "$LAB_ROOT" && $FORCE -eq 0 ]]; then
        die "$LAB_ROOT already exists — run with --reset first, or --force to rebuild"
    fi
    [[ -e "$LAB_ROOT" ]] && do_reset

    WORK="$(mktemp -d -t lpic1-1033.XXXXXXXX)"
    mkdir -p "$STATE_DIR" "$LAB_ROOT"
    chmod 0755 "$STATE_DIR"

    mkdir -p "$APP" "$DATA" "$TPL" "$SRV/etc" \
             "$SPOOL/archive" "$BACKUPS" "$RELEASES" "$LEGACY" "$IMAGES" "$LOGDIR"

    local now; now="$(date +%s)"

    # ---------------------------------------------------------------- data
    # 10 invoices = the state the service must be returned to.
    local i f
    for i in $(seq 1 10); do
        f="$(printf '%s/INV-2026-%02d.yaml' "$DATA" "$i")"
        printf 'invoice_id: INV-2026-%02d\ncustomer: ACME-%02d\namount_eur: %d\nvat_pct: 21\nstatus: issued\nissued_at: 2026-08-%02d\n' \
               "$i" "$i" "$(( i * 137 ))" "$(( 14 + i ))" > "$f"
    done
    relpaths "$DATA" > "$STATE_DIR/data.paths"
    hashes   "$DATA" > "$STATE_DIR/data.hashes"

    # FAULT 1: two nightly backups whose extension lies about the compression.
    #   invoicer-2026-08-24.tar.gz  is really XZ  and holds an INCOMPLETE
    #                               6-invoice snapshot (the decoy).
    #   invoicer-2026-08-25.tar.bz2 is really GZIP and holds all 10 invoices.
    mkdir -p "$WORK/old/data"
    for i in $(seq 1 6); do
        cp -p "$(printf '%s/INV-2026-%02d.yaml' "$DATA" "$i")" "$WORK/old/data/"
    done
    tar -C "$WORK/old" -cf - data | xz   -9 -c > "$BACKUPS/invoicer-2026-08-24.tar.gz"
    tar -C "$SRV"      -cf - data | gzip -9 -c > "$BACKUPS/invoicer-2026-08-25.tar.bz2"
    touch -d '2026-08-24 03:10:00' "$BACKUPS/invoicer-2026-08-24.tar.gz"
    touch -d '2026-08-25 03:10:00' "$BACKUPS/invoicer-2026-08-25.tar.bz2"
    rm -rf -- "$DATA"                       # <-- the break

    # ------------------------------------------------------------- templates
    mkdir -p "$TPL/partials"
    printf 'INVOICE {{invoice_id}}\nCustomer: {{customer}}\nTotal: {{amount_eur}} EUR\n'   > "$TPL/invoice.tmpl"
    printf 'CREDIT NOTE for {{invoice_id}}\nRefund: {{amount_eur}} EUR\n'                   > "$TPL/credit-note.tmpl"
    printf 'REMINDER: invoice {{invoice_id}} is overdue since {{issued_at}}.\n'             > "$TPL/reminder.tmpl"
    printf '<header>ACME S.A. — VAT ESB00000000</header>\n'                                 > "$TPL/partials/header.part"
    printf '<footer>Generated by invoicer 2.4.1</footer>\n'                                 > "$TPL/partials/footer.part"
    printf 'body { font-family: sans-serif; }\n'                                            > "$TPL/partials/styles.css"
    relpaths "$TPL" > "$STATE_DIR/tpl.paths"
    hashes   "$TPL" > "$STATE_DIR/tpl.hashes"

    # FAULT 2 (payload): the templates only survive inside a legacy cpio archive.
    ( cd "$TPL" && find . -print0 | cpio --null --create --format=newc ) \
        > "$LEGACY/legacy-templates.cpio" 2>/dev/null
    find "$TPL" -mindepth 1 -delete          # <-- the break (dir stays, empty)

    # ------------------------------------------------------------- release
    local rel="$WORK/release/build/output/staging/invoicer-2.4.1"
    mkdir -p "$rel/bin" "$rel/lib" "$rel/share"
    cat > "$rel/bin/invoicer.sh" <<'EOS'
#!/bin/sh
# invoicer 2.4.1 — entry point (lab stub, renders nothing for real)
. "$(dirname "$0")/../lib/render.sh"
exit 0
EOS
    chmod 0755 "$rel/bin/invoicer.sh"
    printf 'render_invoice() { :; }\n'                        > "$rel/lib/render.sh"
    printf 'to_pdf() { :; }\n'                                > "$rel/lib/pdf.sh"
    printf 'data_dir=/srv/invoicer/data\ntemplate_dir=/srv/invoicer/templates\n' > "$rel/share/invoicer.conf"
    printf '2.4.1\n'                                          > "$rel/VERSION"
    relpaths "$rel" > "$STATE_DIR/app.paths"
    hashes   "$rel" > "$STATE_DIR/app.hashes"

    # FAULT 3: the tarball carries four levels of build-server prefix.
    tar -C "$WORK/release" -czf "$RELEASES/invoicer-2.4.1.tar.gz" build
    # <-- the break: $APP exists but is empty

    # --------------------------------------------------------------- spool
    # FAULT 4: filenames that break naive globbing. Every *.txt must reach
    # spool/incoming/archive/ intact; the four non-.txt files must not move.
    local nl=$'\n'
    printf 'cleanup notes, do not lose\n'      > "$SPOOL/-tmp-cleanup.txt"
    printf 'Q3 revenue: 412k EUR\n'            > "$SPOOL/Q3 revenue notes.txt"
    printf 'draft, unsent\n'                   > "$SPOOL/invoice${nl}DRAFT.txt"
    printf 'ACME contract renewal\n'           > "$SPOOL/contract(2026)final.txt"
    printf 'signed off by finance\n"'          > "$SPOOL/\$HOME_signoff.txt"
    printf 'id,amount\n1,137\n'                > "$SPOOL/data[2026].csv"
    printf 'uptime 99.95%%\n'                  > "$SPOOL/50%_uptime.log"
    printf 'binary-ish payload\n'              > "$SPOOL/payload.bin"
    printf 'keep me where I am\n'              > "$SPOOL/manifest.json"
    names1 "$SPOOL" | tr -d '\0' >/dev/null    # sanity: names1 works here
    ( cd "$SPOOL" && find . -maxdepth 1 -type f -name '*.txt' -printf '%f\0' | sort -z ) \
        > "$STATE_DIR/spool_txt.names"
    ( cd "$SPOOL" && find . -maxdepth 1 -type f -name '*.txt' -exec sha256sum {} + \
        | sed 's/^\\//' | cut -c1-64 | sort ) > "$STATE_DIR/spool_txt.hashes"
    ( cd "$SPOOL" && find . -maxdepth 1 -type f ! -name '*.txt' -printf '%f\0' | sort -z ) \
        > "$STATE_DIR/spool_rest.names"

    # ------------------------------------------------------------ firmware
    # FAULT 5: a 64 KiB image whose 512-byte header was wiped by a bad dd.
    local img="$IMAGES/invoicer-firmware.img"
    head -c 65536 /dev/urandom > "$img"
    { printf 'INVOICER-FW-HEADER v2 magic=0x494E5643 crc=deadbeef'; head -c 462 /dev/zero; } \
        | dd of="$img" bs=512 count=1 conv=notrunc status=none
    dd if="$img" of="$IMAGES/header.bin" bs=512 count=1 status=none
    sha256sum < "$img" | cut -c1-64 > "$STATE_DIR/fw.sha"
    dd if=/dev/zero of="$img" bs=512 count=1 conv=notrunc status=none   # <-- the break

    # ---------------------------------------------------------------- logs
    # FAULT 6: prune by age, not by name. Numbers are interleaved on purpose,
    # and two stale files carry hostile names.
    local keep=(1 2 3 4 31 32 33 34 35 36 37 38 39 40)
    local stale=(5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)
    printf 'current log\n' > "$LOGDIR/invoicer.log"
    touch -d "@$(( now - 3600 ))" "$LOGDIR/invoicer.log"
    for i in "${keep[@]}"; do
        printf 'rotated log %s\n' "$i" > "$LOGDIR/invoicer.log.$i"
        touch -d "@$(( now - (2 + i % 7) * 86400 ))" "$LOGDIR/invoicer.log.$i"
    done
    for i in "${stale[@]}"; do
        printf 'rotated log %s\n' "$i" > "$LOGDIR/invoicer.log.$i"
        touch -d "@$(( now - (45 + i) * 86400 ))" "$LOGDIR/invoicer.log.$i"
    done
    printf 'stale debug trace\n' > "$LOGDIR/-old-debug.log"
    printf 'stale audit trail\n' > "$LOGDIR/audit report 2026-05.log"
    touch -d "@$(( now - 90 * 86400 ))"  "$LOGDIR/-old-debug.log"
    touch -d "@$(( now - 120 * 86400 ))" "$LOGDIR/audit report 2026-05.log"
    ( cd "$LOGDIR" && find . -maxdepth 1 -type f ! -mtime +30 -printf '%f\0' | sort -z ) \
        > "$STATE_DIR/logs_keep.names"

    chmod 0644 "$STATE_DIR"/*
    install_checker
    briefing > "$LAB_ROOT/README.txt"

    # Hand the tree to the invoking user so the student can work unprivileged.
    if [[ -n "${SUDO_USER:-}" ]] && id -u "$SUDO_USER" >/dev/null 2>&1; then
        chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$LAB_ROOT"
    fi

    ok "lab built and broken"
    say ""
    briefing
}

# --------------------------------------------------------------------------
# the grader
# --------------------------------------------------------------------------
install_checker() {
    {
        printf '#!/usr/bin/env bash\n'
        printf '# lab-103.3-check — grader for LPIC-1 topic 103.3 (generated file, do not edit)\n'
        printf 'LAB_ROOT=%q\nSTATE_DIR=%q\n' "$LAB_ROOT" "$STATE_DIR"
        cat <<'CHECKER_BODY'
set -uo pipefail
export LC_ALL=C

SRV="$LAB_ROOT/srv/invoicer"; APP="$SRV/app"; DATA="$SRV/data"; TPL="$SRV/templates"
SPOOL="$LAB_ROOT/spool/incoming"; IMAGES="$LAB_ROOT/images"; LOGDIR="$LAB_ROOT/var/log/invoicer"

if [[ -t 1 ]]; then G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; O=$'\033[0m'
else G=""; R=""; Y=""; O=""; fi

PASSED=0; FAILED=0
pass() { printf '%s  PASS  %s %s\n' "$G" "$O" "$1"; PASSED=$((PASSED+1)); }
fail() { printf '%s  FAIL  %s %s\n' "$R" "$O" "$1"; printf '        %shint:%s %s\n' "$Y" "$O" "$2"; FAILED=$((FAILED+1)); }

relpaths() { ( cd "$1" 2>/dev/null && find . -type f | sort ); }
hashes()   { find "$1" -type f -exec sha256sum {} + 2>/dev/null | sed 's/^\\//' | cut -c1-64 | sort; }
names1()   { find "$1" -maxdepth 1 -type f -printf '%f\0' 2>/dev/null | sort -z; }

[[ -d "$STATE_DIR" ]] || { echo "lab state missing — rebuild the lab first"; exit 2; }

echo
echo "LPIC-1 103.3 — grading ${LAB_ROOT}"
echo

# 1 — invoice data restored from the correct backup
if [[ -d "$DATA" ]] \
   && diff -q <(relpaths "$DATA") "$STATE_DIR/data.paths"  >/dev/null 2>&1 \
   && diff -q <(hashes   "$DATA") "$STATE_DIR/data.hashes" >/dev/null 2>&1; then
    pass "1/6 invoice data restored: 10 invoices, byte-for-byte identical"
else
    n=$(find "$DATA" -type f 2>/dev/null | wc -l)
    fail "1/6 invoice data ($n/10 files correct)" \
         "use file(1) on the backups before trusting the extension, and restore the NEWEST complete snapshot into $SRV"
fi

# 2 — spool sorted without data loss
if [[ -d "$SPOOL/archive" ]] \
   && cmp -s <(names1 "$SPOOL/archive") "$STATE_DIR/spool_txt.names" \
   && diff -q <(hashes "$SPOOL/archive") "$STATE_DIR/spool_txt.hashes" >/dev/null 2>&1 \
   && cmp -s <(names1 "$SPOOL")         "$STATE_DIR/spool_rest.names"; then
    pass "2/6 spool sorted: all 5 .txt files archived, 4 non-.txt files untouched"
else
    fail "2/6 spool not sorted correctly" \
         "5 files end in .txt (one starts with '-', one contains a space, one contains a newline). Nothing may be lost, renamed or truncated"
fi

# 3 — release extracted at the right depth
if [[ -x "$APP/bin/invoicer.sh" ]] && [[ ! -e "$APP/build" ]] \
   && diff -q <(relpaths "$APP") "$STATE_DIR/app.paths"  >/dev/null 2>&1 \
   && diff -q <(hashes   "$APP") "$STATE_DIR/app.hashes" >/dev/null 2>&1; then
    pass "3/6 release deployed: $APP/bin/invoicer.sh present and executable"
else
    fail "3/6 release not deployed at the expected depth" \
         "bin/, lib/, share/ and VERSION must sit directly under $APP — strip the build/output/staging/invoicer-2.4.1 prefix, keep the exec bit"
fi

# 4 — templates recovered from the cpio archive
if diff -q <(relpaths "$TPL") "$STATE_DIR/tpl.paths"  >/dev/null 2>&1 \
   && diff -q <(hashes "$TPL") "$STATE_DIR/tpl.hashes" >/dev/null 2>&1; then
    pass "4/6 templates recovered: 6 files including partials/"
else
    fail "4/6 templates missing or incomplete" \
         "the payload is a newc cpio archive in $LAB_ROOT/legacy — extract it INSIDE $TPL, recreating its subdirectory"
fi

# 5 — firmware header repaired without truncating the image
img="$IMAGES/invoicer-firmware.img"
if [[ -f "$img" ]] \
   && [[ "$(stat -c %s "$img")" -eq 65536 ]] \
   && [[ "$(sha256sum < "$img" | cut -c1-64)" == "$(cat "$STATE_DIR/fw.sha")" ]]; then
    pass "5/6 firmware header repaired: 64 KiB intact, magic restored"
else
    sz=$(stat -c %s "$img" 2>/dev/null || echo 0)
    fail "5/6 firmware image still damaged (size ${sz}, expected 65536)" \
         "copy only the first 512-byte block back from header.bin, in place — a plain copy truncates the remaining 65024 bytes"
fi

# 6 — log retention applied by age
stale=$(find "$LOGDIR" -type f -mtime +30 2>/dev/null | wc -l)
if [[ -d "$LOGDIR" ]] && [[ "$stale" -eq 0 ]] \
   && cmp -s <(names1 "$LOGDIR") "$STATE_DIR/logs_keep.names"; then
    pass "6/6 log retention applied: 0 files older than 30 days, 15 recent files kept"
else
    kept=$(find "$LOGDIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
    fail "6/6 log retention wrong (${stale} stale files left, ${kept} files present, 15 expected)" \
         "select by modification time, not by name — the rotation numbers are interleaved and two stale files have hostile names"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
    printf '%sALL %d CHECKS PASSED — the invoicer deployment is healthy.%s\n\n' "$G" "$PASSED" "$O"
    exit 0
fi
printf '%s%d passed, %d still failing.%s Re-run: %s\n\n' "$R" "$PASSED" "$FAILED" "$O" "$0"
exit 1
CHECKER_BODY
    } > "$CHECKER"
    chmod 0755 "$CHECKER"
}

# --------------------------------------------------------------------------
# student briefing
# --------------------------------------------------------------------------
briefing() {
cat <<EOF
===============================================================================
 LPIC-1 103.3 — Perform basic file management — BREAK & FIX
 Lab root : ${LAB_ROOT}
 Grader   : ${CHECKER}   (run it as often as you like, it is read-only)
===============================================================================

INCIDENT REPORT (what the on-call engineer sees)

  02:14  The nightly deploy of "invoicer 2.4.1" is reported as complete, but
         the service does not come up. The unit fails immediately with:

             exec: ${APP}/bin/invoicer.sh: No such file or directory

  02:22  Someone tries to roll back by hand and reports that the data
         directory ${DATA} is gone entirely, and that
         ${TPL} is empty — every invoice template
         has disappeared.

  02:31  The firmware validator on the invoice printer refuses the image
         ${IMAGES}/invoicer-firmware.img with
         "bad magic". Its first 512 bytes are all zeros; a colleague admits
         they ran a dd with the wrong output file earlier tonight.

  02:40  Monitoring pages for disk pressure on ${LOGDIR}:
         42 rotated logs, most of them months old.

  02:55  The unsorted intake directory ${SPOOL}
         is still full: every *.txt must be filed into its archive/ subdir,
         and the previous attempt (rm/mv with a bare *) failed with
         "invalid option -- 't'" and lost nothing only by luck.

YOUR MISSION — six objectives, all gradable

  1. Restore ${DATA} to the LAST COMPLETE nightly
     snapshot. Two archives sit in ${BACKUPS}.
     Their extensions do not match their real compression, and one of them
     is an incomplete snapshot. Identify both before extracting either.

  2. File every *.txt of ${SPOOL} into its
     archive/ subdirectory. Five of them qualify: one begins with '-', one
     contains a space, one contains a newline, one contains parentheses and
     one contains a '\$'. The four non-.txt files must stay where they are.
     Nothing may be lost, renamed or truncated.

  3. Deploy ${RELEASES}/invoicer-2.4.1.tar.gz into
     ${APP} so that bin/, lib/, share/ and VERSION sit
     directly under app/. The build server wrapped everything in four levels
     of prefix (build/output/staging/invoicer-2.4.1). Keep the exec bit.

  4. Recover the six invoice templates from the legacy archive in
     ${LEGACY} into ${TPL},
     recreating its partials/ subdirectory.

  5. Repair invoicer-firmware.img: copy the intact 512-byte header from
     ${IMAGES}/header.bin back over block 0 WITHOUT
     touching the remaining 65024 bytes. Final size must stay 65536.

  6. Delete every file under ${LOGDIR} older than
     30 days and keep everything else. The rotation numbers are interleaved
     on purpose: two stale files carry names that a glob cannot safely
     handle. 15 files must survive.

RULES

  * Only tools from objective 103.3: cp, find, mkdir, mv, ls, rm, rmdir,
    touch, tar, cpio, dd, file, gzip/gunzip, bzip2/bunzip2, xz/unxz and
    globbing. No editor, no scripting language, no hand-crafted content —
    the grader compares SHA-256 sums, not file names.
  * Work as your normal user; nothing here needs root.
  * When you are done:   ${CHECKER}
  * To start over:       sudo $0 --reset && sudo $0

WHAT EACH FAULT IS REALLY TEACHING

  1  An extension is metadata, not evidence: file(1) reads magic bytes.
  2  Word splitting and option parsing are the two ways a file manager
     loses data. find -print0 / -exec ... + and the -- terminator are the
     production answer, not a purist's flourish.
  3  tar stores the paths it was given; --strip-components fixes the
     mismatch between build layout and runtime layout.
  4  cpio still ships inside initramfs and RPM payloads. -i -d -m is the
     restore triad: extract, create dirs, preserve mtimes.
  5  dd defaults to truncating its output file. conv=notrunc plus bs/count
     is what makes an in-place block write safe.
  6  Retention is a property of mtime, never of a filename pattern.
===============================================================================
EOF
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --break)      ACTION="break" ;;
        --check)      ACTION="check" ;;
        --reset)      ACTION="reset" ;;
        -f|--force)   FORCE=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

case "$ACTION" in
    check)
        [[ -x "$CHECKER" ]] || die "grader not installed — build the lab first"
        exec "$CHECKER"
        ;;
    reset)
        require_root
        do_reset
        ;;
    break)
        require_root
        require_tools tar cpio gzip gunzip bzip2 xz dd file find touch sha256sum stat seq install
        confirm_disposable
        build_and_break
        ;;
esac


# =============================================================================
#  S O L U T I O N   —   step by step
#  ---------------------------------------------------------------------------
#  Everything below is commented out. Read it only after the grader has told
#  you "FAIL" at least twice; the diagnostic reflex is the exam skill, the
#  command line is just the notation.
#
#  Shortcut used throughout:
#      LAB=/opt/lab/lpic1-103.3 ; cd "$LAB"
#
#
#  --- FAULT 1 — the archives whose extension lies ---------------------------
#
#  Diagnose first. Never trust the suffix:
#
#      cd "$LAB/backups"
#      ls -l --time-style=long-iso
#      file *
#        invoicer-2026-08-24.tar.gz  : XZ compressed data, checksum CRC64
#        invoicer-2026-08-25.tar.bz2 : gzip compressed data, ... max compression
#
#  So the .gz is really xz and the .bz2 is really gzip. Confirm the contents
#  and pick the newest COMPLETE one before extracting anything:
#
#      xz -dc invoicer-2026-08-24.tar.gz  | tar -tvf -   # only 6 invoices  -> decoy
#      gzip -dc invoicer-2026-08-25.tar.bz2 | tar -tvf - # 10 invoices      -> good
#
#  Restore. The archive stores paths as "data/...", so extract with -C at the
#  parent of data/, i.e. srv/invoicer:
#
#      gzip -dc invoicer-2026-08-25.tar.bz2 | tar -xf - -C "$LAB/srv/invoicer"
#
#  Equivalent one-liners, both acceptable on the exam:
#
#      tar -xzf invoicer-2026-08-25.tar.bz2 -C "$LAB/srv/invoicer"   # GNU tar -z
#      tar --xz -xf invoicer-2026-08-24.tar.gz -C /tmp/decoy         # for the other one
#
#  GNU tar can auto-detect with -a/--auto-compress on create and detects the
#  format on extract anyway; the point of the exercise is that you verified it
#  with file(1) instead of guessing. Verify:
#
#      ls "$LAB/srv/invoicer/data" | wc -l        # -> 10
#
#
#  --- FAULT 2 — filenames that weaponise the shell -------------------------
#
#      cd "$LAB/spool/incoming"
#      ls -b            # -b escapes control chars: you SEE the embedded newline
#      ls -la
#
#  Why `mv *.txt archive/` is wrong: the glob expands to a list whose first
#  element is "-tmp-cleanup.txt", and mv parses a leading '-' as options
#  ("invalid option -- 't'"). The file with the newline would survive the glob
#  but not a `for f in $(ls)` loop, and "Q3 revenue notes.txt" is three words
#  to any unquoted expansion.
#
#  The correct, NUL-safe move — one mv process for the whole batch:
#
#      mkdir -p archive
#      find . -maxdepth 1 -type f -name '*.txt' -exec mv -t archive/ -- {} +
#
#  Portable variant when -t is unavailable (BSD mv), still NUL-safe:
#
#      find . -maxdepth 1 -type f -name '*.txt' -print0 \
#        | xargs -0 -I{} mv -- {} archive/
#
#  Doing a single file by hand needs the -- terminator or a ./ prefix:
#
#      mv -- -tmp-cleanup.txt archive/
#      mv ./-tmp-cleanup.txt archive/
#
#  Verify — the count must be 5 in archive/ and 4 left behind:
#
#      find archive -type f -printf '.' | wc -c     # -> 5
#      find . -maxdepth 1 -type f -printf '.' | wc -c   # -> 4
#
#
#  --- FAULT 3 — the build-directory prefix ---------------------------------
#
#  Look before you extract. This is the habit that prevents tar bombs:
#
#      tar -tzf "$LAB/releases/invoicer-2.4.1.tar.gz" | head
#        build/output/staging/invoicer-2.4.1/bin/invoicer.sh
#        ...
#
#  Four path components to drop, so:
#
#      tar -xzf "$LAB/releases/invoicer-2.4.1.tar.gz" \
#          -C "$LAB/srv/invoicer/app" --strip-components=4
#
#  tar restores the stored mode, so invoicer.sh comes back with 0755. If your
#  umask or a --no-same-permissions extraction lost it:
#
#      chmod 0755 "$LAB/srv/invoicer/app/bin/invoicer.sh"
#
#  Verify:
#
#      ls -l "$LAB/srv/invoicer/app/bin/invoicer.sh"   # -rwxr-xr-x
#      test ! -e "$LAB/srv/invoicer/app/build" && echo "no build/ prefix left"
#
#
#  --- FAULT 4 — the legacy cpio payload ------------------------------------
#
#  Identify and list before extracting; cpio extracts into the CURRENT
#  directory, which is exactly how people spray files over $HOME:
#
#      file "$LAB/legacy/legacy-templates.cpio"     # ASCII cpio archive (SVR4, no CRC)
#      cpio -itv < "$LAB/legacy/legacy-templates.cpio"
#
#  Extract from inside the destination:
#
#      cd "$LAB/srv/invoicer/templates"
#      cpio -idmv --no-absolute-filenames < "$LAB/legacy/legacy-templates.cpio"
#
#        -i  extract      -d  create leading directories (partials/)
#        -m  preserve mtimes   -v  verbose   --no-absolute-filenames  safety
#
#  Verify:
#
#      find . -type f | sort     # 6 files, three of them under ./partials
#
#
#  --- FAULT 5 — the header destroyed by dd ---------------------------------
#
#  Inspect the damage without a hex editor:
#
#      ls -l  "$LAB/images/invoicer-firmware.img"        # 65536 bytes
#      dd if="$LAB/images/invoicer-firmware.img" bs=512 count=1 status=none | od -c | head -3
#      head -c 48 "$LAB/images/header.bin"               # INVOICER-FW-HEADER v2 magic=...
#
#  Write ONLY block 0 back, in place. conv=notrunc is the whole lesson: without
#  it dd truncates the destination to 512 bytes and you have destroyed the
#  payload you were trying to save.
#
#      dd if="$LAB/images/header.bin" \
#         of="$LAB/images/invoicer-firmware.img" \
#         bs=512 count=1 conv=notrunc status=progress
#
#  (If the header had to land somewhere other than block 0 you would add
#   seek=N on the output and skip=N on the input — seek is output-side,
#   skip is input-side. Mixing them up is a classic exam trap.)
#
#  Verify size and magic:
#
#      stat -c %s "$LAB/images/invoicer-firmware.img"    # -> 65536, not 512
#      head -c 21 "$LAB/images/invoicer-firmware.img"    # -> INVOICER-FW-HEADER v2
#
#
#  --- FAULT 6 — retention by age, not by name ------------------------------
#
#  Count first, delete second. -mtime +30 means "modified strictly more than
#  30*24 h ago"; +30 excludes the file that is exactly 30 days old, which is
#  why +30 and -mtime 30 are different questions:
#
#      cd "$LAB/var/log/invoicer"
#      find . -maxdepth 1 -type f -mtime +30 -printf '%TY-%Tm-%Td  %f\n' | sort
#      find . -maxdepth 1 -type f -mtime +30 -printf '.' | wc -c     # -> 28
#
#  Delete. Either form is safe with hostile names; both avoid a glob entirely:
#
#      find . -maxdepth 1 -type f -mtime +30 -delete
#
#      # or, when -delete is unavailable:
#      find . -maxdepth 1 -type f -mtime +30 -print0 | xargs -0 rm -f --
#
#  Why `rm invoicer.log.[0-9]*` is wrong here: the stale and the current
#  rotations share the same name pattern (5..30 are stale, 1..4 and 31..40 are
#  recent), and two stale files are not named invoicer.log.* at all — one
#  starts with '-' and one contains a space.
#
#  Verify:
#
#      find . -type f -mtime +30 | wc -l          # -> 0
#      find . -maxdepth 1 -type f -printf '.' | wc -c   # -> 15
#
#
#  --- FINAL ----------------------------------------------------------------
#
#      lab-103.3-check          # expect: ALL 6 CHECKS PASSED
#      sudo /path/to/break-fix-103.3.sh --reset
#
#
#  REFERENCES
#    LPI 101-500 objectives (103.3):
#      https://www.lpi.org/our-certifications/exam-101-objectives/
#    GNU tar manual — --strip-components, --auto-compress:
#      https://www.gnu.org/software/tar/manual/tar.html
#    GNU cpio manual — copy-in mode, -d, -m, --no-absolute-filenames:
#      https://www.gnu.org/software/cpio/manual/cpio.html
#    GNU coreutils manual — dd (conv=notrunc, seek vs skip):
#      https://www.gnu.org/software/coreutils/manual/html_node/dd-invocation.html
#    GNU findutils manual — -mtime, -print0, -delete, -exec ... +:
#      https://www.gnu.org/software/findutils/manual/html_mono/find.html
#    Bash reference manual — filename expansion:
#      https://www.gnu.org/software/bash/manual/bash.html#Filename-Expansion
# =============================================================================