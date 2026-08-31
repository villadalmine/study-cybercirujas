#!/usr/bin/env bash
#
# ==============================================================================
#  LPIC-1 (Exam 101-500, v5.0) — Topic 103.1: Work on the command line
#  Weight: 6.25
#
#  BREAK & FIX LABORATORY — "The Shell That Forgot How To Work"
#
#  Author's note for the student:
#    This script deliberately damages the *interactive shell environment* of a
#    single unprivileged user (lpicstudent) in ways that are exam-relevant for
#    103.1: PATH, shell built-ins vs. external binaries, aliases, environment
#    variables, quoting, the hashed command table, HISTFILE handling and the
#    exec/type/which family of tools.
#
#    NOTHING here touches system binaries, /etc/profile, root's environment,
#    package files or system services. Every change is confined to
#    /home/lpicstudent and to a throwaway directory under /opt/lpic-lab.
#    Even so: RUN THIS ONLY ON A DISPOSABLE LAB VM. It is designed to be run on
#    a snapshot you can roll back.
#
#  Reference (official):
#    LPI Exam 101-500 Objectives, Topic 103.1 "Work on the command line"
#    https://www.lpi.org/our-certifications/exam-101-objectives/
#    Key knowledge areas exercised below: bash, echo, env, export, pwd, set,
#    unset, type, which, man, uname, history, .bash_history, quoting.
#
#  Usage:
#    sudo ./103.1-break-and-fix.sh break     # damage the environment
#    sudo ./103.1-break-and-fix.sh verify    # check whether you fixed it
#    sudo ./103.1-break-and-fix.sh reset     # restore from the pristine backup
#    sudo ./103.1-break-and-fix.sh solution  # print the step-by-step answer
# ==============================================================================

set -o nounset
set -o pipefail

readonly LAB_USER="lpicstudent"
readonly LAB_HOME="/home/${LAB_USER}"
readonly LAB_DIR="/opt/lpic-lab/103.1"
readonly BACKUP_DIR="${LAB_DIR}/pristine"
readonly STATE_FILE="${LAB_DIR}/.broken"
readonly FLAG_FILE="${LAB_DIR}/flag.txt"
readonly FLAG_VALUE="LPIC1-103.1-PATH-RESTORED"

# ------------------------------------------------------------------------------
# Presentation helpers. Colour only when stdout is a terminal, so that piping
# the output into a file or a pager keeps it readable.
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
else
    readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%s[ info ]%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()    { printf '%s[  ok  ]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()  { printf '%s[ warn ]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf '%s[ fail ]%s %s\n' "${C_RED}"    "${C_RESET}" "$*"; }
die()   { fail "$*"; exit 1; }

rule() {
    printf '%s%s%s\n' "${C_BOLD}" \
        "==============================================================================" \
        "${C_RESET}"
}

# ------------------------------------------------------------------------------
# Safety rails. Two independent guards:
#   1. we must be root (we create a user and write to /opt and another $HOME);
#   2. we refuse to run on anything that looks like it is not a lab machine.
# The second guard is intentionally conservative: it is far cheaper to force a
# student to touch a marker file than to explain a wrecked workstation.
# ------------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This lab must run as root (try: sudo $0 $*)."
    fi
}

require_lab_machine() {
    # An explicit opt-in marker, or an obvious throwaway hostname pattern.
    if [ -f /etc/lpic-lab-vm ]; then
        return 0
    fi
    case "$(uname -n)" in
        *lab*|*lpic*|*vagrant*|*test*|localhost|localhost.localdomain) return 0 ;;
    esac

    rule
    fail "Refusing to run: this does not look like a disposable lab VM."
    say ""
    say "This script modifies a user's shell environment. It is safe and fully"
    say "reversible, but it should never run on a machine you care about."
    say ""
    say "If this really is a throwaway VM with a snapshot you can roll back to,"
    say "declare it explicitly and run the script again:"
    say ""
    say "    sudo touch /etc/lpic-lab-vm"
    say ""
    rule
    exit 1
}

