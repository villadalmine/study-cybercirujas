#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-1 (101-500 / 102-500) — Topic 106.2: Graphical Desktops
#  BREAK & FIX LABORATORY EXERCISE
# ============================================================================
#
#  WARNING: THIS SCRIPT INTENTIONALLY BREAKS THE GRAPHICAL DESKTOP STACK.
#  RUN IT ONLY INSIDE A DISPOSABLE LABORATORY VIRTUAL MACHINE WITH A SNAPSHOT
#  TAKEN BEFOREHAND. NEVER RUN IT ON A WORKSTATION YOU CARE ABOUT.
#
#  Exam objective coverage (weight 0 in 101, examinable in 102-500 as part of
#  "106.2 Graphical Desktops"):
#    - X11 / Wayland as the display server layer
#    - X display managers (LightDM, GDM, SDDM) and how they are selected
#    - Remote desktop protocols: XDMCP, VNC, RDP, SPICE
#    - Where the desktop session is configured and how it is diagnosed
#
#  Official objective reference:
#    https://www.lpi.org/our-certifications/exam-102-objectives/
#    https://www.lpi.org/our-certifications/exam-101-objectives/
#
#  Documentation the student is expected to consult:
#    https://www.x.org/wiki/Documentation/
#    https://wayland.freedesktop.org/docs/html/
#    https://www.freedesktop.org/wiki/Software/systemd/  (display-manager.service)
#    https://tigervnc.org/doc/vncserver.html
#    https://github.com/canonical/lightdm
#    https://man.archlinux.org/man/Xwrapper.config.5
#
# ============================================================================

set -o pipefail

readonly LAB_TAG="lpic1-106.2-breakfix"
readonly STATE_DIR="/var/lib/${LAB_TAG}"
readonly BACKUP_DIR="${STATE_DIR}/backup"
readonly MANIFEST="${STATE_DIR}/manifest.txt"

# ---------------------------------------------------------------------------
# Console styling — degrade gracefully when not attached to a TTY.
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_OFF=''
fi

log()   { printf '%s[ * ]%s %s\n' "${C_BLU}" "${C_OFF}" "$*"; }
ok()    { printf '%s[ + ]%s %s\n' "${C_GRN}" "${C_OFF}" "$*"; }
warn()  { printf '%s[ ! ]%s %s\n' "${C_YEL}" "${C_OFF}" "$*"; }
die()   { printf '%s[ x ]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Safety rails. A break & fix lab is only pedagogically honest if the damage
# is bounded, reversible and confined to a machine the student agreed to lose.
# ---------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script must run as root (sudo $0 break)."
}

refuse_on_non_lab_host() {
    # Heuristic guardrails. None of them is authoritative on its own, so we
    # combine them and still demand an explicit typed confirmation.
    local risk=0 reasons=()

    if [[ -d /var/lib/kubelet || -d /var/lib/etcd ]]; then
        risk=1; reasons+=("Kubernetes node state present (/var/lib/kubelet or /var/lib/etcd)")
    fi
    if systemctl is-active --quiet sshd 2>/dev/null && \
       [[ -f /etc/ssh/sshd_config ]] && \
       grep -qsE '^\s*PermitRootLogin\s+no' /etc/ssh/sshd_config && \
       [[ $(who | wc -l) -gt 2 ]]; then
        risk=1; reasons+=("Multiple interactive users are logged in — this looks shared")
    fi
    if [[ -f /etc/machine-id ]] && command -v virt-what >/dev/null 2>&1; then
        if [[ -z "$(virt-what 2>/dev/null)" ]]; then
            risk=1; reasons+=("virt-what reports bare metal, not a VM")
        fi
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if [[ "$(systemd-detect-virt 2>/dev/null)" == "none" ]]; then
            risk=1; reasons+=("systemd-detect-virt says 'none' — this is not virtualised")
        fi
    fi

    if [[ ${risk} -eq 1 ]]; then
        warn "This host does NOT look like a disposable lab VM:"
        printf '        %s- %s%s\n' "${C_DIM}" "${reasons[@]/#/}" "${C_OFF}" 2>/dev/null || true
        local r
        for r in "${reasons[@]}"; do printf '        %s- %s%s\n' "${C_DIM}" "${r}" "${C_OFF}"; done
        echo
    fi
}

