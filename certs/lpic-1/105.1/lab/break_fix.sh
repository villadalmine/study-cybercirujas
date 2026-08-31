#!/usr/bin/env bash
#===============================================================================
#  LPIC-1 v5.0 — Topic 105.1  "Customize and use the shell environment"
#  Exam weight: 6.25   |   Objective lives in exam 102-500
#
#  BREAK & FIX LABORATORY — controlled damage + guided recovery
#
#  Official references:
#    - LPI exam objectives (101-500): https://www.lpi.org/our-certifications/exam-101-objectives/
#    - LPI exam objectives (102-500): https://www.lpi.org/our-certifications/exam-102-objectives/
#    - GNU Bash Reference Manual, "Bash Startup Files":
#        https://www.gnu.org/software/bash/manual/bash.html#Bash-Startup-Files
#    - bash(1) — INVOCATION, PROMPTING, HISTORY sections
#    - GNU Coreutils manual (umask / file creation mask):
#        https://www.gnu.org/software/coreutils/manual/html_node/index.html
#
#  WHAT THIS SCRIPT DOES
#    It injects 10 realistic, self-inflicted shell-environment faults into a
#    dedicated laboratory account and into /etc/profile.d, prints a symptom
#    briefing, and ships a grader (--verify) that proves the student actually
#    repaired the environment instead of papering over it.
#
#  *** RUN THIS ONLY ON A DISPOSABLE LABORATORY VM ***
#    One fault is system-wide (/etc/profile.d) and therefore affects EVERY
#    account on the machine, including root. This is deliberate: 105.1 is about
#    the difference between per-user and system-wide startup files, and you
#    cannot feel that difference from a per-user-only break. Never run it on a
#    workstation, a build agent, or anything you care about. Snapshot first.
#
#  USAGE
#    sudo ./105.1-break-and-fix.sh --break   [--user NAME] [--yes] [--force]
#    sudo ./105.1-break-and-fix.sh --brief   [--user NAME]
#    sudo ./105.1-break-and-fix.sh --verify  [--user NAME]
#    sudo ./105.1-break-and-fix.sh --restore [--user NAME]
#
#  The step-by-step solution is at the BOTTOM of this file, fully commented.
#  Do not scroll there until --verify reports 10/10 or you are truly stuck.
#===============================================================================

set -uo pipefail

#------------------------------------------------------------------------------
# Globals
#------------------------------------------------------------------------------
LAB_USER="lpic105"
LAB_HOME=""
STATE_DIR="/root/lpic-105.1-lab"
MANIFEST="${STATE_DIR}/created.manifest"
BRIEF_FILE="/var/tmp/lpic-105.1-briefing.txt"
PROFILE_LOCALE="/etc/profile.d/99-lpic105-lab-locale.sh"
PROFILE_TMOUT="/etc/profile.d/99-lpic105-lab-timeout.sh"
PROBE="/var/tmp/.lpic105-probe.$$"
ACTION=""
ASSUME_YES=0
FORCE=0
PASS=0
FAIL=0

trap 'rm -f "$PROBE"' EXIT

#------------------------------------------------------------------------------
# Output helpers
#------------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

usage() {
    sed -n '2,45p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
    exit 0
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "This lab must run as root (it creates a user and writes /etc/profile.d)."
}

#------------------------------------------------------------------------------
# Run a snippet of shell code AS the lab user, in a realistic shell.
#   $1 = bash option string:  -ilc  (interactive login)  |  -ic (interactive,
#        non-login: what you get from `bash` inside an existing session)
#   $2 = shell code
# env -i guarantees we observe a *fresh* login, not root's already-polluted
# environment. Job-control noise from a TTY-less interactive shell is filtered.
#------------------------------------------------------------------------------
as_student() {
    local opts="$1" code="$2" out
    printf '%s\n' "$code" > "$PROBE"
    chmod 0644 "$PROBE"
    if command -v runuser >/dev/null 2>&1; then
        out=$(runuser -u "$LAB_USER" -- env -i \
                HOME="$LAB_HOME" USER="$LAB_USER" LOGNAME="$LAB_USER" \
                SHELL=/bin/bash TERM=dumb \
                /bin/bash "$opts" ". $PROBE" 2>&1)
    else
        out=$(su "$LAB_USER" -c "env -i HOME='$LAB_HOME' USER='$LAB_USER' \
                LOGNAME='$LAB_USER' SHELL=/bin/bash TERM=dumb \
                /bin/bash $opts '. $PROBE'" 2>&1)
    fi
    printf '%s\n' "$out" \
        | grep -vE 'cannot set terminal process group|no job control in this shell'
}

