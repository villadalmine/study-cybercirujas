#!/usr/bin/env bash
#
# =============================================================================
#  teach-plat :: BREAK & FIX LAB
#  Certification : LPIC-1 (exams 101-500 / 102-500, version 5.0)
#  Topic         : 106.1 - Install and configure X11
#  Lab id        : lpic1-106.1
#
#  WHAT THIS SCRIPT DOES
#    It arms four layered, reversible faults in the X11 stack of a DISPOSABLE
#    lab VM and prints a mission brief. The faults are ordered so that fixing
#    one exposes the next, which is exactly how a real "the desktop is gone"
#    ticket unfolds: boot target -> X server config -> input config -> client
#    side environment and X authorisation.
#
#  WHAT IT DOES NOT DO
#    It does not touch the network, sshd, the bootloader, partitions, the
#    package database or any user data. Every file it modifies is backed up
#    first under /var/lib/teach-plat/labs/lpic1-106.1/backup and can be put
#    back with `--restore`. SSH access is preserved on purpose: you must be
#    able to recover the box even with no graphical stack at all.
#
#  RUN IT ONLY ON A THROWAWAY VM WITH A SNAPSHOT TAKEN BEFOREHAND.
#
#  Official reference material
#    - LPI exam 101-500 objectives ......... https://www.lpi.org/our-certifications/exam-101-objectives/
#    - LPI exam 102-500 objectives ......... https://www.lpi.org/our-certifications/exam-102-objectives/
#    - xorg.conf(5) ........................ https://www.x.org/releases/current/doc/man/man5/xorg.conf.5.xhtml
#    - Xorg(1) ............................. https://www.x.org/releases/current/doc/man/man1/Xorg.1.xhtml
#    - Xserver(1), xauth(1), xhost(1) ...... https://www.x.org/releases/current/doc/man/man1/
#    - X security / authorisation .......... https://www.x.org/releases/current/doc/man/man7/Xsecurity.7.xhtml
#    - localectl(1) / systemd-localed ...... https://www.freedesktop.org/software/systemd/man/latest/localectl.html
#    - systemd.special(7) (boot targets) ... https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html
#    - GDM configuration ................... https://help.gnome.org/admin/gdm/stable/configuration.html.en
#    - Wayland vs X11 ...................... https://wayland.freedesktop.org/faq.html
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail

# ------------------------------------------------------------------ constants
readonly LAB_ID="lpic1-106.1"
readonly LAB_TITLE="LPIC-1 106.1 - Install and configure X11"
readonly STATE_DIR="/var/lib/teach-plat/labs/${LAB_ID}"
readonly BACKUP_DIR="${STATE_DIR}/backup"
readonly MANIFEST="${STATE_DIR}/manifest.tsv"
readonly MISSION_FILE="${STATE_DIR}/MISSION.txt"

readonly XORG_CONF="/etc/X11/xorg.conf"
readonly XORG_CONF_D="/etc/X11/xorg.conf.d"
readonly KBD_SNIPPET="${XORG_CONF_D}/00-keyboard.conf"
readonly BOGUS_DRIVER="labvideo"
readonly BOGUS_LAYOUT="dvorak"
readonly BOGUS_DISPLAY=":99"
readonly BOGUS_XAUTH="/tmp/.lab-106.1-authority"
readonly RC_MARKER_OPEN="# >>> teach-plat lab ${LAB_ID} >>>"
readonly RC_MARKER_CLOSE="# <<< teach-plat lab ${LAB_ID} <<<"

LAB_USER=""
LAB_HOME=""
ASSUME_YES="no"

# ------------------------------------------------------------------- plumbing
c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'
c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_blue=$'\033[34m'
if [[ ! -t 1 ]]; then c_reset=""; c_bold=""; c_red=""; c_green=""; c_yellow=""; c_blue=""; fi

log()  { printf '%s[lab]%s %s\n' "${c_blue}"   "${c_reset}" "$*"; }
ok()   { printf '%s[ ok]%s %s\n' "${c_green}"  "${c_reset}" "$*"; }
warn() { printf '%s[!! ]%s %s\n' "${c_yellow}" "${c_reset}" "$*" >&2; }
die()  { printf '%s[err]%s %s\n' "${c_red}"    "${c_reset}" "$*" >&2; exit 1; }