confirm_or_abort() {
    cat <<'BANNER'

  +--------------------------------------------------------------------+
  |   LPIC-1  106.2  Graphical Desktops   --   BREAK & FIX             |
  |                                                                    |
  |   This will deliberately disable the graphical login on this        |
  |   machine and misconfigure a remote desktop service.                |
  |                                                                    |
  |   Requirements before you continue:                                 |
  |     1. This is a THROW-AWAY lab VM.                                 |
  |     2. You have a snapshot you can roll back to.                    |
  |     3. You have a working SSH session OR console access, because    |
  |        the graphical session will go away.                          |
  +--------------------------------------------------------------------+

BANNER
    if [[ -n "${LAB_ASSUME_YES:-}" ]]; then
        warn "LAB_ASSUME_YES is set — skipping interactive confirmation."
        return 0
    fi
    local answer=""
    read -r -p "  Type exactly  BREAK MY LAB  to continue: " answer
    [[ "${answer}" == "BREAK MY LAB" ]] || die "Aborted. Nothing was changed."
}

check_ssh_lifeline() {
    # If the student breaks the display manager and has no second way in,
    # the lab becomes a reboot exercise instead of a diagnostic exercise.
    if ! systemctl is-active --quiet ssh 2>/dev/null && \
       ! systemctl is-active --quiet sshd 2>/dev/null; then
        warn "No sshd/ssh service is active."
        warn "Make sure you can reach a text console (Ctrl+Alt+F3) before proceeding."
        warn "Without a console or SSH you will only be able to recover from a snapshot."
        echo
    else
        ok "SSH is active — you have a lifeline into this VM."
    fi
}

# ---------------------------------------------------------------------------
# Backup helpers. Every file we touch is copied verbatim first and recorded in
# a manifest, so the built-in restore path is exact rather than approximate.
# ---------------------------------------------------------------------------
init_state() {
    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${STATE_DIR}"
    : > "${MANIFEST}"
}

backup_file() {
    # backup_file <absolute-path>
    # Records the original file (or the fact that it did not exist) so that
    # 'restore' can put the system back byte for byte.
    local src="$1"
    local dst="${BACKUP_DIR}${src}"
    mkdir -p "$(dirname "${dst}")"
    if [[ -e "${src}" || -L "${src}" ]]; then
        cp -a "${src}" "${dst}"
        printf 'FILE\t%s\n' "${src}" >> "${MANIFEST}"
    else
        printf 'ABSENT\t%s\n' "${src}" >> "${MANIFEST}"
    fi
}

record_unit_state() {
    # record_unit_state <unit>
    # Saves enabled/disabled and active/inactive so the restore is faithful.
    local unit="$1" enabled active
    enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || echo unknown)"
    active="$(systemctl is-active  "${unit}" 2>/dev/null || echo unknown)"
    printf 'UNIT\t%s\t%s\t%s\n' "${unit}" "${enabled}" "${active}" >> "${MANIFEST}"
}

# ---------------------------------------------------------------------------
# Environment discovery. The exam expects the candidate to identify WHICH
# display manager and WHICH display server the distribution is using, rather
# than assume one. The lab does the same before it breaks anything.
# ---------------------------------------------------------------------------
DM_UNIT=""
DM_NAME=""
DISPLAY_SERVER=""

detect_display_manager() {
    # /etc/systemd/system/display-manager.service is the canonical answer on
    # any systemd distribution: it is a symlink to the real DM unit file.
    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        local target
        target="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)"
        DM_NAME="$(basename "${target}" .service)"
        DM_UNIT="display-manager.service"
    else
        local candidate
        for candidate in gdm gdm3 lightdm sddm xdm lxdm slim; do
            if systemctl list-unit-files "${candidate}.service" >/dev/null 2>&1 && \
               systemctl cat "${candidate}.service" >/dev/null 2>&1; then
                DM_NAME="${candidate}"
                DM_UNIT="${candidate}.service"
                break
            fi
        done
    fi

    if [[ -z "${DM_NAME}" ]]; then
        DM_NAME="(none installed)"
        DM_UNIT=""
    fi
}

detect_display_server() {
    # loginctl exposes the session type; XDG_SESSION_TYPE is the per-session
    # view of the same fact. Fall back to inspecting running processes.
    local sid type=""
    sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NR==1{print $1}')"
    if [[ -n "${sid}" ]]; then
        type="$(loginctl show-session "${sid}" -p Type --value 2>/dev/null)"
    fi
    if [[ -z "${type}" ]]; then
        if pgrep -x Xorg   >/dev/null 2>&1; then type="x11"
        elif pgrep -x Xwayland >/dev/null 2>&1; then type="wayland"
        else type="unknown"; fi
    fi
    DISPLAY_SERVER="${type}"
}

print_environment() {
    echo
    log "Laboratory environment detected:"
    printf '      %-24s %s\n' "Distribution:"    "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    printf '      %-24s %s\n' "Display manager:" "${DM_NAME}"
    printf '      %-24s %s\n' "DM unit:"         "${DM_UNIT:-none}"
    printf '      %-24s %s\n' "Session type:"    "${DISPLAY_SERVER}"
    printf '      %-24s %s\n' "Default target:"  "$(systemctl get-default 2>/dev/null || echo unknown)"
    printf '      %-24s %s\n' "Xorg present:"    "$(command -v Xorg >/dev/null 2>&1 && echo yes || echo no)"
    printf '      %-24s %s\n' "VNC server:"      "$(command -v vncserver Xvnc x0vncserver 2>/dev/null | head -n1 || echo 'not installed')"
    echo
}

