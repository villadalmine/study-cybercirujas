#!/usr/bin/env bash
# =============================================================================
#  LPIC-1 (Exam 101-500 / 102-500, version 5.0)
#  Topic 110.1 - Perform security administration tasks
#  Break & Fix lab driver
#
#  Reference (official objectives):
#    https://www.lpi.org/our-certifications/exam-101-objectives/
#    https://www.lpi.org/our-certifications/exam-102-objectives/
#
#  Key knowledge areas exercised here:
#    - Audit a system to find files with the SUID/SGID bit set
#    - Set or change user passwords and password aging information
#    - Discover open ports on a system
#    - Set up limits on user logins, processes and memory usage
#    - Determine which users have logged in / are currently logged in
#    - Basic sudo configuration and usage
#  Utilities: find, passwd, chage, usermod, su, sudo, visudo, ulimit,
#             ss / netstat / lsof / fuser / nmap, who, w, last, faillog
#
#  >>> DESTRUCTIVE. RUN ONLY ON A DISPOSABLE LABORATORY VM. <<<
#  This script deliberately breaks authentication, resource limits and
#  privilege escalation paths. It modifies /etc/sudoers.d, /etc/security,
#  /etc/shadow aging fields, the SUID bit of /usr/bin/passwd, and starts a
#  network listener. Never run it on a machine you care about, on a shared
#  host, or on anything reachable from an untrusted network.
#
#  Usage:
#    sudo ./110.1-break-and-fix.sh break   --yes-i-am-in-a-disposable-vm
#    sudo ./110.1-break-and-fix.sh verify
#    sudo ./110.1-break-and-fix.sh restore
#
#  KEEP A ROOT SHELL OPEN for the whole exercise. Fault 3 and fault 4 affect
#  privilege escalation and session limits for the lab user; the root shell is
#  your rescue path, and `restore` is your undo button.
# =============================================================================

set -euo pipefail

LAB_USER="lpicstu"
LAB_PASS="Lpic1-Lab-2026"
LISTEN_PORT="31337"
STATE_DIR="/var/backups/lpic-110.1-breakfix"
SUDO_DROPIN_DIR="/etc/sudoers.d"
SUDO_DROPIN_GOOD="${SUDO_DROPIN_DIR}/10-lab-ops"
SUDO_DROPIN_BROKEN="${SUDO_DROPIN_DIR}/10-lab-ops.conf"
LIMITS_FILE="/etc/security/limits.d/99-lab-hardening.conf"
ROGUE_SUID="/usr/local/bin/diskreport"
SVC_ROOT="/var/tmp/labsvc-root"
NOLOGIN_FILE="/etc/nologin"

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_CYA=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_BLD=""; C_RST=""
fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BLD$C_CYA" "$*" "$C_RST"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        say "This script must run as root (it edits /etc/shadow, /etc/sudoers.d, SUID bits)."
        exit 1
    fi
}

# Resolve real paths once; /usr/bin vs /bin differs across distributions.
PASSWD_BIN="$(command -v passwd || echo /usr/bin/passwd)"
ID_BIN="$(command -v id || echo /usr/bin/id)"
DU_BIN="$(command -v du || echo /usr/bin/du)"

# -----------------------------------------------------------------------------
# BREAK
# -----------------------------------------------------------------------------

confirm_or_die() {
    if [ "${1:-}" != "--yes-i-am-in-a-disposable-vm" ]; then
        say ""
        say "${C_RED}${C_BLD}REFUSING TO RUN.${C_RST}"
        say "This script is destructive. Re-run it as:"
        say "  $0 break --yes-i-am-in-a-disposable-vm"
        say ""
        exit 2
    fi
    say ""
    say "${C_YEL}Breaking the system in 5 seconds. Ctrl-C to abort.${C_RST}"
    sleep 5
}

save_state() {
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"
    {
        echo "PASSWD_BIN=$PASSWD_BIN"
        echo "ID_BIN=$ID_BIN"
        echo "LAB_USER=$LAB_USER"
        echo "LISTEN_PORT=$LISTEN_PORT"
        echo "BROKEN_AT=$(date -Is)"
    } > "${STATE_DIR}/state.env"
}