check() {   # check "<title>" <0|1> ["<hint shown on failure>"]
    local title="$1" rc="$2" hint="${3:-}"
    if [ "$rc" -eq 0 ]; then
        printf '  [PASS] %s\n' "$title"
        PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$title"
        [ -n "$hint" ] && printf '         hint: %s\n' "$hint"
        FAIL=$((FAIL + 1))
    fi
}

resolve_user() {
    LAB_HOME=$(getent passwd "$LAB_USER" | cut -d: -f6)
    [ -n "$LAB_HOME" ] || die "User '$LAB_USER' does not exist. Run --break first."
    [ -d "$LAB_HOME" ] || die "Home directory '$LAB_HOME' of '$LAB_USER' is missing."
}

#------------------------------------------------------------------------------
# BREAK
#------------------------------------------------------------------------------
do_break() {
    need_root
    command -v useradd >/dev/null 2>&1 || die "useradd(8) not found; create '$LAB_USER' manually and re-run."

    if [ "$ASSUME_YES" -ne 1 ]; then
        rule
        say "You are about to damage the shell environment of THIS machine:"
        say "  * per-user startup files of the account '${LAB_USER}'"
        say "  * ${PROFILE_LOCALE}   (system-wide: affects every user, root included)"
        say "  * ${PROFILE_TMOUT}   (system-wide: idle auto-logout)"
        say "Everything is backed up under ${STATE_DIR} and '--restore' undoes it,"
        say "but this is still only for a disposable laboratory VM."
        rule
        printf 'Type exactly BREAK to continue: '
        read -r answer
        [ "$answer" = "BREAK" ] || die "Aborted; nothing was modified."
    fi

    # --- create the victim account if needed -------------------------------
    if getent passwd "$LAB_USER" >/dev/null; then
        info "Reusing existing account '$LAB_USER'."
    else
        info "Creating laboratory account '$LAB_USER' (shell /bin/bash, home from /etc/skel)."
        useradd --create-home --shell /bin/bash --comment "LPIC-1 105.1 lab" "$LAB_USER" \
            || die "useradd failed."
        # No password is set on purpose: enter the account with
        #   su - lpic105     (as root)   or   sudo -iu lpic105
        passwd --lock "$LAB_USER" >/dev/null 2>&1 || true
    fi
    resolve_user

    # --- refuse to nuke an account that looks real -------------------------
    local entries
    entries=$(find "$LAB_HOME" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if [ "$entries" -gt 25 ] && [ "$FORCE" -ne 1 ]; then
        die "'$LAB_HOME' holds $entries entries — that does not look like a scratch account. Re-run with --force if you really mean it."
    fi

    # --- back everything up ------------------------------------------------
    local stamp backup
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="${STATE_DIR}/backup-${stamp}"
    mkdir -p "$backup"
    : > "$MANIFEST"
    local f
    for f in .bashrc .bash_profile .bash_login .profile .bash_logout .bash_history; do
        [ -e "${LAB_HOME}/${f}" ] && cp -a "${LAB_HOME}/${f}" "${backup}/${f}"
    done
    ln -sfn "$backup" "${STATE_DIR}/latest"
    ok "Backup written to ${backup}"

    # ======================================================================
    # FAULT 1 + FAULT 2  —  ~/.bash_profile
    #   1) PATH is *assigned* instead of *extended* -> login shells lose
    #      /usr/bin and /bin entirely.
    #   2) ~/.bashrc is never sourced from the login shell, so the two kinds
    #      of session behave differently. This is THE classic 105.1 trap.
    # ======================================================================
    cat > "${LAB_HOME}/.bash_profile" <<'BASH_PROFILE'
# ~/.bash_profile — LPIC-1 105.1 laboratory file (INTENTIONALLY BROKEN)
# Read by bash for INTERACTIVE LOGIN shells only (console login, ssh, su -).
# See bash(1), section INVOCATION.

PATH=/usr/local/games:/usr/games
export PATH

umask 000
BASH_PROFILE
    printf '%s\n' "${LAB_HOME}/.bash_profile" >> "$MANIFEST"

    # ======================================================================
    # FAULT 3..8  —  ~/.bashrc
    #   3) PATH clobbered again, this time for non-login interactive shells
    #   4) umask 000  -> every new file is world-writable
    #   5) alias ls='ls --colour=auto'  -> British spelling, invalid option
    #   6) PS1 with unescaped non-printing sequences -> line-wrap corruption
    #   7) history disabled (HISTFILE=/dev/null, HISTSIZE=0)
    #   8) EDITOR/VISUAL point at a binary that does not exist
    #   9) unterminated `if` -> "syntax error: unexpected end of file"; bash
    #      aborts the sourcing there, so everything AFTER it silently never
    #      runs, while everything BEFORE it has already taken effect.
    # ======================================================================
    cat > "${LAB_HOME}/.bashrc" <<'BASHRC'
# ~/.bashrc — LPIC-1 105.1 laboratory file (INTENTIONALLY BROKEN)
# Read by bash for INTERACTIVE NON-LOGIN shells, and by login shells only if
# ~/.bash_profile explicitly sources it. See bash(1), section INVOCATION.

# --- search path ------------------------------------------------------------
PATH=/usr/local/games:/usr/games
export PATH

# --- default file creation mask ---------------------------------------------
umask 000

# --- aliases ----------------------------------------------------------------
alias ls='ls --colour=auto'
alias ll='ls -l'
alias grep='grep --colour=auto'

# --- prompt -----------------------------------------------------------------
PS1='\e[1;31m\u@\h:\w\$ \e[0m'

# --- command history ---------------------------------------------------------
HISTFILE=/dev/null
HISTSIZE=0
HISTFILESIZE=0

# --- preferred editor --------------------------------------------------------
export EDITOR=/usr/bin/nano-ng
export VISUAL=/usr/bin/nano-ng

# --- optional lab prompt decoration ------------------------------------------
if [ -n "$LAB_EXTRA_PROMPT" ]; then
    PS1="[lab] $PS1"

# NOTE: nothing below this point is ever executed. Ask yourself why.
export LAB105_MARKER=loaded
BASHRC
    chown "$LAB_USER":"$(id -gn "$LAB_USER")" "${LAB_HOME}/.bashrc" "${LAB_HOME}/.bash_profile"
    chmod 0644 "${LAB_HOME}/.bashrc" "${LAB_HOME}/.bash_profile"
    printf '%s\n' "${LAB_HOME}/.bashrc" >> "$MANIFEST"

    # ======================================================================
    # FAULT 9 — system-wide bogus locale (/etc/profile.d)
    #   Affects every login shell on the box. Symptom is the setlocale
    #   warning bash, perl and ssh all print.
    # ======================================================================
    cat > "$PROFILE_LOCALE" <<'PROFILED'
# LPIC-1 105.1 laboratory file (INTENTIONALLY BROKEN)
# Sourced by /etc/profile for every login shell on this system.
LC_ALL=xx_XX.UTF-8
LANG=xx_XX.UTF-8
export LC_ALL LANG
PROFILED
    chmod 0644 "$PROFILE_LOCALE"
    printf '%s\n' "$PROFILE_LOCALE" >> "$MANIFEST"

    # ======================================================================
    # FAULT 10 — system-wide idle auto-logout
    #   TMOUT is a bash builtin variable: an interactive shell that reads no
    #   input for TMOUT seconds terminates. Common in hardening baselines,
    #   and a frequent "my session keeps dying" support ticket.
    # ======================================================================
    cat > "$PROFILE_TMOUT" <<'PROFILED'
# LPIC-1 105.1 laboratory file (INTENTIONALLY BROKEN)
TMOUT=600
export TMOUT
PROFILED
    chmod 0644 "$PROFILE_TMOUT"
    printf '%s\n' "$PROFILE_TMOUT" >> "$MANIFEST"

    ok "10 faults injected."
    write_brief
    cat "$BRIEF_FILE"
}

#------------------------------------------------------------------------------
# BRIEFING
#------------------------------------------------------------------------------
write_brief() {
    cat > "$BRIEF_FILE" <<BRIEF
===============================================================================
 LPIC-1 105.1 — Customize and use the shell environment
 BREAK & FIX BRIEFING                       account under repair: ${LAB_USER}
===============================================================================

HOW TO ENTER THE BROKEN ENVIRONMENT
  As root:
      su - ${LAB_USER}        # interactive LOGIN shell   -> ~/.bash_profile
      su   ${LAB_USER}        # interactive NON-LOGIN shell -> ~/.bashrc
  Confirm which one you are in:
      shopt login_shell       # "on" = login shell
      echo \$0                 # "-bash" = login shell

SYMPTOMS YOU WILL SEE (verbatim, more or less)

  1. Almost every command disappears:
         bash: ls: command not found
         bash: vi: command not found
     ...but /bin/ls still works when you type the absolute path. The binaries
     are fine; the shell no longer knows where to look.

  2. Two sessions of the same account behave DIFFERENTLY. The prompt, aliases
     and editor you configured show up in one kind of shell and not the other.

  3. Every new interactive shell prints:
         bash: ${LAB_HOME}/.bashrc: line NN: syntax error: unexpected end of file
     Part of the file has clearly taken effect anyway. Work out which part,
     and why the rest did not.

  4. Listing files fails on a valid command:
         ls: unrecognized option '--colour=auto'
         Try 'ls --help' for more information.

  5. Any file you create is readable AND writable by the whole world:
         touch /tmp/probe && ls -l /tmp/probe
         -rw-rw-rw- 1 ${LAB_USER} ${LAB_USER} 0 ... /tmp/probe
     A security finding, not a cosmetic one.

  6. The prompt corrupts the line: type a long command and the text overwrites
     the prompt, or Ctrl-r / Up-arrow redraw the line in the wrong column.
     Bash is mis-counting the width of the prompt.

  7. history is empty in every new shell, and nothing is ever written to
     ~/.bash_history.

  8. Editing anything fails:
         crontab -e
         /usr/bin/nano-ng: No such file or directory
         crontab: "/usr/bin/nano-ng" exited with status 127

  9. Every login shell on the machine — including root's — warns:
         bash: warning: setlocale: LC_ALL: cannot change locale (xx_XX.UTF-8):
               No such file or directory
         perl: warning: Setting locale failed.
     Note that this one is NOT in the user's home directory.

 10. Idle sessions close by themselves after ten minutes:
         timed out waiting for input: auto-logout

YOUR MISSION
  Restore a sane, explainable shell environment for '${LAB_USER}' and for the
  system, using only the tools of objective 105.1:
      ~/.bash_profile  ~/.bash_login  ~/.profile  ~/.bashrc  ~/.bash_logout
      /etc/profile  /etc/profile.d/*  /etc/bash.bashrc  /etc/environment
      export, set, unset, alias, unalias, function, umask, source (.), env

RULES OF ENGAGEMENT
  * Do NOT solve it by deleting every dotfile. A working PATH, a usable prompt,
    a persistent history, a sane umask and a working editor must all be
    configured, on purpose, in the correct file.
  * Do NOT hardcode a fix that only lives in your current session. It has to
    survive a fresh login: exit, log in again, and re-test.
  * Both kinds of interactive shell must end up equivalent for the things that
    belong in ~/.bashrc (aliases, prompt, history, umask).
  * The locale fix must use a locale that actually exists on this machine
    (locale -a), not just the removal of a variable.

TOOLS THAT WILL SAVE YOU
  PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH   # emergency, in-session
  unset TMOUT                                       # stop the auto-logout now
  bash --noprofile --norc                           # a shell that reads nothing
  env -i /bin/bash --noprofile --norc               # ...with an empty environment
  bash -lx -c exit                                  # trace the startup sequence
  bash -n ~/.bashrc                                 # syntax check, no execution
  type ls ; command ls ; \\ls                        # bypass an alias
  grep -R 'TMOUT\\|LC_ALL' /etc/profile /etc/profile.d /etc/environment

GRADE YOURSELF
      sudo $(readlink -f "$0" 2>/dev/null || printf '%s' "$0") --verify --user ${LAB_USER}
  Ten checks; the grader briefly appends one probe line to ~/.bashrc and then
  restores the file byte-for-byte, so do not be surprised by the timestamp.

  Instructor escape hatch (undoes the lab): --restore
  This briefing is saved at: ${BRIEF_FILE}
===============================================================================
BRIEF
    chmod 0644 "$BRIEF_FILE"
}

do_brief() {
    resolve_user
    [ -f "$BRIEF_FILE" ] || write_brief
    cat "$BRIEF_FILE"
}

#------------------------------------------------------------------------------
# VERIFY — the grader
#------------------------------------------------------------------------------
do_verify() {
    need_root
    resolve_user
    rule
    say " LPIC-1 105.1 — grading the environment of '${LAB_USER}'"
    rule

    local out rc

    # --- C1: ~/.bashrc parses -------------------------------------------
    rc=1
    if [ -f "${LAB_HOME}/.bashrc" ]; then
        bash -n "${LAB_HOME}/.bashrc" >/dev/null 2>&1 && rc=0
    fi
    check "~/.bashrc is syntactically valid (bash -n)" "$rc" \
          "bash -n ~/.bashrc prints the offending line number"

    # --- C2: login shell has a usable PATH ------------------------------
    out=$(as_student -ilc 'printf "%s|%s\n" "$PATH" "$(command -v ls || echo NONE)"')
    rc=1
    case "$out" in
        *:/bin*|*/usr/bin*) : ;;
        *) out="${out}" ;;
    esac
    if printf '%s' "$out" | grep -q '/usr/bin' && ! printf '%s' "$out" | grep -q 'NONE'; then
        rc=0
    fi
    check "login shell PATH resolves the standard binaries" "$rc" \
          "extend PATH (PATH=\"\$PATH:...\"), never assign over it"

    # --- C3: ~/.bashrc is reached from a LOGIN shell --------------------
    rc=1
    if [ -f "${LAB_HOME}/.bashrc" ]; then
        cp -a "${LAB_HOME}/.bashrc" "${PROBE}.rc.bak"
        printf '\nexport LAB105_PROBE=ok\n' >> "${LAB_HOME}/.bashrc"
        out=$(as_student -ilc 'printf "%s\n" "${LAB105_PROBE:-missing}"')
        cp -a "${PROBE}.rc.bak" "${LAB_HOME}/.bashrc"
        rm -f "${PROBE}.rc.bak"
        printf '%s' "$out" | grep -q '^ok$' && rc=0
    fi
    check "a LOGIN shell also sources ~/.bashrc" "$rc" \
          "add [ -f ~/.bashrc ] && . ~/.bashrc to ~/.bash_profile (or ~/.profile)"

    # --- C4: umask does not expose files to the world -------------------
    out=$(as_student -ic 'umask')
    out=$(printf '%s' "$out" | tail -n1 | tr -cd '0-7')
    rc=1
    if [ ${#out} -ge 3 ]; then
        local others="${out: -1}"
        [ $(( others & 2 )) -eq 2 ] && rc=0
    fi
    check "umask masks write for 'other' (got '${out:-?}')" "$rc" \
          "022 is the conventional value; 027 if the site hardens it"

    # --- C5: ls is usable ------------------------------------------------
    out=$(as_student -ic 'ls -d / >/dev/null 2>&1; echo "__RC=$?"; ls -d / 2>&1 | head -n1')
    rc=1
    printf '%s' "$out" | grep -q '__RC=0' \
        && ! printf '%s' "$out" | grep -qi 'unrecognized option\|invalid option' && rc=0
    check "'ls' runs without an option error" "$rc" \
          "type ls shows the alias; GNU coreutils spells it --color"

    # --- C6: PS1 brackets its non-printing sequences --------------------
    out=$(as_student -ic 'printf "%s" "$PS1"')
    rc=0
    if printf '%s' "$out" | grep -q '\\e\[\|\\033\['; then
        local o c
        o=$(printf '%s' "$out" | grep -o '\\\[' | wc -l)
        c=$(printf '%s' "$out" | grep -o '\\\]' | wc -l)
        { [ "$o" -gt 0 ] && [ "$o" -eq "$c" ]; } || rc=1
    fi
    check "PS1 wraps escape sequences in \\[ ... \\]" "$rc" \
          "unbracketed escapes make bash mis-measure the prompt width"

    # --- C7: history is persistent ---------------------------------------
    out=$(as_student -ic 'printf "%s|%s\n" "${HISTFILE:-unset}" "${HISTSIZE:-0}"')
    out=$(printf '%s' "$out" | tail -n1)
    local hfile hsize
    hfile="${out%%|*}"; hsize="${out##*|}"
    rc=1
    case "$hsize" in ''|*[!0-9]*) hsize=0 ;; esac
    if [ "$hfile" != "/dev/null" ] && [ "$hfile" != "unset" ] && [ "$hsize" -ge 100 ]; then
        rc=0
    fi
    check "history is kept (HISTFILE=${hfile:-?}, HISTSIZE=${hsize})" "$rc" \
          "HISTFILE=~/.bash_history, HISTSIZE>=1000, shopt -s histappend"

    # --- C8: EDITOR resolves ---------------------------------------------
    out=$(as_student -ilc 'if [ -z "${EDITOR:-}" ]; then echo UNSET; elif command -v "$EDITOR" >/dev/null 2>&1; then echo OK; else echo BROKEN; fi')
    rc=1
    printf '%s' "$out" | grep -qE '^(OK|UNSET)$' && rc=0
    check "EDITOR points at an installed program" "$rc" \
          "export EDITOR=\"\$(command -v vi)\" — verify with command -v"

    # --- C9: no bogus locale ---------------------------------------------
    out=$(as_student -ilc 'true')
    rc=1
    ! printf '%s' "$out" | grep -qi 'cannot change locale\|setlocale' && rc=0
    check "login shells emit no setlocale warning" "$rc" \
          "grep -R LC_ALL /etc/profile.d ; pick a locale listed by locale -a"

    # --- C10: no aggressive idle timeout ----------------------------------
    out=$(as_student -ilc 'printf "%s\n" "${TMOUT:-0}"')
    out=$(printf '%s' "$out" | tail -n1 | tr -cd '0-9')
    [ -z "$out" ] && out=0
    rc=1
    { [ "$out" -eq 0 ] || [ "$out" -ge 900 ]; } && rc=0
    check "no surprise auto-logout (TMOUT=${out})" "$rc" \
          "TMOUT is set system-wide; find the file under /etc/profile.d"

    rule
    printf ' RESULT: %d passed, %d failed  (out of %d)\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
    if [ "$FAIL" -eq 0 ]; then
        ok "Environment restored. Log in once more by hand and read your own files aloud:"
        say "    su - ${LAB_USER} ; shopt login_shell ; echo \$PATH ; type ls ; umask ; echo \$HISTFILE"
    else
        warn "Not there yet. Re-read the briefing: ${BRIEF_FILE}"
    fi
    rule
    [ "$FAIL" -eq 0 ]
}

