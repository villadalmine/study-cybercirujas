#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 v5.0  |  Exam 101-500  |  Topic 104.5 — Manage file permissions and
#                                                  ownership   (weight 4.69)
#
#  BREAK & FIX LABORATORY — DISPOSABLE VM ONLY
#
#  This script deliberately misconfigures ownership, permission bits, special
#  bits (setuid / setgid / sticky) and the shell file-creation mask inside a
#  self-contained sandbox, then asks you to restore a correct, least-privilege
#  configuration. It never touches anything outside the paths and accounts
#  declared in the CONFIGURATION block below.
#
#  Official objective source:
#    https://www.lpi.org/our-certifications/exam-101-objectives/
#  Manual pages that are the real reference for this topic:
#    chmod(1) chown(1) chgrp(1) umask(1p) stat(1) find(1) ls(1) inode(7)
#    path_resolution(7) credentials(7) execve(2) open(2) sudo(8)
#
#  Usage:
#    sudo ./break-fix-104.5.sh --break     # inject the faults + print briefing
#    sudo ./break-fix-104.5.sh --brief     # reprint the briefing
#    sudo ./break-fix-104.5.sh --hints     # progressive hints, no answers
#    sudo ./break-fix-104.5.sh --verify    # grade your repair (exit 0 = solved)
#    sudo ./break-fix-104.5.sh --reset     # wipe and re-inject a clean break
#    sudo ./break-fix-104.5.sh --clean     # remove every lab artefact
#
#  The full step-by-step solution is at the END of this file, commented out.
#  Do not scroll there until --verify has beaten you at least three times.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------------------- CONFIGURATION -------------------------------
LAB_ID="lab1045"
LAB_ROOT="/srv/${LAB_ID}"
LAB_ETC="/etc/${LAB_ID}"
LAB_BIN="/usr/local/bin/${LAB_ID}-report"
LAB_PROFILE="/etc/profile.d/${LAB_ID}-umask.sh"
LAB_GROUP="webteam"
LAB_USERS=("labdev1" "labdev2" "labsvc")

SHARED="${LAB_ROOT}/shared"
PROJECTS="${SHARED}/projects"
DROPBOX="${LAB_ROOT}/dropbox"
TOOLS="${LAB_ROOT}/tools"
ROGUE="${TOOLS}/dumpcfg"
CONF="${LAB_ETC}/app.conf"
STATE="${LAB_ROOT}/.lab-state"

C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
C_CYA=$'\033[1;36m'; C_RST=$'\033[0m'
[ -t 1 ] || { C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_RST=""; }