create_lab_user() {
    if ! id -u "$LAB_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -c "LPIC-1 lab student" "$LAB_USER"
    fi
    printf '%s:%s\n' "$LAB_USER" "$LAB_PASS" | chpasswd
    # Baseline aging so the "before" picture is sane and the student can compare.
    chage -E -1 -M 99999 -m 0 -W 7 -I -1 "$LAB_USER"
    passwd -u "$LAB_USER" >/dev/null 2>&1 || true
}

snapshot_suid_baseline() {
    # Free, offline integrity baseline. Real systems keep this in a package
    # database (rpm -Va / dpkg --verify) or in AIDE; here a flat file is enough.
    find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null \
        | sort > "${STATE_DIR}/suid-sgid.baseline"
    say "  baseline: $(wc -l < "${STATE_DIR}/suid-sgid.baseline") SUID/SGID files recorded"
}

fault_1_suid() {
    # 1a. Strip the SUID bit from passwd(1). Non-root users can no longer change
    #     their own password: the binary can no longer write /etc/shadow.
    stat -c '%a %n' "$PASSWD_BIN" > "${STATE_DIR}/passwd.mode"
    chmod u-s "$PASSWD_BIN"

    # 1b. Plant a root-owned SUID binary outside any package. Harmless payload
    #     (du), but it is exactly the shape of a real backdoor and it must show
    #     up in the audit.
    install -m 0755 -o root -g root "$DU_BIN" "$ROGUE_SUID"
    chmod 4755 "$ROGUE_SUID"
}

fault_2_aging() {
    cp -a /etc/shadow "${STATE_DIR}/shadow.bak"
    # Account expiration date in the past + locked password hash.
    chage -E 2020-01-01 "$LAB_USER"
    # Maximum password age 0 => the password is considered expired every login.
    chage -M 0 -W 0 "$LAB_USER"
    usermod -L "$LAB_USER"
}

fault_3_sudo() {
    # The grant itself is written correctly... into a filename sudo silently
    # ignores. sudo skips any file in /etc/sudoers.d whose name contains a dot
    # or ends in '~', and it says nothing about it. `visudo -c` reports OK.
    umask 0227
    cat > "$SUDO_DROPIN_BROKEN" <<EOF
# Lab operations grant for the on-call student account.
# Reviewed and approved by the platform team.
${LAB_USER} ALL=(root) NOPASSWD: ${ID_BIN}, /usr/bin/systemctl
EOF
    chmod 0440 "$SUDO_DROPIN_BROKEN"
    umask 0022
    rm -f "$SUDO_DROPIN_GOOD"
}

fault_4_limits() {
    mkdir -p /etc/security/limits.d
    cat > "$LIMITS_FILE" <<EOF
# Hardening drop-in applied by "the previous administrator".
# Intent: contain fork bombs. Effect: nobody can work.
${LAB_USER}  hard  nproc  6
${LAB_USER}  soft  nproc  6
EOF
    chmod 0644 "$LIMITS_FILE"
}

fault_5_listener() {
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 not found - fault 5 (rogue listener) skipped on this VM"
        return 0
    fi
    mkdir -p "$SVC_ROOT"
    ( cd "$SVC_ROOT" && setsid nohup python3 -m http.server "$LISTEN_PORT" \
        --bind 0.0.0.0 >/dev/null 2>&1 & )
    sleep 1
    pgrep -f "http.server ${LISTEN_PORT}" > "${STATE_DIR}/labsvc.pid" 2>/dev/null || true
}

fault_6_nologin() {
    cat > "$NOLOGIN_FILE" <<'EOF'
Scheduled maintenance in progress. Interactive logins are disabled.
EOF
    chmod 0644 "$NOLOGIN_FILE"
}

do_break() {
    confirm_or_die "${1:-}"
    head1 "== Preparing lab state =="
    save_state
    create_lab_user
    snapshot_suid_baseline

    head1 "== Injecting faults =="
    fault_1_suid    ; ok "fault 1 injected"
    fault_2_aging   ; ok "fault 2 injected"
    fault_3_sudo    ; ok "fault 3 injected"
    fault_4_limits  ; ok "fault 4 injected"
    fault_5_listener; ok "fault 5 injected"
    fault_6_nologin ; ok "fault 6 injected"

    print_briefing
}

