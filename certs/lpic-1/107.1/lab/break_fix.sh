#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 (exams 101-500 / 102-500, version 5.0)
#  Topic 107.1 - Manage user and group accounts and related system files
#
#  BREAK & FIX LABORATORY
#
#  Key files:    /etc/passwd  /etc/shadow  /etc/group  /etc/gshadow
#                /etc/login.defs  /etc/default/useradd  /etc/skel
#  Key tools:    useradd usermod userdel groupadd groupmod groupdel
#                passwd chage getent id pwck grpck pwconv grpconv chpasswd
#
#  Official references:
#    https://www.lpi.org/our-certifications/exam-101-objectives/
#    https://www.lpi.org/our-certifications/exam-102-objectives/
#    https://man7.org/linux/man-pages/man5/passwd.5.html
#    https://man7.org/linux/man-pages/man5/shadow.5.html
#    https://man7.org/linux/man-pages/man5/gshadow.5.html
#    https://man7.org/linux/man-pages/man5/login.defs.5.html
#    https://man7.org/linux/man-pages/man8/useradd.8.html
#    https://man7.org/linux/man-pages/man8/pwck.8.html
#    https://man7.org/linux/man-pages/man8/pwconv.8.html
#
#  DANGER
#  ------
#  This script edits /etc/passwd, /etc/shadow, /etc/group and /etc/gshadow.
#  Run it ONLY on a disposable lab VM (snapshot it first). It never touches
#  root, never touches accounts with UID < 1000, and never modifies any user
#  other than the two lab accounts it creates itself - but a mistake in an
#  account database is still the fastest way to lock yourself out of a box.
#  Keep a second root shell open while you work.
#
#  USAGE
#    sudo ./107.1-break-and-fix.sh break    --i-am-in-a-disposable-lab-vm
#    sudo ./107.1-break-and-fix.sh verify
#    sudo ./107.1-break-and-fix.sh restore   # undo everything, keep lab users
#    sudo ./107.1-break-and-fix.sh cleanup   # remove lab users and groups
#
#  The full step-by-step solution is at the END of this file, commented out.
#  Do not read it until 'verify' has beaten you at least twice.
# =============================================================================

set -euo pipefail

# ------------------------------- constants ----------------------------------
USER_A="lpicops"       # the human operator account
USER_B="lpicsvc"       # the service/maintenance account
UID_A=6107
UID_B=6108
GROUP_A="devops107"    # primary group of USER_A
GROUP_B="labops107"    # supplementary group of USER_A
GID_A=6107
GID_B=6108
LAB_PASS="Lpic107.Lab"

BACKUP_DIR="/var/tmp/lpic-107.1-backup"
MARKER="${BACKUP_DIR}/.broken"
DB_FILES=(/etc/passwd /etc/shadow /etc/group /etc/gshadow)

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_CYA=$'\033[1;36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_BLD=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$C_CYA" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

# ------------------------------- guardrails ---------------------------------
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "This lab must run as root (use sudo)."
}

require_tools() {
    local t missing=()
    for t in useradd usermod userdel groupadd groupdel chpasswd chage getent stat awk sed; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]} (install shadow-utils / passwd)."
}

confirm_lab() {
    # Two independent confirmations: an explicit flag AND a typed word.
    local flag_ok="no"
    for arg in "$@"; do
        [[ "$arg" == "--i-am-in-a-disposable-lab-vm" ]] && flag_ok="yes"
    done
    if [[ "$flag_ok" != "yes" ]]; then
        die "Refusing to run without --i-am-in-a-disposable-lab-vm (snapshot the VM first)."
    fi
    if [[ -t 0 ]]; then
        printf '%sType BREAK to damage the account databases on %s: %s' \
               "$C_YEL" "$(hostname)" "$C_OFF"
        local answer; read -r answer
        [[ "$answer" == "BREAK" ]] || die "Aborted by operator."
    else
        warn "Non-interactive session: proceeding on the flag alone."
    fi
}

# ------------------------------- backup / restore ---------------------------
backup_databases() {
    mkdir -p "$BACKUP_DIR"
    chmod 0700 "$BACKUP_DIR"
    local f
    for f in "${DB_FILES[@]}"; do
        [[ -f "$f" ]] || continue
        cp -a "$f" "${BACKUP_DIR}/$(basename "$f").orig"
        # Record the original mode/owner so 'restore' puts back the distro default.
        stat -c '%n %a %U %G' "$f" >> "${BACKUP_DIR}/modes.orig"
    done
    info "Databases backed up to ${BACKUP_DIR}"
}

