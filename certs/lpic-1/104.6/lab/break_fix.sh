#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-1  (exams 101-500 + 102-500, version 5.0)
#  Topic 104.6 — Create and change hard and symbolic links      Weight: 3.12
#
#  BREAK & FIX LAB — "orderd", a fake production service deployed the way real
#  services are deployed: atomic release directories behind a 'current'
#  symlink, a config chain built out of relative symlinks, a shared library
#  directory reached through a link, a ledger file kept in two places by a
#  hard link, snapshot jobs, and a daemon that opens its log file exactly once.
#
#  This script arms five independent faults, all of them caused by links (or
#  by the absence of one). Nothing outside the lab tree is touched:
#      $LAB_ROOT   default /var/tmp/lab-lpic1-104.6   (one filesystem)
#      /dev/shm/lab-lpic1-104.6                       (a SECOND filesystem)
#  No package is installed, no system file is modified, no service is stopped.
#  Run it on a DISPOSABLE lab VM anyway: that is the habit you want.
#
#  Usage
#      chmod +x break-fix-104.6.sh
#      ./break-fix-104.6.sh setup           # clean lab tree, no faults
#      ./break-fix-104.6.sh break [N|all]   # arm fault N (1..5), default all
#      ./break-fix-104.6.sh status          # inventory + diagnostics
#      ./break-fix-104.6.sh verify [N|all]  # grade your fix (exit 0 == fixed)
#      ./break-fix-104.6.sh reset           # stop lab processes, delete tree
#      -y | --yes                           # skip the interactive confirmation
#      LAB_ROOT=/opt/lab-links ./break-fix-104.6.sh break
#
#  Exam objective and reference documentation (official sources):
#    LPI 101-500 objectives, 104.6 ...... https://www.lpi.org/our-certifications/exam-101-objectives/
#    ln(1) ............................. https://man7.org/linux/man-pages/man1/ln.1.html
#    symlink(7) ........................ https://man7.org/linux/man-pages/man7/symlink.7.html
#    link(2)  (EXDEV, EPERM, EMLINK) ... https://man7.org/linux/man-pages/man2/link.2.html
#    symlink(2) / readlink(2) .......... https://man7.org/linux/man-pages/man2/symlink.2.html
#    unlink(2)  (link count, open fds) . https://man7.org/linux/man-pages/man2/unlink.2.html
#    stat(1) / stat(2) ................. https://man7.org/linux/man-pages/man1/stat.1.html
#    POSIX ln utility .................. https://pubs.opengroup.org/onlinepubs/9699919799/utilities/ln.html
#    path_resolution(7)  (ELOOP) ....... https://man7.org/linux/man-pages/man7/path_resolution.7.html
#
#  THE STEP-BY-STEP SOLUTION IS AT THE BOTTOM OF THIS FILE, COMMENTED OUT.
#  Do not scroll down until you have fought each fault with ls -l, stat,
#  readlink and find. The diagnosis is the exam question; the ln command is
#  only the last five seconds of the answer.
# ============================================================================

set -euo pipefail

LAB_ROOT="${LAB_ROOT:-/var/tmp/lab-lpic1-104.6}"
SHM_DIR="/dev/shm/lab-lpic1-104.6"
MARKER=".disposable-lab-104.6"
WRITER_TAG="orderd-writer-lpic1-1046"
SELF="$0"
ASSUME_YES="${LAB_ASSUME_YES:-0}"
SKIP_F4=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
    C_B=$'\033[1;36m'; C_D=$'\033[2m';    C_0=$'\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
fi

say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }
note()  { printf '%s%s%s\n'  "$C_D" "$*" "$C_0"; }
warn()  { printf '%s%s%s\n'  "$C_Y" "$*" "$C_0"; }
ok()    { printf '  %s[ PASS ]%s %s\n' "$C_G" "$C_0" "$*"; }
bad()   { printf '  %s[ FAIL ]%s %s\n' "$C_R" "$C_0" "$*"; }
die()   { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Paths used by every fault
# ---------------------------------------------------------------------------
REL="$LAB_ROOT/srv/orderd/releases"
CUR="$LAB_ROOT/srv/orderd/current"
SHARED_LIB="$LAB_ROOT/srv/orderd/shared/lib"
CONF_LINK="$LAB_ROOT/etc/orderd/orderd.conf"
LEDGER="$LAB_ROOT/var/lib/orderd/ledger.dat"
LEDGER_BAK="$LAB_ROOT/var/backups/orderd/ledger.dat"
DAILY="$LAB_ROOT/var/snapshots/daily"
OFFBOX="$SHM_DIR/snapshots"
LOG="$LAB_ROOT/var/log/orderd/orderd.log"
STATE="$LAB_ROOT/.state"
PIDFILE="$LAB_ROOT/var/run/orderd-writer.pid"
BIN="$LAB_ROOT/usr/local/bin"
STARTER="$BIN/orderd-start.sh"
BACKUP="$BIN/backup-ledger.sh"
WRITER="$BIN/$WRITER_TAG.sh"
LEDGER_MARK="ORDER 0101 accepted (post-rotation entry)"

# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------
validate_root() {
    case "$LAB_ROOT" in
        /var/tmp/*|/tmp/*|/srv/*|/opt/*) ;;
        *) die "LAB_ROOT must live under /var/tmp, /tmp, /srv or /opt (got '$LAB_ROOT')" ;;
    esac
    case "$LAB_ROOT" in
        */) die "LAB_ROOT must not end in '/'" ;;
        *lab*) ;;
        *) die "LAB_ROOT must contain the string 'lab' (got '$LAB_ROOT')" ;;
    esac
}

preflight() {
    local t missing=()
    for t in stat readlink ln find cmp grep sed date; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]}"
    command -v pkill >/dev/null 2>&1 || note "note: procps 'pkill' not found; reset will rely on the PID file only"
    command -v lsof  >/dev/null 2>&1 || note "note: 'lsof' not found; fault 5 can still be solved through /proc"
}