#------------------------------------------------------------------------------
# RESTORE — instructor escape hatch
#------------------------------------------------------------------------------
do_restore() {
    need_root
    resolve_user
    local backup="${STATE_DIR}/latest"
    [ -d "$backup" ] || die "No backup found under ${STATE_DIR}."

    local path
    if [ -f "$MANIFEST" ]; then
        while IFS= read -r path; do
            [ -n "$path" ] && [ -e "$path" ] && rm -f "$path" && info "removed $path"
        done < "$MANIFEST"
    fi
    rm -f "$PROFILE_LOCALE" "$PROFILE_TMOUT"

    local f
    for f in .bashrc .bash_profile .bash_login .profile .bash_logout .bash_history; do
        if [ -e "${backup}/${f}" ]; then
            cp -a "${backup}/${f}" "${LAB_HOME}/${f}"
            chown "$LAB_USER":"$(id -gn "$LAB_USER")" "${LAB_HOME}/${f}"
            info "restored ${LAB_HOME}/${f}"
        fi
    done
    rm -f "$BRIEF_FILE"
    ok "Laboratory reverted. Open a new login shell to pick up the clean environment."
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------
[ $# -eq 0 ] && usage
while [ $# -gt 0 ]; do
    case "$1" in
        --break)   ACTION="break" ;;
        --verify)  ACTION="verify" ;;
        --restore) ACTION="restore" ;;
        --brief)   ACTION="brief" ;;
        --user)    shift; LAB_USER="${1:-}"; [ -n "$LAB_USER" ] || die "--user needs a name" ;;
        --yes)     ASSUME_YES=1 ;;
        --force)   FORCE=1 ;;
        -h|--help) usage ;;
        *)         die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
