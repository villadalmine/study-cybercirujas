#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1  (Exam 101-500 / 102-500, version 5.0)
#  Topic 103.8 - Basic file editing            Exam weight: 4.69
#
#  BREAK & FIX LABORATORY
#
#  What this script does:
#    It deliberately sabotages the vi/vim environment of a DISPOSABLE lab VM
#    and leaves a broken configuration file that can only be repaired with an
#    editor. The student must diagnose the editor itself before being able to
#    edit anything at all - which is the real production skill behind this
#    objective: "vi is the only editor guaranteed to exist on every UNIX box,
#    and it will behave exactly as its configuration tells it to".
#
#  Faults injected (4 environment faults + 6 content defects):
#    F1  poisoned global vimrc                 -> every buffer opens read-only
#    F2  directory-local .exrc ('exrc' option) -> E21 only inside the lab dir
#    F3  stale vim swap file with unsaved work -> E325 ATTENTION on every open
#    F4  broken $EDITOR / $VISUAL              -> crontab -e / visudo unusable
#    C1..C6 syntax defects inside mailer.conf  -> require dd, cw, o, x, :%s
#
#  Skills exercised (LPI 101 objective 103.8 key knowledge areas):
#    vi navigation, insert/normal/ex modes, c/d/p/y/dd/yy, ZZ, :w! :q! :wq,
#    /?  n N search, :%s substitution, vim -u NONE, :recover, EDITOR/VISUAL.
#
#  SAFETY CONTRACT
#    * Runs ONLY when the operator confirms the machine is disposable
#      (interactive prompt, or LPIC_LAB_CONFIRM=yes for unattended runs).
#    * Touches nothing outside: /opt/lab/103.8-basic-file-editing,
#      the global vimrc, ~/.vimrc of the lab user, /etc/profile.d, and
#      /usr/local/bin/lab-*.
#    * Every pre-existing file is backed up under /var/lib/lpic-lab/103.8
#      and listed in a manifest; "--restore" puts the machine back exactly
#      as it was (including deleting files that did not exist before).
#    * NO service is stopped, NO package is removed, NO real /etc/fstab,
#      /etc/passwd or bootloader file is ever modified.
#
#  Usage:
#    sudo ./103.8-break-and-fix.sh --break     # inject the faults + briefing
#    sudo ./103.8-break-and-fix.sh --check     # grade the repair
#    sudo ./103.8-break-and-fix.sh --brief     # re-print the mission briefing
#    sudo ./103.8-break-and-fix.sh --restore   # undo everything
#
#  Official reference:
#    LPI Exam 101 objectives - https://www.lpi.org/our-certifications/exam-101-objectives/
#    (103.8 Basic file editing: vi, vim, EDITOR/VISUAL, modes, ZZ, :w! :q! :wq)
#
#  The complete step-by-step solution is at the END of this file, commented out.
# =============================================================================

set -Eeuo pipefail

# ------------------------------- constants ----------------------------------
readonly LAB_ID="103.8"
readonly LAB_ROOT="/opt/lab/103.8-basic-file-editing"
readonly SVC_DIR="${LAB_ROOT}/svc"
readonly CONF="${SVC_DIR}/mailer.conf"
readonly VALIDATOR="/usr/local/bin/lab-validate-mailer"
readonly EDITOR_PROFILE="/etc/profile.d/99-lab-editor.sh"
readonly FAKE_EDITOR="/usr/local/bin/vi-lab"
readonly STATE_DIR="/var/lib/lpic-lab/${LAB_ID}"
readonly BACKUP_DIR="${STATE_DIR}/backup"
readonly MANIFEST="${STATE_DIR}/manifest.tsv"
readonly MARK_BEGIN='" >>>>> LPIC-103.8 LAB BREAK - BEGIN'
readonly MARK_END='" <<<<< LPIC-103.8 LAB BREAK - END'
readonly CRON_TAG="lpic-103.8"

# ------------------------------- presentation -------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3)
    C_BLU=$(tput setaf 4); C_BLD=$(tput bold);    C_RST=$(tput sgr0)
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

info()  { printf '%s[ .. ]%s %s\n' "${C_BLU}" "${C_RST}" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "${C_GRN}" "${C_RST}" "$*"; }
warn()  { printf '%s[ !! ]%s %s\n' "${C_YEL}" "${C_RST}" "$*"; }
die()   { printf '%s[FAIL]%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }
rule()  { printf '%s\n' "-----------------------------------------------------------------------------"; }

trap 'printf "%s[TRAP]%s aborted at line %s\n" "${C_RED}" "${C_RST}" "${LINENO}" >&2' ERR

# ------------------------------- helpers ------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "This laboratory rewrites /etc and must run as root (use sudo)."
}