# ===========================================================================
#  THE BREAKAGE
# ===========================================================================
#  Four independent faults are injected. They are layered deliberately: the
#  student who only restarts the display manager fixes nothing, because the
#  unit itself has been pointed at a non-existent binary AND the boot target
#  has been changed AND the X server wrapper forbids starting X AND the
#  display manager's own configuration references a session that is not
#  installed. Real production breakage is rarely a single cause.
# ===========================================================================

break_1_default_target() {
    log "Fault 1/4: switching the default systemd target."
    printf 'DEFAULT_TARGET\t%s\n' \
        "$(systemctl get-default 2>/dev/null || echo graphical.target)" >> "${MANIFEST}"
    systemctl set-default multi-user.target >/dev/null 2>&1 \
        && ok "  default target -> multi-user.target" \
        || warn "  could not change the default target"
}

break_2_xwrapper() {
    log "Fault 2/4: forbidding X server startup for regular users."
    # Xwrapper.config governs who may start the X server through the setuid
    # wrapper /usr/lib/xorg/Xorg.wrap on Debian-family systems.
    local f=/etc/X11/Xwrapper.config
    mkdir -p /etc/X11
    backup_file "${f}"
    cat > "${f}" <<'EOF'
# Injected by the LPIC-1 106.2 break & fix laboratory.
allowed_users=nobody
needs_root_rights=no
EOF
    ok "  ${f} now sets allowed_users=nobody"
}

break_3_display_manager_unit() {
    log "Fault 3/4: corrupting the display manager unit."
    if [[ -z "${DM_UNIT}" ]]; then
        warn "  no display manager unit found — skipping this fault"
        return 0
    fi

    record_unit_state "${DM_UNIT}"

    # A drop-in override is the realistic failure: an operator "customises"
    # the unit, typos the ExecStart path, and the DM never comes up again.
    # It is also strictly reversible, since the vendor unit is untouched.
    local dropin_dir="/etc/systemd/system/${DM_NAME}.service.d"
    local dropin="${dropin_dir}/99-lab-override.conf"
    mkdir -p "${dropin_dir}"
    backup_file "${dropin}"
    cat > "${dropin}" <<EOF
# Injected by the LPIC-1 106.2 break & fix laboratory.
[Service]
ExecStart=
ExecStart=/usr/sbin/${DM_NAME}-greeter-secure --config /etc/${DM_NAME}/hardened.conf
Restart=no
EOF
    printf 'DROPIN\t%s\n' "${dropin_dir}" >> "${MANIFEST}"

    systemctl daemon-reload >/dev/null 2>&1
    systemctl stop "${DM_UNIT}" >/dev/null 2>&1 || true
    ok "  ${DM_NAME}.service overridden with a non-existent ExecStart and stopped"
}

break_4_session_and_remote_desktop() {
    log "Fault 4/4: pointing the greeter at a session that is not installed,"
    log "           and leaving a half-configured VNC service behind."

    # 4a. LightDM/SDDM/GDM all name the session to launch in their own
    #     configuration. Naming a .desktop file that does not exist in
    #     /usr/share/xsessions produces a login loop rather than a hard error.
    case "${DM_NAME}" in
        lightdm)
            local d=/etc/lightdm/lightdm.conf.d
            mkdir -p "${d}"
            backup_file "${d}/99-lab.conf"
            cat > "${d}/99-lab.conf" <<'EOF'
# Injected by the LPIC-1 106.2 break & fix laboratory.
[Seat:*]
user-session=corporate-desktop
greeter-session=corporate-greeter
EOF
            ok "  lightdm seat pinned to the missing session 'corporate-desktop'"
            ;;
        sddm)
            local d=/etc/sddm.conf.d
            mkdir -p "${d}"
            backup_file "${d}/99-lab.conf"
            cat > "${d}/99-lab.conf" <<'EOF'
# Injected by the LPIC-1 106.2 break & fix laboratory.
[Autologin]
Session=corporate-desktop.desktop
[General]
DisplayServer=x11
EOF
            ok "  sddm autologin pinned to the missing session 'corporate-desktop'"
            ;;
        gdm|gdm3)
            local f=/etc/gdm3/custom.conf
            [[ -f /etc/gdm/custom.conf ]] && f=/etc/gdm/custom.conf
            mkdir -p "$(dirname "${f}")"
            backup_file "${f}"
            cat >> "${f}" <<'EOF'