done

mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

case "$ACTION" in
    break)   do_break ;;
    verify)  do_verify ;;
    restore) do_restore ;;
    brief)   do_brief ;;
    *)       usage ;;
esac

#===============================================================================
#                       S O L U T I O N   (spoilers below)
#===============================================================================
#
# Everything from here down is commented out. Read it only after you have
# genuinely attempted the repair; the diagnostic reflexes are the exam material,
# the final file contents are not.
#
#-------------------------------------------------------------------------------
# STEP 0 — Make the session survivable before you fix anything
#-------------------------------------------------------------------------------
#   The shell you are typing into is itself damaged. Repair it in memory first;
#   these changes are volatile and disappear on logout, which is exactly right.
#
#     PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#     export PATH
#     unset TMOUT
#     unalias -a                 # drop every alias in this session
#     unset LC_ALL; export LANG=C.UTF-8
#
#   If PATH is so broken that you cannot even run export, remember that export,
#   unset and cd are shell BUILTINS: they need no PATH. Only external programs
#   do. Anything else you can still reach by absolute path: /bin/ls, /usr/bin/vi.
#
#   A shell that reads nothing at all, when you need clean ground truth:
#     bash --noprofile --norc
#     env -i /bin/bash --noprofile --norc
#
#-------------------------------------------------------------------------------
# STEP 1 — Find out WHICH file is doing it (do not guess)
#-------------------------------------------------------------------------------
#   Bash startup order, from bash(1) INVOCATION — memorize this table:
#
#     interactive LOGIN shell   : /etc/profile  -> /etc/profile.d/*.sh
#                                 then the FIRST that exists of
#                                 ~/.bash_profile, ~/.bash_login, ~/.profile
#                                 on exit: ~/.bash_logout
#     interactive NON-LOGIN     : /etc/bash.bashrc (Debian) or /etc/bashrc
#                                 (RHEL), then ~/.bashrc
#     non-interactive (scripts) : neither; only $BASH_ENV if it is set
#
#   "FIRST that exists" is fault 2 in disguise: creating ~/.bash_profile hides
#   the distribution's ~/.profile, and with it the line that used to source
#   ~/.bashrc.
#
#   Trace the real thing instead of reasoning about it:
#     bash -lx -c exit 2>&1 | less        # every line of every startup file
#     shopt login_shell                    # am I a login shell?
#     echo $0                              # -bash => login shell
#     grep -R 'TMOUT\|LC_ALL\|PATH=' /etc/profile /etc/profile.d /etc/bash.bashrc \
#          /etc/bashrc /etc/environment ~/.bash_profile ~/.bashrc ~/.profile 2>/dev/null
#
#-------------------------------------------------------------------------------
# STEP 2 — The system-wide faults (/etc/profile.d) — symptoms 9 and 10
#-------------------------------------------------------------------------------
#   /etc/profile sources every *.sh under /etc/profile.d/ for login shells.
#   That is the correct place for site-wide settings, and therefore the first
#   place to look when a fault hits every account including root.
#
#     ls -l /etc/profile.d/
#     cat /etc/profile.d/99-lpic105-lab-locale.sh
#     cat /etc/profile.d/99-lpic105-lab-timeout.sh
#
#   Locale: never invent a locale name. Ask the system which ones are generated:
#     locale                       # what is in effect now
#     locale -a | grep -i utf       # what actually exists
#     localectl status              # systemd systems
#   Then either remove the file, or point it at a real locale:
#     rm -f /etc/profile.d/99-lpic105-lab-locale.sh
#     # or:  printf 'LANG=C.UTF-8\nexport LANG\n' > /etc/profile.d/99-lpic105-lab-locale.sh
#   Note LC_ALL outranks LANG and every other LC_* variable; that is why setting
#   it is a blunt instrument and why it is unset here rather than adjusted.
#
#   Timeout: TMOUT is a bash builtin variable, not a program.
#     rm -f /etc/profile.d/99-lpic105-lab-timeout.sh
#     unset TMOUT          # for the sessions already running
#
#-------------------------------------------------------------------------------
# STEP 3 — The syntax error — symptom 3
#-------------------------------------------------------------------------------
#   Check without executing:
#     bash -n ~/.bashrc
#     ~/.bashrc: line 41: syntax error: unexpected end of file
#
#   The `if` opened near the bottom is never closed. Because `source` reads and
#   executes a file command by command, everything ABOVE the broken construct
#   already ran (that is why the bad PATH and umask are in effect) and
#   everything BELOW it never ran. Add the missing terminator:
#
#     if [ -n "${LAB_EXTRA_PROMPT:-}" ]; then
#         PS1="[lab] $PS1"
#     fi
#
#   Re-check with bash -n until it is silent. Get into the habit of running
#   bash -n on any startup file you edit: a syntax error in ~/.bashrc is
#   annoying, the same error in /etc/profile can lock every user out.
#
#-------------------------------------------------------------------------------
# STEP 4 — PATH — symptom 1
#-------------------------------------------------------------------------------
#   PATH=/usr/local/games:/usr/games      # WRONG: replaces the whole path
#   PATH="$PATH:$HOME/.local/bin"         # RIGHT: extends it
#   export PATH                           # or: export PATH="$PATH:$HOME/bin"
#
#   Rules worth internalizing:
#     * A variable must be exported to reach child processes; assignment alone
#       keeps it in the current shell only.  Compare:  set | grep X   vs  env | grep X
#     * Prefer appending to prepending: a directory placed before /usr/bin can
#       shadow system binaries, which is both a bug source and an attack vector.
#     * Never put . (the current directory) in PATH.
#     * PATH belongs in a login-time file (~/.bash_profile or ~/.profile). It is
#       exported, so every child shell inherits it; re-appending it in ~/.bashrc
#       makes it grow every time you open a nested shell.
#
#-------------------------------------------------------------------------------
# STEP 5 — umask — symptom 5
#-------------------------------------------------------------------------------
#     umask                # 0000 -> new files 666, new directories 777
#     umask 022            # files 644, directories 755  (conventional)
#     umask -S             # u=rwx,g=rx,o=rx  symbolic form
#   The mask is subtracted from 666 (files) / 777 (directories); the execute bit
#   is never granted to a new file by the kernel. Set it in ~/.bashrc so every
#   interactive shell agrees, and check /etc/profile too — most distributions
#   already choose 022 or 002 there based on USER_PRIVATE_GROUP.
#   Verify: touch /tmp/p && ls -l /tmp/p   ->  -rw-r--r--
#
#-------------------------------------------------------------------------------
# STEP 6 — The alias — symptom 4
#-------------------------------------------------------------------------------
#     type ls              # ls is aliased to `ls --colour=auto'
#     alias                # list every alias
#     unalias ls           # remove it for this session
#     \ls                  # run the command, bypassing the alias (backslash)
#     command ls           # same idea, explicit builtin
#     /bin/ls              # absolute path also bypasses it
#   GNU coreutils spells the option --color. Fix the alias in ~/.bashrc:
#     alias ls='ls --color=auto'
#   Remember: aliases are NOT inherited by child shells and are ignored in
#   non-interactive shells. That is why they belong in ~/.bashrc, never in
#   ~/.bash_profile, and why scripts must never rely on them. When you need
#   logic or arguments in the middle, use a shell function instead:
#     mkcd() { mkdir -p -- "$1" && cd -- "$1"; }
#
#-------------------------------------------------------------------------------
# STEP 7 — The prompt — symptom 6
#-------------------------------------------------------------------------------
#   Bash computes the printable width of PS1 to know where the cursor is. Any
#   non-printing sequence must be fenced in \[ ... \] or the arithmetic is wrong
#   and long command lines overwrite themselves.
#
#     PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
#
#   Prompt escapes from bash(1) PROMPTING: \u user, \h short host, \H FQDN,
#   \w full working directory, \W basename, \$ shows # for root and $ otherwise,
#   \t time, \d date, \! history number, \n newline.
#   PS2 is the continuation prompt (default '> '), PS3 the select prompt, PS4
#   the trace prefix used by set -x — worth setting to
#     PS4='+ ${BASH_SOURCE}:${LINENO}: '
#   Apply without logging out:  source ~/.bashrc   (or:  . ~/.bashrc)
#
#-------------------------------------------------------------------------------
# STEP 8 — History — symptom 7
#-------------------------------------------------------------------------------
#     HISTFILE="$HOME/.bash_history"   # where it is written on exit
#     HISTSIZE=5000                    # lines kept in memory
#     HISTFILESIZE=10000               # lines kept on disk
#     HISTCONTROL=ignoredups:ignorespace   # skip duplicates and " command"
#     HISTTIMEFORMAT='%F %T '          # timestamps, hugely useful in postmortems
#     shopt -s histappend              # append instead of overwrite on exit
#     PROMPT_COMMAND='history -a'      # flush after every command
#   HISTSIZE=0 disables history entirely; HISTFILE=/dev/null silently discards
#   it. Both are legitimate hardening choices in some environments — which is
#   why the fault is plausible rather than absurd.
#   Inspect:  history 10 ; history -a ; history -r ; !! ; !$ ; Ctrl-r
#
#-------------------------------------------------------------------------------
# STEP 9 — EDITOR / VISUAL — symptom 8
#-------------------------------------------------------------------------------
#     command -v vi ; command -v nano ; command -v vim
#     export EDITOR="$(command -v vi)"
#     export VISUAL="$EDITOR"
#   crontab -e, visudo, git and less all obey these. Because they must reach
#   child processes, they have to be EXPORTED, and because they are inherited
#   they belong in the login-time file.
#
#-------------------------------------------------------------------------------
# STEP 10 — Reunite login and non-login shells — symptom 2
#-------------------------------------------------------------------------------
#   The canonical layout, and the answer the exam is looking for:
#
#     ~/.bash_profile  ->  environment that is INHERITED (PATH, EDITOR, LANG,
#                          anything exported), then explicitly source ~/.bashrc
#     ~/.bashrc        ->  everything that is NOT inherited and must be rebuilt
#                          in each interactive shell (aliases, functions, PS1,
#                          history settings, umask, shopt)
#
#   Reference ~/.bash_profile:
#     # ~/.bash_profile
#     [ -f "$HOME/.profile" ] && . "$HOME/.profile"      # if the distro uses it
#     PATH="$PATH:$HOME/.local/bin"; export PATH
#     export EDITOR="$(command -v vi)"; export VISUAL="$EDITOR"
#     [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"        # <-- the missing link
#
#   Reference ~/.bashrc (head), with the guard every distribution ships:
#     # ~/.bashrc
#     case $- in *i*) ;; *) return ;; esac   # do nothing in non-interactive shells
#     umask 022
#     alias ls='ls --color=auto'
#     alias ll='ls -alF'
#     alias grep='grep --color=auto'
#     PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
#     HISTFILE="$HOME/.bash_history"; HISTSIZE=5000; HISTFILESIZE=10000
#     HISTCONTROL=ignoredups:ignorespace; HISTTIMEFORMAT='%F %T '
#     shopt -s histappend checkwinsize
#
#   The `case $- in *i*)` guard matters: $- holds the current shell option
#   flags, and `i` is present only in interactive shells. Without the guard, a
#   ~/.bashrc that prints output will corrupt scp, rsync and sftp sessions —
#   a classic production incident that traces straight back to this objective.
#
#   Alternative, equally valid fix: delete the stray ~/.bash_profile so that
#   ~/.profile (which on Debian-family systems already sources ~/.bashrc) takes
#   over again, and put the environment there. Just be deliberate about it.
#
#-------------------------------------------------------------------------------
# STEP 11 — Prove it, the way you would in production
#-------------------------------------------------------------------------------
#     bash -n ~/.bashrc && bash -n ~/.bash_profile     # syntax
#     exec bash -l                                     # replace the shell, fresh login
#     exit; su - lpic105                               # a genuinely new session
#     shopt login_shell ; echo "$PATH" ; type ls ; umask ; echo "$HISTFILE" ; echo "$EDITOR"
#     locale ; echo "TMOUT=${TMOUT:-unset}"
#     touch /tmp/p && ls -l /tmp/p                     # expect -rw-r--r--
#     env | sort | less                                # exported only
#     set | less                                       # exported + shell-local + functions
#     sudo ./105.1-break-and-fix.sh --verify --user lpic105
#
#   The distinction in those last two commands is the heart of 105.1: `env`
#   shows what your children will inherit, `set` shows what only this shell
#   knows. Every variable you place in a startup file is a decision about which
#   of the two lists it belongs on.
#===============================================================================