detect_lab_user() {
    local u="${LPIC_LAB_USER:-${SUDO_USER:-}}"
    if [ -z "${u}" ]; then u="$(logname 2>/dev/null || true)"; fi
    if [ -z "${u}" ] || [ "${u}" = "root" ]; then
        u="$(awk -F: '$3>=1000 && $3<65000 {print $1; exit}' /etc/passwd || true)"
    fi
    [ -n "${u}" ] || die "Could not determine the unprivileged lab user. Set LPIC_LAB_USER=<name>."
    id "${u}" >/dev/null 2>&1 || die "Lab user '${u}' does not exist."
    printf '%s' "${u}"
}

lab_home() { getent passwd "$1" | cut -d: -f6; }

# Run a command as the lab user through a LOGIN shell (so /etc/profile.d is read).
lab_login_eval() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -l "${LAB_USER}" -c "$1"
    else
        su - "${LAB_USER}" -c "$1"
    fi
}

# Run a command as the lab user WITHOUT a login shell.
lab_run() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "${LAB_USER}" -- /bin/sh -c "$1"
    else
        su "${LAB_USER}" -s /bin/sh -c "$1"
    fi
}

confirm_disposable_vm() {
    rule
    printf '%sTHIS SCRIPT DAMAGES THE EDITOR CONFIGURATION OF THIS MACHINE ON PURPOSE.%s\n' "${C_BLD}${C_YEL}" "${C_RST}"
    printf 'Host: %s   Kernel: %s   Lab user: %s\n' "$(hostname)" "$(uname -r)" "${LAB_USER}"
    printf 'Run it ONLY on a throw-away lab VM / container / snapshot you can discard.\n'
    rule
    if [ "${LPIC_LAB_CONFIRM:-no}" = "yes" ]; then
        warn "LPIC_LAB_CONFIRM=yes - proceeding unattended."
        return 0
    fi
    [ -t 0 ] || die "No TTY and LPIC_LAB_CONFIRM is not set to 'yes'. Refusing to break a machine blindly."
    local answer=""
    printf 'Type exactly BREAK-MY-LAB to continue: '
    read -r answer
    [ "${answer}" = "BREAK-MY-LAB" ] || die "Confirmation not given. Nothing was modified."
}

# --- backup / restore bookkeeping -------------------------------------------
init_state() {
    install -d -m 0755 "${STATE_DIR}" "${BACKUP_DIR}"
    [ -f "${MANIFEST}" ] || : > "${MANIFEST}"
}

# stash <path>  -> remembers the ORIGINAL state of <path> exactly once
stash() {
    local path="$1" key
    key="$(printf '%s' "${path}" | sed 's|/|_|g')"
    grep -qF -- "	${path}	" "${MANIFEST}" 2>/dev/null && return 0
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        cp -a -- "${path}" "${BACKUP_DIR}/${key}"
        printf 'existed\t%s\t%s\n' "${path}" "${key}" >> "${MANIFEST}"
    else
        printf 'absent\t%s\t%s\n' "${path}" "${key}" >> "${MANIFEST}"
    fi
}

restore_all() {
    [ -f "${MANIFEST}" ] || { warn "No manifest found - nothing to restore."; return 0; }
    local state path key
    # Restore in reverse order of injection.
    tac "${MANIFEST}" | while IFS=$'\t' read -r state path key; do
        [ -n "${path:-}" ] || continue
        case "${state}" in
            existed)
                rm -rf -- "${path}"
                cp -a -- "${BACKUP_DIR}/${key}" "${path}"
                info "restored  ${path}"
                ;;
            absent)
                rm -rf -- "${path}"
                info "removed   ${path}"
                ;;
        esac
    done
    rm -rf -- "${LAB_ROOT}" "${STATE_DIR}"
    ok "Machine returned to its pre-laboratory state."
    warn "The crontab entry tagged '${CRON_TAG}' (if you created one) is NOT removed automatically:"
    printf '        crontab -u %s -e     # delete the line tagged %s\n' "${LAB_USER}" "${CRON_TAG}"
}

# =============================================================================
#  BREAK PHASE
# =============================================================================