usage() {
    cat <<USAGE
${LAB_TITLE}

Usage: sudo $0 <command> [--yes]

Commands:
  --break     Back up the current state and arm the four faults.
  --verify    Self-grade: check whether the system has been repaired.
              (Runs without root, with reduced coverage.)
  --status    Show which faults are currently armed.
  --restore   Emergency rollback. Undo every change from the backup.
              This is the escape hatch, not the exercise: using it means
              you did not solve the lab.
  --help      This text.

Options:
  --yes       Skip the interactive confirmation (for automated lab builds).
              Equivalent to exporting LAB_CONFIRM=BREAK.

Environment:
  LAB_USER    Unprivileged user who owns the graphical session.
              Defaults to \$SUDO_USER, then to the first UID >= 1000.
USAGE
}

need_root() {
    [[ ${EUID} -eq 0 ]] || die "this command needs root: re-run with sudo."
}

as_user() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "${LAB_USER}" -- "$@"
    else
        su -s /bin/bash -c "$(printf '%q ' "$@")" "${LAB_USER}"
    fi
}

detect_lab_user() {
    local u="${LAB_USER:-${SUDO_USER:-}}"
    if [[ -z "${u}" ]]; then
        u="$(awk -F: '$3 >= 1000 && $3 < 65000 && $7 !~ /(nologin|false)$/ {print $1; exit}' /etc/passwd)"
    fi
    [[ -n "${u}" ]] || die "cannot determine the lab user; export LAB_USER=<name>."
    id "${u}" >/dev/null 2>&1 || die "user '${u}' does not exist."
    LAB_USER="${u}"
    LAB_HOME="$(getent passwd "${u}" | cut -d: -f6)"
    [[ -d "${LAB_HOME}" ]] || die "home directory of '${u}' not found: ${LAB_HOME}"
}

# ------------------------------------------------------- backup / restore api
# Every file we are about to touch is recorded in a manifest as EXISTED or
# ABSENT, so --restore can tell "put the original back" from "delete what the
# lab created". Path encoding replaces '/' with '%' to keep a flat backup dir.

backup_file() {
    local path="$1" key="${1//\//%}"
    mkdir -p "${BACKUP_DIR}"
    if grep -qP "\t\Q${path}\E$" "${MANIFEST}" 2>/dev/null; then
        return 0                      # already recorded; keep the first state
    fi
    if [[ -e "${path}" ]]; then
        cp -a -- "${path}" "${BACKUP_DIR}/${key}"
        printf 'EXISTED\t%s\n' "${path}" >>"${MANIFEST}"
    else
        printf 'ABSENT\t%s\n'  "${path}" >>"${MANIFEST}"
    fi
}

restore_file() {
    local state="$1" path="$2" key="${2//\//%}"
    case "${state}" in
        EXISTED)
            mkdir -p "$(dirname -- "${path}")"
            cp -a -- "${BACKUP_DIR}/${key}" "${path}"
            log "restored ${path}" ;;
        ABSENT)
            rm -f -- "${path}"
            log "removed ${path} (did not exist before the lab)" ;;
    esac
}

# ------------------------------------------------------------------ preflight
preflight() {
    need_root
    detect_lab_user

    [[ -d /run/systemd/system ]] || die "systemd is not the init system here; this lab targets a systemd VM."

    command -v Xorg >/dev/null 2>&1 || command -v X >/dev/null 2>&1 || cat <<'NOX' && true
NOX
    if ! command -v Xorg >/dev/null 2>&1 && ! command -v X >/dev/null 2>&1; then
        die "no Xorg server found. Install an X11 desktop first, e.g.
       Debian/Ubuntu : apt install --no-install-recommends xserver-xorg xinit lightdm xfce4 x11-utils x11-xserver-utils
       Fedora/RHEL   : dnf install @base-x lightdm xfce-desktop xorg-x11-utils
       openSUSE      : zypper install xorg-x11-server xfce4-session lightdm"
    fi

    if ! systemctl list-unit-files 2>/dev/null | grep -qE '^(display-manager|gdm3?|lightdm|sddm|xdm|lxdm)\.service'; then
        warn "no display manager unit detected. Faults 1, 2 and 4 assume a DM-driven"
        warn "graphical login. Without one you will have to reproduce them with startx(1)."
    fi

    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        warn "the current session is Wayland. The lab forces the X11 session on the"
        warn "display manager, but some distributions (recent Fedora GNOME, for one)"
        warn "no longer ship a GNOME X11 session at all. If graphical login stays"
        warn "Wayland after the reboot, install a genuinely X11 desktop (Xfce, MATE,"
        warn "i3) or drive the lab from a text console with startx."
    fi
}