print_briefing() {
    cat <<EOF

${C_BLD}=============================================================================
 LPIC-1 110.1 - BREAK & FIX BRIEFING
=============================================================================${C_RST}

A lab account exists: user ${C_BLD}${LAB_USER}${C_RST}, password ${C_BLD}${LAB_PASS}${C_RST}
A SUID/SGID baseline taken BEFORE the damage is at:
  ${STATE_DIR}/suid-sgid.baseline

Six independent faults were injected. They are layered: some symptoms only
become visible after you have fixed an earlier one. Work top to bottom and
re-run '$0 verify' as often as you like.

${C_BLD}--- FAULT 1: the SUID audit ---${C_RST}
SYMPTOM   As ${LAB_USER}, 'passwd' fails with
            passwd: Authentication token manipulation error
          even when the current password is typed correctly. Meanwhile the
          machine carries one SUID root binary that no package installed.
GOAL      Audit the whole filesystem for SUID/SGID files, diff the result
          against the baseline above, restore the legitimate binary that lost
          its SUID bit, and neutralise the illegitimate one. Be able to explain
          why a SUID root copy of a program is a privilege escalation and why
          'passwd' needs the bit in the first place.

${C_BLD}--- FAULT 2: password aging and account state ---${C_RST}
SYMPTOM   'su - ${LAB_USER}' from root is refused:
            Your account has expired; please contact your system administrator
          and the shadow entry reports the password as locked.
GOAL      Unlock the account, remove the expiration date, and set a sane aging
          policy: maximum 90 days, minimum 1 day, 7 days of warning, 14 days of
          inactivity grace. Prove it with the aging report, not from memory.

${C_BLD}--- FAULT 3: sudo grant that does nothing ---${C_RST}
SYMPTOM   Once you can log in as ${LAB_USER}, 'sudo -n id' answers
            Sorry, user ${LAB_USER} may not run ... on <host>
          and 'sudo -l' lists nothing - although a file under /etc/sudoers.d
          plainly grants the access, its syntax is valid, and 'visudo -c'
          reports 'parsed OK'.
GOAL      Find out why sudo ignores that file, make the grant effective without
          rewriting the rule, and leave the file with the ownership and mode
          sudo demands. Target: 'sudo -n id -u' prints 0 as ${LAB_USER}.

${C_BLD}--- FAULT 4: resource limits ---${C_RST}
SYMPTOM   A ${LAB_USER} session dies on trivial work:
            bash: fork: retry: Resource temporarily unavailable
          Pipelines with two or three commands abort. Root is unaffected.
GOAL      Find the limit that is being applied, which file and which PAM module
          applied it, and raise it to something workable (>= 1024 processes)
          while keeping a limit in place. Verify from inside a fresh login
          session, not from root's shell.

${C_BLD}--- FAULT 5: unexplained open port ---${C_RST}
SYMPTOM   The host listens on TCP ${LISTEN_PORT} on all interfaces. No unit file,
          no entry in the package manager, no documentation.
GOAL      Identify the socket, the PID, the program, the user that owns it and
          the directory it is exposing. Stop it. Do it with the socket tools,
          not by guessing - be ready to show the exact commands.

${C_BLD}--- FAULT 6: interactive logins disabled ---${C_RST}
SYMPTOM   Non-root logins are refused with a maintenance message; root still
          logs in normally.
GOAL      Find the mechanism (it is a single file consulted by PAM) and restore
          normal logins. Also report who has logged into this machine recently
          and who is logged in right now.

${C_BLD}Self-grade:${C_RST}  $0 verify
${C_BLD}Undo everything:${C_RST}  $0 restore

EOF
}

# -----------------------------------------------------------------------------
# VERIFY
# -----------------------------------------------------------------------------

PASS_N=0
FAIL_N=0
check() { # check "<label>" <exit-status>
    if [ "$2" -eq 0 ]; then ok "$1"; PASS_N=$((PASS_N+1))
    else bad "$1"; FAIL_N=$((FAIL_N+1)); fi
}