ensure_lab_user() {
    if id "${LAB_USER}" >/dev/null 2>&1; then
        info "Lab user '${LAB_USER}' already exists."
        return 0
    fi

    info "Creating lab user '${LAB_USER}' ..."
    # -m creates the home directory from /etc/skel, so the student starts with a
    # normal, distribution-standard ~/.bashrc and ~/.bash_profile.
    useradd --create-home --shell /bin/bash "${LAB_USER}" \
        || die "useradd failed; create the user manually and re-run."

    # A known password so the student can 'su - lpicstudent' from anywhere.
    if command -v chpasswd >/dev/null 2>&1; then
        printf '%s:%s\n' "${LAB_USER}" "lpic103" | chpasswd
        info "Password for '${LAB_USER}' set to: lpic103"
    fi

    ok "Lab user created with a pristine ~/.bashrc from /etc/skel."
}

# ------------------------------------------------------------------------------
# Backup / restore of every file we are about to touch. Anything we modify is
# copied here FIRST, byte for byte, so 'reset' is a true rollback and not a
# best-effort re-creation.
# ------------------------------------------------------------------------------
backup_file() {
    local src="$1"
    local dst="${BACKUP_DIR}/$(basename "${src}")"

    mkdir -p "${BACKUP_DIR}"
    if [ -e "${src}" ]; then
        cp -a "${src}" "${dst}"
    else
        # Record the absence explicitly: on restore we must delete, not create.
        : > "${dst}.absent"
    fi
}

restore_file() {
    local dst="$1"
    local src="${BACKUP_DIR}/$(basename "${dst}")"

    if [ -e "${src}.absent" ]; then
        rm -f "${dst}"
    elif [ -e "${src}" ]; then
        cp -a "${src}" "${dst}"
        chown "${LAB_USER}:$(id -gn "${LAB_USER}")" "${dst}" 2>/dev/null || true
    fi
}