confirm() {
    [[ "${ASSUME_YES}" == "yes" || "${LAB_CONFIRM:-}" == "BREAK" ]] && return 0
    cat <<EOF

${c_bold}${c_red}This will deliberately break the graphical stack of THIS machine.${c_reset}

  host          : $(hostname)
  lab user      : ${LAB_USER}
  backups       : ${BACKUP_DIR}
  rollback      : sudo $0 --restore

Run it only on a disposable lab VM with a snapshot already taken.

EOF
    local answer=""
    read -r -p "Type BREAK to continue, anything else to abort: " answer
    [[ "${answer}" == "BREAK" ]] || die "aborted by the operator. Nothing was changed."
}

# ------------------------------------------------------------- lab groundwork
# Not a fault: the faults live in the X server, so the display manager must
# actually start an X server. Forcing the X11 session is part of the setup and
# is reverted by --restore like everything else.
force_x11_session() {
    local gdm_conf=""
    for candidate in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
        [[ -f "${candidate}" ]] && gdm_conf="${candidate}" && break
    done

    if [[ -n "${gdm_conf}" ]]; then
        backup_file "${gdm_conf}"
        if grep -qE '^[[:space:]]*#?[[:space:]]*WaylandEnable' "${gdm_conf}"; then
            sed -i -E 's/^[[:space:]]*#?[[:space:]]*WaylandEnable.*/WaylandEnable=false/' "${gdm_conf}"
        else
            sed -i -E '0,/^\[daemon\]/s//[daemon]\nWaylandEnable=false/' "${gdm_conf}"
        fi
        log "GDM: WaylandEnable=false in ${gdm_conf}"
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^sddm\.service'; then
        mkdir -p /etc/sddm.conf.d
        backup_file /etc/sddm.conf.d/10-lab-x11.conf
        printf '[General]\nDisplayServer=x11\n' >/etc/sddm.conf.d/10-lab-x11.conf
        log "SDDM: DisplayServer=x11 in /etc/sddm.conf.d/10-lab-x11.conf"
    fi
}

# ---------------------------------------------------------------- the faults
# FAULT 1 - a static /etc/X11/xorg.conf that pins a driver which does not
#           exist, with an explicit ServerLayout so autodetection cannot save
#           the day. Xorg aborts with "no screens found".
fault_1_broken_xorg_conf() {
    mkdir -p "${XORG_CONF_D}"
    backup_file "${XORG_CONF}"
    cat >"${XORG_CONF}" <<EOF
# Written by the teach-plat lab ${LAB_ID}. It is deliberately wrong.
Section "ServerLayout"
    Identifier     "LabLayout"
    Screen       0 "LabScreen" 0 0
EndSection

Section "Device"
    Identifier     "LabCard"
    Driver         "${BOGUS_DRIVER}"
    BusID          "PCI:0:2:0"
EndSection

Section "Monitor"
    Identifier     "LabMonitor"
EndSection

Section "Screen"
    Identifier     "LabScreen"
    Device         "LabCard"
    Monitor        "LabMonitor"
    DefaultDepth   24
    SubSection "Display"
        Depth      24
        Modes      "1024x768"
    EndSubSection
EndSection

Section "ServerFlags"
    Option         "AutoAddGPU" "false"
    Option         "AutoBindGPU" "false"
EndSection
EOF
    chmod 0644 "${XORG_CONF}"
    ok "fault 1 armed: ${XORG_CONF} pins Driver \"${BOGUS_DRIVER}\""
}

# FAULT 2 - an InputClass snippet that forces a keyboard layout nobody in the
#           room types. Only visible once the X server starts again.
fault_2_wrong_keymap() {
    mkdir -p "${XORG_CONF_D}"
    backup_file "${KBD_SNIPPET}"
    cat >"${KBD_SNIPPET}" <<EOF
# Written by the teach-plat lab ${LAB_ID}. It is deliberately wrong.
Section "InputClass"
    Identifier     "system-keyboard"
    MatchIsKeyboard "on"
    Option         "XkbLayout" "${BOGUS_LAYOUT}"
    Option         "XkbModel"  "pc105"
EndSection
EOF
    chmod 0644 "${KBD_SNIPPET}"
    ok "fault 2 armed: X11 keyboard layout forced to '${BOGUS_LAYOUT}'"
}

# FAULT 3 - client-side sabotage: DISPLAY points at a server that does not
#           exist and XAUTHORITY points at a file full of noise. This is the
#           "the desktop works but no X client will start from my terminal"
#           class of ticket.
fault_3_display_and_xauth() {
    local rc="${LAB_HOME}/.bashrc"
    backup_file "${rc}"
    [[ -f "${rc}" ]] || { : >"${rc}"; chown "${LAB_USER}:" "${rc}"; }

    if ! grep -qF "${RC_MARKER_OPEN}" "${rc}"; then
        cat >>"${rc}" <<EOF

${RC_MARKER_OPEN}
export DISPLAY=${BOGUS_DISPLAY}
export XAUTHORITY=${BOGUS_XAUTH}
${RC_MARKER_CLOSE}
EOF
    fi

    backup_file "${BOGUS_XAUTH}"
    head -c 128 /dev/urandom >"${BOGUS_XAUTH}"
    chown "${LAB_USER}:" "${BOGUS_XAUTH}"
    chmod 0600 "${BOGUS_XAUTH}"
    ok "fault 3 armed: DISPLAY=${BOGUS_DISPLAY} and a corrupt XAUTHORITY for ${LAB_USER}"
}