restore_databases() {
    [[ -d "$BACKUP_DIR" ]] || die "No backup found in ${BACKUP_DIR}; nothing to restore."
    local f base
    for f in "${DB_FILES[@]}"; do
        base="${BACKUP_DIR}/$(basename "$f").orig"
        [[ -f "$base" ]] || continue
        cp -a "$base" "$f"
    done
    # Re-apply the recorded modes (cp -a already did, this is belt and braces).
    if [[ -f "${BACKUP_DIR}/modes.orig" ]]; then
        while read -r name mode owner group; do
            [[ -e "$name" ]] || continue
            chmod "$mode" "$name"
            chown "${owner}:${group}" "$name"
        done < <(sort -u "${BACKUP_DIR}/modes.orig")
    fi
    if [[ -d "/home/${USER_A}" ]]; then
        chown -R "${UID_A}:${GID_A}" "/home/${USER_A}"
        chmod 0700 "/home/${USER_A}"
    fi
    rm -f "$MARKER"
    info "Account databases restored to their pre-break state."
}

# ------------------------------- lab build-up -------------------------------
build_lab_accounts() {
    getent group "$GROUP_A" >/dev/null 2>&1 || groupadd -g "$GID_A" "$GROUP_A"
    getent group "$GROUP_B" >/dev/null 2>&1 || groupadd -g "$GID_B" "$GROUP_B"

    if ! getent passwd "$USER_A" >/dev/null 2>&1; then
        useradd -m -u "$UID_A" -g "$GROUP_A" -s /bin/bash \
                -c "LPIC 107.1 lab operator" "$USER_A"
    fi
    if ! getent passwd "$USER_B" >/dev/null 2>&1; then
        useradd -m -u "$UID_B" -g "$GROUP_B" -s /bin/bash \
                -c "LPIC 107.1 lab service account" "$USER_B"
    fi

    usermod -aG "$GROUP_B" "$USER_A"
    printf '%s:%s\n%s:%s\n' "$USER_A" "$LAB_PASS" "$USER_B" "$LAB_PASS" | chpasswd

    info "Lab accounts ready: ${USER_A} (uid ${UID_A}), ${USER_B} (uid ${UID_B})"
    info "Lab password for both accounts: ${LAB_PASS}"
}

# ------------------------------- the breakage -------------------------------
# Every edit below is deliberate, reversible and confined to the lab accounts.
break_lab() {
    # -- FAULT 1: dangling primary GID -------------------------------------
    # Delete the primary group of USER_A from /etc/group and /etc/gshadow,
    # leaving the numeric GID orphaned in /etc/passwd.
    sed -i -E "/^${GROUP_A}:/d" /etc/group
    [[ -f /etc/gshadow ]] && sed -i -E "/^${GROUP_A}:/d" /etc/gshadow

    # -- FAULT 2: missing shadow entry --------------------------------------
    # /etc/passwd still says the password is shadowed ('x'), but the record
    # in /etc/shadow is gone: the account has no password, no ageing data.
    sed -i -E "/^${USER_A}:/d" /etc/shadow

    # -- FAULT 3: home directory hijacked -----------------------------------
    # Correct path, correct entry in /etc/passwd, wrong ownership and mode.
    if [[ -d "/home/${USER_A}" ]]; then
        chown -R root:root "/home/${USER_A}"
        chmod 0700 "/home/${USER_A}"
    fi

    # -- FAULT 4: non-existent login shell ----------------------------------
    sed -i -E "s|^(${USER_B}:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:).*$|\1/bin/borkshell|" /etc/passwd

    # -- FAULT 5: expired account -------------------------------------------
    # Field 8 of /etc/shadow = account expiration, in days since 1970-01-01.
    chage -E 1 "$USER_B"

    # -- FAULT 6a: world-readable /etc/shadow -------------------------------
    chmod 0644 /etc/shadow

    # -- FAULT 6b: /etc/group and /etc/gshadow out of sync -------------------
    # USER_A is a member of GROUP_B in /etc/group but not in /etc/gshadow.
    if [[ -f /etc/gshadow ]]; then
        sed -i -E "s|^(${GROUP_B}:[^:]*:[^:]*:).*$|\1|" /etc/gshadow
    fi

    touch "$MARKER"
}