# ==============================================================================
#  BREAK
# ==============================================================================
do_break() {
    require_root "break"
    require_lab_machine
    ensure_lab_user

    if [ -f "${STATE_FILE}" ]; then
        warn "The lab is already broken. Run 'reset' before breaking it again."
        exit 1
    fi

    mkdir -p "${LAB_DIR}" "${BACKUP_DIR}"
    chmod 755 /opt/lpic-lab "${LAB_DIR}"

    local lab_group
    lab_group="$(id -gn "${LAB_USER}")"

    backup_file "${LAB_HOME}/.bashrc"
    backup_file "${LAB_HOME}/.bash_profile"
    backup_file "${LAB_HOME}/.profile"
    backup_file "${LAB_HOME}/.bash_history"

    # --- The reward the student must eventually read --------------------------
    printf '%s\n' "${FLAG_VALUE}" > "${FLAG_FILE}"
    chmod 644 "${FLAG_FILE}"

    # --------------------------------------------------------------------------
    # SABOTAGE 1 — PATH is truncated to a single directory.
    #
    # Everything in /usr/bin and /usr/sbin becomes unreachable by bare name.
    # This is the classic "command not found for a command that obviously
    # exists" symptom. Note it does NOT break the shell itself: built-ins
    # (cd, echo, export, type, set, unset, pwd, help) keep working, which is
    # exactly the built-in vs. external distinction 103.1 asks about.
    # --------------------------------------------------------------------------
    #
    # SABOTAGE 2 — a hostile alias shadows an external command.
    #
    # 'ls' is aliased to something that always fails. Alias > function >
    # built-in > external in bash's lookup order, so the student must know how
    # to see through it: type -a, \ls, 'ls', command ls, unalias.
    # --------------------------------------------------------------------------
    #
    # SABOTAGE 3 — a shell function shadows an external command.
    #
    # 'which' is redefined as a function that lies. A student who trusts
    # 'which' blindly will chase the wrong file. 'type -a which' exposes it.
    # --------------------------------------------------------------------------
    #
    # SABOTAGE 4 — HISTFILE is pointed at an unwritable path and HISTSIZE=0.
    #
    # Command history silently disappears between logins. This is the
    # .bash_history / history knowledge area, and it is deliberately silent:
    # there is no error message at all until logout.
    # --------------------------------------------------------------------------
    #
    # SABOTAGE 5 — an exported variable with an embedded quoting trap.
    #
    # LAB_TARGET holds a path containing spaces and a literal dollar sign.
    # Reading the flag requires correct quoting; an unquoted expansion word-
    # splits and fails. This is the quoting / metacharacter-escaping area.
    # --------------------------------------------------------------------------

    local trap_dir="${LAB_DIR}/reports \$daily"
    mkdir -p "${trap_dir}"
    printf 'Read this with correct quoting. The flag lives in %s\n' "${FLAG_FILE}" \
        > "${trap_dir}/README"
    chmod -R a+rX "${LAB_DIR}"

    cat >> "${LAB_HOME}/.bashrc" <<'BROKEN_BASHRC'

# ------------------------------------------------------------------------------
# LPIC-1 103.1 LAB — injected by the break & fix script. Remove this whole block
# (and only this block) once you understand what each line does.
# ------------------------------------------------------------------------------

# [1] PATH truncated: external commands outside /usr/local/bin vanish.
export PATH="/usr/local/bin"

# [2] Alias shadowing an external command.
alias ls='echo "ls: permission denied (lab)"; false'

# [3] Function shadowing the 'which' utility so it reports a fake location.
which() { echo "/opt/definitely-not-here/$1"; }

# [4] History silently discarded.
export HISTFILE=/proc/lpic/nonexistent/.bash_history
export HISTSIZE=0
export HISTFILESIZE=0

# [5] A quoting trap: the value contains spaces and a literal '$'.
export LAB_TARGET='/opt/lpic-lab/103.1/reports $daily'

# [6] Noisy but harmless: PS1 no longer shows where you are.
export PS1='$ '
# ------------------------------------------------------------------------------
# END LPIC-1 103.1 LAB
# ------------------------------------------------------------------------------
BROKEN_BASHRC

    chown "${LAB_USER}:${lab_group}" "${LAB_HOME}/.bashrc"

    # Seed a history file the student can inspect *before* logging out and
    # discovering that nothing new is being appended to it.
    cat > "${LAB_HOME}/.bash_history" <<'SEED_HISTORY'
uname -a
echo $PATH
type -a ls
history | tail -5
SEED_HISTORY
    chown "${LAB_USER}:${lab_group}" "${LAB_HOME}/.bash_history"
    chmod 600 "${LAB_HOME}/.bash_history"

    date -u +'%Y-%m-%dT%H:%M:%SZ' > "${STATE_FILE}"

    # --------------------------------------------------------------------------
    # Brief the student.
    # --------------------------------------------------------------------------
    rule
    say "${C_BOLD} LPIC-1 103.1 — Work on the command line — BREAK & FIX${C_RESET}"
    rule
    say ""
    say "${C_BOLD}The scenario${C_RESET}"
    say ""
    say "  A colleague 'optimised' the shell environment of the account"
    say "  ${C_BOLD}${LAB_USER}${C_RESET} and then went on holiday. The account still logs in,"
    say "  but it is barely usable. You have root on this VM, but the exercise"
    say "  is to diagnose and repair the account ${C_BOLD}from inside it${C_RESET}."
    say ""
    say "  Enter the broken environment with:"
    say ""
    say "      ${C_BOLD}su - ${LAB_USER}${C_RESET}        (password: lpic103)"
    say ""
    say "  The leading dash matters: it starts a *login* shell, which is what"
    say "  reads the startup files that were tampered with."
    say ""
    say "${C_BOLD}The symptoms you will see${C_RESET}"
    say ""
    say "  1. Almost every command fails instantly:"
    say ""
    say "         \$ uname -a"
    say "         bash: uname: command not found"
    say "         \$ cat /etc/hostname"
    say "         bash: cat: command not found"
    say ""
    say "     ...yet some things still work perfectly:"
    say ""
    say "         \$ cd /tmp && pwd"
    say "         /tmp"
    say "         \$ echo \"still alive\""
    say "         still alive"
    say ""
    say "     ${C_YELLOW}Why do those two survive?${C_RESET} Answering that is half the lab."
    say ""
    say "  2. 'ls' does not fail with 'command not found'. It fails with a"
    say "     permission message that no real 'ls' would ever print:"
    say ""
    say "         \$ ls"
    say "         ls: permission denied (lab)"
    say ""
    say "  3. 'which bash' confidently reports a path that does not exist:"
    say ""
    say "         \$ which bash"
    say "         /opt/definitely-not-here/bash"
    say ""
    say "  4. Your command history is gone every time you log back in, and"
    say "     'history' shows almost nothing. No error is ever printed."
    say ""
    say "  5. The prompt is a bare '\$ ' with no user, host or directory."
    say ""
    say "${C_BOLD}Your objectives${C_RESET}"
    say ""
    say "  O1. Restore a working PATH for ${LAB_USER}, both for the current"
    say "      session and permanently, so that ordinary external commands"
    say "      (uname, cat, ls, grep, id) run by bare name again."
    say ""
    say "  O2. Make the real /bin/ls run when you type 'ls', and be able to"
    say "      explain — using 'type -a ls' — the order bash uses to resolve"
    say "      a command name."
    say ""
    say "  O3. Make 'which' be the external utility again, and prove it with"
    say "      'type -a which'."
    say ""
    say "  O4. Make command history persist across logins: HISTFILE must point"
    say "      at ${LAB_HOME}/.bash_history and HISTSIZE/HISTFILESIZE"
    say "      must be sane. Verify that a command you run now is present in"
    say "      that file after you log out and back in."
    say ""
    say "  O5. Read the file ${LAB_DIR}/reports \$daily/README"
    say "      using the exported variable \$LAB_TARGET. The value contains a"
    say "      space and a literal dollar sign, so unquoted expansion will"
    say "      not work. Then print the flag from ${FLAG_FILE}."
    say ""
    say "${C_BOLD}Tools that will get you there (all are 103.1 material)${C_RESET}"
    say ""
    say "      type -a       command       builtin       enable"
    say "      echo \"\$PATH\"  export        set           unset"
    say "      env           alias         unalias        history"
    say "      uname -a      man bash      help"
    say ""
    say "${C_BOLD}Rules of engagement${C_RESET}"
    say ""
    say "  * Do not just delete ~/.bashrc and log out. Fix the current shell"
    say "    first, with no external commands available, and only then repair"
    say "    the file. Recovering a live session is the actual skill."
    say "  * Everything you need is a bash built-in plus one absolute path."
    say ""
    say "${C_BOLD}When you think you are done${C_RESET}"
    say ""
    say "      exit                      # leave the ${LAB_USER} shell"
    say "      sudo $0 verify"
    say ""
    say "  Stuck? ${C_BOLD}sudo $0 solution${C_RESET}"
    say "  Ruined it? ${C_BOLD}sudo $0 reset${C_RESET}   (restores the pristine files)"
    say ""
    rule
}