# FAULT 4 - the boot target is no longer graphical. The first symptom the
#           student meets, and the one that hides all the others.
fault_4_boot_target() {
    local current
    current="$(systemctl get-default 2>/dev/null || echo graphical.target)"
    mkdir -p "${STATE_DIR}"
    printf '%s\n' "${current}" >"${STATE_DIR}/default.target"
    systemctl set-default multi-user.target >/dev/null 2>&1
    ok "fault 4 armed: default boot target is now multi-user.target (was ${current})"
}

# --------------------------------------------------------------- mission text
write_mission() {
    cat >"${MISSION_FILE}" <<EOF
================================================================================
 ${LAB_TITLE}
 BREAK & FIX - mission brief
================================================================================

SCENARIO
  A junior admin "tuned the graphics" on this workstation over the weekend and
  then went on holiday. Monday morning the user (${LAB_USER}) reports: "there is
  no desktop any more". You have console and SSH access. Nothing is broken in
  the network, the packages or the data.

WHAT YOU ARE GOING TO SEE
  1. The machine boots to a plain text login prompt. No display manager, no
     greeter, no graphical session. 'systemctl status display-manager' shows
     the unit is not running.

  2. Once the graphical target is running again, the display manager keeps
     restarting or drops straight back to the console. The X server log ends in
     lines such as:

         (EE) Failed to load module "${BOGUS_DRIVER}" (module does not exist, 0)
         (EE) No drivers available.
         (EE) Fatal server error:
         (EE) no screens found(EE)

  3. When the greeter finally appears, the keyboard types the wrong characters:
     'sudo' comes out as something else entirely. The console (text) keyboard is
     fine; only X is affected. That asymmetry is the clue.

  4. Inside the graphical session, opening a terminal and launching any X client
     fails:

         \$ xclock
         Error: Can't open display: ${BOGUS_DISPLAY}

     and after you point DISPLAY back at the real server:

         \$ xdpyinfo | head -1
         No protocol specified
         xdpyinfo: unable to open display ":0".

YOUR OBJECTIVE
  Bring the machine back to a working graphical login for ${LAB_USER}, with:
    a) 'systemctl get-default' returning graphical.target and the display
       manager active;
    b) an X server that starts with no (EE) lines in its log and no leftover
       hand-written configuration pinning a non-existent driver;
    c) the correct keyboard layout in X ('setxkbmap -query' agrees with
       'localectl status');
    d) ${LAB_USER} able to run X clients from a terminal in their own session,
       with a valid MIT-MAGIC-COOKIE-1 in their authority file.

RULES OF ENGAGEMENT
  - Do not reinstall the desktop, and do not restore the VM snapshot.
  - Diagnose from logs first: the answer is written in them, verbatim.
  - Useful ground: Xorg(1), xorg.conf(5), xauth(1), xhost(1), localectl(1),
    journalctl(1), /var/log/Xorg.0.log, ~/.local/share/xorg/Xorg.0.log.
  - Ctrl+Alt+F2..F6 switch to text consoles; use one of them (or SSH) while X
    is down.

SELF-GRADING
      sudo $0 --verify

ESCAPE HATCH (using it means the lab is not solved)
      sudo $0 --restore

NEXT STEP
  Reboot now so the faults take effect from a clean boot:
      sudo reboot
================================================================================
EOF
    chmod 0644 "${MISSION_FILE}"
}

# --------------------------------------------------------------- commands
cmd_break() {
    preflight
    confirm

    if [[ -f "${MANIFEST}" ]]; then
        die "this lab is already armed (manifest at ${MANIFEST}).
       Run '$0 --restore' first if you want to re-arm it from a clean state."
    fi

    mkdir -p "${STATE_DIR}" "${BACKUP_DIR}"
    chmod 0700 "${STATE_DIR}"
    : >"${MANIFEST}"

    log "backing up every file the lab is about to touch..."
    force_x11_session
    fault_1_broken_xorg_conf
    fault_2_wrong_keymap
    fault_3_display_and_xauth
    fault_4_boot_target

    write_mission
    printf '\n'
    cat "${MISSION_FILE}"
    printf '\n'
    log "mission brief saved to ${MISSION_FILE}"
    log "reboot to start the exercise:  sudo reboot"
}