do_verify() {
    head1 "== Verifying fixes for topic 110.1 =="

    # Fault 1a - passwd must be SUID root again.
    if [ -u "$PASSWD_BIN" ] && [ "$(stat -c '%U' "$PASSWD_BIN")" = "root" ]; then
        check "1a  $PASSWD_BIN is SUID root" 0
    else
        check "1a  $PASSWD_BIN is SUID root" 1
    fi

    # Fault 1b - the planted binary must no longer be SUID (removed or chmod).
    if [ ! -e "$ROGUE_SUID" ] || [ ! -u "$ROGUE_SUID" ]; then
        check "1b  rogue SUID binary neutralised ($ROGUE_SUID)" 0
    else
        check "1b  rogue SUID binary neutralised ($ROGUE_SUID)" 1
    fi

    # Fault 2 - account unlocked, not expired, sane aging.
    local st exp maxd warnd inact
    st="$(passwd -S "$LAB_USER" 2>/dev/null | awk '{print $2}')"
    exp="$(chage -l "$LAB_USER" 2>/dev/null | awk -F': *' '/Account expires/{print $2}')"
    maxd="$(chage -l "$LAB_USER" 2>/dev/null | awk -F': *' '/Maximum number/{print $2}')"
    warnd="$(chage -l "$LAB_USER" 2>/dev/null | awk -F': *' '/warning/{print $2}')"
    inact="$(chage -l "$LAB_USER" 2>/dev/null | awk -F': *' '/Password inactive/{print $2}')"
    [ "$st" = "P" ] && check "2a  password unlocked (passwd -S => P)" 0 \
                    || check "2a  password unlocked (passwd -S => P)" 1
    [ "$exp" = "never" ] && check "2b  account has no expiration date" 0 \
                         || check "2b  account has no expiration date" 1
    if [ "${maxd:-0}" -ge 1 ] 2>/dev/null && [ "${maxd:-0}" -le 90 ] 2>/dev/null; then
        check "2c  maximum password age is sane (1..90, now $maxd)" 0
    else
        check "2c  maximum password age is sane (1..90, now ${maxd:-unset})" 1
    fi
    if [ "${warnd:-0}" -ge 7 ] 2>/dev/null && [ "$inact" != "never" ]; then
        check "2d  warning >= 7 days and inactivity grace set" 0
    else
        check "2d  warning >= 7 days and inactivity grace set" 1
    fi

    # Fault 3 - the sudo grant must actually apply.
    if su - "$LAB_USER" -c "sudo -n $ID_BIN -u" 2>/dev/null | grep -qx '0'; then
        check "3   sudo grant effective (sudo -n id -u => 0)" 0
    else
        check "3   sudo grant effective (sudo -n id -u => 0)" 1
    fi

    # Fault 4 - nproc limit inside a real login session.
    local nproc_val
    nproc_val="$(su - "$LAB_USER" -c 'ulimit -u' 2>/dev/null || echo 0)"
    if [ "$nproc_val" = "unlimited" ] || { [ "${nproc_val:-0}" -ge 1024 ] 2>/dev/null; }; then
        check "4   nproc limit workable in a login session ($nproc_val)" 0
    else
        check "4   nproc limit workable in a login session (${nproc_val:-?})" 1
    fi

    # Fault 5 - port must be closed.
    if command -v ss >/dev/null 2>&1; then
        if [ -z "$(ss -H -ltn "sport = :${LISTEN_PORT}" 2>/dev/null)" ]; then
            check "5   TCP ${LISTEN_PORT} no longer listening" 0
        else
            check "5   TCP ${LISTEN_PORT} no longer listening" 1
        fi
    else
        warn "ss not available; check TCP ${LISTEN_PORT} manually with netstat/lsof"
    fi

    # Fault 6 - /etc/nologin must be gone.
    [ ! -e "$NOLOGIN_FILE" ] && check "6   $NOLOGIN_FILE removed" 0 \
                             || check "6   $NOLOGIN_FILE removed" 1

    printf '\n  %s%d passed%s / %s%d failed%s\n\n' \
        "$C_GRN" "$PASS_N" "$C_RST" "$C_RED" "$FAIL_N" "$C_RST"
    [ "$FAIL_N" -eq 0 ]
}

# -----------------------------------------------------------------------------
# RESTORE - full undo, for when the lab is over or the student is stuck
# -----------------------------------------------------------------------------