# ==============================================================================
#  VERIFY
#  Every check runs a fresh *login* shell as the lab user, because that is the
#  only honest way to test a persistent fix: it re-reads the startup files.
# ==============================================================================
as_lab_user() {
    # -l : login shell, so ~/.bash_profile / ~/.profile / ~/.bashrc are read.
    # -c : run the command and exit.
    su -l "${LAB_USER}" -c "$1" 2>&1
}

do_verify() {
    require_root "verify"

    if [ ! -f "${STATE_FILE}" ]; then
        warn "The lab has not been broken yet. Run: sudo $0 break"
        exit 1
    fi

    local passed=0 failed=0
    check() {
        local label="$1" result="$2"
        if [ "${result}" = "PASS" ]; then
            ok "${label}"
            passed=$((passed + 1))
        else
            fail "${label}"
            failed=$((failed + 1))
        fi
    }

    rule
    say "${C_BOLD} Verifying the repair of ${LAB_USER}'s environment${C_RESET}"
    rule

    # --- O1: PATH contains the standard binary directories ---------------------
    local path_value
    path_value="$(as_lab_user 'printf "%s" "$PATH"')"
    case ":${path_value}:" in
        *:/usr/bin:*) check "O1a  PATH includes /usr/bin  [${path_value}]" PASS ;;
        *)            check "O1a  PATH includes /usr/bin  [${path_value}]" FAIL ;;
    esac

    # --- O1: external commands resolve by bare name ----------------------------
    local uname_out
    uname_out="$(as_lab_user 'uname -s')"
    if [ "${uname_out}" = "Linux" ]; then
        check "O1b  'uname -s' resolves by bare name -> ${uname_out}" PASS
    else
        check "O1b  'uname -s' still fails -> ${uname_out}" FAIL
    fi

    # --- O2: 'ls' is the external binary, not the hostile alias ----------------
    local ls_type
    ls_type="$(as_lab_user 'type -t ls')"
    if [ "${ls_type}" = "file" ]; then
        check "O2   'type -t ls' reports 'file' (real binary, alias gone)" PASS
    else
        check "O2   'type -t ls' reports '${ls_type}' (expected 'file')" FAIL
    fi

    # --- O3: 'which' is the external utility, not the lying function -----------
    local which_type
    which_type="$(as_lab_user 'type -t which')"
    if [ "${which_type}" = "file" ] || [ "${which_type}" = "alias" ]; then
        check "O3   'which' is no longer a shell function (type -t -> ${which_type})" PASS
    else
        check "O3   'which' is still a ${which_type:-<undefined>}" FAIL
    fi

    # --- O4: history is persistent -------------------------------------------
    local histfile histsize
    histfile="$(as_lab_user 'printf "%s" "${HISTFILE:-<unset>}"')"
    histsize="$(as_lab_user 'printf "%s" "${HISTSIZE:-<unset>}"')"

    if [ "${histfile}" = "${LAB_HOME}/.bash_history" ] || [ "${histfile}" = "<unset>" ]; then
        check "O4a  HISTFILE points at the real history file [${histfile}]" PASS
    else
        check "O4a  HISTFILE is wrong [${histfile}]" FAIL
    fi

    if [ "${histsize}" = "<unset>" ] || { [ "${histsize}" -gt 0 ] 2>/dev/null; }; then
        check "O4b  HISTSIZE allows history to be kept [${histsize}]" PASS
    else
        check "O4b  HISTSIZE is ${histsize}: nothing will ever be remembered" FAIL
    fi

    # --- O5: the quoting trap was solved -------------------------------------
    local readme_out
    readme_out="$(as_lab_user 'cat "$LAB_TARGET/README" 2>/dev/null || true')"
    if [ -n "${readme_out}" ]; then
        check "O5a  \"\$LAB_TARGET/README\" is readable with correct quoting" PASS
    else
        check "O5a  \$LAB_TARGET does not resolve to a readable README" FAIL
    fi

    local flag_out
    flag_out="$(as_lab_user "cat '${FLAG_FILE}' 2>/dev/null || true")"
    if [ "${flag_out}" = "${FLAG_VALUE}" ]; then
        check "O5b  flag readable: ${FLAG_VALUE}" PASS
    else
        check "O5b  flag not readable by ${LAB_USER}" FAIL
    fi

    say ""
    rule
    if [ "${failed}" -eq 0 ]; then
        ok "${C_BOLD}ALL ${passed} CHECKS PASSED — 103.1 environment repaired.${C_RESET}"
        say ""
        say "Now make sure you can explain, without looking anything up:"
        say "  * why 'cd' and 'echo' kept working when PATH was empty;"
        say "  * the exact order bash resolves: alias, keyword, function,"
        say "    builtin, hashed path, PATH search;"
        say "  * why 'type -a' is more trustworthy than 'which';"
        say "  * when you need 'hash -r'."
        say ""
        say "Roll the VM back to its snapshot, or run: sudo $0 reset"
    else
        fail "${failed} check(s) still failing, ${passed} passed."
        say ""
        say "Re-read the symptom list from 'break', or run: sudo $0 solution"
    fi
    rule

    [ "${failed}" -eq 0 ]
}