create_lab_tree() {
    stash "${LAB_ROOT}"
    install -d -m 0755 "${LAB_ROOT}" "${SVC_DIR}"

    # ---- the file the student must repair (6 deliberate defects) ------------
    cat > "${CONF}" <<'CONF_EOF'
# lab-mailer(8) configuration - schema v2
#
# TODO(ops): schema v2 made the SMTP banner mandatory. Add the line
#            smtp_banner = lab-mailer ESMTP ready
#            immediately below the hostname key. Then fix the merge that
#            was committed half-resolved and the two keys with no value.
#
listen_address = 0.0.0.0
listen_port = 25
listen_port = 2525
<<<<<<< HEAD
hostname = mail.lab.example.net
=======
hostname = mail.old.example.net
>>>>>>> feature/rename-mail-host
queue_dir = /var/spool/lab-mailer
max_message_size@TAB@= 10M
relay_host
tls_cert = /etc/ssl/certs/lab-mailer.pem
tls_key
log_level = debgu
workers = twelve
CONF_EOF
    # A literal TAB - invisible in cat(1), obvious in vi with ':set list'.
    sed -i "s/@TAB@/$(printf '\t')/" "${CONF}"
    chown "${LAB_USER}:$(id -gn "${LAB_USER}")" "${CONF}"
    ok "Lab tree created at ${LAB_ROOT}"
}

install_validator() {
    stash "${VALIDATOR}"
    cat > "${VALIDATOR}" <<'VAL_EOF'
#!/usr/bin/env bash
# lab-validate-mailer - schema v2 checker for the LPIC-1 103.8 laboratory.
# Exits 0 when every rule passes. This file is NOT part of the breakage:
# read it if you want to know exactly what "repaired" means.
set -uo pipefail
CONF="${1:-/opt/lab/103.8-basic-file-editing/svc/mailer.conf}"
PASS=0; FAIL=0
p() { printf '  [ OK ] %s\n' "$1"; PASS=$((PASS+1)); }
f() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
t() { if [ "$1" -eq 0 ]; then p "$2"; else f "$2"; fi; }

[ -r "${CONF}" ] || { printf '  [FAIL] %s is not readable\n' "${CONF}"; exit 2; }
printf 'Validating %s\n' "${CONF}"

! grep -Eq '^(<{7}|={7}|>{7})' "${CONF}"; t $? "C1 no unresolved merge-conflict markers"

[ "$(grep -Ec '^[[:space:]]*hostname[[:space:]]*=' "${CONF}")" = "1" ] \
  && grep -Eq '^hostname[[:space:]]*=[[:space:]]*mail\.lab\.example\.net[[:space:]]*$' "${CONF}"
t $? "C2 exactly one hostname key, set to mail.lab.example.net"

[ "$(grep -Ec '^[[:space:]]*listen_port[[:space:]]*=' "${CONF}")" = "1" ] \
  && grep -Eq '^listen_port[[:space:]]*=[[:space:]]*25[[:space:]]*$' "${CONF}"
t $? "C3 exactly one listen_port key, set to 25"

grep -Eq '^relay_host[[:space:]]*=[[:space:]]*smtp-out\.lab\.example\.net[[:space:]]*$' "${CONF}"
t $? "C4 relay_host = smtp-out.lab.example.net"

grep -Eq '^tls_key[[:space:]]*=[[:space:]]*/etc/ssl/private/lab-mailer\.key[[:space:]]*$' "${CONF}"
t $? "C5 tls_key = /etc/ssl/private/lab-mailer.key"

grep -Eq '^log_level[[:space:]]*=[[:space:]]*debug[[:space:]]*$' "${CONF}"
t $? "C6 log_level = debug (typo 'debgu' corrected)"

grep -Eq '^workers[[:space:]]*=[[:space:]]*12[[:space:]]*$' "${CONF}"
t $? "C7 workers = 12 (numeric)"

grep -Eq '^smtp_banner[[:space:]]*=[[:space:]]*lab-mailer ESMTP ready[[:space:]]*$' "${CONF}"
t $? "C8 smtp_banner key added"

! grep -qP '\t' "${CONF}" 2>/dev/null || ! grep -q "$(printf '\t')" "${CONF}"
t $? "C9 no literal TAB characters left in the file"

! grep -q '^# EDIT IN PROGRESS' "${CONF}"
t $? "C10 no leftover text recovered from the stale swap file"

# every effective line must be key = value
BAD="$(grep -vE '^[[:space:]]*(#|$)' "${CONF}" | grep -vcE '^[a-z_]+[[:space:]]*=[[:space:]]*.+$' || true)"
[ "${BAD}" = "0" ]; t $? "C11 every non-comment line matches 'key = value'"

printf 'Result: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
printf 'mailer.conf: schema v2 OK\n'
VAL_EOF
    chmod 0755 "${VALIDATOR}"
    ok "Validator installed: ${VALIDATOR}"
}