# Injected by the LPIC-1 106.2 break & fix laboratory.
[daemon]
WaylandEnable=false
DefaultSession=corporate-desktop.desktop
EOF
            ok "  gdm DefaultSession pinned to the missing session 'corporate-desktop'"
            ;;
        *)
            warn "  unknown display manager '${DM_NAME}' — session fault skipped"
            ;;
    esac

    # 4b. A user-level VNC unit that will not start: the template unit exists
    #     but the geometry/localhost arguments and the missing passwd file
    #     make it fail. This is the "remote desktop" half of the objective.
    local unit=/etc/systemd/system/labvnc@.service
    backup_file "${unit}"
    cat > "${unit}" <<'EOF'
# Injected by the LPIC-1 106.2 break & fix laboratory.
# TigerVNC per-display template unit. Deliberately incomplete.
[Unit]
Description=Lab TigerVNC server on display %i
After=syslog.target network.target

[Service]
Type=simple
User=%i
PAMName=login
PIDFile=/home/%i/.vnc/%H:1.pid
ExecStartPre=/usr/bin/vncserver -kill :1 > /dev/null 2>&1
ExecStart=/usr/bin/vncserver :1 -geometry 99999x99999 -depth 24 -localhost no -rfbauth /etc/vnc/nonexistent.passwd
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF
    printf 'UNITFILE\t%s\n' "${unit}" >> "${MANIFEST}"
    systemctl daemon-reload >/dev/null 2>&1
    ok "  /etc/systemd/system/labvnc@.service created with an invalid invocation"
}

# ---------------------------------------------------------------------------
# The student-facing briefing. State the symptom and the acceptance criteria;
# do not state the cause.
# ---------------------------------------------------------------------------
print_briefing() {
    cat <<BRIEFING

${C_RED}============================================================================${C_OFF}
${C_RED}  BREAKAGE COMPLETE — 106.2 GRAPHICAL DESKTOPS${C_OFF}
${C_RED}============================================================================${C_OFF}

${C_YEL}THE SCENARIO${C_OFF}

  You are on call. A developer workstation ("${HOSTNAME}") came back from a
  maintenance window and no longer presents a graphical login. The change
  ticket is vague: "hardened the desktop and enabled remote access". The
  person who ran it is unreachable. You have SSH and console access only.

${C_YEL}THE SYMPTOMS YOU WILL OBSERVE${C_OFF}

  1. After a reboot the machine stops at a black text console with a
     "${HOSTNAME} login:" prompt. No greeter, no desktop.

  2. ${C_DIM}systemctl status ${DM_UNIT:-display-manager.service}${C_OFF} reports the unit as
     ${C_DIM}failed${C_OFF} with something similar to:

         Failed to locate executable /usr/sbin/${DM_NAME}-greeter-secure:
         No such file or directory
         ${DM_NAME}.service: Failed at step EXEC spawning ...: No such file or directory
         ${DM_NAME}.service: Main process exited, code=exited, status=203/EXEC

  3. Starting X by hand as a normal user fails immediately:

         \$ startx
         Only console users are allowed to run the X server
         xinit: giving up
         xinit: unable to connect to X server: Connection refused

  4. Even after you get the display manager running, authenticating drops
     you straight back to the greeter — a classic ${C_DIM}login loop${C_OFF} — and
     ${C_DIM}~/.xsession-errors${C_OFF} / the journal show the session command was
     not found.

  5. ${C_DIM}systemctl start labvnc@\$USER${C_OFF} fails, so the documented remote
     desktop fallback is unavailable too.

${C_YEL}WHAT YOU MUST ACHIEVE (acceptance criteria)${C_OFF}

  [ ] A. ${C_DIM}systemctl get-default${C_OFF} returns ${C_DIM}graphical.target${C_OFF}.
  [ ] B. ${C_DIM}systemctl is-active ${DM_UNIT:-display-manager.service}${C_OFF} returns ${C_DIM}active${C_OFF},
         and the unit runs its distribution-provided ExecStart — not a
         hand-written one.
  [ ] C. An unprivileged user on the physical console can start an X
         session (${C_DIM}startx${C_OFF} succeeds, or the greeter appears on tty7/tty1).
  [ ] D. Logging in from the greeter reaches a real desktop session that
         exists in ${C_DIM}/usr/share/xsessions/${C_OFF} or
         ${C_DIM}/usr/share/wayland-sessions/${C_OFF} — no login loop.
  [ ] E. ${C_DIM}labvnc@<user>${C_OFF} either starts and serves a display, or is
         removed deliberately with a written justification. A service you
         cannot explain is not a service you leave running.

${C_YEL}RULES OF ENGAGEMENT${C_OFF}

  - Do not restore the VM snapshot. Diagnosing is the exercise.
  - Do not reinstall the display manager package. Everything you need is a
     configuration change.
  - Work from the journal outward: ${C_DIM}journalctl -b -u ${DM_UNIT:-display-manager.service}${C_OFF},
     ${C_DIM}/var/log/Xorg.0.log${C_OFF}, ${C_DIM}~/.xsession-errors${C_OFF}.
  - Write down each cause as you find it. There is more than one.

${C_YEL}COMMANDS THAT WILL EARN THEIR KEEP${C_OFF}

  systemctl get-default
  systemctl status display-manager.service
  systemctl cat  ${DM_NAME}.service
  systemctl list-unit-files --type=service | grep -Ei 'gdm|lightdm|sddm|xdm'
  readlink -f /etc/systemd/system/display-manager.service
  ls -l /usr/share/xsessions/ /usr/share/wayland-sessions/
  loginctl list-sessions ; loginctl show-session <id> -p Type
  grep -R . /etc/X11/Xwrapper.config
  journalctl -b -u ${DM_UNIT:-display-manager.service} --no-pager
  ss -lntp | grep -E '5900|5901|177'

${C_GRN}When you are done, verify yourself:${C_OFF}   ${C_DIM}sudo $0 verify${C_OFF}
${C_GRN}Emergency reset (last resort):${C_OFF}         ${C_DIM}sudo $0 restore${C_OFF}

BRIEFING
}