cmd_status() {
    detect_lab_user 2>/dev/null || true
    printf '%s%s%s\n\n' "${c_bold}" "${LAB_TITLE} - armed faults" "${c_reset}"

    if [[ -f "${XORG_CONF}" ]] && grep -q "${BOGUS_DRIVER}" "${XORG_CONF}" 2>/dev/null; then
        printf '  fault 1  %sARMED%s   %s pins Driver "%s"\n' "${c_red}" "${c_reset}" "${XORG_CONF}" "${BOGUS_DRIVER}"
    else
        printf '  fault 1  %sclear%s   no bogus driver in %s\n' "${c_green}" "${c_reset}" "${XORG_CONF}"
    fi

    if [[ -f "${KBD_SNIPPET}" ]] && grep -q "\"${BOGUS_LAYOUT}\"" "${KBD_SNIPPET}" 2>/dev/null; then
        printf '  fault 2  %sARMED%s   XkbLayout "%s" in %s\n' "${c_red}" "${c_reset}" "${BOGUS_LAYOUT}" "${KBD_SNIPPET}"
    else
        printf '  fault 2  %sclear%s   X11 keymap not forced to "%s"\n' "${c_green}" "${c_reset}" "${BOGUS_LAYOUT}"
    fi

    if [[ -n "${LAB_HOME}" ]] && grep -qF "${RC_MARKER_OPEN}" "${LAB_HOME}/.bashrc" 2>/dev/null; then
        printf '  fault 3  %sARMED%s   DISPLAY/XAUTHORITY override in %s/.bashrc\n' "${c_red}" "${c_reset}" "${LAB_HOME}"
    else
        printf '  fault 3  %sclear%s   no lab block in the shell rc file\n' "${c_green}" "${c_reset}"
    fi

    local target; target="$(systemctl get-default 2>/dev/null || echo unknown)"
    if [[ "${target}" != "graphical.target" ]]; then
        printf '  fault 4  %sARMED%s   default target is %s\n' "${c_red}" "${c_reset}" "${target}"
    else
        printf '  fault 4  %sclear%s   default target is graphical.target\n' "${c_green}" "${c_reset}"
    fi
    printf '\n'
}

cmd_verify() {
    detect_lab_user 2>/dev/null || true
    local pass=0 fail=0
    check() {  # check <label> <shell-condition...>
        local label="$1"; shift
        if "$@" >/dev/null 2>&1; then
            printf '  %sPASS%s  %s\n' "${c_green}" "${c_reset}" "${label}"; pass=$((pass + 1))
        else
            printf '  %sFAIL%s  %s\n' "${c_red}" "${c_reset}" "${label}"; fail=$((fail + 1))
        fi
    }

    printf '\n%s%s - self-grading%s\n\n' "${c_bold}" "${LAB_TITLE}" "${c_reset}"

    check "1. no non-existent driver pinned in ${XORG_CONF}" \
        bash -c "[[ ! -f '${XORG_CONF}' ]] || ! grep -q '${BOGUS_DRIVER}' '${XORG_CONF}'"

    check "2. X11 keyboard layout is no longer '${BOGUS_LAYOUT}'" \
        bash -c "! localectl status 2>/dev/null | grep -i 'X11 Layout' | grep -qi '${BOGUS_LAYOUT}'"

    check "3. no DISPLAY/XAUTHORITY override left in ${LAB_HOME:-<home>}/.bashrc" \
        bash -c "[[ -z '${LAB_HOME}' ]] || ! grep -qF '${RC_MARKER_OPEN}' '${LAB_HOME}/.bashrc' 2>/dev/null"

    check "4. default boot target is graphical.target" \
        bash -c "[[ \"\$(systemctl get-default 2>/dev/null)\" == graphical.target ]]"

    check "5. the display manager unit is active" \
        systemctl is-active --quiet display-manager.service

    check "6. an X server is listening (socket in /tmp/.X11-unix)" \
        bash -c "compgen -G '/tmp/.X11-unix/X*' >/dev/null || pgrep -x Xorg >/dev/null"

    check "7. the X server log has no fatal (EE) 'no screens found'" \
        bash -c "! grep -rqs 'no screens found' /var/log/Xorg.*.log ${LAB_HOME:-/root}/.local/share/xorg/Xorg.*.log"

    printf '\n  %sMANUAL%s  8. inside the graphical session as %s, run:\n' \
        "${c_yellow}" "${c_reset}" "${LAB_USER:-<user>}"
    printf '              echo "$DISPLAY"; xauth list; xdpyinfo | head -3; xclock\n'
    printf '          DISPLAY must be :0 (or :1), xauth must list an\n'
    printf '          MIT-MAGIC-COOKIE-1 entry for this host, and xclock must open.\n'

    printf '\n  %d passed, %d failed\n\n' "${pass}" "${fail}"
    [[ ${fail} -eq 0 ]] || return 1
    ok "automated checks green. Confirm check 8 by hand and the lab is solved."
}