# ------------------------------- the briefing -------------------------------
briefing() {
    rule
    say "${C_BLD}LPIC-1 107.1 - BREAK & FIX: the account databases are damaged${C_OFF}"
    rule
    say ""
    say "Six independent faults were injected. They only affect the two lab"
    say "accounts (${USER_A}, ${USER_B}) and the permissions of /etc/shadow."
    say "Repair them ${C_BLD}by hand${C_OFF}. Re-run this script with 'verify' to grade yourself."
    say ""
    say "${C_BLD}FAULT 1 - the group that isn't there${C_OFF}"
    say "  Symptom:  \$ id ${USER_A}"
    say "            uid=${UID_A}(${USER_A}) gid=${GID_A} groups=${GID_A},${GID_B}(${GROUP_B})"
    say "            ...the primary group prints as a bare number, with no name."
    say "            \$ ls -ld /home/${USER_A}   ->  the group column shows ${GID_A}."
    say "  Goal:     'id ${USER_A}' must resolve gid=${GID_A} to the name ${GROUP_A}"
    say "            again, WITHOUT changing the user's numeric GID (files on"
    say "            disk are owned by GID ${GID_A} and must not be re-chowned to a"
    say "            different number)."
    say ""
    say "${C_BLD}FAULT 2 - a user with no shadow record${C_OFF}"
    say "  Symptom:  \$ getent shadow ${USER_A}          ->  prints nothing"
    say "            \$ chage -l ${USER_A}                ->  fails or prints garbage"
    say "            \$ pwck -r                          ->  reports a missing entry"
    say "            Logging in as ${USER_A} is impossible: the password field in"
    say "            /etc/passwd is 'x', so authentication is redirected to a"
    say "            /etc/shadow line that no longer exists."
    say "  Goal:     ${USER_A} has a valid /etc/shadow entry again, with a real"
    say "            password hash (field 2 starts with \$) and a last-change date"
    say "            (field 3). 'passwd -S ${USER_A}' must report status P."
    say ""
    say "${C_BLD}FAULT 3 - locked out of your own home${C_OFF}"
    say "  Symptom:  # su - ${USER_A}"
    say "            su: warning: cannot change directory to /home/${USER_A}:"
    say "            Permission denied"
    say "            -bash: /home/${USER_A}/.bashrc: Permission denied"
    say "            \$ pwd  ->  /"
    say "  Goal:     /home/${USER_A} and everything under it is owned by"
    say "            ${USER_A}:${GROUP_A}, private mode (0700), and 'su - ${USER_A}'"
    say "            lands in the home directory with the dotfiles sourced."
    say "            Note the dependency: you cannot chown to a group that does"
    say "            not exist yet - fix FAULT 1 first."
    say ""
    say "${C_BLD}FAULT 4 - the shell that was never installed${C_OFF}"
    say "  Symptom:  # su - ${USER_B}"
    say "            su: failed to execute /bin/borkshell: No such file or directory"
    say "            \$ getent passwd ${USER_B}   ->  field 7 points nowhere."
    say "  Goal:     field 7 of the ${USER_B} entry is an existing, executable shell"
    say "            listed in /etc/shells, changed with the proper tool (do not"
    say "            hand-edit /etc/passwd - know which command does it safely)."
    say ""
    say "${C_BLD}FAULT 5 - the account that expired in 1970${C_OFF}"
    say "  Symptom:  \$ chage -l ${USER_B} | grep -i 'account expires'"
    say "            Account expires : Jan 02, 1970"
    say "            Login attempt:  'Your account has expired; please contact"
    say "            your system administrator.'  (su/ssh/login all refuse.)"
    say "  Goal:     the account never expires (field 8 of /etc/shadow empty,"
    say "            'chage -l' says 'never'), and password ageing is left intact."
    say ""
    say "${C_BLD}FAULT 6 - the databases no longer agree with each other${C_OFF}"
    say "  Symptom:  \$ ls -l /etc/shadow    ->  -rw-r--r-- : every local user can"
    say "            read the password hashes. This is a real, exploitable finding."
    say "            \$ grpck -r             ->  complains about ${GROUP_B}"
    say "            \$ getent group ${GROUP_B}   lists ${USER_A} as a member, but the"
    say "            member field of ${GROUP_B} in /etc/gshadow is empty."
    say "  Goal:     /etc/shadow is back to the distribution default (0640"
    say "            root:shadow on Debian/Ubuntu, 0000 root:root on RHEL family),"
    say "            and /etc/group and /etc/gshadow list the same members, with"
    say "            'pwck -r' and 'grpck -r' both silent."
    say ""
    rule
    say "Tools you are expected to reach for, and to be able to explain:"
    say "  getent  id  groups  pwck  grpck  pwconv  grpconv  vipw  vigr"
    say "  useradd  usermod  userdel  groupadd  groupmod  groupdel"
    say "  passwd  chage  chsh  chpasswd  newgrp  gpasswd"
    say "Read the record layout first: man 5 passwd, man 5 shadow, man 5 gshadow."
    rule
    say "Grade yourself:  sudo $0 verify"
    say "Escape hatch:    sudo $0 restore     (undoes all six faults)"
    rule
}