log()  { printf '%s[ lab ]%s %s\n' "$C_CYA" "$C_RST" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[fatal]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
ok()   { printf '  %s[ PASS ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
bad()  { printf '  %s[ FAIL ]%s %s\n' "$C_RED" "$C_RST" "$*"; }

HAVE_RUNUSER="no"
command -v runuser >/dev/null 2>&1 && HAVE_RUNUSER="yes"

quote_cmd() { local a out=""; for a in "$@"; do out+=$(printf '%q ' "$a"); done; printf '%s' "$out"; }

# Run a command as an unprivileged lab account (non-login shell: no profile).
as_user() {
  local u="$1"; shift
  if [ "$HAVE_RUNUSER" = "yes" ]; then
    runuser -u "$u" -- "$@"
  else
    su -s /bin/bash -c "$(quote_cmd "$@")" "$u"
  fi
}

# Run a command in a LOGIN shell, so /etc/profile and /etc/profile.d/* are read.
as_login() {
  local u="$1"; shift
  if [ "$HAVE_RUNUSER" = "yes" ]; then
    runuser -l "$u" -c "$*"
  else
    su -l -c "$*" "$u"
  fi
}

# stat -c %a drops leading zeros ("644", "2775"); normalise to 4 octal digits.
norm_mode() { local m; m=$(stat -c '%a' "$1") || return 1; while [ ${#m} -lt 4 ]; do m="0$m"; done; printf '%s' "$m"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "This lab manipulates accounts and system paths: run it as root."; }

require_tools() {
  local t
  for t in stat find chmod chown chgrp useradd groupadd id getent; do
    command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
  done
  [ "$HAVE_RUNUSER" = "yes" ] || command -v su >/dev/null 2>&1 || die "Neither runuser(1) nor su(1) is available."
}

confirm_disposable() {
  local virt="unknown"
  command -v systemd-detect-virt >/dev/null 2>&1 && virt=$(systemd-detect-virt 2>/dev/null || echo none)
  cat <<EOF

${C_YEL}This script creates local accounts, a world-writable directory and a setuid
binary. Run it ONLY on a throw-away lab VM or container you can destroy.${C_RST}
  virtualisation detected : ${virt}
  hostname                : $(hostname)
  paths it will own       : ${LAB_ROOT} ${LAB_ETC} ${LAB_BIN} ${LAB_PROFILE}
  accounts it will create : ${LAB_USERS[*]} (group ${LAB_GROUP})

EOF
  [ "$virt" = "none" ] && warn "No virtualisation detected — this may be bare metal."
  if [ "${LAB_ASSUME_YES:-0}" = "1" ]; then log "LAB_ASSUME_YES=1 — skipping confirmation."; return 0; fi
  local answer=""
  read -r -p "Type BREAK-104.5 to continue: " answer || true
  [ "$answer" = "BREAK-104.5" ] || die "Confirmation not given. Nothing was modified."
}

# ------------------------------- ENVIRONMENT ---------------------------------

create_accounts() {
  local created=() u
  getent group "$LAB_GROUP" >/dev/null 2>&1 || { groupadd "$LAB_GROUP"; created+=("group:$LAB_GROUP"); }
  for u in "${LAB_USERS[@]}"; do
    if ! id -u "$u" >/dev/null 2>&1; then
      useradd -m -s /bin/bash -c "LPIC-1 104.5 lab account" "$u"
      created+=("user:$u")
    else
      warn "Account $u already existed — it will NOT be deleted by --clean."
    fi
    usermod -aG "$LAB_GROUP" "$u"
  done
  printf '%s\n' "${created[@]:-}" > "$STATE"
  chmod 0600 "$STATE"
}

seed_content() {
  mkdir -p "$SHARED" "$PROJECTS" "$DROPBOX" "$TOOLS" "$LAB_ETC" "$LAB_ROOT/reports-archive"

  cat > "$PROJECTS/spec.md" <<'EOF'
# Sprint 34 — shared design specification
Owner: labdev1   Reviewers: labdev2, labsvc
Both developers must be able to read AND edit this file through the group.
EOF

  cat > "$SHARED/README.txt" <<'EOF'
Team share for group "webteam".
Every file created here must belong to the group, without anyone having to
run chgrp by hand afterwards.
EOF

  cat > "$CONF" <<'EOF'
# lab1045 application configuration
# Consumed by /usr/local/bin/lab1045-report, which runs as the service account.
APP_NAME="lab1045-report"
APP_ENV="lab"
DB_HOST="127.0.0.1"
DB_USER="reporter"
DB_PASSWORD="s3cr3t-never-world-readable"
EOF

  cat > "$LAB_BIN" <<'EOF'
#!/usr/bin/env bash
# lab1045-report — minimal service entry point used by the 104.5 lab.
set -euo pipefail
CONF="/etc/lab1045/app.conf"
OUT="/srv/lab1045/shared/reports"

if [ ! -r "$CONF" ]; then
  echo "lab1045-report: cannot read ${CONF}: Permission denied" >&2
  exit 78          # EX_CONFIG
fi
# shellcheck disable=SC1090
. "$CONF"

mkdir -p "$OUT" 2>/dev/null || { echo "lab1045-report: cannot create ${OUT}: Permission denied" >&2; exit 73; }
stamp=$(date +%Y%m%dT%H%M%S)
file="${OUT}/report-${stamp}-$(id -un).txt"
{
  echo "app     : ${APP_NAME} (${APP_ENV})"
  echo "runas   : $(id -un):$(id -gn)  uid=$(id -u) euid=$(id -u -r)"
  echo "backend : ${DB_USER}@${DB_HOST}"
  echo "written : ${stamp}"
} > "$file" 2>/dev/null || { echo "lab1045-report: cannot write ${file}: Permission denied" >&2; exit 73; }

echo "REPORT OK -> ${file}"
EOF

  # Seed the drop-box with a file belonging to each developer so that the
  # missing sticky bit is immediately observable.
  echo "invoice 2026-08 — property of labdev1" > "$DROPBOX/invoice-labdev1.txt"
  echo "notes — property of labdev2"           > "$DROPBOX/notes-labdev2.txt"
  chown labdev1:"$LAB_GROUP" "$DROPBOX/invoice-labdev1.txt"
  chown labdev2:"$LAB_GROUP" "$DROPBOX/notes-labdev2.txt"
  chmod 0664 "$DROPBOX"/*.txt

  # Rogue privileged helper: a copy of cat(1) carrying the setuid bit.
  # It is owned by the UNPRIVILEGED service account on purpose — the lesson
  # (find it, prove what it leaks, neutralise it) is identical, while the lab
  # never ships an actual root privilege escalation.
  install -m 0755 "$(command -v cat)" "$ROGUE"
}

inject_faults() {
  # F1 — team share: wrong group owner, no setgid, group cannot write.
  chown root:root "$SHARED"
  chmod 0755 "$SHARED"

  # F2 — public drop-box: world-writable with NO sticky bit.
  chown root:root "$DROPBOX"
  chmod 0777 "$DROPBOX"

  # F3 — service entry point is not executable.
  chown root:root "$LAB_BIN"
  chmod 0644 "$LAB_BIN"

  # F4 — configuration unreadable by the account that must consume it.
  chown root:root "$CONF"
  chmod 0600 "$CONF"
  chmod 0755 "$LAB_ETC"

  # F5 — site-wide umask kills every group permission on new files.
  cat > "$LAB_PROFILE" <<'EOF'
# Deployed by a hardening change. It also broke team collaboration:
# every new file is created 0600 / every new directory 0700.
umask 0077
EOF
  chmod 0644 "$LAB_PROFILE"

  # F6 — setuid helper left behind by a "quick debug session".
  chown labsvc:labsvc "$ROGUE"
  chmod 4755 "$ROGUE"

  # F7 — private project tree inside the share: no group access at all.
  chown -R labdev1:labdev1 "$PROJECTS"
  chmod 0700 "$PROJECTS"
  chmod 0600 "$PROJECTS/spec.md"

  chmod 0755 "$LAB_ROOT" "$TOOLS"
  chown root:root "$LAB_ROOT" "$TOOLS"
}

# --------------------------------- BRIEFING ----------------------------------

brief() {
  cat <<EOF

${C_CYA}==============================================================================
 LPIC-1 104.5 — BREAK & FIX BRIEFING            (7 faults injected)
==============================================================================${C_RST}

SCENARIO
  A "hardening" change was pushed to a shared build host at 02:00. Since then
  the reporting service does not start, the two developers cannot collaborate,
  and the security scanner raised a finding. You are on call. You may not
  create new accounts, and you may not widen permissions beyond what each
  identity genuinely needs.

CAST
  group ${LAB_GROUP}   : labdev1, labdev2, labsvc   (verify with: id labdev1)
  service account      : labsvc runs ${LAB_BIN}
  secret               : ${CONF} holds DB_PASSWORD

--------------------------------- SYMPTOMS -----------------------------------

 S1  Neither developer can write to the team share.
       # runuser -u labdev2 -- touch ${SHARED}/hello
       touch: cannot touch '${SHARED}/hello': Permission denied
     Even once writing works, a file created by labdev1 must NOT come out owned
     by group labdev1 — the group of the share has to be inherited.

 S2  In the public drop-box, anybody can destroy anybody else's file:
       # runuser -u labdev2 -- rm -f ${DROPBOX}/invoice-labdev1.txt
       (succeeds — and it must not; the file belongs to labdev1)

 S3  The service entry point refuses to start:
       # runuser -u labsvc -- ${LAB_BIN}
       runuser: failed to execute ${LAB_BIN}: Permission denied
     Note the file IS there and IS readable. Read permission is not enough to
     execute; and a script also needs its interpreter line to be usable.

 S4  Once it starts, it dies on its configuration:
       # runuser -u labsvc -- ${LAB_BIN}
       lab1045-report: cannot read ${CONF}: Permission denied
     Constraint: after your fix, labdev1 must still be UNABLE to read the
     secret. "chmod 644" and "chmod 777" are both wrong answers here.

 S5  Every newly created file loses its group permissions:
       # runuser -l labdev1 -c 'umask; touch ~/probe; ls -l ~/probe'
       0077
       -rw------- 1 labdev1 labdev1 0 ... /home/labdev1/probe
     Teamwork through the group is impossible while this holds.

 S6  The security scanner flagged a setuid file under ${LAB_ROOT}:
       # find ${LAB_ROOT} -perm -4000 -type f -ls
     Prove to yourself what it leaks, then neutralise it without deleting the
     rest of the tooling directory.

 S7  Inside the share, ${PROJECTS} is a black hole for everybody but labdev1:
       # runuser -u labdev2 -- ls ${PROJECTS}
       ls: cannot open directory '${PROJECTS}': Permission denied

------------------------------- YOUR MISSION ---------------------------------
  1. Both developers and the service account can create, read and modify files
     under ${SHARED}, and new files land in group ${LAB_GROUP} automatically.
  2. In ${DROPBOX} everyone may create files, but only the owner (or root)
     may delete or rename their own.
  3. ${LAB_BIN} executes for labsvc and exits 0 printing "REPORT OK".
  4. labsvc reads ${CONF}; the file stays unreadable to any other non-root user.
  5. A login shell for labdev1 reports a mask that preserves group permissions.
  6. No setuid or setgid FILE remains anywhere under ${LAB_ROOT}.
  7. labdev2 can read and edit ${PROJECTS}/spec.md through the group.

RULES OF ENGAGEMENT
  * chmod -R 777 is an outage, not a fix. Any grader run that finds a
    world-writable regular file or a 0777 share fails the exercise.
  * Do not delete and re-create the tree — repair it in place.
  * Symbolic (u g o a + - =) and octal notation are both acceptable; be able to
    translate between them out loud, the exam asks for both.

TOOLBOX      ls -ld  stat -c '%A %a %U %G %n'  chmod  chown  chgrp  umask -S
             find -perm  id  groups  newgrp  namei -l  getfacl (out of scope)

GRADE YOURSELF   sudo $0 --verify
NEED A NUDGE     sudo $0 --hints
${C_CYA}==============================================================================${C_RST}

EOF
}

hints() {
  cat <<EOF

HINT 1 (S1/S7) A directory's x bit means "traverse", its w bit means "create and
        delete entries in it". Group ownership of a directory is only half the
        job: which extra bit makes new entries inherit the directory's group,
        and how is it spelled in octal and in symbolic notation?

HINT 2 (S2)    There is one bit whose entire purpose is "in this directory, only
        the owner of a file may unlink it". /tmp carries it. Compare:
          stat -c '%A %a' /tmp   vs   stat -c '%A %a' ${DROPBOX}

HINT 3 (S3)    ls -l shows -rw-r--r--. Which single bit is missing for the class
        of user that must run it? Also check the interpreter referenced on the
        first line is itself executable: head -1 ${LAB_BIN}

HINT 4 (S4)    Three permission classes exist: owner, group, other. You need
        exactly one of them to gain read access and the other to gain nothing.
        Changing the file's GROUP is cheaper than changing its owner.

HINT 5 (S5)    umask is subtractive: the resulting mode is 0666 & ~mask for
        files and 0777 & ~mask for directories. Which mask value leaves group
        rw intact while still denying "other"? Consider 0002 and 0007, and
        remember user private groups (see /etc/login.defs, USERGROUPS_ENAB).

HINT 6 (S6)    find / -perm -4000 -type f 2>/dev/null is the classic audit
        one-liner. -4000 means "these bits at least"; /4000 means "any of
        these bits". Removing the bit (u-s) is preferable to deleting a file
        whose provenance you have not yet established.

EOF
}

# --------------------------------- GRADER ------------------------------------

PASSED=0; FAILED=0
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; PASSED=$((PASSED+1)); else bad "$d"; FAILED=$((FAILED+1)); fi }

chk_f1() {
  local mode grp probe pgrp
  mode=$(norm_mode "$SHARED") || return 1
  grp=$(stat -c '%G' "$SHARED")
  [ "$grp" = "$LAB_GROUP" ] || return 1
  [ $(( 8#$mode & 8#2000 )) -ne 0 ] || return 1            # setgid on the directory
  [ $(( 8#$mode & 8#0070 )) -eq $(( 8#0070 )) ] || return 1 # group rwx
  [ $(( 8#$mode & 8#0002 )) -eq 0 ] || return 1             # not world-writable
  probe="${SHARED}/.probe.f1.$$"
  as_user labdev2 touch "$probe" || return 1
  pgrp=$(stat -c '%G' "$probe"); rm -f "$probe"
  [ "$pgrp" = "$LAB_GROUP" ]
}

chk_f2() {
  local mode probe rc
  mode=$(norm_mode "$DROPBOX") || return 1
  [ $(( 8#$mode & 8#1000 )) -ne 0 ] || return 1             # sticky bit
  [ $(( 8#$mode & 8#0002 )) -ne 0 ] || return 1             # still a drop-box
  probe="${DROPBOX}/.probe.f2.$$"
  as_user labdev1 touch "$probe" || return 1
  rc=0; as_user labdev2 rm -f "$probe" >/dev/null 2>&1 || rc=$?
  rm -f "$probe"
  [ "$rc" -ne 0 ]                                            # deletion must be refused
}

chk_f3() {
  local mode
  mode=$(norm_mode "$LAB_BIN") || return 1
  [ $(( 8#$mode & 8#0022 )) -eq 0 ] || return 1              # not group/other writable
  as_user labsvc test -x "$LAB_BIN"
}

chk_f4() {
  local mode
  mode=$(norm_mode "$CONF") || return 1
  [ $(( 8#$mode & 8#0007 )) -eq 0 ] || return 1              # secret hidden from "other"
  as_user labsvc test -r "$CONF" || return 1
  ! as_user labdev1 test -r "$CONF"
}

chk_f5() {
  local u
  u=$(as_login labdev1 'umask' 2>/dev/null | tr -d '[:space:]') || return 1
  [ -n "$u" ] || return 1
  [ $(( 8#$u & 8#0070 )) -eq 0 ] || return 1                 # group bits not masked
  [ $(( 8#$u & 8#0002 )) -ne 0 ] || return 1                 # "other" still masked
}

chk_f6() { [ -z "$(find "$LAB_ROOT" -type f -perm /6000 -print -quit 2>/dev/null)" ]; }

chk_f7() {
  as_user labdev2 test -r "${PROJECTS}/spec.md" || return 1
  as_user labdev2 test -w "${PROJECTS}/spec.md" || return 1
  as_user labdev2 test -x "$PROJECTS"
}

chk_e2e() { as_user labsvc "$LAB_BIN" 2>/dev/null | grep -q '^REPORT OK'; }

chk_no_777() { [ -z "$(find "$LAB_ROOT" -type f -perm -0002 -print -quit 2>/dev/null)" ]; }

verify() {
  [ -d "$LAB_ROOT" ] || die "Lab not installed. Run: $0 --break"
  echo
  log "Grading topic 104.5 …"
  check "F1  team share is ${LAB_GROUP}-owned, setgid, group-writable"      chk_f1
  check "F2  drop-box is world-writable AND sticky (owner-only deletion)"   chk_f2
  check "F3  ${LAB_BIN##*/} is executable by labsvc"                        chk_f3
  check "F4  labsvc reads the config, labdev1 does not"                     chk_f4
  check "F5  login umask preserves group permissions"                       chk_f5
  check "F6  no setuid/setgid file remains under ${LAB_ROOT}"               chk_f6
  check "F7  labdev2 can read and edit projects/spec.md via the group"      chk_f7
  check "SAFE no world-writable regular file was left behind"               chk_no_777
  check "E2E ${LAB_BIN##*/} runs end to end and prints REPORT OK"           chk_e2e
  echo
  if [ "$FAILED" -eq 0 ]; then
    printf '  %sALL %d CHECKS PASSED — objective 104.5 restored.%s\n\n' "$C_GRN" "$PASSED" "$C_RST"
    log "Now explain out loud: why setgid on a directory and not on a file, and why 0002 rather than 0022."
    return 0
  fi
  printf '  %s%d passed, %d failed.%s  Re-run with --hints, then --verify again.\n\n' "$C_RED" "$PASSED" "$FAILED" "$C_RST"
  return 1
}

# ------------------------------- LIFECYCLE -----------------------------------

clean() {
  local entry u
  if [ -r "$STATE" ]; then
    while IFS= read -r entry; do
      case "$entry" in
        user:*)  u="${entry#user:}"
                 for known in "${LAB_USERS[@]}"; do
                   [ "$u" = "$known" ] && { pkill -KILL -u "$u" 2>/dev/null || true; userdel -r "$u" >/dev/null 2>&1 || true; }
                 done ;;
        group:*) [ "${entry#group:}" = "$LAB_GROUP" ] && groupdel "$LAB_GROUP" >/dev/null 2>&1 || true ;;
      esac
    done < "$STATE"
  else
    warn "No state file; leaving accounts untouched. Remove them by hand if this lab created them."
  fi
  case "$LAB_ROOT" in /srv/lab*) rm -rf -- "$LAB_ROOT" ;; *) die "Refusing to remove unexpected path: $LAB_ROOT" ;; esac
  case "$LAB_ETC"  in /etc/lab*) rm -rf -- "$LAB_ETC"  ;; *) die "Refusing to remove unexpected path: $LAB_ETC"  ;; esac
  rm -f -- "$LAB_BIN" "$LAB_PROFILE"
  log "Lab artefacts removed."
}