# ===========================================================================
#  VERIFICATION — machine-checkable acceptance criteria
# ===========================================================================
verify() {
    local pass=0 fail=0
    check() {
        local label="$1"; shift
        if "$@" >/dev/null 2>&1; then
            printf '  %s[PASS]%s %s\n' "${C_GRN}" "${C_OFF}" "${label}"; ((pass++))
        else
            printf '  %s[FAIL]%s %s\n' "${C_RED}" "${C_OFF}" "${label}"; ((fail++))
        fi
    }

    echo
    log "Verifying the acceptance criteria for 106.2 ..."
    echo

    check "A. Default target is graphical.target" \
        bash -c '[[ "$(systemctl get-default)" == "graphical.target" ]]'

    check "B1. Display manager unit is active" \
        bash -c 'systemctl is-active --quiet display-manager.service'

    check "B2. No laboratory drop-in override remains" \
        bash -c '! ls /etc/systemd/system/*.service.d/99-lab-override.conf >/dev/null 2>&1'

    check "C. Xwrapper allows console/anybody users" \
        bash -c '! grep -qsE "^allowed_users=nobody" /etc/X11/Xwrapper.config'

    check "D1. At least one session desktop file exists" \
        bash -c 'ls /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop >/dev/null 2>&1'

    check "D2. No configuration still references the missing session" \
        bash -c '! grep -RqsE "corporate-(desktop|greeter)" /etc/lightdm /etc/sddm.conf.d /etc/sddm.conf /etc/gdm3 /etc/gdm 2>/dev/null'

    check "E. labvnc template is either valid or removed" \
        bash -c '! grep -qs "99999x99999" /etc/systemd/system/labvnc@.service'

    echo
    if [[ ${fail} -eq 0 ]]; then
        ok "All ${pass} checks passed. The graphical stack is restored."
        echo
        printf '  %sReboot once and confirm the greeter appears unattended:%s\n' "${C_DIM}" "${C_OFF}"
        printf '  %s  sudo systemctl reboot%s\n\n' "${C_DIM}" "${C_OFF}"
        return 0
    else
        warn "${fail} check(s) still failing, ${pass} passing. Keep going."
        echo
        return 1
    fi
}

# ===========================================================================
#  RESTORE — exact rollback from the manifest, for when the lab must end
# ===========================================================================
restore() {
    [[ -f "${MANIFEST}" ]] || die "No manifest at ${MANIFEST}. Nothing to restore."

    log "Restoring from ${MANIFEST} ..."
    local kind path a b
    while IFS=$'\t' read -r kind path a b; do
        case "${kind}" in
            FILE)
                if [[ -e "${BACKUP_DIR}${path}" ]]; then
                    mkdir -p "$(dirname "${path}")"
                    cp -a "${BACKUP_DIR}${path}" "${path}"
                    ok "  restored ${path}"
                fi
                ;;
            ABSENT)
                rm -f "${path}" && ok "  removed ${path} (did not exist originally)"
                ;;
            DROPIN)
                rm -rf "${path}" && ok "  removed drop-in directory ${path}"
                ;;
            UNITFILE)
                rm -f "${path}" && ok "  removed unit file ${path}"
                ;;
            DEFAULT_TARGET)
                systemctl set-default "${path}" >/dev/null 2>&1 \
                    && ok "  default target -> ${path}"
                ;;
            UNIT)
                systemctl daemon-reload >/dev/null 2>&1
                [[ "${a}" == "enabled" ]] && systemctl enable  "${path}" >/dev/null 2>&1
                [[ "${b}" == "active"  ]] && systemctl restart "${path}" >/dev/null 2>&1
                ok "  unit ${path} back to ${a}/${b}"
                ;;
        esac
    done < "${MANIFEST}"

    systemctl daemon-reload >/dev/null 2>&1
    ok "Restore complete. Reboot to confirm: systemctl reboot"
}