# --- F3: leave a genuine stale swap file with UNSAVED changes ----------------
# Must run BEFORE the vimrc is poisoned and before the file becomes read-only.
inject_stale_swapfile() {
    local swp="${SVC_DIR}/.mailer.conf.swp"
    stash "${swp}"
    if command -v script >/dev/null 2>&1 && command -v vim >/dev/null 2>&1; then
        lab_run "cd '${SVC_DIR}' && script -q -c \"vim -u NONE -N -i NONE --cmd 'set directory=. nobackup' -c 'normal! ggO# EDIT IN PROGRESS - DO NOT COMMIT' -c 'preserve' -c 'sleep 30' mailer.conf\" /dev/null" >/dev/null 2>&1 &
        local pid=$!
        sleep 3
        pkill -9 -u "$(id -u "${LAB_USER}")" -f "vim -u NONE -N -i NONE" >/dev/null 2>&1 || true
        kill -9 "${pid}" >/dev/null 2>&1 || true
        wait "${pid}" 2>/dev/null || true
    fi
    if [ ! -f "${swp}" ]; then
        # Fallback for hosts without script(1): a swap file that vim will
        # detect (E325) but will not be able to recover from.
        printf 'b0VIM 8.2\0\0\0\0' > "${swp}"
        dd if=/dev/zero bs=1024 count=4 >> "${swp}" 2>/dev/null
        chown "${LAB_USER}:$(id -gn "${LAB_USER}")" "${swp}"
        warn "script(1) unavailable - a synthetic (non-recoverable) swap file was planted."
    else
        ok "Stale swap file planted: ${swp}"
    fi
    # F0: read-only permission bits on a file the student still owns.
    chmod 0444 "${CONF}"
}

# --- F1: poison the GLOBAL vimrc --------------------------------------------
pick_global_vimrc() {
    for f in /etc/vim/vimrc /etc/vimrc /etc/vim/vimrc.local; do
        [ -f "${f}" ] && { printf '%s' "${f}"; return 0; }
    done
    install -d -m 0755 /etc/vim
    printf '%s' /etc/vim/vimrc
}

poison_global_vimrc() {
    local vimrc; vimrc="$(pick_global_vimrc)"
    stash "${vimrc}"
    cat >> "${vimrc}" <<EOF

${MARK_BEGIN}
" Injected by the LPIC-1 103.8 break & fix laboratory.
set readonly            " every buffer opens read-only  -> E45 on :w
set backspace=          " BS cannot erase past the insert point
set noshowmode          " the '-- INSERT --' indicator is hidden
set exrc                " read ./.vimrc and ./.exrc from the current directory
set secure              " ...in restricted mode
inoremap <Esc> <Nop>    " ESC no longer leaves insert mode
${MARK_END}
EOF
    ok "Global vimrc poisoned: ${vimrc}"
}

poison_user_vimrc() {
    local home; home="$(lab_home "${LAB_USER}")"
    local uvimrc="${home}/.vimrc"
    stash "${uvimrc}"
    cat >> "${uvimrc}" <<EOF
${MARK_BEGIN}
set readonly
set nomodifiable
${MARK_END}
EOF
    chown "${LAB_USER}:$(id -gn "${LAB_USER}")" "${uvimrc}"
    ok "User vimrc poisoned: ${uvimrc}"
}

# --- F2: directory-local .exrc, active only inside the lab directory --------
plant_local_exrc() {
    local exrc="${SVC_DIR}/.exrc"
    stash "${exrc}"
    cat > "${exrc}" <<'EOF'
" Directory-local vi configuration - honoured because 'exrc' is enabled.
set nomodifiable
set noundofile
EOF
    chmod 0644 "${exrc}"
    chown root:root "${exrc}"
    ok "Directory-local .exrc planted in ${SVC_DIR}"
}

# --- F4: break EDITOR / VISUAL ----------------------------------------------
break_editor_variables() {
    stash "${FAKE_EDITOR}"
    cat > "${FAKE_EDITOR}" <<'EOF'
#!/bin/sh
# Site-wide editor wrapper (lab). Perfectly functional... if it were executable.
exec /usr/bin/vi "$@"
EOF
    chmod 0644 "${FAKE_EDITOR}"        # <-- NOT executable: this is the fault
    chown root:root "${FAKE_EDITOR}"

    stash "${EDITOR_PROFILE}"
    cat > "${EDITOR_PROFILE}" <<EOF
# Site policy: force everybody through the wrapper editor.
export EDITOR=${FAKE_EDITOR}
export VISUAL="\${EDITOR}"
EOF
    chmod 0644 "${EDITOR_PROFILE}"
    ok "EDITOR/VISUAL sabotaged through ${EDITOR_PROFILE}"
}

do_break() {
    require_root
    command -v vi >/dev/null 2>&1 || warn "vi not found - install vim/vim-tiny (or busybox vi) before starting."
    confirm_disposable_vm
    init_state
    create_lab_tree
    install_validator
    inject_stale_swapfile      # order matters: swap first, poison afterwards
    poison_global_vimrc
    poison_user_vimrc
    plant_local_exrc
    break_editor_variables
    printf '\n'
    ok "All faults injected."
    print_brief
}