cmd_restore() {
    need_root
    [[ -f "${MANIFEST}" ]] || die "nothing to restore: no manifest at ${MANIFEST}."

    warn "rolling back every change made by this lab."
    while IFS=$'\t' read -r state path; do
        [[ -n "${path:-}" ]] || continue
        restore_file "${state}" "${path}"
    done <"${MANIFEST}"

    if [[ -f "${STATE_DIR}/default.target" ]]; then
        local target; target="$(cat "${STATE_DIR}/default.target")"
        systemctl set-default "${target}" >/dev/null 2>&1 || true
        log "default boot target set back to ${target}"
    fi

    rm -f "${MANIFEST}" "${STATE_DIR}/default.target" "${MISSION_FILE}"
    rm -rf "${BACKUP_DIR}"
    ok "rollback complete. Reboot to return to a normal graphical login."
}

# ------------------------------------------------------------------ dispatch
main() {
    local cmd="${1:-}"
    shift || true
    for arg in "$@"; do
        case "${arg}" in
            --yes) ASSUME_YES="yes" ;;
            *) die "unknown option: ${arg}" ;;
        esac
    done
    case "${cmd}" in
        --break)   cmd_break ;;
        --verify)  cmd_verify ;;
        --status)  cmd_status ;;
        --restore) cmd_restore ;;
        --help|-h|"") usage ;;
        *) usage; die "unknown command: ${cmd}" ;;
    esac
}

main "$@"