# ==============================================================================
#  RESET
# ==============================================================================
do_reset() {
    require_root "reset"

    if [ ! -d "${BACKUP_DIR}" ]; then
        die "No pristine backup found at ${BACKUP_DIR}; nothing to restore."
    fi

    info "Restoring ${LAB_USER}'s startup files from ${BACKUP_DIR} ..."
    restore_file "${LAB_HOME}/.bashrc"
    restore_file "${LAB_HOME}/.bash_profile"
    restore_file "${LAB_HOME}/.profile"
    restore_file "${LAB_HOME}/.bash_history"

    rm -f "${STATE_FILE}"
    ok "Environment restored. Run 'sudo $0 break' to start over."
}

# ==============================================================================
#  SOLUTION
# ==============================================================================
do_solution() {
    rule
    say "${C_BOLD} SOLUTION — LPIC-1 103.1 Work on the command line${C_RESET}"
    rule
    sed -n '/^# SOLUTION-BEGIN/,/^# SOLUTION-END/p' "$0" \
        | sed -e 's/^# SOLUTION-BEGIN$//' -e 's/^# SOLUTION-END$//' -e 's/^#\{1,2\} \{0,1\}//'
    rule
}

usage() {
    say "Usage: sudo $0 {break|verify|reset|solution}"
    say ""
    say "  break     Damage ${LAB_USER}'s shell environment and brief the student."
    say "  verify    Check the five objectives from a fresh login shell."
    say "  reset     Restore the pristine startup files from backup."
    say "  solution  Print the full step-by-step walkthrough."
}

case "${1:-}" in
    break)    do_break ;;
    verify)   do_verify ;;
    reset)    do_reset ;;
    solution) do_solution ;;
    *)        usage; exit 1 ;;