# =============================================================================
#  MISSION BRIEFING
# =============================================================================
print_brief() {
cat <<BRIEF

$(rule)
${C_BLD}LPIC-1 103.8 - BASIC FILE EDITING - BREAK & FIX${C_RST}
$(rule)

${C_BLD}SCENARIO${C_RST}
  You are on call. The lab-mailer service refuses to start after a colleague
  pushed a half-resolved merge into its configuration and then "hardened" the
  editor for everybody. The configuration file is:

      ${CONF}

  A schema checker is already installed and is NOT broken:

      ${VALIDATOR}          # run it as often as you like

${C_BLD}SYMPTOMS YOU WILL SEE${C_RST}
  1. Opening the file greets you with:
         E325: ATTENTION
         Found a swap file by the name ".mailer.conf.swp"
     ...and vi asks you to choose between Open Read-Only, Edit anyway,
     Recover, Delete it, Quit, Abort.
  2. Once inside, typing text produces nothing useful and you get:
         E21: Cannot make changes, 'modifiable' is off
     Note that the SAME vi works normally in your home directory. Only this
     directory is affected. Ask yourself why - and what vi reads at startup.
  3. If you get past that, saving fails with:
         E45: 'readonly' option is set (add ! to override)
     and ls shows the file as -r--r--r--, although you own it.
  4. ESC does not take you out of insert mode, and '-- INSERT --' is not
     displayed at the bottom, so you cannot even tell which mode you are in.
     Backspace refuses to delete existing characters.
  5. In a NEW login shell:
         \$ crontab -e
         /usr/local/bin/vi-lab: Permission denied
         crontab: "/usr/local/bin/vi-lab" exited with status 126
     No editor-driven tool (crontab -e, visudo, vipw, git commit) works.

${C_BLD}YOUR MISSION${C_RST}
  A. Restore a sane, predictable vi environment for user '${LAB_USER}':
     no forced read-only, no forced 'nomodifiable', ESC works again,
     no stale swap file left behind in ${SVC_DIR}.
  B. Using vi ONLY (no sed, no awk, no echo >>, no cp of a fixed copy),
     repair ${CONF} until the validator passes:
        - remove the merge-conflict markers, keep hostname mail.lab.example.net
        - keep a single listen_port, value 25
        - relay_host = smtp-out.lab.example.net
        - tls_key    = /etc/ssl/private/lab-mailer.key
        - log_level  = debug          (currently 'debgu')
        - workers    = 12             (currently 'twelve')
        - add        smtp_banner = lab-mailer ESMTP ready   below hostname
        - remove the literal TAB character (hint: :set list)
        - remove any line recovered from the swap file (# EDIT IN PROGRESS)
  C. Make \$EDITOR usable again and prove it by running 'crontab -e' as
     ${LAB_USER} and adding exactly this line:
        @daily ${VALIDATOR} >/dev/null 2>&1  # ${CRON_TAG}

${C_BLD}RULES OF ENGAGEMENT${C_RST}
  * You may consult 'man vi', 'vimtutor', ':help', and the LPI objectives:
    https://www.lpi.org/our-certifications/exam-101-objectives/
  * You may NOT edit the file with anything other than vi/vim.
  * You may NOT reinstall vim, and you may NOT delete the whole lab tree.
  * Time target: 25 minutes.

${C_BLD}GRADE YOURSELF${C_RST}
      sudo $0 --check
${C_BLD}GIVE UP / CLEAN UP${C_RST}
      sudo $0 --restore
$(rule)

BRIEF
}

# =============================================================================
#  CHECK PHASE
# =============================================================================
CHK_PASS=0
CHK_FAIL=0
chk() {  # chk <exit-status> <description> [hint]
    if [ "$1" -eq 0 ]; then
        printf '  %s[ OK ]%s %s\n' "${C_GRN}" "${C_RST}" "$2"; CHK_PASS=$((CHK_PASS+1))
    else
        printf '  %s[FAIL]%s %s\n' "${C_RED}" "${C_RST}" "$2"; CHK_FAIL=$((CHK_FAIL+1))
        [ -n "${3:-}" ] && printf '         hint: %s\n' "$3"
    fi
}

do_check() {
    require_root
    [ -f "${MANIFEST}" ] || die "This lab was never started here. Run '--break' first."
    printf '\n%sPART A - editor environment%s\n' "${C_BLD}" "${C_RST}"

    local vimrc; vimrc="$(pick_global_vimrc)"
    ! grep -qF "LPIC-103.8 LAB BREAK" "${vimrc}" 2>/dev/null
    chk $? "global vimrc (${vimrc}) no longer forces readonly/exrc/ESC remap" \
           "remove the marked block from ${vimrc}"

    local uvimrc="$(lab_home "${LAB_USER}")/.vimrc"
    if [ -f "${uvimrc}" ]; then
        ! grep -Eq '^[[:space:]]*set[[:space:]]+(readonly|ro|nomodifiable|noma)\b' "${uvimrc}"
    else
        true
    fi
    chk $? "~${LAB_USER}/.vimrc no longer forces readonly/nomodifiable" \
           "edit ${uvimrc} (with vim -u NONE if needed)"

    if [ -f "${SVC_DIR}/.exrc" ]; then
        ! grep -Eq 'nomodifiable|noma' "${SVC_DIR}/.exrc"
    else
        true
    fi
    chk $? "directory-local .exrc no longer disables modification" \
           "either delete ${SVC_DIR}/.exrc or turn 'exrc' off"

    [ -z "$(find "${SVC_DIR}" -maxdepth 1 -name '.*.sw[a-p]' -print -quit 2>/dev/null)" ]
    chk $? "no stale swap file left in ${SVC_DIR}" \
           "open the file, choose (R)ecover or (D)elete, then remove the .swp"

    [ ! -e "${CONF}" ] || [ -w "${CONF}" ]
    chk $? "${CONF} is writable by its owner" "chmod u+w ${CONF}"

    printf '\n%sPART B - configuration repair%s\n' "${C_BLD}" "${C_RST}"
    if [ -x "${VALIDATOR}" ]; then
        if "${VALIDATOR}" "${CONF}" | sed 's/^/  /'; then
            CHK_PASS=$((CHK_PASS+1))
            printf '  %s[ OK ]%s mailer.conf passes schema v2\n' "${C_GRN}" "${C_RST}"
        else
            CHK_FAIL=$((CHK_FAIL+1))
            printf '  %s[FAIL]%s mailer.conf still violates schema v2\n' "${C_RED}" "${C_RST}"
        fi
    else
        chk 1 "validator missing (${VALIDATOR})" "re-run --break"
    fi

    printf '\n%sPART C - EDITOR / VISUAL%s\n' "${C_BLD}" "${C_RST}"
    lab_login_eval 'ed="${VISUAL:-${EDITOR:-vi}}"; p="$(command -v "$ed" 2>/dev/null)"; test -n "$p" -a -x "$p"' >/dev/null 2>&1
    chk $? "\$VISUAL/\$EDITOR of ${LAB_USER} resolves to an executable editor" \
           "chmod +x ${FAKE_EDITOR}, or drop ${EDITOR_PROFILE} and export EDITOR=vi"

    if command -v crontab >/dev/null 2>&1; then
        crontab -u "${LAB_USER}" -l 2>/dev/null | grep -q "${CRON_TAG}"
        chk $? "crontab of ${LAB_USER} contains the line tagged '${CRON_TAG}'" \
               "fix \$EDITOR first, then: crontab -e"
    else
        warn "crontab(1) is not installed on this host - part C.2 skipped."
    fi

    rule
    if [ "${CHK_FAIL}" -eq 0 ]; then
        printf '%sLAB PASSED%s  (%d checks)\n' "${C_BLD}${C_GRN}" "${C_RST}" "${CHK_PASS}"
        printf 'Clean up with: sudo %s --restore\n' "$0"
        rule; return 0
    fi
    printf '%sLAB INCOMPLETE%s  %d passed / %d failed\n' "${C_BLD}${C_YEL}" "${C_RST}" "${CHK_PASS}" "${CHK_FAIL}"
    rule; return 1
}

# =============================================================================
#  ENTRY POINT
# =============================================================================
usage() {
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    LAB_USER="$(detect_lab_user)"; readonly LAB_USER
    case "${1:---help}" in
        --break|-b)     do_break ;;
        --check|-c)     do_check ;;
        --brief|-p)     print_brief ;;
        --restore|-r)   require_root; restore_all ;;
        --help|-h)      usage ;;
        *)              die "Unknown option '$1'. Try --help." ;;
    esac
}