confirm() {
    [[ "$ASSUME_YES" == "1" ]] && return 0
    cat <<EOF

${C_Y}This script creates and breaks files under:
    $LAB_ROOT
    $SHM_DIR
It starts one background shell (a fake log-writing daemon) and it will delete
those two directories on 'reset'. Run it only on a disposable lab VM.${C_0}

EOF
    [[ -t 0 ]] || die "not a terminal; re-run with --yes to confirm non-interactively"
    local answer
    read -r -p "Type 'lab' to continue: " answer
    [[ "$answer" == "lab" ]] || die "aborted by user"
}

lab_exists() { [[ -f "$LAB_ROOT/$MARKER" ]]; }
need_lab()   { lab_exists || die "no lab at $LAB_ROOT — run: $SELF setup"; }

have_second_fs() {
    [[ -d /dev/shm ]] || return 1
    mkdir -p "$OFFBOX" 2>/dev/null || return 1
    local a b
    a="$(stat -c %d "$LAB_ROOT" 2>/dev/null)" || return 1
    b="$(stat -c %d "$SHM_DIR"  2>/dev/null)" || return 1
    [[ "$a" != "$b" ]]
}

# ---------------------------------------------------------------------------
# Background "daemon" used by fault 5
# ---------------------------------------------------------------------------
writer_pid() {
    [[ -f "$PIDFILE" ]] || return 1
    local p; p="$(cat "$PIDFILE" 2>/dev/null)" || return 1
    [[ -n "$p" && -d "/proc/$p" ]] || return 1
    printf '%s\n' "$p"
}

start_writer() {
    writer_pid >/dev/null 2>&1 && return 0
    mkdir -p "$(dirname "$LOG")" "$(dirname "$PIDFILE")"
    nohup "$WRITER" "$LOG" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$PIDFILE"
    sleep 1
}

stop_writer() {
    local p
    if p="$(writer_pid 2>/dev/null)"; then kill -TERM "$p" 2>/dev/null || true; fi
    command -v pkill >/dev/null 2>&1 && { pkill -f "$WRITER_TAG" 2>/dev/null || true; }
    rm -f "$PIDFILE"
}