# ------------------------------- the grader ---------------------------------
PASSED=0
FAILED=0

result() { # result <name> <0|1> <hint>
    if [[ "$2" -eq 0 ]]; then
        printf '%s[PASS]%s %s\n' "$C_GRN" "$C_OFF" "$1"
        PASSED=$((PASSED + 1))
    else
        printf '%s[FAIL]%s %s\n        hint: %s\n' "$C_RED" "$C_OFF" "$1" "$3"
        FAILED=$((FAILED + 1))
    fi
}

verify_lab() {
    local rc gid gname line f2 f3 owner mode shell expires members_group members_gshadow

    rule
    say "${C_BLD}Grading topic 107.1${C_OFF}"
    rule

    # FAULT 1 - primary group resolves, and the GID did not move.
    rc=1
    gid="$(id -g "$USER_A" 2>/dev/null || echo "")"
    gname="$(getent group "${gid:-none}" 2>/dev/null | cut -d: -f1 || true)"
    [[ "$gid" == "$GID_A" && "$gname" == "$GROUP_A" ]] && rc=0
    result "FAULT 1  primary group ${GROUP_A} (gid ${GID_A}) resolves for ${USER_A}" "$rc" \
           "groupadd with an explicit GID; 'getent group ${GID_A}' must print a name."

    # FAULT 2 - shadow entry exists and carries a real hash.
    rc=1
    line="$(awk -F: -v u="$USER_A" '$1==u {print}' /etc/shadow 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
        f2="$(printf '%s' "$line" | cut -d: -f2)"
        f3="$(printf '%s' "$line" | cut -d: -f3)"
        if [[ -n "$f2" && "$f2" != "x" && "$f2" != "!" && "$f2" != "!!" && -n "$f3" ]]; then
            rc=0
        fi
    fi
    result "FAULT 2  ${USER_A} has a usable /etc/shadow entry" "$rc" \
           "pwconv rebuilds the missing record from /etc/passwd; then set a password."

    # FAULT 3 - home ownership and mode.
    rc=1
    if [[ -d "/home/${USER_A}" ]]; then
        owner="$(stat -c '%u:%g' "/home/${USER_A}")"
        mode="$(stat -c '%a' "/home/${USER_A}")"
        if [[ "$owner" == "${UID_A}:${GID_A}" && "$mode" =~ ^(700|750|755)$ ]]; then
            # No stray root-owned leftovers inside the home directory.
            if ! find "/home/${USER_A}" ! -uid "$UID_A" -print -quit | grep -q .; then
                rc=0
            fi
        fi
    fi
    result "FAULT 3  /home/${USER_A} owned by ${USER_A}:${GROUP_A}, recursively" "$rc" \
           "chown -R, and remember the dotfiles copied from /etc/skel."

    # FAULT 4 - login shell exists and is executable.
    rc=1
    shell="$(getent passwd "$USER_B" | cut -d: -f7 || true)"
    [[ -n "$shell" && -x "$shell" ]] && rc=0
    result "FAULT 4  ${USER_B} has an existing, executable login shell (${shell:-none})" "$rc" \
           "usermod -s (or chsh -s); check the list with 'chsh -l' or cat /etc/shells."

    # FAULT 5 - account expiration cleared.
    rc=1
    expires="$(awk -F: -v u="$USER_B" '$1==u {print $8}' /etc/shadow 2>/dev/null || true)"
    [[ -z "$expires" || "$expires" == "-1" ]] && rc=0
    result "FAULT 5  ${USER_B} account never expires" "$rc" \
           "chage -E -1 (or usermod -e ''); confirm with 'chage -l ${USER_B}'."

    # FAULT 6a - /etc/shadow permissions.
    rc=1
    mode="$(stat -c '%a' /etc/shadow)"
    [[ "$mode" =~ ^(0|400|600|640)$ ]] && rc=0
    result "FAULT 6a /etc/shadow is not world-readable (mode ${mode})" "$rc" \
           "Match your distribution's default: 0640 root:shadow, or 0000 root:root."

    # FAULT 6b - group / gshadow member lists agree.
    rc=1
    members_group="$(awk -F: -v g="$GROUP_B" '$1==g {print $4}' /etc/group 2>/dev/null || true)"
    if [[ -f /etc/gshadow ]]; then
        members_gshadow="$(awk -F: -v g="$GROUP_B" '$1==g {print $4}' /etc/gshadow 2>/dev/null || true)"
    else
        members_gshadow="$members_group"
    fi
    if [[ ",${members_group}," == *",${USER_A},"* && ",${members_gshadow}," == *",${USER_A},"* ]]; then
        rc=0
    fi
    result "FAULT 6b ${GROUP_B} lists ${USER_A} in BOTH /etc/group and /etc/gshadow" "$rc" \
           "grpconv re-synchronises gshadow from group; gpasswd -a does it properly."

    rule
    say "Consistency check (diagnostic output, not graded):"
    pwck -r  2>&1 | sed 's/^/  pwck : /'  || true
    grpck -r 2>&1 | sed 's/^/  grpck: /'  || true
    rule
    printf '%sPASSED %d%s   %sFAILED %d%s\n' "$C_GRN" "$PASSED" "$C_OFF" "$C_RED" "$FAILED" "$C_OFF"
    if [[ "$FAILED" -eq 0 ]]; then
        say "${C_GRN}All six faults repaired. Now log in as each account and prove it:${C_OFF}"
        say "  su - ${USER_A}   # lands in /home/${USER_A}, prompt works, id resolves names"
        say "  su - ${USER_B}   # real shell, no expiration message"
        rm -f "$MARKER"
    else
        say "Keep going. Re-run '$0 verify' after each repair."
    fi
    rule
    [[ "$FAILED" -eq 0 ]]
}