main "$@"

# =============================================================================
#                        S O L U T I O N   (instructor)
# =============================================================================
# Everything below is commented out on purpose. Do not read it until you have
# spent your 25 minutes on the lab.
#
# -----------------------------------------------------------------------------
# STEP 0 - DIAGNOSE BEFORE TOUCHING ANYTHING
# -----------------------------------------------------------------------------
#   The single most valuable habit of this objective: when vi misbehaves, prove
#   whether the problem is the FILE, the CONFIGURATION, or the ENVIRONMENT.
#
#   $ cd /opt/lab/103.8-basic-file-editing/svc
#   $ ls -la                      # -r--r--r-- mailer.conf, .exrc, .mailer.conf.swp
#   $ vim -u NONE -N mailer.conf  # -u NONE = ignore EVERY vimrc; -N = nocompatible
#
#   If vi behaves correctly with '-u NONE', the fault is in a configuration
#   file, not in vi. To list what vim actually sourced:
#
#   :scriptnames                  # every file read, in order
#   :verbose set readonly?        # -> "Last set from /etc/vim/vimrc line NN"
#   :verbose set modifiable?      # -> "Last set from .exrc"
#   :verbose imap <Esc>           # -> shows the offending inoremap
#
#   ':verbose set <option>?' is the answer to "who set this?" and it is worth
#   more in production than memorising options.
#
# -----------------------------------------------------------------------------
# STEP 1 - THE STALE SWAP FILE (E325)
# -----------------------------------------------------------------------------
#   $ vim mailer.conf
#   E325: ATTENTION - Found a swap file by the name ".mailer.conf.swp"
#
#   Read the dialog: it prints the owner, the host, the modification time and
#   whether the swap is NEWER than the file. Decision rule:
#     * process still running (vim tells you)   -> quit, use the other session
#     * swap newer than the file, work worth it -> (R)ecover
#     * junk / crashed session, nothing worth it-> (D)elete it
#
#   Recover, inspect, then discard the swap explicitly:
#     press R                      # Recover
#     :w! recovered.conf           # keep the recovered text somewhere safe
#     :q
#     $ vim -r mailer.conf         # same thing from the shell
#     $ rm -f .mailer.conf.swp     # ALWAYS remove the swap after recovering
#
#   The recovered buffer contains the junk line '# EDIT IN PROGRESS - DO NOT
#   COMMIT'. Delete it with dd (see step 3). If you choose (D)elete instead of
#   (R)ecover, vim removes the swap for you and the junk line never appears.
#
# -----------------------------------------------------------------------------
# STEP 2 - RESTORE A SANE EDITOR
# -----------------------------------------------------------------------------
#   Two legitimate routes. Route A repairs the machine (what the mission asks),
#   route B is the emergency bypass you use when you must edit RIGHT NOW.
#
#   Route A - repair the configuration:
#     $ sudo vim -u NONE -N /etc/vim/vimrc        # or /etc/vimrc on RHEL/SUSE
#       /LPIC-103.8<Enter>                        # jump to the marker
#       :.,/LAB BREAK - END/d                     # delete the whole block
#       :wq
#     $ vim -u NONE -N ~/.vimrc
#       /LPIC-103.8<Enter>
#       :.,/LAB BREAK - END/d
#       :wq
#     $ rm -f /opt/lab/103.8-basic-file-editing/svc/.exrc     # needs sudo (root-owned)
#     $ chmod u+w /opt/lab/103.8-basic-file-editing/svc/mailer.conf
#
#     Why .exrc mattered: 'set exrc' makes vim source ./.vimrc and ./.exrc from
#     the CURRENT directory. That is why vi was broken only inside that one
#     directory. 'set secure' limits what such a file may do (no :autocmd, no
#     shell commands) but 'set nomodifiable' is still honoured. Leaving 'exrc'
#     on in a shared or downloaded directory is a real security problem.
#
#   Route B - bypass, per invocation:
#     $ vim -u NONE -N mailer.conf     # ignore all vimrc files
#     inside vim, if you did not clean the configs:
#       :set modifiable                # or :set ma      -> fixes E21
#       :set noreadonly                # or :set noro    -> fixes E45
#       :set backspace=indent,eol,start
#       :iunmap <Esc>                  # ESC works again
#     and if ESC is still dead, these are the equivalent keys - memorise them:
#       CTRL-[      exactly the same character as ESC
#       CTRL-C      leaves insert mode (skips abbreviations/InsertLeave)
#
# -----------------------------------------------------------------------------
# STEP 3 - REPAIR mailer.conf WITH vi ONLY
# -----------------------------------------------------------------------------
#   $ cd /opt/lab/103.8-basic-file-editing/svc
#   $ vim mailer.conf
#
#   Make the invisible visible first:
#     :set list          " TAB shows as ^I, end of line as $
#     :set number        " line numbers help you talk about the file
#
#   3.1 Delete the junk line recovered from the swap (if present)
#       /EDIT IN PROGRESS<Enter>     " search forward
#       dd                           " delete the whole line
#
#   3.2 Delete the duplicated port
#       /2525<Enter>
#       dd
#
#   3.3 Resolve the merge conflict: keep mail.lab.example.net, drop the rest.
#       /<<<<<<<<Enter>              " cursor on the '<<<<<<< HEAD' line
#       dd                           " remove '<<<<<<< HEAD'
#       j                            " move down to '======='
#       3dd                          " delete '=======', the old hostname and '>>>>>>>'
#       (equivalent: place the cursor on '=======' and use  d/>>>>>>><Enter> )
#       Verify:  :g/^[<=>]\{7\}/p    " should print nothing
#
#   3.4 Add the mandatory banner below the hostname line
#       /^hostname<Enter>
#       o                            " open a NEW line BELOW and enter insert mode
#       smtp_banner = lab-mailer ESMTP ready
#       <Esc>                        " or CTRL-[ if ESC is still remapped
#
#   3.5 Replace the literal TAB with a space
#       /max_message_size<Enter>
#       f<Ctrl-V><Tab>               " f + a literal TAB moves onto the TAB char
#       r<Space>                     " replace ONE character with a space
#       (bulk alternative:  :%s/\t/ /g   - substitute every tab in the file)
#
#   3.6 Give relay_host a value (the line has a key and nothing else)
#       /^relay_host<Enter>
#       A                            " append at END of line, enter insert mode
#        = smtp-out.lab.example.net
#       <Esc>
#
#   3.7 Same for tls_key
#       /^tls_key<Enter>
#       A
#        = /etc/ssl/private/lab-mailer.key
#       <Esc>
#
#   3.8 Fix the typo 'debgu'
#       /debgu<Enter>
#       cw                           " change word: deletes it and inserts
#       debug
#       <Esc>
#       (ex alternative:  :%s/debgu/debug/g )
#
#   3.9 'twelve' is not a number
#       /twelve<Enter>
#       cw
#       12
#       <Esc>
#
#   3.10 Save. The file is mode 0444, so a plain :w fails:
#        :w        -> E45: 'readonly' option is set (add ! to override)
#                     or "E505: ... is read-only (add ! to override)"
#        :w!       -> writes anyway, because YOU own the inode and may chmod it
#        Cleanest:  :q!  then  chmod u+w mailer.conf  and edit again.
#        And the classic when you are NOT the owner and forgot sudo:
#        :w !sudo tee % > /dev/null      " pipe the buffer to sudo tee, then :e!
#
#        Exit shortcuts worth knowing for the exam:
#          :wq   / :x  / ZZ    write (only if modified, for :x and ZZ) and quit
#          :q!         / ZQ    quit discarding every change
#          :w file             write the buffer to another file
#
#   3.11 Verify:
#        $ /usr/local/bin/lab-validate-mailer
#
# -----------------------------------------------------------------------------
# STEP 4 - EDITOR / VISUAL
# -----------------------------------------------------------------------------
#   Diagnosis:
#     $ echo "$EDITOR $VISUAL"       -> /usr/local/bin/vi-lab
#     $ ls -l /usr/local/bin/vi-lab  -> -rw-r--r-- : NOT executable (exit 126)
#     $ grep -rn EDITOR /etc/profile.d/
#
#   VISUAL wins over EDITOR in most tools (crontab, git, less), so check both.
#
#   Fix, either one:
#     $ sudo chmod 0755 /usr/local/bin/vi-lab           # make the wrapper work
#     $ sudo rm -f /etc/profile.d/99-lab-editor.sh      # or drop the policy
#     $ export EDITOR=vi VISUAL=vi                      # per-session override
#   Log out and back in (or 'source /etc/profile') so the new value is exported.
#
#   Then create the required entry:
#     $ crontab -e
#       @daily /usr/local/bin/lab-validate-mailer >/dev/null 2>&1  # lpic-103.8
#       ZZ
#     $ crontab -l
#   One-shot override without touching the environment permanently:
#     $ EDITOR=vi crontab -e
#     $ sudo EDITOR=vi visudo        # visudo ALWAYS validates syntax on save
#
# -----------------------------------------------------------------------------
# STEP 5 - GRADE AND CLEAN UP
# -----------------------------------------------------------------------------
#   $ sudo /path/to/103.8-break-and-fix.sh --check
#   $ sudo /path/to/103.8-break-and-fix.sh --restore
#
# -----------------------------------------------------------------------------
# TAKEAWAYS
# -----------------------------------------------------------------------------
#   * 'vim -u NONE -N <file>' is the seatbelt: it separates "vi is broken" from
#     "vi is configured to do this".
#   * ':verbose set <opt>?' names the file and line that set an option.
#   * E21 = 'modifiable' is off; E45/E505 = 'readonly'/permissions. Different
#     causes, different fixes - do not answer both with :w! blindly.
#   * A .swp file is unsaved work, not garbage: recover, inspect, then delete.
#   * 'set exrc' turns any directory you cd into a configuration source.
#   * VISUAL and EDITOR drive crontab -e, visudo, vipw, git commit, less -v.
#     An unusable editor variable breaks administration, not just editing.
#
# Reference: LPI Exam 101 objectives, 103.8 Basic file editing
#            https://www.lpi.org/our-certifications/exam-101-objectives/
# =============================================================================