do_restore() {
    head1 "== Restoring the VM to its pre-lab state =="

    chmod u+s "$PASSWD_BIN" 2>/dev/null || true; ok "SUID restored on $PASSWD_BIN"
    rm -f "$ROGUE_SUID";                          ok "rogue SUID binary removed"
    rm -f "$SUDO_DROPIN_BROKEN" "$SUDO_DROPIN_GOOD"; ok "sudoers drop-ins removed"
    rm -f "$LIMITS_FILE";                         ok "limits drop-in removed"
    rm -f "$NOLOGIN_FILE";                        ok "$NOLOGIN_FILE removed"

    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    pkill -f "http.server ${LISTEN_PORT}" >/dev/null 2>&1 || true
    rm -rf "$SVC_ROOT";                           ok "listener on ${LISTEN_PORT} stopped"

    if id -u "$LAB_USER" >/dev/null 2>&1; then
        pkill -KILL -u "$LAB_USER" >/dev/null 2>&1 || true
        sleep 1
        userdel -r "$LAB_USER" >/dev/null 2>&1 || true
        ok "lab user $LAB_USER removed"
    fi

    rm -rf "$STATE_DIR";                          ok "lab state removed"
    say ""
    say "Restore complete. Verify by hand: 'ls -l $PASSWD_BIN', 'ss -ltnp', 'sudo -l'."
}

# -----------------------------------------------------------------------------

main() {
    require_root
    case "${1:-break}" in
        break)   shift || true; do_break "${1:-}" ;;
        verify)  do_verify ;;
        restore) do_restore ;;
        brief)   print_briefing ;;
        *)       say "Usage: $0 {break --yes-i-am-in-a-disposable-vm|verify|restore|brief}"; exit 2 ;;
    esac
}

main "$@"