esac

exit $?

# SOLUTION-BEGIN
#
# ==============================================================================
# STEP-BY-STEP WALKTHROUGH
# ==============================================================================
#
# You are inside `su - lpicstudent`. PATH is "/usr/local/bin", `ls` is a hostile
# alias, `which` is a lying function, history is being discarded, and the prompt
# is bare. You have exactly one thing to work with: bash itself.
#
# ------------------------------------------------------------------------------
# STEP 0 — Understand why the shell is not completely dead
# ------------------------------------------------------------------------------
#
#   $ cd /tmp && pwd
#   /tmp
#   $ echo "hello"
#   hello
#   $ cat /etc/hostname
#   bash: cat: command not found
#
# `cd`, `pwd` and `echo` are SHELL BUILT-INS: they live inside the bash process
# and are never looked up in PATH. `cat` is an EXTERNAL BINARY at /usr/bin/cat
# and can only be found through PATH (or by absolute/relative path). That single
# distinction is the core of objective 103.1, and it is what makes this lab
# recoverable at all.
#
# Confirm it with the built-in that answers exactly this question:
#
#   $ type cd
#   cd is a shell builtin
#   $ type -a echo
#   echo is a shell builtin
#   echo is /usr/bin/echo          <-- only visible once PATH is fixed
#   $ type cat
#   bash: type: cat: not found
#
# `type` is itself a built-in, so it keeps working. `which` does not — and here
# it is worse than useless, because it has been replaced by a function.
#
# List every built-in available to you right now:
#
#   $ enable -a | head
#   $ help                          # one-line summary of every built-in
#
# ------------------------------------------------------------------------------
# STEP 1 — See the damage (O1 diagnosis)
# ------------------------------------------------------------------------------
#
#   $ echo "$PATH"
#   /usr/local/bin
#
# There it is. Two directories short of a working system. Note the quotes around
# $PATH: without them the value would be word-split, which usually does not
# matter for PATH but is a habit the exam expects.
#
# Look at the wider environment using built-ins only:
#
#   $ set | grep -i hist            # 'grep' is external -> fails right now
#   bash: grep: command not found
#
#   $ echo "$HISTFILE $HISTSIZE $HISTFILESIZE"
#   /proc/lpic/nonexistent/.bash_history 0 0
#
# `set` (built-in) prints shell variables AND functions; `export -p` prints only
# exported ones; `env` is an external command and is unreachable until PATH is
# fixed. Use the right tool for the situation you are actually in.
#
# ------------------------------------------------------------------------------
# STEP 2 — Repair PATH in the LIVE session (O1, current shell)
# ------------------------------------------------------------------------------
#
# `export` is a built-in, so this works even with a broken PATH:
#
#   $ export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
#   $ echo "$PATH"
#   /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#   $ uname -a
#   Linux lpic-lab 6.1.0-lab #1 SMP x86_64 GNU/Linux
#
# If you preferred to append rather than retype, the idiom is:
#
#   $ export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
#
# Never write `PATH=/usr/bin` without `export` if child processes need it, and
# never put an empty element or "." in PATH — an empty element means "the
# current directory", which is a real privilege-escalation vector:
#
#   PATH="/usr/bin:"      # trailing colon == "." — do not do this
#
# After changing PATH, clear bash's hash table so it re-searches from scratch:
#
#   $ hash -r
#   $ hash
#   hits    command
#      1    /usr/bin/uname
#
# `hash` caches the full path of every external command you have run. If a
# binary moves and a command keeps resolving to the old location, `hash -r` is
# the answer — a classic exam question.
#
# ------------------------------------------------------------------------------
# STEP 3 — Unmask 'ls' (O2)
# ------------------------------------------------------------------------------
#
#   $ ls
#   ls: permission denied (lab)
#
# That is not the real /bin/ls. Ask bash what it is actually running, and ask
# for ALL matches, not just the first:
#
#   $ type -a ls
#   ls is aliased to `echo "ls: permission denied (lab)"; false'
#   ls is /usr/bin/ls
#
# Bash resolves a command name in this fixed order — memorise it:
#
#   1. alias
#   2. shell keyword   (if, for, while, function, [[ ... )
#   3. shell function
#   4. shell built-in
#   5. hashed path
#   6. PATH search
#
# Three ways to bypass an alias for a single command (alias expansion is
# suppressed when any character of the word is quoted or escaped):
#
#   $ \ls                    # backslash-escape the first character
#   $ 'ls'                    # quote the word
#   $ command ls              # skip aliases and functions entirely
#
# And the permanent fix for the current session:
#
#   $ unalias ls
#   $ type -a ls
#   ls is /usr/bin/ls
#
# `unalias -a` removes every alias at once. `alias` with no arguments lists
# them all — run it to check nothing else was tampered with.
#
# ------------------------------------------------------------------------------
# STEP 4 — Unmask 'which' (O3)
# ------------------------------------------------------------------------------
#
#   $ which bash
#   /opt/definitely-not-here/bash
#   $ type -a which
#   which is a function
#   which ()
#   {
#       echo "/opt/definitely-not-here/$1"
#   }
#   which is /usr/bin/which
#
# A function outranks the external binary, so `which` was lying. Remove it with
# the built-in that deletes functions and variables:
#
#   $ unset -f which
#   $ type -a which
#   which is /usr/bin/which
#   $ which bash
#   /usr/bin/bash
#
# Note `unset -f` (function) versus `unset -v` (variable). Plain `unset NAME`
# tries the variable first, which is why being explicit matters.
#
# LESSON: `which` is an external program. It knows nothing about aliases,
# functions or built-ins, and on some systems it reads its own startup files.
# `type -a` is a bash built-in and reports the truth about what YOUR shell will
# execute. Prefer `type -a` for diagnosis; `which` is only for scripting a path.
#
# ------------------------------------------------------------------------------
# STEP 5 — Restore command history (O4)
# ------------------------------------------------------------------------------
#
#   $ echo "$HISTFILE"
#   /proc/lpic/nonexistent/.bash_history
#   $ history
#       1  echo $PATH
#       2  history
#
# Nothing is being saved because HISTFILE points at an unwritable path and
# HISTSIZE=0 means "remember zero commands in memory". Fix both:
#
#   $ export HISTFILE="$HOME/.bash_history"
#   $ export HISTSIZE=1000
#   $ export HISTFILESIZE=2000
#
# Useful history operations from the objective:
#
#   $ history                 # numbered list of the in-memory list
#   $ history 5               # last five entries
#   $ history -w              # write the in-memory list to $HISTFILE now
#   $ history -a              # append only the new entries of this session
#   $ history -r              # read $HISTFILE into memory
#   $ history -c              # clear the in-memory list
#   $ !42                     # re-run entry 42
#   $ !!                      # re-run the previous command
#
# History is written on a clean exit, so a killed terminal loses the session.
# `history -a` after important work is a real operational habit.
#
# Prove the fix survives a logout:
#
#   $ echo "MARKER-103-1"
#   $ history -a
#   $ exit
#   $ su - lpicstudent
#   $ grep MARKER-103-1 ~/.bash_history
#   MARKER-103-1
#
# (Note: HISTCONTROL=ignorespace makes a command prefixed with a space stay out
# of history — the correct way to type a one-off command containing a secret.)
#
# ------------------------------------------------------------------------------
# STEP 6 — The quoting trap (O5)
# ------------------------------------------------------------------------------
#
#   $ echo $LAB_TARGET
#   /opt/lpic-lab/103.1/reports $daily
#   $ cat $LAB_TARGET/README
#   cat: '/opt/lpic-lab/103.1/reports': No such file or directory
#   cat: '$daily/README': No such file or directory
#
# Unquoted expansion word-splits on the space, so `cat` receives TWO arguments
# instead of one. The value itself is fine; the expansion is not. Quote it:
#
#   $ cat "$LAB_TARGET/README"
#   Read this with correct quoting. The flag lives in /opt/lpic-lab/103.1/flag.txt
#
# The three quoting mechanisms, exactly as 103.1 frames them:
#
#   "double quotes"  suppress word splitting and globbing;
#                    $ ` \ and (in interactive shells) ! keep their meaning.
#   'single quotes'  suppress EVERYTHING. No expansion of any kind is possible,
#                    and a single quote cannot appear inside.
#   \backslash       escapes exactly the next character.
#
# Which is why the variable was created with single quotes: the literal '$' in
# '$daily' survives only because nothing inside single quotes is expanded.
#
#   $ echo '$daily'      ->  $daily
#   $ echo "$daily"      ->  (empty: expands an undefined variable)
#   $ echo \$daily       ->  $daily
#
# Now collect the flag:
#
#   $ cat /opt/lpic-lab/103.1/flag.txt
#   LPIC1-103.1-PATH-RESTORED
#
# ------------------------------------------------------------------------------
# STEP 7 — Make the repair permanent
# ------------------------------------------------------------------------------
#
# Everything above lives only in the current shell. The sabotage is in
# ~/.bashrc, so it comes back on the next login. Edit the file and delete the
# whole block between the two "LPIC-1 103.1 LAB" comment markers:
#
#   $ vi ~/.bashrc          # or: nano ~/.bashrc
#
# Then reload it in the current shell without logging out:
#
#   $ source ~/.bashrc      # or the POSIX equivalent:  . ~/.bashrc
#
# Verify from a genuinely fresh login shell — this is the only honest test,
# because it re-reads the startup files from disk:
#
#   $ exit
#   $ su - lpicstudent
#   $ echo "$PATH"; type -a ls; type -a which; echo "$HISTFILE $HISTSIZE"
#
# Which startup file does what (103.1 / 105.1 boundary, but always examined):
#
#   Login shell         : /etc/profile -> ~/.bash_profile OR ~/.bash_login OR
#                         ~/.profile  (the FIRST one that exists, only that one)
#   Interactive non-login: /etc/bash.bashrc -> ~/.bashrc
#   Most distributions have ~/.bash_profile source ~/.bashrc, which is why an
#   error in ~/.bashrc breaks login shells too.
#
# ------------------------------------------------------------------------------
# STEP 8 — Confirm and reflect
# ------------------------------------------------------------------------------
#
#   $ exit
#   $ sudo /path/to/103.1-break-and-fix.sh verify
#   [  ok  ] O1a  PATH includes /usr/bin
#   [  ok  ] O1b  'uname -s' resolves by bare name -> Linux
#   [  ok  ] O2   'type -t ls' reports 'file' (real binary, alias gone)
#   [  ok  ] O3   'which' is no longer a shell function
#   [  ok  ] O4a  HISTFILE points at the real history file
#   [  ok  ] O4b  HISTSIZE allows history to be kept
#   [  ok  ] O5a  "$LAB_TARGET/README" is readable with correct quoting
#   [  ok  ] O5b  flag readable: LPIC1-103.1-PATH-RESTORED
#
# ------------------------------------------------------------------------------
# COMMAND SUMMARY — the 103.1 toolkit used here
# ------------------------------------------------------------------------------
#
#   bash            the shell itself; `bash --version`, `man bash`
#   echo            built-in; `echo "$VAR"` — always quote
#   env             run a command in a modified environment; `env` alone prints
#                   the exported environment; `env -i cmd` starts it empty
#   export          mark a shell variable for export to child processes
#   pwd             print working directory (built-in; `pwd -P` resolves symlinks)
#   set             set shell options / list all shell variables and functions
#   unset           remove a variable (-v) or a function (-f)
#   type -a         THE diagnostic: what will this name actually run, in order
#   which           external; finds a binary in PATH, blind to shell constructs
#   man             manual pages; `man 1 bash`, `man -k keyword`, `man 5 passwd`
#   uname           system information; `uname -a`, `-r` kernel, `-m` arch
#   history         command history; -a append, -w write, -r read, -c clear
#   .bash_history   where it is stored, controlled by HISTFILE/HISTSIZE
#   hash / hash -r  the cached command-location table, and how to flush it
#   command         run bypassing aliases and functions
#   alias / unalias define and remove aliases
#
# ------------------------------------------------------------------------------
# OFFICIAL SOURCES
# ------------------------------------------------------------------------------
#
#   LPI Exam 101-500 Objectives (Topic 103.1, weight 2 — Topic 103 total 26)
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#
#   GNU Bash Reference Manual — Shell Expansions, Quoting, Bash History
#     https://www.gnu.org/software/bash/manual/bash.html
#     https://www.gnu.org/software/bash/manual/bash.html#Quoting
#     https://www.gnu.org/software/bash/manual/bash.html#Bash-History-Facilities
#
#   POSIX.1-2024 Shell Command Language (Base Specifications, Vol. 3)
#     https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html
#
#   man-pages: bash(1), env(1), which(1), uname(1), history in bash(1)
#     https://man7.org/linux/man-pages/man1/bash.1.html
#     https://man7.org/linux/man-pages/man1/env.1.html
#     https://man7.org/linux/man-pages/man1/uname.1.html
#
# SOLUTION-END