# ===========================================================================
#  ENTRY POINT
# ===========================================================================
usage() {
    cat <<EOF
Usage: sudo $0 <break|verify|restore|status>

  break     Inject the four faults and print the student briefing.
  verify    Check the acceptance criteria (safe to run repeatedly).
  restore   Roll back every change from the manifest. Last resort.
  status    Show the detected display manager / display server only.

Environment:
  LAB_ASSUME_YES=1   Skip the interactive confirmation (automation only).
EOF
}

main() {
    case "${1:-}" in
        break)
            require_root
            detect_display_manager
            detect_display_server
            print_environment
            refuse_on_non_lab_host
            check_ssh_lifeline
            confirm_or_abort
            init_state
            break_1_default_target
            break_2_xwrapper
            break_3_display_manager_unit
            break_4_session_and_remote_desktop
            print_briefing
            ;;
        verify)
            verify
            ;;
        restore)
            require_root
            restore
            ;;
        status)
            detect_display_manager
            detect_display_server
            print_environment
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"

# ===========================================================================
# ===========================================================================
#
#   S O L U T I O N   —   DO NOT READ UNTIL YOU HAVE TRIED
#
#   Everything below this line is commentary. It is the walk-through an
#   instructor would give after the student has spent time in the journal.
#
# ===========================================================================
# ===========================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 — Orient before you touch anything
# ---------------------------------------------------------------------------
#
#   The first question in every graphical-desktop incident is not "how do I
#   fix it" but "what is supposed to be running here". Three facts settle it:
#
#     $ systemctl get-default
#     multi-user.target
#
#     $ readlink -f /etc/systemd/system/display-manager.service
#     /lib/systemd/system/lightdm.service
#
#     $ loginctl list-sessions
#     SESSION  UID USER   SEAT  TTY
#           3 1000 student       pts/0
#
#   Read that carefully. The default target is multi-user, so systemd was
#   never asked to bring up a greeter at boot. display-manager.service is a
#   symlink — that symlink IS how a systemd distribution records "this is my
#   display manager"; on Debian the same choice is mirrored in
#   /etc/X11/default-display-manager. And the only session is a pts, i.e.
#   remote: nothing is attached to a seat, which is consistent with "no
#   graphical login".
#
#   Reference: https://www.freedesktop.org/software/systemd/man/systemd.special.html
#
# ---------------------------------------------------------------------------
# STEP 1 — Fault 1: the boot target
# ---------------------------------------------------------------------------
#
#   graphical.target pulls in display-manager.service; multi-user.target does
#   not. Restoring it:
#
#     $ sudo systemctl set-default graphical.target
#     Removed /etc/systemd/system/default.target.
#     Created symlink /etc/systemd/system/default.target -> /lib/systemd/system/graphical.target.
#
#   Verify — note that get-default reads the symlink, it does not change the
#   RUNNING state; isolate does that without a reboot:
#
#     $ systemctl get-default
#     graphical.target
#     $ sudo systemctl isolate graphical.target
#
#   On a legacy SysV-init system the equivalent is the initdefault line in
#   /etc/inittab (runlevel 5 vs 3). LPIC-1 still expects you to know both
#   spellings of the same idea.
#
# ---------------------------------------------------------------------------
# STEP 2 — Fault 3: the display manager unit will not exec
# ---------------------------------------------------------------------------
#
#   Isolating graphical.target now tries to start the DM and it fails loudly:
#
#     $ systemctl status lightdm.service
#     * lightdm.service - Light Display Manager
#          Loaded: loaded (/lib/systemd/system/lightdm.service; enabled)
#         Drop-In: /etc/systemd/system/lightdm.service.d
#                  `-99-lab-override.conf
#          Active: failed (Result: exit-code)
#         Process: 1421 ExecStart=/usr/sbin/lightdm-greeter-secure --config ...
#                  (code=exited, status=203/EXEC)
#
#   Two things in that output are the whole diagnosis. "Drop-In:" tells you
#   the vendor unit has been modified without being edited — this is why
#   reinstalling the package would NOT have helped, and why `systemctl cat`
#   is the correct reading tool rather than `cat` on the vendor file:
#
#     $ systemctl cat lightdm.service
#     # /lib/systemd/system/lightdm.service
#     ...
#     ExecStart=/usr/sbin/lightdm
#     ...
#     # /etc/systemd/system/lightdm.service.d/99-lab-override.conf
#     [Service]
#     ExecStart=
#     ExecStart=/usr/sbin/lightdm-greeter-secure --config /etc/lightdm/hardened.conf
#
#   And status=203/EXEC means systemd could not execute the binary at all —
#   not that the program ran and failed. 203 is "file missing or not
#   executable", every time. Confirm and remove the override:
#
#     $ ls -l /usr/sbin/lightdm-greeter-secure
#     ls: cannot access '/usr/sbin/lightdm-greeter-secure': No such file or directory
#
#     $ sudo rm -rf /etc/systemd/system/lightdm.service.d
#     $ sudo systemctl daemon-reload
#     $ sudo systemctl restart lightdm
#
#   The empty `ExecStart=` before the replacement is not decoration: in
#   systemd, ExecStart in a drop-in is additive for Type=oneshot and illegal
#   to specify twice otherwise, so the empty assignment is the documented way
#   to clear the vendor value. Recognising that idiom tells you immediately
#   that this was a hand-written override rather than package damage.
#
#   Reference: https://www.freedesktop.org/software/systemd/man/systemd.unit.html
#
# ---------------------------------------------------------------------------
# STEP 3 — Fault 2: X refuses to start for a normal user
# ---------------------------------------------------------------------------
#
#   With the DM running you may still see nothing on the console, and a
#   manual attempt is unambiguous:
#
#     $ startx
#     X.Org X Server 1.21.1.7
#     ...
#     Only console users are allowed to run the X server
#     xinit: giving up
#     xinit: unable to connect to X server: Connection refused
#     xinit: server error
#
#   That message comes from Xorg.wrap, the setuid helper, and it reads its
#   policy from /etc/X11/Xwrapper.config:
#
#     $ cat /etc/X11/Xwrapper.config
#     allowed_users=nobody
#     needs_root_rights=no
#
#   allowed_users takes exactly three values: `root`, `console` (the default
#   and the correct answer here — users logged in on a physical VT) and
#   `anybody`. `nobody` is not one of them, so nobody qualifies. Fix:
#
#     $ sudo tee /etc/X11/Xwrapper.config >/dev/null <<'EOF'
#     allowed_users=console
#     needs_root_rights=auto
#     EOF
#
#     $ sudo dpkg-reconfigure xserver-xorg-legacy   # the packaged way, Debian
#
#   Then retry from a real VT (Ctrl+Alt+F3), not from SSH — the whole point
#   of `console` is that a pts session does not satisfy it:
#
#     $ startx
#     (X starts; Ctrl+Alt+F7 / F1 returns to the greeter)
#
#   Reference: https://man.archlinux.org/man/Xwrapper.config.5
#
# ---------------------------------------------------------------------------
# STEP 4 — Fault 4a: the login loop
# ---------------------------------------------------------------------------
#
#   The greeter is back, you type the password, the screen blinks and you are
#   at the greeter again. Nothing in `systemctl status lightdm` looks wrong,
#   because the failure is in the user's session, not the daemon:
#
#     $ tail -n 20 ~/.xsession-errors
#     /usr/sbin/lightdm-session: 12: exec: corporate-desktop: not found
#
#     $ journalctl -b _COMM=lightdm | tail
#     lightdm[1522]: Session pid=1698: Exited with return value 127
#
#   127 is "command not found" from the shell — the same signal as 203/EXEC
#   one layer up. Now compare what was requested with what exists:
#
#     $ grep -R user-session /etc/lightdm/
#     /etc/lightdm/lightdm.conf.d/99-lab.conf:user-session=corporate-desktop
#
#     $ ls /usr/share/xsessions/
#     xfce.desktop
#     $ ls /usr/share/wayland-sessions/
#     (empty)
#
#   The seat is pinned to a session whose .desktop file was never installed.
#   The names in these directories, minus the .desktop suffix, are the only
#   legal values. Repair by pointing at a session that is actually present —
#   or simply by deleting the injected drop-in so the DM auto-selects:
#
#     $ sudo rm /etc/lightdm/lightdm.conf.d/99-lab.conf
#     $ sudo systemctl restart lightdm
#
#   The equivalents on the other display managers, for the exam:
#     - GDM:  /etc/gdm3/custom.conf   -> [daemon] DefaultSession=, WaylandEnable=
#     - SDDM: /etc/sddm.conf(.d/)     -> [Autologin] Session=, [General] DisplayServer=
#     - LightDM: /etc/lightdm/lightdm.conf(.d/) -> [Seat:*] user-session=, greeter-session=
#
#   Note WaylandEnable=false was also injected into GDM in this lab. It is
#   not a fault by itself — it is a legitimate switch — but you should be
#   able to state what it changes: it forces X11 sessions, which is exactly
#   what you want when debugging with tools that need an X server, and
#   exactly what breaks a Wayland-only compositor. Confirm which one you
#   ended up in with:
#
#     $ echo $XDG_SESSION_TYPE
#     x11
#     $ loginctl show-session $(loginctl list-sessions --no-legend | awk 'NR==1{print $1}') -p Type
#     Type=x11
#
#   Reference: https://wayland.freedesktop.org/docs/html/
#
# ---------------------------------------------------------------------------
# STEP 5 — Fault 4b: the remote desktop service
# ---------------------------------------------------------------------------
#
#     $ sudo systemctl start labvnc@student
#     Job for labvnc@student.service failed because the control process exited.
#
#     $ journalctl -u labvnc@student -n 20 --no-pager
#     vncserver: Invalid geometry 99999x99999
#     vncserver: Could not open password file /etc/vnc/nonexistent.passwd
#
#   Three separate defects in one ExecStart, and each maps to something the
#   objective expects you to know:
#
#     -geometry 99999x99999   nonsense resolution; use e.g. 1280x800.
#     -rfbauth <file>         the VNC password file must exist and be 0600.
#                             It is created with `vncpasswd`, not by hand.
#     -localhost no           exposes RFB (5900+display) on every interface
#                             in cleartext. VNC has no transport security;
#                             the production answer is -localhost yes plus an
#                             SSH tunnel: ssh -L 5901:localhost:5901 host.
#
#   A working unit, and the verification:
#
#     $ sudo -u student vncpasswd            # writes ~/.vnc/passwd, mode 0600
#     $ sudo sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/vncserver :1 -geometry 1280x800 -depth 24 -localhost yes|' \
#           /etc/systemd/system/labvnc@.service
#     $ sudo systemctl daemon-reload
#     $ sudo systemctl start labvnc@student
#     $ ss -lntp | grep 590
#     LISTEN 0 5 127.0.0.1:5901 0.0.0.0:* users:(("Xtigervnc",pid=2210,fd=7))
#
#   127.0.0.1, not 0.0.0.0 — that is the line to check. The alternative
#   accepted answer for criterion E is to remove the unit entirely:
#
#     $ sudo systemctl disable --now labvnc@student
#     $ sudo rm /etc/systemd/system/labvnc@.service && sudo systemctl daemon-reload
#
#   Know the neighbours too, because the objective lists them:
#     - XDMCP  — the X protocol's own remote login (port 177/udp). Historic,
#                unencrypted, disabled by default; you should be able to say
#                why it is off, not how to turn it on.
#     - RDP    — Microsoft's protocol; on Linux served by xrdp or by GNOME's
#                built-in gnome-remote-desktop. Encrypted, the modern choice.
#     - SPICE  — virtualisation-oriented (QEMU/KVM), with device redirection;
#                the right answer for a VM console, not for a workstation.
#
#   Reference: https://tigervnc.org/doc/vncserver.html
#
# ---------------------------------------------------------------------------
# STEP 6 — Prove it, then prove it survives a reboot
# ---------------------------------------------------------------------------
#
#     $ sudo /path/to/this-script.sh verify
#       [PASS] A. Default target is graphical.target
#       [PASS] B1. Display manager unit is active
#       [PASS] B2. No laboratory drop-in override remains
#       [PASS] C. Xwrapper allows console/anybody users
#       [PASS] D1. At least one session desktop file exists
#       [PASS] D2. No configuration still references the missing session
#       [PASS] E. labvnc template is either valid or removed
#
#     $ sudo systemctl reboot
#
#   A fix that passes only while you are logged in is not a fix. The reboot
#   is the acceptance test: set-default, the removed drop-in and the removed
#   greeter drop-in are all persistent-state changes, and the reboot is what
#   distinguishes them from a `systemctl isolate` that papered over the
#   problem for the length of your session.
#
# ---------------------------------------------------------------------------
# WHAT TO CARRY INTO THE EXAM
# ---------------------------------------------------------------------------
#
#   * The display manager is selected by the display-manager.service symlink
#     (and /etc/X11/default-display-manager on Debian), never by guesswork.
#   * graphical.target vs multi-user.target is the modern runlevel 5 vs 3.
#   * status=203/EXEC means the binary is missing; exit 127 from a session
#     script means the same thing one layer down.
#   * Xwrapper.config allowed_users is root | console | anybody.
#   * Available sessions live in /usr/share/xsessions and
#     /usr/share/wayland-sessions; DM configuration must name one of them.
#   * VNC is cleartext: bind it to localhost and tunnel over SSH. XDMCP is
#     legacy and unencrypted. RDP (xrdp) is the encrypted remote desktop.
#     SPICE belongs to the virtualisation stack.
#   * $XDG_SESSION_TYPE / loginctl show-session -p Type answers "X11 or
#     Wayland?" without guessing from process names.
#
# ===========================================================================