deleted_fds() {
    local p t
    for p in /proc/[0-9]*/fd/*; do
        t="$(readlink "$p" 2>/dev/null)" || continue
        case "$t" in
            "$LAB_ROOT"*" (deleted)") printf '%s -> %s\n' "$p" "$t" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Build a pristine lab tree
# ---------------------------------------------------------------------------
build_lab() {
    head1 "Building a clean lab tree under $LAB_ROOT"
    mkdir -p "$LAB_ROOT"/{etc/orderd,var/lib/orderd,var/backups/orderd,var/log/orderd,var/run,var/snapshots/daily,.state}
    mkdir -p "$BIN" "$SHARED_LIB" "$REL"/{1.4.2,1.5.0}/{bin,etc} "$OFFBOX"

    cat > "$LAB_ROOT/$MARKER" <<EOF
Disposable lab for LPIC-1 topic 104.6 (hard and symbolic links).
Created by $SELF. Safe to delete: rm -rf "$LAB_ROOT" "$SHM_DIR"
EOF

    local v
    for v in 1.4.2 1.5.0; do
        cat > "$REL/$v/etc/orderd.conf" <<EOF
# orderd configuration — release $v
listen  = 127.0.0.1:8443
ledger  = ../../../../var/lib/orderd/ledger.dat
libdir  = lib
workers = 4
EOF
        cat > "$REL/$v/bin/orderd" <<'EOF'
#!/usr/bin/env bash
echo "orderd: binary stub (lab)"
EOF
        chmod 0755 "$REL/$v/bin/orderd"
        # relative link: from releases/<v>/ ,  ../../shared/lib == srv/orderd/shared/lib
        ln -sfn ../../shared/lib "$REL/$v/lib"
    done

    printf 'ELF-ish payload, release 1.5.0\n' > "$SHARED_LIB/liborder.so.1"
    ln -sfn liborder.so.1 "$SHARED_LIB/liborder.so"

    # Atomic-release pattern: 'current' is a RELATIVE symlink to a release dir.
    ln -sfn releases/1.5.0 "$CUR"
    # Config chain: from etc/orderd/ , ../../srv/... == $LAB_ROOT/srv/...
    ln -sfn ../../srv/orderd/current/etc/orderd.conf "$CONF_LINK"
    # Command in PATH: from usr/local/bin/ , ../../../srv/... == $LAB_ROOT/srv/...
    ln -sfn ../../../srv/orderd/current/bin/orderd "$BIN/orderd"

    # The ledger: ONE inode, TWO names (a hard link, not a copy).
    printf 'ORDER %04d accepted\n' {1..20} > "$LEDGER"
    ln -f "$LEDGER" "$LEDGER_BAK"

    cat > "$STARTER" <<'EOF'
#!/usr/bin/env bash
# Fake service launcher. Exits 78 (EX_CONFIG) or 71 (EX_OSERR) like a real one.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CONF="$ROOT/etc/orderd/orderd.conf"
if [ ! -L "$CONF" ] && [ ! -f "$CONF" ]; then
    echo "orderd: configuration not found: $CONF" >&2; exit 78
fi
if [ ! -e "$CONF" ]; then
    echo "orderd: cannot read configuration: $CONF: No such file or directory" >&2
    echo "orderd: hint: the path exists as a link but its target does not" >&2
    exit 78
fi
LIBDIR="$ROOT/srv/orderd/current/lib"
if ! readlink -e "$LIBDIR" >/dev/null 2>&1; then
    echo "orderd: library directory unusable: $LIBDIR" >&2
    ls -ld "$LIBDIR" 2>&1 | sed 's/^/orderd: /' >&2
    exit 71
fi
echo "orderd: started"
echo "orderd:   config -> $(readlink -f "$CONF")"
echo "orderd:   libdir -> $(readlink -e "$LIBDIR")"
exit 0
EOF
    chmod 0755 "$STARTER"

    write_backup_script good

    cat > "$WRITER" <<'EOF'
#!/usr/bin/env bash
# Fake daemon: opens its log ONCE at start-up (fd 3) and keeps it open,
# exactly like syslogd, nginx or any long-running service.
set -u
LOG="$1"
exec 3>>"$LOG"
reopen() { exec 3>&-; exec 3>>"$LOG"; }   # SIGHUP == logrotate's postrotate
trap reopen HUP
trap 'exec 3>&- 2>/dev/null; exit 0' TERM INT
i=0
while :; do
    i=$((i+1))
    printf '%s orderd[%d]: ORDER %04d accepted\n' "$(date -Is)" "$$" "$i" >&3
    sleep 2
done
EOF
    chmod 0755 "$WRITER"

    : > "$LOG"
    say "  tree ready: releases 1.4.2 / 1.5.0, current -> releases/1.5.0, ledger hard-linked (nlink=2)"
}

write_backup_script() { # write_backup_script good|buggy
    if [[ "$1" == "buggy" ]]; then
        cat > "$BACKUP" <<'EOF'
#!/usr/bin/env bash
# backup-ledger.sh — nightly ledger snapshots
# 2026-08-24: "optimised" by a colleague — hard links everywhere, zero copies,
#             zero extra disk. Reviewed by nobody.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LEDGER="$ROOT/var/lib/orderd/ledger.dat"
DAILY="$ROOT/var/snapshots/daily"
OFFBOX="${OFFBOX_DIR:-/dev/shm/lab-lpic1-104.6/snapshots}"
mkdir -p "$DAILY" "$OFFBOX"
ln -f "$LEDGER" "$DAILY/ledger.dat"
ln -f "$LEDGER" "$OFFBOX/ledger.dat"
echo "backup-ledger: ok"
EOF
    else
        cat > "$BACKUP" <<'EOF'
#!/usr/bin/env bash
# backup-ledger.sh — nightly ledger snapshots
#   same filesystem  -> hard link  (instant, no extra blocks)
#   other filesystem -> real copy  (hard links cannot cross a mount point)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LEDGER="$ROOT/var/lib/orderd/ledger.dat"
DAILY="$ROOT/var/snapshots/daily"
OFFBOX="${OFFBOX_DIR:-/dev/shm/lab-lpic1-104.6/snapshots}"
mkdir -p "$DAILY" "$OFFBOX"
ln -f "$LEDGER" "$DAILY/ledger.dat"
cp -p -- "$LEDGER" "$OFFBOX/ledger.dat"
echo "backup-ledger: ok"
EOF
    fi
    chmod 0755 "$BACKUP"
}

# ---------------------------------------------------------------------------
# Faults
# ---------------------------------------------------------------------------
fault_title() {
    case "$1" in
        1) echo "dangling symlink — the release that was never uploaded" ;;
        2) echo "severed hard link — rename-on-save split one inode into two" ;;
        3) echo "symlink loop (ELOOP) — the library path that eats itself" ;;
        4) echo "cross-device hard link (EXDEV) — the backup that cannot link" ;;
        5) echo "unlinked open inode — the log file with a link count of 0" ;;
    esac
}

break_1() {
    ln -sfn releases/1.5.1 "$CUR"
    cat <<EOF

${C_R}FAULT 1 ARMED${C_0} — $(fault_title 1)

  Scenario
    A deploy job rolled the atomic 'current' symlink forward to release 1.5.1,
    whose tarball never finished uploading. Nothing was copied and nothing was
    deleted: exactly one symlink target changed.

  Symptom you will see
    \$ ls -l $CUR
        the link is listed, permissions lrwxrwxrwx, looks healthy
    \$ cat $CONF_LINK
        cat: $CONF_LINK: No such file or directory
    \$ $STARTER
        orderd: cannot read configuration ...  (exit 78, EX_CONFIG)
    A symbolic link is an independent inode holding a PATH STRING. The string
    is stored verbatim and resolved at every open(). 'ls -l' shows the link
    itself; 'ls -lL', cat, and every reader follow it and fail.

  What you must achieve
    * $CUR is still a SYMBOLIC LINK (not a copy, not a renamed directory)
    * its stored target is RELATIVE, so the tree stays relocatable
    * it resolves to a release directory that exists and holds etc/orderd.conf
    * reading $CONF_LINK works again

  Hints     man 1 ln (-s, -f, -n)   man 7 symlink   readlink / readlink -f
            find "$LAB_ROOT" -xtype l      (lists every broken link in a tree)
  Grade it  $SELF verify 1
EOF
}

break_2() {
    cp -p "$LEDGER" "$LEDGER.tmp"
    printf '%s\n' "$LEDGER_MARK" >> "$LEDGER.tmp"
    mv -f "$LEDGER.tmp" "$LEDGER"
    cat <<EOF

${C_R}FAULT 2 ARMED${C_0} — $(fault_title 2)

  Scenario
    $LEDGER and
    $LEDGER_BAK
    were ONE inode with TWO names (a hard link: nlink=2). An operator "edited
    the ledger in place" with a tool that writes a temporary file and renames
    it over the original — sed -i, most editors' default backupcopy, rsync
    without -H, an ansible template task. rename(2) replaced the NAME, so the
    name now points at a brand-new inode.

  Symptom you will see
    \$ stat -c '%n  inode=%i  links=%h  size=%s' $LEDGER $LEDGER_BAK
        two different inode numbers, links=1 on each
    New entries appended to var/lib never appear in var/backups, and vice
    versa. Nothing errors out. The backup silently froze in time.

  What you must achieve
    * both paths point at ONE inode again (identical %i) with %h >= 2
    * neither path is a symbolic link — this must be a HARD link
    * the surviving content is the NEWEST one, the copy that contains
      '$LEDGER_MARK'

  Hints     man 1 ln   man 2 link   ls -i   stat -c '%i %h'
            find "$LAB_ROOT" -inum <N>   (all names of one inode)
  Grade it  $SELF verify 2
EOF
}

break_3() {
    ln -sfn ../lib   "$REL/1.5.0/lib"
    ln -sfn 1.5.0/lib "$REL/lib"
    cat <<EOF

${C_R}FAULT 3 ARMED${C_0} — $(fault_title 3)

  Scenario
    Someone tried to "share the library directory between releases" and
    created two symlinks that point at each other:
        $REL/1.5.0/lib  ->  ../lib
        $REL/lib        ->  1.5.0/lib

  Symptom you will see
    \$ ls -l $REL/1.5.0/lib/
        ls: cannot access '...': Too many levels of symbolic links   (ELOOP)
    \$ readlink -e $REL/1.5.0/lib   ->  prints nothing, exit 1
    \$ $STARTER                     ->  exit 71 (EX_OSERR)
    \$ find -L $LAB_ROOT            ->  find: 'Too many levels of symbolic links'
    The kernel caps symlink resolution (40 hops on Linux) and returns ELOOP.
    Each individual link is valid; the CYCLE is the defect.

  What you must achieve
    * $REL/1.5.0/lib resolves cleanly (readlink -e succeeds)
    * it resolves to the real shared directory
      $SHARED_LIB
      through a LINK — do not copy the directory
    * $REL/1.5.0/lib/liborder.so.1 is readable again
    * $SHARED_LIB/liborder.so (the soname link) is left intact

  Hints     man 7 path_resolution   man 1 readlink (-f vs -e vs -m)
            ls -l on the LINK, never on the target: ls -ld, ls -l --  and
            'namei -l <path>' walks a path component by component.
  Grade it  $SELF verify 3
EOF
}

break_4() {
    if [[ "$SKIP_F4" == "1" ]]; then
        warn "FAULT 4 SKIPPED — no second filesystem available (/dev/shm missing or same device as $LAB_ROOT)"
        return 0
    fi
    write_backup_script buggy
    cat <<EOF

${C_R}FAULT 4 ARMED${C_0} — $(fault_title 4)

  Scenario
    $BACKUP was "optimised" to use hard links for
    every snapshot, so backups would cost no disk at all. The daily snapshot
    directory lives on the same filesystem as the ledger; the off-box
    directory ($OFFBOX) is on a different
    mounted filesystem (tmpfs).

  Symptom you will see
    \$ $BACKUP
        ln: failed to create hard link '$OFFBOX/ledger.dat'
            => '...': Invalid cross-device link          (EXDEV, exit != 0)
    The daily snapshot may already exist; the off-box one never appears, and
    because the script runs with 'set -e' every later step is skipped too.
    A hard link is a directory entry pointing at an inode NUMBER, and inode
    numbers are only meaningful inside one filesystem. link(2) therefore
    fails with EXDEV across a mount point — always, by design.

  What you must achieve
    * running $BACKUP exits 0
    * $DAILY/ledger.dat is still a TRUE HARD LINK
      to the ledger (same inode number, no extra blocks consumed)
    * $OFFBOX/ledger.dat exists, on the OTHER
      filesystem, as a regular file with identical content — not a symlink,
      because a symlink pointing back into the failing filesystem is not a
      backup of anything

  Hints     man 2 link (EXDEV)   df -h / stat -c '%d %n' to compare devices
            cp -a, cp -p, cp -l, cp --preserve=links, rsync -H, tar -h
  Grade it  $SELF verify 4
EOF
}

break_5() {
    start_writer
    local p; p="$(writer_pid)" || die "the lab writer failed to start"
    sleep 4
    kill -STOP "$p" 2>/dev/null || true
    local lines last
    lines="$(wc -l < "$LOG")"
    last="$(tail -n 1 "$LOG")"
    printf '%s\n' "$lines" > "$STATE/f5.lines"
    printf '%s\n' "$last"  > "$STATE/f5.lastline"
    rm -f "$LOG"
    kill -CONT "$p" 2>/dev/null || true
    cat <<EOF

${C_R}FAULT 5 ARMED${C_0} — $(fault_title 5)

  Scenario
    A cleanup script ran 'rm' on the active log of a daemon that opened the
    file once at start-up and still holds the descriptor. PID $p is that
    daemon; it is running right now and it is still writing.

  Symptom you will see
    \$ ls -l $(dirname "$LOG")
        orderd.log is gone
    \$ ps -p $p ; ls -l /proc/$p/fd
        3 -> $LOG (deleted)
    \$ lsof +L1 -p $p            (if lsof is installed)
        NLINK column shows 0
    df keeps reporting the space as used and it will not come back until the
    last descriptor closes. unlink(2) removed the NAME, not the inode: the
    inode's link count dropped to 0 but an open file description still
    references it, so the data is alive and nameless. Everything written
    since the deletion is going into that nameless inode.

  What you must achieve
    * $LOG exists again as a regular file
    * it still contains the lines written BEFORE the deletion, including:
        $last
    * no process anywhere is left holding a deleted file under $LAB_ROOT
      (i.e. logging is writing to a real, named file again)
    * do it WITHOUT killing the ledger data — recover first, restart second

  Hints     man 2 unlink   man 1 lsof (+L1)   ls -l /proc/<pid>/fd
            /proc/<pid>/fd/<n> is a usable handle on the live inode.
            On Linux you cannot ln(1) a deleted inode back into the tree —
            think about what you CAN do with that handle, then about how a
            daemon is told to reopen its log (logrotate: copytruncate vs
            create + postrotate reload).
  Grade it  $SELF verify 5
EOF
}

toolbox() {
    cat <<EOF

${C_B}TOOLBOX — everything you need is read-only until the moment you fix${C_0}
  ls -l / ls -ld / ls -lL / ls -li     link itself vs target, inode numbers
  stat -c '%n inode=%i links=%h dev=%d bytes=%s' FILE
  readlink LINK        the stored string, verbatim, one hop
  readlink -f / -e     fully resolved (-e requires the target to exist)
  realpath / namei -l  canonical path / walk a path component by component
  find DIR -xtype l    every dangling symlink under DIR
  find DIR -inum N     every name of one inode  (also: find -samefile FILE)
  find DIR -type l -printf '%p -> %l\\n'
  df -h / df -i        filesystem boundaries and inode exhaustion
  lsof +L1             open files whose link count is 0
  ln TARGET NAME       hard link      ln -s TARGET NAME   symbolic link
  ln -sfn / ln -sr     replace a link to a directory / build a relative link
EOF
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
status() {
    need_lab
    head1 "Lab inventory — $LAB_ROOT"
    printf '  device of lab root : %s\n' "$(stat -c %d "$LAB_ROOT")"
    [[ -d "$SHM_DIR" ]] && printf '  device of off-box  : %s (%s)\n' "$(stat -c %d "$SHM_DIR")" "$SHM_DIR"

    head1 "Symbolic links (the link itself, never the target)"
    local l
    for l in "$CUR" "$CONF_LINK" "$BIN/orderd" "$REL/1.5.0/lib" "$REL/1.4.2/lib" "$REL/lib" "$SHARED_LIB/liborder.so"; do
        [[ -L "$l" ]] && printf '  %s -> %s\n' "$l" "$(readlink "$l")"
    done

    head1 "Link resolution"
    printf '  config chain : %s\n' "$(readlink -e "$CONF_LINK" 2>/dev/null || echo '*** does not resolve ***')"
    printf '  release lib  : %s\n' "$(readlink -e "$REL/1.5.0/lib" 2>/dev/null || echo '*** does not resolve (ELOOP or dangling) ***')"

    head1 "Ledger inodes"
    stat -c '  %n  inode=%i  links=%h  dev=%d  bytes=%s' "$LEDGER" "$LEDGER_BAK" 2>&1 | sed 's/^stat: /  stat: /'
    [[ -e "$DAILY/ledger.dat" ]] && stat -c '  %n  inode=%i  links=%h  dev=%d' "$DAILY/ledger.dat"
    [[ -e "$OFFBOX/ledger.dat" ]] && stat -c '  %n  inode=%i  links=%h  dev=%d' "$OFFBOX/ledger.dat"

    head1 "Dangling links under the lab tree (find -xtype l)"
    find "$LAB_ROOT" -xtype l -printf '  %p -> %l\n' 2>&1 | sed 's/^find:/  find:/' || true

    head1 "Log writer"
    local p
    if p="$(writer_pid 2>/dev/null)"; then
        printf '  running as PID %s\n' "$p"
        ls -l "/proc/$p/fd" 2>/dev/null | sed 's/^/  /' || true
    else
        printf '  not running\n'
    fi
    [[ -e "$LOG" ]] && stat -c '  %n  inode=%i  links=%h  bytes=%s' "$LOG" || printf '  %s: missing\n' "$LOG"

    head1 "Descriptors held on deleted files under the lab tree"
    local d; d="$(deleted_fds || true)"
    if [[ -n "$d" ]]; then printf '%s\n' "$d" | sed 's/^/  /'; else printf '  none\n'; fi
    echo
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
VFAIL=0
chk() { # chk "description" 'shell expression'
    if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; VFAIL=$((VFAIL + 1)); fi
}

verify_1() {
    chk "current is a symbolic link"                    '[ -L "$CUR" ]'
    chk "its target is relative (tree stays portable)"  '[[ "$(readlink "$CUR")" != /* ]]'
    chk "it resolves to an existing directory"          '[ -d "$CUR/" ]'
    chk "the release it points at is under releases/"   '[[ "$(readlink -e "$CUR")" == "$(readlink -e "$REL")"/* ]]'
    chk "current/etc/orderd.conf is readable"           '[ -f "$CUR/etc/orderd.conf" ]'
    chk "etc/orderd/orderd.conf is still a symlink"     '[ -L "$CONF_LINK" ]'
    chk "the config chain resolves end to end"          '[ -f "$(readlink -e "$CONF_LINK")" ]'
    chk "the config still declares listen ="            'grep -Fq "listen" "$CONF_LINK"'
}

verify_2() {
    chk "var/lib ledger is a regular file, not a link"  '[ -f "$LEDGER" ] && [ ! -L "$LEDGER" ]'
    chk "var/backups ledger is a regular file"          '[ -f "$LEDGER_BAK" ] && [ ! -L "$LEDGER_BAK" ]'
    chk "both names share ONE inode"                    '[ "$(stat -c %i "$LEDGER")" = "$(stat -c %i "$LEDGER_BAK")" ]'
    chk "link count is 2 or more"                       '[ "$(stat -c %h "$LEDGER")" -ge 2 ]'
    chk "the newest entry survived"                     'grep -Fq "$LEDGER_MARK" "$LEDGER"'
    chk "the original 20 entries survived"              'grep -Fq "ORDER 0001 accepted" "$LEDGER" && grep -Fq "ORDER 0020 accepted" "$LEDGER"'
}

verify_3() {
    local L="$REL/1.5.0/lib"
    chk "release 1.5.0 lib path resolves (no ELOOP)"    'readlink -e "'"$L"'" >/dev/null'
    chk "it is reached through a link, not a copy"      '[ -L "'"$L"'" ]'
    chk "it resolves to shared/lib"                     '[ "$(readlink -e "'"$L"'")" = "$(readlink -e "$SHARED_LIB")" ]'
    chk "liborder.so.1 is readable through it"          '[ -f "'"$L"'/liborder.so.1" ]'
    chk "the soname link liborder.so still resolves"    '[ -L "$SHARED_LIB/liborder.so" ] && [ -f "$SHARED_LIB/liborder.so" ]'
    chk "no symlink cycle left under releases/"         '! find -L "$REL" -maxdepth 3 2>&1 | grep -qi "too many levels"'
}

verify_4() {
    if [[ "$SKIP_F4" == "1" ]]; then
        ok "skipped — this machine has no second filesystem to link across"
        return 0
    fi
    chk "backup-ledger.sh runs and exits 0"             '"$BACKUP"'
    chk "daily snapshot exists"                         '[ -f "$DAILY/ledger.dat" ]'
    chk "daily snapshot IS a hard link to the ledger"   '[ "$(stat -c %i "$DAILY/ledger.dat")" = "$(stat -c %i "$LEDGER")" ]'
    chk "off-box copy exists"                           '[ -e "$OFFBOX/ledger.dat" ]'
    chk "off-box copy is a real file, not a symlink"    '[ -f "$OFFBOX/ledger.dat" ] && [ ! -L "$OFFBOX/ledger.dat" ]'
    chk "off-box copy is on the OTHER filesystem"       '[ "$(stat -c %d "$OFFBOX/ledger.dat")" != "$(stat -c %d "$LEDGER")" ]'
    chk "off-box content matches the ledger"            'cmp -s "$OFFBOX/ledger.dat" "$LEDGER"'
}

verify_5() {
    local lines last
    lines="$(cat "$STATE/f5.lines" 2>/dev/null || echo 0)"
    last="$(cat "$STATE/f5.lastline" 2>/dev/null || echo '')"
    chk "the log file exists again"                     '[ -f "$LOG" ]'
    chk "it is a regular file with link count >= 1"     '[ ! -L "$LOG" ] && [ "$(stat -c %h "$LOG")" -ge 1 ]'
    chk "the pre-deletion lines were recovered"         '[ -n "'"$last"'" ] && grep -Fq "'"$last"'" "$LOG"'
    chk "it holds at least the $lines recovered lines"  '[ "$(wc -l < "$LOG")" -ge '"$lines"' ]'
    chk "nothing holds a deleted file under the lab"    '[ -z "$(deleted_fds)" ]'
}

verify_one() {
    local n="$1"
    VFAIL=0
    head1 "Fault $n — $(fault_title "$n")"
    "verify_$n"
    if ((VFAIL == 0)); then
        printf '  %s==> FAULT %s FIXED%s\n' "$C_G" "$n" "$C_0"; return 0
    fi
    printf '  %s==> FAULT %s still broken (%d checks failing)%s\n' "$C_R" "$n" "$VFAIL" "$C_0"; return 1
}

verify_all() {
    local n rc=0 passed=0
    for n in 1 2 3 4 5; do
        if verify_one "$n"; then passed=$((passed + 1)); else rc=1; fi
    done
    head1 "Integration check — does orderd start?"
    if "$STARTER" 2>&1 | sed 's/^/  /'; then :; else rc=1; fi
    head1 "Scorecard: $passed / 5 faults fixed"
    ((rc == 0)) && printf '%sAll faults repaired. 104.6 owned.%s\n\n' "$C_G" "$C_0" \
                || printf '%sKeep digging — re-run: %s status%s\n\n' "$C_Y" "$SELF" "$C_0"
    return $rc
}

# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------
reset_lab() {
    validate_root
    if [[ -d "$LAB_ROOT" && ! -f "$LAB_ROOT/$MARKER" ]]; then
        die "$LAB_ROOT exists but carries no '$MARKER' marker — refusing to delete it"
    fi
    confirm
    stop_writer
    rm -rf -- "$LAB_ROOT"
    [[ "$SHM_DIR" == /dev/shm/lab-lpic1-104.6 ]] && rm -rf -- "$SHM_DIR"
    say "lab removed: $LAB_ROOT $SHM_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
usage() {
    sed -n '2,45p' "$SELF" | sed 's/^# \{0,1\}//'
}

main() {
    local cmd="" arg=""
    while (($# > 0)); do
        case "$1" in
            -y|--yes)   ASSUME_YES=1 ;;
            -h|--help|help) usage; return 0 ;;
            -*)         die "unknown option: $1" ;;
            *)          if [[ -z "$cmd" ]]; then cmd="$1"; else arg="$1"; fi ;;
        esac
        shift
    done
    cmd="${cmd:-break}"
    arg="${arg:-all}"

    validate_root
    preflight
    have_second_fs || SKIP_F4=1

    case "$cmd" in
        setup)
            confirm
            lab_exists && { stop_writer; rm -rf -- "$LAB_ROOT" "$SHM_DIR"; }
            build_lab
            say ""
            say "Clean lab ready. Arm the faults with: $SELF break all"
            ;;
        break)
            [[ "$arg" =~ ^([1-5]|all)$ ]] || die "break takes 1..5 or 'all'"
            lab_exists || { confirm; build_lab; }
            toolbox
            if [[ "$arg" == "all" ]]; then
                local n; for n in 1 2 3 4 5; do "break_$n"; done
                head1 "5 faults armed. Diagnose, repair, then run: $SELF verify all"
            else
                "break_$arg"
                head1 "Fault $arg armed. Grade it with: $SELF verify $arg"
            fi
            say ""
            ;;
        status) status ;;
        verify)
            need_lab
            [[ "$arg" =~ ^([1-5]|all)$ ]] || die "verify takes 1..5 or 'all'"
            if [[ "$arg" == "all" ]]; then verify_all; else verify_one "$arg"; fi
            ;;
        reset)  reset_lab ;;
        *)      die "unknown command '$cmd' — try: $SELF help" ;;
    esac
}

main "$@"

# ############################################################################
# #                                                                          #
# #                     S O L U T I O N   —   S P O I L E R                  #
# #        Read only after you have diagnosed each fault on your own.        #
# #                                                                          #
# ############################################################################
#
# Throughout: LAB=/var/tmp/lab-lpic1-104.6   (or your $LAB_ROOT)
#
# ---------------------------------------------------------------------------
# 0. The two mental models everything below rests on
# ---------------------------------------------------------------------------
# HARD LINK  = one more DIRECTORY ENTRY for an existing inode. There is no
#              "original": every name is equal, the inode carries a link count
#              (st_nlink), and the data dies only when the count reaches 0 AND
#              no process holds it open. Restrictions, from link(2):
#                - cannot cross filesystems .................. EXDEV
#                - cannot normally target a directory ........ EPERM
#                - link count has a ceiling .................. EMLINK
#              A hard link costs one directory entry, zero data blocks.
# SYMLINK    = a small inode whose data IS a path string, stored verbatim and
#              resolved at every open(). It may point anywhere, including at
#              nothing (dangling), at another filesystem, at a directory, or
#              at itself (ELOOP). Relative targets resolve from the directory
#              CONTAINING THE LINK — not from your current working directory.
#              This is the #1 source of "it worked until I moved it".
#
# ---------------------------------------------------------------------------
# FAULT 1 — dangling symlink
# ---------------------------------------------------------------------------
# Diagnose:
#   ls -l  $LAB/srv/orderd/current
#       lrwxrwxrwx ... current -> releases/1.5.1
#   ls -ld $LAB/srv/orderd/current/           # trailing slash follows the link
#       ls: cannot access '.../current/': No such file or directory
#   readlink    $LAB/srv/orderd/current       # releases/1.5.1   (verbatim)
#   readlink -e $LAB/srv/orderd/current       # empty, exit 1  -> target absent
#   ls $LAB/srv/orderd/releases               # 1.4.2  1.5.0    -> no 1.5.1
#   find $LAB -xtype l -printf '%p -> %l\n'   # every broken link in the tree
#
# Fix — repoint the link at a release that exists, keeping the target relative:
#   ln -sfn releases/1.5.0 $LAB/srv/orderd/current
#     -s  symbolic
#     -f  replace the existing link
#     -n  treat the existing link-to-directory as a FILE, not as a directory.
#         Without -n, ln would follow 'current' and create
#         releases/1.5.0/current -> releases/1.5.0 . This single flag is the
#         most common real-world deploy bug in the whole objective.
#   Equivalent, when you only have absolute paths at hand:
#   ln -srfn $LAB/srv/orderd/releases/1.5.0 $LAB/srv/orderd/current   # -r = relative
#
# Verify:
#   readlink -f $LAB/etc/orderd/orderd.conf
#       $LAB/srv/orderd/releases/1.5.0/etc/orderd.conf
#   head -3 $LAB/etc/orderd/orderd.conf ; $LAB/usr/local/bin/orderd-start.sh
#   $LAB/../break-fix-104.6.sh verify 1
# Note: 'ln -sfn TARGET LINK' is atomic-ish but not atomic. Production deploys
# use: ln -sfn releases/1.5.0 current.new && mv -T current.new current
# because rename(2) IS atomic — readers never see a missing 'current'.
#
# ---------------------------------------------------------------------------
# FAULT 2 — severed hard link
# ---------------------------------------------------------------------------
# Diagnose:
#   stat -c '%n inode=%i links=%h size=%s' \
#        $LAB/var/lib/orderd/ledger.dat $LAB/var/backups/orderd/ledger.dat
#       ... inode=131075 links=1 size=441      <- newest, has ORDER 0101
#       ... inode=131074 links=1 size=400      <- frozen copy
#   ls -li  on both, or:  find $LAB -samefile $LAB/var/lib/orderd/ledger.dat
#       only ONE name comes back -> the link is gone
#   diff $LAB/var/lib/orderd/ledger.dat $LAB/var/backups/orderd/ledger.dat
#
# Fix — decide which inode holds the good data (var/lib does), then re-link:
#   cd $LAB
#   ln -f var/lib/orderd/ledger.dat var/backups/orderd/ledger.dat
#     -f overwrites the stale destination. If you prefer to be explicit:
#     rm var/backups/orderd/ledger.dat
#     ln var/lib/orderd/ledger.dat var/backups/orderd/ledger.dat
#     (no -s: a symlink here would fail verification and would not survive
#      the deletion of the source, which is the whole point of the backup.)
#
# Verify:
#   stat -c '%n inode=%i links=%h' var/lib/orderd/ledger.dat \
#                                  var/backups/orderd/ledger.dat
#       identical inode, links=2
#   echo 'ORDER 0102 accepted' >> var/backups/orderd/ledger.dat
#   tail -1 var/lib/orderd/ledger.dat        # appears through the other name
#
# Why it broke, so it never happens again:
#   sed -i, most editors (vim with backupcopy=no), rsync without -H, and any
#   write-temp-then-rename tool CREATE A NEW INODE. Appending (>>), truncating
#   (>) and 'ed'-style in-place edits keep it. Tools that preserve links:
#       sed -i --follow-symlinks   (symlinks only, NOT hard links)
#       vim  :set backupcopy=yes   cp --preserve=links   rsync -H   tar -h
#   Rule of thumb: if a file has %h > 1, verify %h AFTER every automated edit.
#
# ---------------------------------------------------------------------------
# FAULT 3 — symlink loop (ELOOP)
# ---------------------------------------------------------------------------
# Diagnose:
#   ls -l $LAB/srv/orderd/releases/1.5.0/lib   # -> ../lib      (link itself)
#   ls -l $LAB/srv/orderd/releases/lib         # -> 1.5.0/lib   (back again)
#   ls -L $LAB/srv/orderd/releases/1.5.0/lib
#       ls: cannot access ...: Too many levels of symbolic links
#   readlink -e $LAB/srv/orderd/releases/1.5.0/lib     # exit 1
#   namei -l  $LAB/srv/orderd/releases/1.5.0/lib       # walks it, shows the cycle
#   Compare with the healthy release: ls -l $LAB/srv/orderd/releases/1.4.2/lib
#       -> ../../shared/lib                            # that is the pattern
#
# Fix — restore the correct relative target and delete the bogus intermediary:
#   ln -sfn ../../shared/lib $LAB/srv/orderd/releases/1.5.0/lib
#   rm      $LAB/srv/orderd/releases/lib          # or: unlink .../releases/lib
#     'rm' / 'unlink' on a symlink ALWAYS removes the link, never the target —
#     unless you write a trailing slash, which makes rm operate on the
#     directory. Never write 'rm mylink/'.
#   Sanity: from releases/1.5.0/ , ../.. is srv/orderd , so ../../shared/lib is
#   $LAB/srv/orderd/shared/lib. Compute relative targets from the LINK's
#   directory; or let ln do it:  ln -sfnr $LAB/srv/orderd/shared/lib \
#                                          $LAB/srv/orderd/releases/1.5.0/lib
#
# Verify:
#   readlink -e $LAB/srv/orderd/releases/1.5.0/lib
#   ls -l $LAB/srv/orderd/current/lib/            # liborder.so -> liborder.so.1
#   $LAB/usr/local/bin/orderd-start.sh            # exit 0
#   find -L $LAB -maxdepth 6 >/dev/null           # silent = no loops left
#
# ---------------------------------------------------------------------------
# FAULT 4 — cross-device hard link (EXDEV)
# ---------------------------------------------------------------------------
# Diagnose:
#   $LAB/usr/local/bin/backup-ledger.sh
#       ln: failed to create hard link '/dev/shm/.../ledger.dat' => '...':
#           Invalid cross-device link
#   Prove the boundary before touching anything:
#       stat -c '%d %n' $LAB/var/lib/orderd/ledger.dat /dev/shm
#       df -h $LAB/var/lib/orderd/ledger.dat /dev/shm     # two filesystems
#   Read the script:  sed -n '1,20p' $LAB/usr/local/bin/backup-ledger.sh
#
# Fix — hard link inside a filesystem, copy across one. Edit the script:
#   ln -f "$LEDGER" "$DAILY/ledger.dat"      # same fs: instant, zero blocks
#   cp -p -- "$LEDGER" "$OFFBOX/ledger.dat"  # other fs: a real copy (-p keeps
#                                            # mode, ownership, timestamps)
#   Do NOT "fix" it with ln -s: a symlink across filesystems is legal but
#   useless as a backup — it stores a path, so if the source filesystem dies
#   you are left holding a dangling string.
#   One-liner, if you prefer sed over an editor:
#     sed -i 's|^ln -f "\$LEDGER" "\$OFFBOX/ledger.dat"$|cp -p -- "$LEDGER" "$OFFBOX/ledger.dat"|' \
#         $LAB/usr/local/bin/backup-ledger.sh
#
# Verify:
#   $LAB/usr/local/bin/backup-ledger.sh && echo OK
#   stat -c '%n inode=%i links=%h dev=%d' $LAB/var/lib/orderd/ledger.dat \
#        $LAB/var/snapshots/daily/ledger.dat /dev/shm/lab-lpic1-104.6/snapshots/ledger.dat
#       daily  : same inode, same dev   -> real hard link
#       off-box: different inode+dev    -> real copy
#
# Related idioms worth knowing for the exam and for production:
#   cp -al SRC DST      hard-link farm: an instant "snapshot" tree, same fs
#                       (the classic rsync --link-dest / rsnapshot backup)
#   cp -a               archive: recurse, preserve, and do NOT follow symlinks
#   rsync -aH           preserves hard links between transferred files
#   tar -cf x.tar dir   stores hard links as links; 'tar -h' dereferences
#                       symlinks instead of archiving them
#   mv across a mount point is a copy+unlink, so it changes the inode and
#   silently breaks hard links exactly like fault 2.
#
# ---------------------------------------------------------------------------
# FAULT 5 — unlinked inode still held open (link count 0)
# ---------------------------------------------------------------------------
# Diagnose:
#   PID=$(cat $LAB/var/run/orderd-writer.pid)
#   ls -l $LAB/var/log/orderd/            # empty: the NAME is gone
#   ps -p $PID -o pid,cmd                 # the daemon is alive and writing
#   ls -l /proc/$PID/fd
#       3 -> /var/tmp/lab-lpic1-104.6/var/log/orderd/orderd.log (deleted)
#   lsof +L1 -p $PID                      # NLINK column = 0
#   df -h $LAB                            # blocks still consumed
#   stat -c '%h' /proc/$PID/fd/3          # link count 0: no name left
#   Reading the live data:  tail -5 /proc/$PID/fd/3
#
# Fix — recover FIRST, then give the daemon a named file again:
#   PID=$(cat $LAB/var/run/orderd-writer.pid)
#   cp /proc/$PID/fd/3 $LAB/var/log/orderd/orderd.log     # rescue the content
#   chmod 0644         $LAB/var/log/orderd/orderd.log
#   kill -HUP $PID                                        # daemon reopens (fd 3
#                                                         # -> the new, named file)
#   sleep 3; ls -l /proc/$PID/fd/3; tail -3 $LAB/var/log/orderd/orderd.log
#     ('cp' from /proc is required: on Linux you CANNOT re-link a deleted
#      inode into the namespace — link(2) on /proc/PID/fd/N returns ENOENT
#      for an inode whose link count already reached 0. The descriptor gives
#      you the DATA, not a name.)
#   If the daemon does not handle SIGHUP, restart it after the copy:
#      kill -TERM $PID
#      nohup $LAB/usr/local/bin/orderd-writer-lpic1-1046.sh \
#            $LAB/var/log/orderd/orderd.log >/dev/null 2>&1 &
#      echo $! > $LAB/var/run/orderd-writer.pid
#
# Verify:
#   ls -l /proc/[0-9]*/fd/* 2>/dev/null | grep deleted | grep lab-lpic1
#       (no output: nothing is holding a nameless inode any more)
#   stat -c '%n inode=%i links=%h bytes=%s' $LAB/var/log/orderd/orderd.log
#
# The production lesson: 'rm' on an open log frees NO space and loses NO data
# until the last descriptor closes — which is why deleting logs to fix a full
# disk so often does nothing, and why logrotate offers exactly two correct
# strategies: 'copytruncate' (copy the file, then truncate the same inode, so
# the descriptor stays valid) or 'create' + a postrotate signal that makes the
# daemon reopen. Both are just link-count arithmetic.
#
# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
#   ./break-fix-104.6.sh verify all      # 5/5 and orderd starts
#   ./break-fix-104.6.sh reset -y        # stop the writer, delete both trees
# ############################################################################