# =============================================================================
#  S O L U T I O N   -   step by step
#  Do not read this until you have tried. Every command below is meant to be
#  typed as root on the lab VM unless the prompt says otherwise.
# =============================================================================
#
# -----------------------------------------------------------------------------
# FAULT 1 - SUID/SGID audit
# -----------------------------------------------------------------------------
#
#   Reproduce the symptom first, from the student account (after fault 2 and 6
#   are fixed, or with 'su -s /bin/bash - lpicstu'):
#
#     $ passwd
#     Changing password for lpicstu.
#     Current password:
#     passwd: Authentication token manipulation error
#     passwd: password unchanged
#
#   Audit the filesystem. -perm -4000 means "SUID bit set, other bits ignored";
#   -perm -2000 is SGID. -xdev keeps find on one filesystem, which is what you
#   want so /proc, /sys and network mounts do not pollute the result:
#
#     # find / -xdev -perm -4000 -type f -print 2>/dev/null | sort
#     # find / -xdev -perm -2000 -type f -print 2>/dev/null | sort
#     # find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
#           -exec ls -l {} \; 2>/dev/null
#
#   Diff against the baseline the lab took before breaking anything:
#
#     # find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null \
#         | sort > /tmp/suid.now
#     # diff /var/backups/lpic-110.1-breakfix/suid-sgid.baseline /tmp/suid.now
#     < /usr/bin/passwd            <- legitimate binary that LOST the bit
#     > /usr/local/bin/diskreport  <- binary that GAINED the bit
#
#   1a. passwd(1) is SUID root by design: it runs as an unprivileged user but
#       must write /etc/shadow, which is mode 0000/0640 root:shadow. Without the
#       bit the write is refused and PAM reports a token manipulation error.
#
#     # ls -l /usr/bin/passwd
#     -rwxr-xr-x 1 root root 68208 ... /usr/bin/passwd     <- no 's'
#     # chmod u+s /usr/bin/passwd
#     # ls -l /usr/bin/passwd
#     -rwsr-xr-x 1 root root 68208 ... /usr/bin/passwd     <- correct
#
#       Equivalent octal form: chmod 4755 /usr/bin/passwd
#       On a package-managed system the authoritative fix is to ask the package
#       manager what the mode should be, never to guess:
#         # rpm -Vf /usr/bin/passwd        (RPM: '.M.......' flags a mode change)
#         # dpkg --verify passwd           (Debian family)
#
#   1b. The planted file is the dangerous half. It is root-owned, SUID, and
#       lives outside any package - a classic persistence backdoor. Confirm it
#       belongs to nobody:
#
#     # ls -l /usr/local/bin/diskreport
#     -rwsr-xr-x 1 root root ... /usr/local/bin/diskreport
#     # rpm -qf /usr/local/bin/diskreport   ->  "file ... is not owned by any package"
#     # dpkg -S /usr/local/bin/diskreport   ->  "no path found matching pattern"
#
#       Remove the bit, or remove the file. In an incident you would preserve it
#       for forensics first (copy it, hash it) and only then remove it:
#
#     # sha256sum /usr/local/bin/diskreport
#     # chmod u-s /usr/local/bin/diskreport     # neutralise
#     # rm -f /usr/local/bin/diskreport         # or delete outright
#
#       Why it matters: any SUID root program that can run another program, open
#       an arbitrary file, or write where you choose is a full root escalation.
#       A SUID copy of a shell, find, vim, awk, cp or dd hands over the machine.
#       That is why the audit is a periodic job, and why 'nosuid' is mounted on
#       /home, /tmp and any removable media.
#
# -----------------------------------------------------------------------------
# FAULT 2 - password aging and account state
# -----------------------------------------------------------------------------
#
#     # su - lpicstu
#     Your account has expired; please contact your system administrator
#
#   Read the two independent pieces of state - the lock flag lives in the hash
#   field of /etc/shadow, the dates live in fields 3..8 of the same line:
#
#     # passwd -S lpicstu
#     lpicstu L 08/31/2026 0 0 0 -1
#              ^ L = locked (P = usable password, NP = no password at all)
#
#     # chage -l lpicstu
#     Last password change                : Aug 31, 2026
#     Password expires                    : Aug 31, 2026
#     Password inactive                   : never
#     Account expires                     : Jan 01, 2020      <- in the past
#     Minimum number of days between password change  : 0
#     Maximum number of days between password change  : 0     <- expires daily
#     Number of days of warning before password expires : 0
#
#   Fix, one concern at a time:
#
#     # usermod -U lpicstu            # unlock  (equivalently: passwd -u lpicstu)
#     # chage -E -1 lpicstu           # remove the account expiration date
#     # chage -M 90 -m 1 -W 7 -I 14 lpicstu
#         -M 90  maximum password age
#         -m 1   minimum days between changes (blocks change-it-back tricks)
#         -W 7   warn 7 days ahead
#         -I 14  after expiry, 14 days of grace before the account goes inactive
#
#     # chage -d 0 lpicstu            # OPTIONAL: force a change at next login
#
#   Verify - always re-read the state, never trust the command's exit status:
#
#     # passwd -S lpicstu
#     lpicstu P 08/31/2026 1 90 7 14
#     # chage -l lpicstu | egrep 'Account expires|Maximum|warning|inactive'
#
#   Know the difference between the three "no" states:
#     usermod -L / passwd -l  -> prepends '!' to the hash: password auth is
#                                blocked, but SSH keys and su from root still
#                                work. Reversible with -U / -u.
#     chage -E <date>         -> the account itself expires: PAM refuses every
#                                login method, keys included.
#     usermod -s /usr/sbin/nologin -> no interactive shell, service account.
#
# -----------------------------------------------------------------------------
# FAULT 3 - a sudo rule that is never read
# -----------------------------------------------------------------------------
#
#     lpicstu$ sudo -n id
#     Sorry, user lpicstu may not run sudo on lab01.
#     lpicstu$ sudo -l
#     Sorry, user lpicstu may not run sudo on lab01.
#
#   Look at what is actually there, as root:
#
#     # ls -l /etc/sudoers.d/
#     -r--r----- 1 root root 168 ... 10-lab-ops.conf
#     # cat /etc/sudoers.d/10-lab-ops.conf
#     lpicstu ALL=(root) NOPASSWD: /usr/bin/id, /usr/bin/systemctl
#     # visudo -cf /etc/sudoers.d/10-lab-ops.conf
#     /etc/sudoers.d/10-lab-ops.conf: parsed OK
#
#   Syntax is fine, mode is fine, owner is fine - and sudo still ignores it.
#   The reason is in the #includedir semantics documented in sudoers(5): when
#   sudo reads a directory it SKIPS every file whose name ends in '~' or
#   CONTAINS A DOT. That is deliberate, so that package manager leftovers
#   (.rpmnew, .dpkg-dist, .bak) never silently grant privileges. The failure is
#   silent: no warning, no log line.
#
#   Confirm what sudo really loaded, and for whom:
#
#     # grep -r '^@includedir\|^#includedir' /etc/sudoers
#     @includedir /etc/sudoers.d
#     # sudo -l -U lpicstu
#     User lpicstu is not allowed to run sudo on lab01.
#
#   Fix - rename, do not rewrite the rule; then enforce ownership and mode:
#
#     # mv /etc/sudoers.d/10-lab-ops.conf /etc/sudoers.d/10-lab-ops
#     # chown root:root /etc/sudoers.d/10-lab-ops
#     # chmod 0440 /etc/sudoers.d/10-lab-ops
#     # visudo -cf /etc/sudoers.d/10-lab-ops
#     /etc/sudoers.d/10-lab-ops: parsed OK
#     # sudo -l -U lpicstu
#     User lpicstu may run the following commands on lab01:
#         (root) NOPASSWD: /usr/bin/id, /usr/bin/systemctl
#
#     lpicstu$ sudo -n id -u
#     0
#
#   Rules of the road for sudoers, all examinable:
#     - Edit ONLY through 'visudo' (or 'visudo -f <file>'): it locks the file and
#       refuses to save a file that does not parse. A syntax error saved by hand
#       makes sudo refuse to run at all, on the whole machine.
#     - Files must be mode 0440 and owned root:root; sudo refuses a
#       group/world-writable sudoers file.
#     - LAST MATCH WINS. A later 'lpicstu ALL=(ALL) !ALL' cancels an earlier
#       grant. Ordering in /etc/sudoers.d is lexical by filename, which is why
#       the files are numbered.
#     - 'sudo -l' shows your own privileges; 'sudo -l -U <user>' shows another
#       user's, and is the fastest way to answer "why can't they".
#     - 'su -' replaces the whole environment with the target user's login
#       environment; plain 'su' keeps yours. Same distinction as 'sudo -i' vs
#       'sudo -s'.
#
# -----------------------------------------------------------------------------
# FAULT 4 - resource limits
# -----------------------------------------------------------------------------
#
#     lpicstu$ ls -l /usr | wc -l
#     bash: fork: retry: Resource temporarily unavailable
#
#   Read the limit from inside the session that suffers it. Root's limits are
#   irrelevant here, which is the whole trap:
#
#     # su - lpicstu -c 'ulimit -u'
#     6
#     # su - lpicstu -c 'ulimit -a'
#     ...
#     max user processes              (-u) 6
#
#   Find who applied it. pam_limits(8) reads /etc/security/limits.conf plus
#   every *.conf under /etc/security/limits.d/:
#
#     # grep -rn 'nproc' /etc/security/limits.conf /etc/security/limits.d/
#     /etc/security/limits.d/99-lab-hardening.conf:3:lpicstu  hard  nproc  6
#     /etc/security/limits.d/99-lab-hardening.conf:4:lpicstu  soft  nproc  6
#     # grep -rn pam_limits /etc/pam.d/     # the module that enforces it
#     /etc/pam.d/system-auth:session  required  pam_limits.so
#
#   Fix - keep a limit, make it usable. Note the ordering rule: a *soft* limit
#   is the value in force and any user may raise it up to the *hard* limit; the
#   hard limit can only be lowered by an unprivileged user, never raised.
#
#     # cat > /etc/security/limits.d/99-lab-hardening.conf <<'EOF'
#     lpicstu  soft  nproc   1024
#     lpicstu  hard  nproc   2048
#     lpicstu  soft  nofile  4096
#     lpicstu  hard  nofile  8192
#     EOF
#     # chmod 0644 /etc/security/limits.d/99-lab-hardening.conf
#
#   Changes apply to NEW sessions only - pam_limits runs at session setup, so an
#   existing shell keeps the old value. Test with a fresh login shell:
#
#     # su - lpicstu -c 'ulimit -u; ulimit -n'
#     1024
#     4096
#
#   Related knowledge: 'ulimit -a' lists every limit; -u processes, -n open
#   files, -f file size, -v virtual memory, -c core size, -H/-S select hard or
#   soft. 'ulimit' is a shell builtin and affects only that shell and its
#   children. On systemd hosts a service's limits come from the unit
#   (LimitNPROC=, LimitNOFILE=), NOT from limits.d - a very common misdiagnosis.
#
# -----------------------------------------------------------------------------
# FAULT 5 - the unexplained open port
# -----------------------------------------------------------------------------
#
#   Enumerate listening sockets. -t TCP, -u UDP, -l listening, -n numeric (do
#   not resolve names - faster and it does not lie to you), -p process:
#
#     # ss -tulpn
#     Netid State  Local Address:Port  Peer Address:Port Process
#     tcp   LISTEN 0.0.0.0:22         0.0.0.0:*         users:(("sshd",pid=812,fd=3))
#     tcp   LISTEN 0.0.0.0:31337      0.0.0.0:*         users:(("python3",pid=4211,fd=3))
#
#     # ss -ltnp 'sport = :31337'          # filter to one port
#     # netstat -tulpn | grep 31337        # older equivalent (net-tools)
#     # lsof -i :31337 -P -n               # socket -> PID -> user
#     # lsof -nP -iTCP -sTCP:LISTEN        # every TCP listener, same idea
#     # fuser -v -n tcp 31337              # PID + user owning the port
#
#   Now identify the process itself before killing it:
#
#     # ps -o pid,user,lstart,cmd -p 4211
#     PID USER  STARTED                      CMD
#     4211 root Sun Aug 31 ... python3 -m http.server 31337 --bind 0.0.0.0
#     # ls -l /proc/4211/cwd        # WHICH directory it is publishing
#     lrwxrwxrwx 1 root root 0 ... /proc/4211/cwd -> /var/tmp/labsvc-root
#     # ls -l /proc/4211/exe        # the real binary behind the name
#
#   Stop it:
#
#     # kill 4211                # SIGTERM first
#     # fuser -k 31337/tcp       # or: kill whatever holds the port
#     # ss -ltnp 'sport = :31337'   # must print nothing
#
#   Scan from ANOTHER host to see what an attacker sees. nmap against your own
#   loopback hides host-firewall behaviour, so it proves less than it seems:
#
#     other$ nmap -sT -p 1-65535 <lab-ip>
#     other$ nmap -sV -p 31337 <lab-ip>
#
#   Only scan machines you own or are authorised to test.
#
# -----------------------------------------------------------------------------
# FAULT 6 - /etc/nologin, and who is on the box
# -----------------------------------------------------------------------------
#
#   If /etc/nologin exists, pam_nologin(8) prints its contents and refuses every
#   non-root login. It is the intended way to drain a host for maintenance - and
#   an equally effective way to lock everyone out if you forget it there.
#
#     # cat /etc/nologin
#     Scheduled maintenance in progress. Interactive logins are disabled.
#     # grep -rn pam_nologin /etc/pam.d/
#     /etc/pam.d/login:auth  required  pam_nologin.so
#     /etc/pam.d/sshd:account required pam_nologin.so
#     # rm -f /etc/nologin
#
#   And the login accounting half of the objective:
#
#     # who                 # current sessions, from /var/run/utmp
#     # w                   # same, plus load average and what each one is running
#     # who -b              # last boot time
#     # last                # login history, from /var/log/wtmp
#     # last -n 20 lpicstu  # that user's last 20 logins
#     # lastb               # FAILED logins, from /var/log/btmp (root only)
#     # lastlog             # last login per account, from /var/log/lastlog
#     # faillog -u lpicstu  # failure counters, where the package provides it
#
#   utmp = now, wtmp = history, btmp = failures, lastlog = one line per user.
#   They are binary files: read them with these tools, never with cat.
#
# -----------------------------------------------------------------------------
# CLOSING THE LOOP
# -----------------------------------------------------------------------------
#
#     # ./110.1-break-and-fix.sh verify        # expect 9 passed / 0 failed
#     # ./110.1-break-and-fix.sh restore       # return the VM to its baseline
#
#   Official objectives:
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#     https://www.lpi.org/our-certifications/exam-102-objectives/
#   Manual pages that answer every question above:
#     find(1) chmod(1) passwd(1) chage(1) usermod(8) shadow(5) sudo(8)
#     sudoers(5) visudo(8) su(1) limits.conf(5) pam_limits(8) pam_nologin(8)
#     ulimit in bash(1) ss(8) netstat(8) lsof(8) fuser(1) nmap(1)
#     who(1) w(1) last(1) lastlog(8)
# =============================================================================