# =============================================================================
#  S O L U T I O N   -   step by step
#  Do not read this until you have genuinely tried. Every command below is a
#  real command with the output you should expect on the lab VM.
# =============================================================================
#
# -----------------------------------------------------------------------------
# STEP 0 - get a working shell and take the temperature
# -----------------------------------------------------------------------------
#   The machine booted to text. Log in at the console (or ssh in) and look at
#   the two facts that decide everything else: which target is running, and
#   whether a display manager exists at all.
#
#     $ systemctl get-default
#     multi-user.target
#
#     $ systemctl status display-manager.service --no-pager
#     ● lightdm.service - Light Display Manager
#          Loaded: loaded (/lib/systemd/system/lightdm.service; enabled)
#          Active: inactive (dead)
#
#     $ systemctl list-unit-files --type=target | grep graphical
#     graphical.target    static
#
#   Reading: the unit is enabled but nothing pulled it in, because
#   graphical.target was never reached. That is fault 4, not a broken X server
#   - yet. Resist the urge to reinstall anything.
#
# -----------------------------------------------------------------------------
# STEP 1 - fault 4: put the boot target back
# -----------------------------------------------------------------------------
#   'systemctl set-default' rewrites the symlink
#   /etc/systemd/system/default.target. 'isolate' switches the running system
#   without a reboot.
#
#     $ sudo systemctl set-default graphical.target
#     Removed /etc/systemd/system/default.target.
#     Created symlink /etc/systemd/system/default.target -> /usr/lib/systemd/system/graphical.target.
#
#     $ ls -l /etc/systemd/system/default.target
#     lrwxrwxrwx 1 root root 40 ... -> /usr/lib/systemd/system/graphical.target
#
#     $ sudo systemctl isolate graphical.target
#
#   The screen blinks, and then... you are back at a text console, or the
#   display manager restarts in a loop. Fault 4 is fixed; fault 1 is now
#   visible.
#
#     $ systemctl status display-manager.service --no-pager | tail -5
#        Active: activating (auto-restart) (Result: exit-code)
#       Process: 1123 ExecStart=/usr/sbin/lightdm (code=exited, status=1/FAILURE)
#
# -----------------------------------------------------------------------------
# STEP 2 - fault 1: read the X server log, then trust it
# -----------------------------------------------------------------------------
#   Two log locations matter, and knowing which one applies is exam material:
#     * X started as root (classic, or by most display managers):
#           /var/log/Xorg.<display>.log
#     * rootless X started by the session user (modern default):
#           ~/.local/share/xorg/Xorg.<display>.log
#   The display manager's own journal is the third place to look.
#
#     $ sudo journalctl -b -u display-manager --no-pager | tail -20
#     lightdm[1123]: Failed to start X server
#
#     $ sudo grep -E '\(EE\)|\(WW\)' /var/log/Xorg.0.log
#     [    12.884] (WW) Warning, couldn't open module labvideo
#     [    12.884] (EE) Failed to load module "labvideo" (module does not exist, 0)
#     [    12.885] (EE) No drivers available.
#     [    12.885] (EE) Fatal server error:
#     [    12.885] (EE) no screens found(EE)
#     [    12.885] (EE) Please consult the The X.Org Foundation support at ...
#
#   The log names the module. Now find who asked for it. X reads, in order:
#     /etc/X11/xorg.conf, then /etc/X11/xorg.conf-4, /etc/xorg.conf, and then
#     every *.conf in /etc/X11/xorg.conf.d/ and /usr/share/X11/xorg.conf.d/,
#     in lexicographic order; /etc wins over /usr/share on equal names.
#
#     $ ls -l /etc/X11/xorg.conf /etc/X11/xorg.conf.d/
#     -rw-r--r-- 1 root root 612 ... /etc/X11/xorg.conf
#     /etc/X11/xorg.conf.d/:
#     -rw-r--r-- 1 root root 214 ... 00-keyboard.conf
#
#     $ grep -n 'Driver' /etc/X11/xorg.conf
#     11:    Driver         "labvideo"
#
#   Fix. On any modern system the right answer is usually to remove the
#   hand-written file entirely and let Xorg autodetect through KMS: keep the
#   evidence rather than deleting it outright.
#
#     $ sudo mv /etc/X11/xorg.conf /root/xorg.conf.broken.$(date +%F)
#
#   Validate BEFORE handing the machine back, on a spare display, so a second
#   mistake does not cost you another reboot:
#
#     $ sudo Xorg :2 -verbose 3 -logfile /tmp/x2.log ; echo "exit=$?"
#     (Ctrl+Alt+F2 to come back, then:)
#     $ grep -c '(EE)' /tmp/x2.log
#     0
#
#   Alternative if the hardware really does need a static file, X can write a
#   correct skeleton for you:
#
#     $ sudo Xorg -configure          # writes /root/xorg.conf.new
#     $ sudo Xorg -config /root/xorg.conf.new :2   # test it, then install it
#
#   Restart the greeter:
#
#     $ sudo systemctl restart display-manager
#     $ systemctl is-active display-manager
#     active
#
# -----------------------------------------------------------------------------
# STEP 3 - fault 2: the keyboard types nonsense in X only
# -----------------------------------------------------------------------------
#   The greeter is up and the keys are wrong. The text console is fine, so the
#   kernel keymap (vconsole, 'loadkeys') is not the problem: this is XKB.
#
#     $ localectl status
#            System Locale: LANG=en_US.UTF-8
#        VC Keymap: us
#       X11 Layout: dvorak
#        X11 Model: pc105
#
#     $ cat /etc/X11/xorg.conf.d/00-keyboard.conf
#     Section "InputClass"
#         Identifier "system-keyboard"
#         MatchIsKeyboard "on"
#         Option "XkbLayout" "dvorak"
#         ...
#
#   Fix it through the tool that owns the file - localectl writes exactly this
#   snippet, so hand-editing and then running localectl later would be undone:
#
#     $ sudo localectl set-x11-keymap us pc105
#     $ localectl status | grep 'X11 Layout'
#       X11 Layout: us
#
#   For the currently running X session, without logging out:
#
#     $ setxkbmap us
#     $ setxkbmap -query
#     rules:      evdev
#     model:      pc105
#     layout:     us
#
#   Then restart the display manager (or log out and in) so the greeter and the
#   session pick up the new InputClass:
#
#     $ sudo systemctl restart display-manager
#
#   Note: a full desktop environment (GNOME, KDE, Xfce) may override XKB with
#   its own per-user setting. If 'setxkbmap -query' disagrees with localectl
#   inside the session, look at the DE's keyboard settings too - that layering
#   is a classic support trap.
#
# -----------------------------------------------------------------------------
# STEP 4 - fault 3: no X client will start from the user's terminal
# -----------------------------------------------------------------------------
#   Log in graphically as the lab user, open a terminal:
#
#     $ xclock
#     Error: Can't open display: :99
#
#   Two variables govern an X client: where the server is (DISPLAY) and how to
#   prove you may talk to it (XAUTHORITY, holding an MIT-MAGIC-COOKIE-1).
#
#     $ echo "$DISPLAY"; echo "$XAUTHORITY"
#     :99
#     /tmp/.lab-106.1-authority
#
#     $ ls /tmp/.X11-unix/
#     X0                      # the real server is display :0, not :99
#
#   Find who is setting them. The session environment is not the culprit here;
#   the shell rc file is:
#
#     $ grep -n 'teach-plat lab' ~/.bashrc
#     102:# >>> teach-plat lab lpic1-106.1 >>>
#     105:# <<< teach-plat lab lpic1-106.1 <<<
#
#     $ sed -n '100,106p' ~/.bashrc
#
#   Remove that block (edit it out with your editor, or):
#
#     $ sed -i '/# >>> teach-plat lab lpic1-106.1 >>>/,/# <<< teach-plat lab lpic1-106.1 <<</d' ~/.bashrc
#     $ rm -f /tmp/.lab-106.1-authority
#
#   Fix the current shell without logging out:
#
#     $ unset XAUTHORITY
#     $ export DISPLAY=:0
#     $ xauth list
#     labvm/unix:0  MIT-MAGIC-COOKIE-1  9f3c1a...e4
#     $ xdpyinfo | head -3
#     name of display:    :0
#     version number:     11.0
#     vendor string:      The X.Org Foundation
#     $ xclock &
#
#   If authorisation is still refused ("No protocol specified", or
#   "X11 connection rejected because of wrong authentication"), the cookie in
#   the user's authority file does not match the server's. Three ways out, in
#   increasing order of bluntness:
#
#     a) Regenerate the entry from the running server (needs current access):
#          $ xauth generate :0 . trusted
#
#     b) Copy the cookie from the display manager's own authority file (as
#        root; the path depends on the DM):
#          # xauth -f /var/lib/lightdm/.Xauthority list :0
#          # xauth -f /home/USER/.Xauthority merge /var/lib/lightdm/.Xauthority
#        GDM keeps it under /run/user/<uid>/gdm/Xauthority instead.
#
#     c) From a shell that already has access, grant the local user by
#        identity rather than by host - this is the correct modern form:
#          $ xhost +si:localuser:USER
#          $ xhost
#          access control enabled, only authorized clients can connect
#          SI:localuser:USER
#        NEVER 'xhost +' on a machine you care about: it disables access
#        control entirely and any local or remote client can read your
#        keystrokes and screen. See Xsecurity(7).
#
#     d) Simplest and most durable: log out and log back in. The display
#        manager writes a fresh authority file for the session.
#
# -----------------------------------------------------------------------------
# STEP 5 - confirm the repair
# -----------------------------------------------------------------------------
#     $ sudo bash /path/to/this-script --verify
#       PASS  1. no non-existent driver pinned in /etc/X11/xorg.conf
#       PASS  2. X11 keyboard layout is no longer 'dvorak'
#       PASS  3. no DISPLAY/XAUTHORITY override left in /home/USER/.bashrc
#       PASS  4. default boot target is graphical.target
#       PASS  5. the display manager unit is active
#       PASS  6. an X server is listening (socket in /tmp/.X11-unix)
#       PASS  7. the X server log has no fatal (EE) 'no screens found'
#
#   Then reboot once and log in graphically, to prove the fix survives a boot
#   rather than only the running session:
#
#     $ sudo reboot
#
# -----------------------------------------------------------------------------
# PRODUCTION NOTES worth carrying out of this lab
# -----------------------------------------------------------------------------
#   * A static /etc/X11/xorg.conf is a liability on modern hardware. Prefer a
#     minimal snippet in /etc/X11/xorg.conf.d/ that changes exactly one thing,
#     and let KMS autodetection do the rest. A single wrong Driver line in the
#     monolithic file takes down every screen.
#   * The (EE)/(WW)/(II)/(--)/(**) markers in Xorg.0.log are a grep-ready
#     severity scheme: (--) is probed, (**) comes from your config file. If a
#     value shows as (**) you asked for it - that is how you tell "the hardware
#     says so" from "someone configured it".
#   * Keyboard layout lives in two independent places: the kernel VC keymap
#     ('localectl set-keymap', loadkeys) and the X/XKB layout ('localectl
#     set-x11-keymap', setxkbmap). Fixing one does not fix the other.
#   * DISPLAY and XAUTHORITY are the whole client-side story, including over
#     SSH: 'ssh -X' sets DISPLAY to localhost:10.0 and writes a proxy cookie
#     into the remote XAUTHORITY. If X forwarding "does not work", print both
#     variables on the remote side before blaming the network. 'ssh -Y' is the
#     trusted variant - weaker isolation, use it only when -X is too strict.
#   * On Wayland sessions none of the xorg.conf machinery applies: the
#     compositor owns the display, and X clients run through Xwayland. Check
#     'echo $XDG_SESSION_TYPE' before spending an hour in xorg.conf.d.
# =============================================================================