# ------------------------------- cleanup ------------------------------------
cleanup_lab() {
    local u g
    for u in "$USER_A" "$USER_B"; do
        if getent passwd "$u" >/dev/null 2>&1; then
            # Refuse to remove anything that is not the lab account.
            local this_uid; this_uid="$(id -u "$u")"
            if [[ "$this_uid" == "$UID_A" || "$this_uid" == "$UID_B" ]]; then
                userdel -r "$u" 2>/dev/null || userdel "$u" || true
                info "Removed user ${u}"
            else
                warn "Skipping ${u}: unexpected UID ${this_uid}, not a lab account."
            fi
        fi
    done
    for g in "$GROUP_A" "$GROUP_B"; do
        getent group "$g" >/dev/null 2>&1 && { groupdel "$g" || true; info "Removed group ${g}"; }
    done
    # Put /etc/shadow permissions back even if the student never fixed them.
    if [[ -f "${BACKUP_DIR}/modes.orig" ]]; then
        while read -r name mode owner group; do
            [[ "$name" == "/etc/shadow" && -e "$name" ]] || continue
            chmod "$mode" "$name"; chown "${owner}:${group}" "$name"
        done < <(sort -u "${BACKUP_DIR}/modes.orig")
    fi
    rm -f "$MARKER"
    info "Lab removed. Backups kept in ${BACKUP_DIR} - delete them when done."
}

# ------------------------------- entry point --------------------------------
usage() {
    say "usage: $0 {break --i-am-in-a-disposable-lab-vm | verify | restore | cleanup}"
}

main() {
    require_root
    require_tools
    local action="${1:-break}"
    shift || true

    case "$action" in
        break)
            [[ -f "$MARKER" ]] && die "The lab is already broken. Run '$0 verify', or '$0 restore' to reset."
            confirm_lab "$@"
            backup_databases
            build_lab_accounts
            backup_databases            # snapshot again, now WITH the healthy lab accounts
            break_lab
            briefing
            ;;
        verify)  verify_lab ;;
        restore) restore_databases ;;
        cleanup) cleanup_lab ;;
        -h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