do_break() {
  confirm_disposable
  [ -d "$LAB_ROOT" ] && die "Lab already installed. Use --reset to start over, or --verify to grade."
  create_accounts
  seed_content
  inject_faults
  log "7 faults injected."
  brief
}

main() {
  require_root; require_tools
  case "${1:---break}" in
    --break)  do_break ;;
    --brief)  brief ;;
    --hints)  hints ;;
    --verify) verify ;;
    --reset)  clean; do_break ;;
    --clean)  clean ;;
    -h|--help) sed -n '2,40p' "$0" ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
}

main "$@"

# =============================================================================
#  SOLUTION — do not read before you have fought --verify
# =============================================================================
#
#  Method first. Never guess a mode: read the current state, name the class
#  (owner / group / other) that is wrong, then change only that class.
#
#      ls -ld  /srv/lab1045 /srv/lab1045/shared /srv/lab1045/dropbox
#      stat -c '%A %a %U:%G %n' /srv/lab1045/shared /etc/lab1045/app.conf
#      namei -l /srv/lab1045/shared/projects/spec.md   # every component of the path
#      id labdev2                                      # uid, gid, supplementary groups
#
#  Remember: to reach a file you need x on EVERY directory of the path, and
#  path_resolution(7) checks the classes in order owner -> group -> other and
#  stops at the FIRST match. A file 0604 root:webteam is unreadable to a member
#  of webteam: the group class matched and it says "no".
#
# -----------------------------------------------------------------------------
#  F1 — team share: group ownership + setgid
# -----------------------------------------------------------------------------
#      chgrp -R webteam /srv/lab1045/shared
#      chmod 2775 /srv/lab1045/shared          # == chmod g+rwxs,o=rx
#      find /srv/lab1045/shared -type d -exec chmod g+rwxs {} +
#      find /srv/lab1045/shared -type f -exec chmod g+rw   {} +
#
#  Why 2775 and not 0775: the setgid bit on a DIRECTORY (leading 2) makes every
#  new entry inherit the directory's group instead of the creator's primary
#  group, and makes new SUBDIRECTORIES inherit the setgid bit as well. That is
#  the only way "new files land in group webteam automatically" is true without
#  a nightly chgrp cron job. On a file, the same bit means something completely
#  different (run with the file's group, or mandatory locking) — never set it
#  on regular files here.
#  Verify:
#      runuser -u labdev1 -- touch /srv/lab1045/shared/t && ls -l /srv/lab1045/shared/t
#      -rw-rw-r-- 1 labdev1 webteam 0 ... t
#
# -----------------------------------------------------------------------------
#  F2 — drop-box: restore the sticky bit
# -----------------------------------------------------------------------------
#      chmod 1777 /srv/lab1045/dropbox         # == chmod +t (o+t)
#      ls -ld /srv/lab1045/dropbox
#      drwxrwxrwt 2 root root ... /srv/lab1045/dropbox
#
#  The trailing "t" (restricted deletion flag) means: in this directory a
#  non-root user may unlink or rename an entry only if they own the entry or
#  the directory. Without it, w on the directory is enough to delete somebody
#  else's file — write permission belongs to the DIRECTORY, not to the file.
#  This is exactly why /tmp is 1777.
#  Verify:
#      runuser -u labdev2 -- rm -f /srv/lab1045/dropbox/invoice-labdev1.txt
#      rm: cannot remove '...': Operation not permitted
#
# -----------------------------------------------------------------------------
#  F3 — make the service entry point executable
# -----------------------------------------------------------------------------
#      chmod 0755 /usr/local/bin/lab1045-report      # == chmod a+x,go-w
#      ls -l /usr/local/bin/lab1045-report
#      -rwxr-xr-x 1 root root ... /usr/local/bin/lab1045-report
#
#  Read permission lets you copy a script; only x lets execve(2) hand it to the
#  kernel. For a #! script the kernel also needs the interpreter itself to be
#  executable — check with:  head -1 lab1045-report ; ls -l /usr/bin/env
#  Do NOT "fix" it with 0777: a world-writable executable owned by root is a
#  privilege escalation waiting for its first non-root writer.
#
# -----------------------------------------------------------------------------
#  F4 — the configuration secret: change the GROUP, not the mode of "other"
# -----------------------------------------------------------------------------
#      chown root:labsvc /etc/lab1045/app.conf       # or:  chgrp labsvc app.conf
#      chmod 0640 /etc/lab1045/app.conf              # == chmod u=rw,g=r,o=
#      chmod 0755 /etc/lab1045                       # traversal for everyone
#      stat -c '%A %U:%G %n' /etc/lab1045/app.conf
#      -rw-r----- root:labsvc /etc/lab1045/app.conf
#
#  Pattern to memorise for services: root owns the file (so a compromised
#  service cannot rewrite its own configuration), the service's group reads it,
#  "other" gets nothing. 0640 root:<svcgroup> is the production default for any
#  file containing a credential.
#  Verify both directions — the second command MUST fail:
#      runuser -u labsvc  -- head -1 /etc/lab1045/app.conf
#      runuser -u labdev1 -- head -1 /etc/lab1045/app.conf
#      head: cannot open '/etc/lab1045/app.conf' for reading: Permission denied
#
# -----------------------------------------------------------------------------
#  F5 — the file-creation mask
# -----------------------------------------------------------------------------
#      printf 'umask 0002\n' > /etc/profile.d/lab1045-umask.sh
#      chmod 0644 /etc/profile.d/lab1045-umask.sh
#      runuser -l labdev1 -c 'umask; umask -S'
#      0002
#      u=rwx,g=rwx,o=rx
#
#  Arithmetic, because the exam asks it numerically: the mask is SUBTRACTED
#  from the base mode. Files start at 0666, directories at 0777.
#      umask 0077 -> file 0666 & ~0077 = 0600, dir 0777 & ~0077 = 0700  (broken)
#      umask 0022 -> file 0644, dir 0755                                (no group write)
#      umask 0002 -> file 0664, dir 0775                                (correct here)
#      umask 0007 -> file 0660, dir 0770                                (also correct,
#                    and stricter: nothing is readable by "other")
#  0002 is only safe because the distribution uses user private groups (each
#  user's primary group is their own, USERGROUPS_ENAB yes in /etc/login.defs).
#  Where users share a primary group, use 0007 or 0027 instead.
#  Scope matters: /etc/profile.d/*.sh is read by LOGIN shells. A change there is
#  invisible to an already-open session and to non-login shells — log out and
#  back in, or source it, before believing your own fix. For daemons, set the
#  mask in the unit (UMask=) — systemd does not read /etc/profile.
#
# -----------------------------------------------------------------------------
#  F6 — the rogue setuid helper
# -----------------------------------------------------------------------------
#  Audit the whole box the way the scanner does:
#      find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -ls 2>/dev/null
#      find /srv/lab1045 -perm /6000 -type f -printf '%M %u:%g %p\n'
#      -rwsr-xr-x labsvc:labsvc /srv/lab1045/tools/dumpcfg
#
#  Prove the leak before you touch it (this is the part students skip):
#      runuser -u labdev1 -- /srv/lab1045/tools/dumpcfg /etc/lab1045/app.conf
#      ...DB_PASSWORD="s3cr3t-never-world-readable"
#  labdev1 cannot read that file, yet reads it through the helper: the setuid
#  bit made the process run with the EFFECTIVE uid of the file's owner, so the
#  kernel checked labsvc's rights, not labdev1's. A setuid copy of any program
#  that can open an arbitrary path (cat, find -exec, cp, an editor, a shell)
#  hands out that identity wholesale.
#  Neutralise, preserving the evidence:
#      chmod u-s,g-s /srv/lab1045/tools/dumpcfg      # == chmod 0755
#      ls -l /srv/lab1045/tools/dumpcfg
#      -rwxr-xr-x 1 labsvc labsvc ... dumpcfg
#  Then re-run the leak command: Permission denied. In production you would also
#  mount data filesystems nosuid (see mount(8)) so the bit is ignored entirely.
#
# -----------------------------------------------------------------------------
#  F7 — the private subtree inside the share
# -----------------------------------------------------------------------------
#      chgrp -R webteam /srv/lab1045/shared/projects
#      chmod 2775 /srv/lab1045/shared/projects
#      chmod 0664 /srv/lab1045/shared/projects/spec.md
#      runuser -u labdev2 -- sh -c 'echo "reviewed" >> /srv/lab1045/shared/projects/spec.md'
#
#  Note that r on a directory lets you LIST names, while x lets you STAT and
#  open the entries. A directory 0640 lists names and then denies everything —
#  the classic "ls works but nothing else does" symptom. Directories are
#  effectively rx or nothing.
#
# -----------------------------------------------------------------------------
#  END-TO-END CONFIRMATION
# -----------------------------------------------------------------------------
#      runuser -u labsvc -- /usr/local/bin/lab1045-report
#      REPORT OK -> /srv/lab1045/shared/reports/report-<stamp>-labsvc.txt
#      ls -l /srv/lab1045/shared/reports/
#      -rw-rw-r-- 1 labsvc webteam ...    <- group inherited through setgid
#      sudo ./break-fix-104.5.sh --verify
#
# -----------------------------------------------------------------------------
#  ONE-SHOT REPAIR (read it as a checklist, not as a spell)
# -----------------------------------------------------------------------------
#      chgrp -R webteam /srv/lab1045/shared
#      find /srv/lab1045/shared -type d -exec chmod 2775 {} +
#      find /srv/lab1045/shared -type f -exec chmod 0664 {} +
#      chmod 1777 /srv/lab1045/dropbox
#      chmod 0755 /usr/local/bin/lab1045-report
#      chown root:labsvc /etc/lab1045/app.conf && chmod 0640 /etc/lab1045/app.conf
#      printf 'umask 0002\n' > /etc/profile.d/lab1045-umask.sh
#      find /srv/lab1045 -type f -perm /6000 -exec chmod u-s,g-s {} +
#
# -----------------------------------------------------------------------------
#  EXAM TRAPS CONDENSED
# -----------------------------------------------------------------------------
#   * Special bits occupy the leading octal digit: 4=setuid, 2=setgid, 1=sticky.
#     "chmod 755" on a setuid file SILENTLY CLEARS it (3 digits reset the 4th);
#     use chmod u+x when you mean to preserve it.
#   * ls shows the special bits by overloading the x column: s/S (setuid|setgid,
#     lowercase means x is also set) and t/T (sticky). A capital letter means
#     the bit is set but the underlying x is NOT — usually a mistake.
#   * setuid/setgid on a shell script is ignored by Linux; the bit only takes
#     effect on binaries.
#   * chown user:group / chown user: / chown :group / chgrp group are the four
#     forms; only root may give a file away (chown), the owner may only change
#     the group and only to a group they belong to.
#   * Adding a user to a group does not change their running sessions: the
#     supplementary groups are read at login. Use newgrp, or log out; id(1) is
#     the arbiter, /etc/group is only the intent.
#   * umask is a per-process property inherited by children — set it in the
#     shell profile for users, in the unit file (UMask=) for daemons.
#   * Deleting a file is a WRITE to its directory, not to the file: mode 0444
#     does not protect a file living in a directory you can write, which is the
#     whole reason the sticky bit exists.
#
#  Objective reference: https://www.lpi.org/our-certifications/exam-101-objectives/
# =============================================================================