# =============================================================================
#  S O L U T I O N   -   do not read before trying
# =============================================================================
#
#  STEP 0 - Reconnaissance. Never repair a database you have not read.
#
#      # getent passwd lpicops lpicsvc
#      # getent group  devops107 labops107
#      # grep -E '^(lpicops|lpicsvc):' /etc/shadow
#      # ls -l /etc/passwd /etc/shadow /etc/group /etc/gshadow
#      # pwck -r ; grpck -r
#      # id lpicops ; ls -ld /home/lpicops
#
#      pwck and grpck in read-only mode (-r) are the canonical first move:
#      they compare the four files field by field and answer "no" to every
#      repair prompt, so they can never make things worse.
#
#  ---------------------------------------------------------------------------
#  FAULT 1 - dangling primary GID
#
#      Diagnosis: /etc/passwd field 4 holds 6107, but no line in /etc/group
#      owns GID 6107, so the resolver has nothing to map it to.
#
#          # awk -F: '$1=="lpicops" {print $4}' /etc/passwd     -> 6107
#          # getent group 6107                                   -> (empty)
#
#      Fix - recreate the group with the SAME numeric GID. Never "fix" this
#      by moving the user to another group: the inodes under /home/lpicops
#      are stamped with GID 6107 and would silently become group-orphaned.
#
#          # groupadd -g 6107 devops107
#          # getent group 6107
#          devops107:x:6107:
#          # id lpicops
#          uid=6107(lpicops) gid=6107(devops107) groups=6107(devops107),6108(labops107)
#
#  ---------------------------------------------------------------------------
#  FAULT 2 - missing /etc/shadow entry
#
#      Diagnosis: /etc/passwd field 2 is 'x', which means "the hash lives in
#      /etc/shadow". With the shadow line deleted, PAM finds no credential
#      record at all - the account cannot authenticate and has no ageing data.
#
#          # pwck -r
#          user 'lpicops': no matching entry in /etc/shadow
#
#      Fix - pwconv regenerates any shadow record that /etc/passwd implies,
#      then set a real password (the regenerated field 2 is a placeholder,
#      not a valid hash):
#
#          # pwconv
#          # getent shadow lpicops
#          # passwd lpicops
#          New password: ...
#          # passwd -S lpicops
#          lpicops P 08/27/2026 0 99999 7 -1
#
#      Read the status letters: P = usable password, L = locked, NP = empty.
#      Optionally re-apply the site ageing policy from /etc/login.defs:
#
#          # chage -m 0 -M 99999 -W 7 lpicops
#          # chage -l lpicops
#
#  ---------------------------------------------------------------------------
#  FAULT 3 - home directory ownership
#
#      Diagnosis: the path in /etc/passwd field 6 is correct, but the
#      directory belongs to root with mode 0700, so the user cannot even
#      traverse it; the login shell fails to source ~/.bashrc and lands in /.
#
#          # ls -ld /home/lpicops
#          drwx------ 3 root root 4096 ... /home/lpicops
#
#      Fix - only possible AFTER fault 1, because the group name must resolve:
#
#          # chown -R lpicops:devops107 /home/lpicops
#          # chmod 0700 /home/lpicops
#          # find /home/lpicops ! -user lpicops        # must print nothing
#          # su - lpicops -c 'pwd; id'
#          /home/lpicops
#          uid=6107(lpicops) gid=6107(devops107) groups=6107(devops107),6108(labops107)
#
#      If the dotfiles were lost, they come from the skeleton directory:
#          # cp -a /etc/skel/. /home/lpicops/ && chown -R lpicops:devops107 /home/lpicops
#
#  ---------------------------------------------------------------------------
#  FAULT 4 - non-existent login shell
#
#      Diagnosis:
#          # getent passwd lpicsvc | cut -d: -f7
#          /bin/borkshell
#          # su - lpicsvc
#          su: failed to execute /bin/borkshell: No such file or directory
#
#      Fix - use usermod (or chsh), which locks the file and validates the
#      record; hand-editing /etc/passwd with a text editor is only acceptable
#      through vipw, which takes the same lock:
#
#          # chsh -l          # or: cat /etc/shells
#          # usermod -s /bin/bash lpicsvc
#          # getent passwd lpicsvc
#          lpicsvc:x:6108:6108:LPIC 107.1 lab service account:/home/lpicsvc:/bin/bash
#
#      Remember the inverse case for real service accounts: /usr/sbin/nologin
#      (or /bin/false) is the deliberate way to forbid interactive login while
#      keeping the account usable for file ownership and cron/systemd units.
#
#  ---------------------------------------------------------------------------
#  FAULT 5 - expired account
#
#      Diagnosis: field 8 of /etc/shadow is the account expiration date, in
#      days since 1970-01-01 - not to be confused with field 5 (maximum
#      password age) or field 7 (inactivity grace after password expiry).
#
#          # awk -F: '$1=="lpicsvc" {print $8}' /etc/shadow
#          1
#          # chage -l lpicsvc | grep -i 'account expires'
#          Account expires   : Jan 02, 1970
#
#      Fix - clear it (-1 means "never"):
#
#          # chage -E -1 lpicsvc          # equivalently: usermod -e "" lpicsvc
#          # chage -l lpicsvc
#          Last password change      : Aug 27, 2026
#          Password expires          : never
#          Password inactive         : never
#          Account expires           : never
#          Minimum number of days between password change : 0
#          Maximum number of days between password change : 99999
#          Number of days of warning before password expires : 7
#
#  ---------------------------------------------------------------------------
#  FAULT 6a - world-readable /etc/shadow
#
#      Diagnosis: any local user could copy the hashes and crack them offline.
#      This is the whole reason the shadow suite exists.
#
#          # ls -l /etc/shadow
#          -rw-r--r-- 1 root root 1234 ... /etc/shadow
#
#      Fix - restore the distribution default:
#
#          Debian / Ubuntu (a 'shadow' group owns the file, for chage/sg):
#          # chown root:shadow /etc/shadow && chmod 0640 /etc/shadow
#
#          RHEL / Fedora / SUSE (root-only, mode 0000; root ignores the bits):
#          # chown root:root /etc/shadow && chmod 0000 /etc/shadow
#
#      The same reasoning applies to /etc/gshadow. /etc/passwd and /etc/group
#      are 0644 on purpose: every process needs to map UIDs and GIDs to names.
#
#  FAULT 6b - /etc/group and /etc/gshadow disagree
#
#      Diagnosis:
#          # grpck -r
#          'labops107': no members in /etc/gshadow matching /etc/group
#          # awk -F: '$1=="labops107" {print $4}' /etc/group     -> lpicops
#          # awk -F: '$1=="labops107" {print $4}' /etc/gshadow   -> (empty)
#
#      Fix - grpconv rebuilds /etc/gshadow from /etc/group, keeping the group
#      passwords and administrator lists it already had:
#
#          # grpconv
#          # awk -F: '$1=="labops107"' /etc/gshadow
#          labops107:!::lpicops
#
#      The membership-safe way to add a user in the first place is either of:
#          # gpasswd -a lpicops labops107      # writes group AND gshadow
#          # usermod -aG labops107 lpicops     # -a is mandatory, or you REPLACE
#                                              # every supplementary group
#
#  ---------------------------------------------------------------------------
#  FINAL VERIFICATION - prove it, do not assume it
#
#      # pwck -r && grpck -r && echo "databases consistent"
#      # id lpicops ; id lpicsvc
#      # passwd -S lpicops ; passwd -S lpicsvc
#      # chage -l lpicsvc
#      # su - lpicops -c 'pwd; umask; groups'
#      # su - lpicsvc -c 'echo $SHELL'
#      # ls -l /etc/passwd /etc/shadow /etc/group /etc/gshadow
#      # sudo ./107.1-break-and-fix.sh verify
#
#  WHY THESE SIX
#      Each fault isolates one field of one file, and together they cover the
#      whole record layout the exam asks you to recite:
#        /etc/passwd  name:x:UID:GID:GECOS:home:shell        (faults 1, 3, 4)
#        /etc/shadow  name:hash:lastchg:min:max:warn:inact:expire:  (2, 5, 6a)
#        /etc/group   name:x:GID:members                     (fault 6b)
#        /etc/gshadow name:hash:admins:members               (fault 6b)
#      Learn the field numbers by position; in an exam room you will not have
#      the man page, and 'awk -F: {print $8}' is only useful if you know that
#      field 8 is the account expiry and not the password expiry.
# =============================================================================