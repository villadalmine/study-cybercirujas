#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 (exams 101-500 + 102-500, version 5.0)
#  Topic 1.1 - System Architecture   |   Exam weight: 10
#  BREAK & FIX laboratory
# =============================================================================
#
#  WHAT THIS IS
#  ------------
#  A controlled sabotage harness. It injects a set of realistic, reversible
#  faults into a THROW-AWAY lab VM, prints the symptom the student will observe
#  and the objective they must reach, and then gets out of the way. Every fault
#  maps to a published LPI objective inside topic 1.1:
#
#    Fault A  101.1  Determine and configure hardware settings
#                    (kernel modules, /etc/modprobe.d, lsmod/modinfo/modprobe)
#    Fault B  101.2  Boot the system
#                    (kernel ring buffer, dmesg, journalctl -k, sysctl/procfs)
#    Fault C  101.3  Change runlevels / boot targets
#                    (default.target, systemctl get-default/set-default)
#    Fault D  101.3  Shutdown and reboot the system
#                    (masked units, systemctl reboot/poweroff, wall)
#    Fault E  101.2  Boot the system - HARD MODE, opt-in, needs console access
#                    (bootloader, kernel command line, GRUB 2 regeneration)
#
#  Reference: https://www.lpi.org/our-certifications/lpic-1-overview/
#             https://www.lpi.org/our-certifications/exam-101-objectives/
#
#  REQUIREMENTS
#  ------------
#    * A disposable virtual machine you are willing to destroy.
#    * root (or sudo) on that VM.
#    * systemd as PID 1 (this lab targets modern LPIC-1 v5.0 systems).
#    * Hypervisor console access if you enable HARD MODE (--hard), because
#      that fault is only repairable from the GRUB menu at boot time.
#
#  USAGE
#  -----
#    sudo ./lpic1-1.1-break-and-fix.sh break            # inject Faults A-D
#    sudo ./lpic1-1.1-break-and-fix.sh break --hard     # also inject Fault E
#    sudo ./lpic1-1.1-break-and-fix.sh brief            # reprint the briefing
#    sudo ./lpic1-1.1-break-and-fix.sh check            # grade yourself
#    sudo ./lpic1-1.1-break-and-fix.sh restore          # SPOILER: undo all
#
#  RULES OF ENGAGEMENT
#  -------------------
#    1. Do not run `restore`, and do not read the commented solution at the
#       bottom of this file, until `check` reports 0 open faults - or until
#       you have genuinely stalled for 20 minutes on one of them.
#    2. man pages, --help, journalctl and the /proc + /sys filesystems are
#       all fair game. That is the actual exam skill.
#    3. Everything the lab changed is backed up under /var/lib/lpic1-lab.
#       Reading those backups is legal and it is also cheating yourself.
#    4. Target time: 30-45 minutes for Faults A-D, +15 for Fault E.
#
#  SAFETY
#  ------
#    * Refuses to run outside a virtual machine unless --force is passed.
#    * Refuses to run without an interactive confirmation unless --yes.
#    * Never touches user data, partitions, filesystems or the network config.
#    * Every mutation is backed up before it happens and is undone by
#      `restore`. Faults A-D do not require a reboot to observe or to fix.
#
# =============================================================================

set -euo pipefail

readonly LAB_ID="lpic1-1.1"
readonly LAB_HOME="/var/lib/lpic1-lab/topic-1.1"
readonly BACKUP_DIR="${LAB_HOME}/backup"
readonly STATE_FILE="${LAB_HOME}/state"
readonly BROKEN_UNIT="lpic1-lab-broken.target"
readonly MODPROBE_CONF="/etc/modprobe.d/99-${LAB_ID}.conf"
readonly SYSCTL_CONF="/etc/sysctl.d/99-${LAB_ID}.conf"

HARD_MODE=0
ASSUME_YES=0
FORCE=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()  { printf '%s[ lab ]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '%s[ ok  ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[warn ]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[error]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

hr()      { printf '%s\n' "-------------------------------------------------------------------------------"; }
heading() { hr; printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; hr; }

# ---------------------------------------------------------------------------
# State handling (idempotency: every action can be re-run safely)
# ---------------------------------------------------------------------------
state_set() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp)"
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
}

state_get() {
    local key="$1"
    [[ -f "$STATE_FILE" ]] || return 0
    sed -n "s/^${key}=//p" "$STATE_FILE" | tail -n1
}

backup_file() {
    # Copies a file (or symlink, verbatim) once. Later calls are no-ops, so a
    # second `break` never overwrites a pristine backup with a broken one.
    local src="$1" dst
    dst="${BACKUP_DIR}/$(printf '%s' "${src#/}" | tr '/' '_')"
    [[ -e "$dst" || -e "${dst}.absent" ]] && return 0
    if [[ -e "$src" || -L "$src" ]]; then
        cp -a --no-dereference "$src" "$dst"
    else
        : > "${dst}.absent"
    fi
}

restore_file() {
    local src="$1" dst
    dst="${BACKUP_DIR}/$(printf '%s' "${src#/}" | tr '/' '_')"
    if [[ -e "${dst}.absent" ]]; then
        rm -f "$src"
    elif [[ -e "$dst" || -L "$dst" ]]; then
        cp -a --no-dereference "$dst" "$src"
    fi
}

has() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Pre-flight guards
# ---------------------------------------------------------------------------
preflight() {
    [[ ${EUID} -eq 0 ]] || die "This lab must run as root. Try: sudo $0 $*"

    [[ -d /run/systemd/system ]] || \
        die "systemd is not PID 1. This lab targets systemd-based distributions."

    local virt="unknown"
    if has systemd-detect-virt; then
        virt="$(systemd-detect-virt || true)"
    fi
    if [[ "$virt" == "none" && ${FORCE} -eq 0 ]]; then
        err "systemd-detect-virt reports bare metal, not a virtual machine."
        err "This script deliberately damages the running system."
        die  "If this really is a disposable host, re-run with --force."
    fi

    mkdir -p "$BACKUP_DIR"
    chmod 0700 "$LAB_HOME"
}

confirm() {
    [[ ${ASSUME_YES} -eq 1 ]] && return 0
    printf '\n%sThis will deliberately break the running system (%s).%s\n' \
        "$C_YELLOW" "$(hostname)" "$C_RESET"
    printf 'Type exactly: %sBREAK MY LAB VM%s to continue: ' "$C_BOLD" "$C_RESET"
    local answer
    read -r answer
    [[ "$answer" == "BREAK MY LAB VM" ]] || die "Aborted. Nothing was changed."
}

# ---------------------------------------------------------------------------
# FAULT A - 101.1: a kernel module that refuses to load
# ---------------------------------------------------------------------------
pick_module() {
    # Choose a module that exists on this kernel and is not currently in use,
    # so unloading it cannot disturb anything that matters.
    local m used
    for m in dummy vfat loop cifs nfs; do
        modinfo "$m" >/dev/null 2>&1 || continue
        used="$(lsmod | awk -v mod="$m" '$1 == mod { print $3 }')"
        [[ -n "$used" && "$used" -gt 0 ]] && continue
        printf '%s' "$m"
        return 0
    done
    return 1
}

break_fault_a() {
    local mod
    mod="$(state_get MODULE)"
    if [[ -z "$mod" ]]; then
        mod="$(pick_module)" || { warn "Fault A skipped: no safe module found."; return 0; }
        state_set MODULE "$mod"
    fi

    backup_file "$MODPROBE_CONF"
    cat > "$MODPROBE_CONF" <<EOF
# ${LAB_ID} - lab fault A. Two different mechanisms, both documented in
# modprobe.d(5). Removing only one of them is not enough.
blacklist ${mod}
install ${mod} /bin/false
EOF
    modprobe -r "$mod" >/dev/null 2>&1 || true
    depmod -a >/dev/null 2>&1 || true
    state_set FAULT_A applied
    log "Fault A armed on module '${mod}'."
}

check_fault_a() {
    local mod
    mod="$(state_get MODULE)"
    [[ -n "$mod" ]] || return 0
    if lsmod | awk '{print $1}' | grep -qx "$mod"; then return 0; fi
    modprobe "$mod" >/dev/null 2>&1
}

restore_fault_a() {
    restore_file "$MODPROBE_CONF"
    depmod -a >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# FAULT B - 101.2: the kernel ring buffer becomes unreadable
# ---------------------------------------------------------------------------
break_fault_b() {
    backup_file "$SYSCTL_CONF"
    state_set DMESG_RESTRICT_ORIG "$(sysctl -n kernel.dmesg_restrict 2>/dev/null || echo 0)"
    cat > "$SYSCTL_CONF" <<EOF
# ${LAB_ID} - lab fault B
kernel.dmesg_restrict = 1
EOF
    sysctl -q -w kernel.dmesg_restrict=1
    state_set FAULT_B applied
    log "Fault B armed (kernel.dmesg_restrict = 1)."
}

check_fault_b() {
    [[ "$(sysctl -n kernel.dmesg_restrict 2>/dev/null || echo 0)" == "0" ]]
}

restore_fault_b() {
    restore_file "$SYSCTL_CONF"
    sysctl -q -w "kernel.dmesg_restrict=$(state_get DMESG_RESTRICT_ORIG || echo 0)" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# FAULT C - 101.3: default.target points into the void
# ---------------------------------------------------------------------------
break_fault_c() {
    local current
    current="$(systemctl get-default 2>/dev/null || echo multi-user.target)"
    [[ -n "$(state_get DEFAULT_TARGET)" ]] || state_set DEFAULT_TARGET "$current"

    backup_file /etc/systemd/system/default.target
    ln -sfn "/etc/systemd/system/${BROKEN_UNIT}" /etc/systemd/system/default.target
    systemctl daemon-reload
    state_set FAULT_C applied
    log "Fault C armed (default.target -> ${BROKEN_UNIT}, which does not exist)."
}

check_fault_c() {
    local def
    def="$(systemctl get-default 2>/dev/null || true)"
    [[ -n "$def" ]] || return 1
    systemctl cat "$def" >/dev/null 2>&1
}

restore_fault_c() {
    local orig
    orig="$(state_get DEFAULT_TARGET)"
    rm -f /etc/systemd/system/default.target
    restore_file /etc/systemd/system/default.target
    if ! check_fault_c; then
        systemctl set-default "${orig:-multi-user.target}" >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# FAULT D - 101.3: the machine can no longer be rebooted the normal way
# ---------------------------------------------------------------------------
break_fault_d() {
    systemctl mask reboot.target >/dev/null 2>&1
    state_set FAULT_D applied
    log "Fault D armed (reboot.target masked)."
}

check_fault_d() {
    [[ "$(systemctl is-enabled reboot.target 2>/dev/null || true)" != "masked" ]]
}

restore_fault_d() {
    systemctl unmask reboot.target >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# FAULT E - 101.2 HARD MODE: a poisoned kernel command line
# ---------------------------------------------------------------------------
grub_cfg_path() {
    local c
    for c in /boot/grub/grub.cfg /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg; do
        if [[ -f "$c" ]]; then printf '%s' "$c"; return 0; fi
    done
    return 1
}

regen_grub() {
    local cfg
    cfg="$(grub_cfg_path || true)"
    if has update-grub; then
        update-grub
    elif has grub-mkconfig; then
        grub-mkconfig -o "${cfg:-/boot/grub/grub.cfg}"
    elif has grub2-mkconfig; then
        grub2-mkconfig -o "${cfg:-/boot/grub2/grub.cfg}"
    else
        warn "No GRUB 2 generator found; the bootloader was left untouched."
        return 1
    fi
}

set_grub_kv() {
    local key="$1" value="$2" file=/etc/default/grub
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

break_fault_e() {
    if has grubby && [[ -d /boot/loader/entries ]]; then
        # Fedora / RHEL / CentOS Stream with BLS snippets: /etc/default/grub is
        # not authoritative for kernel arguments, grubby is.
        grubby --update-kernel=ALL --args="systemd.unit=${BROKEN_UNIT}" >/dev/null
        state_set GRUB_METHOD grubby
    else
        [[ -f /etc/default/grub ]] || { warn "Fault E skipped: no /etc/default/grub."; return 0; }
        backup_file /etc/default/grub
        if grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            sed -i -E "s|^([[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=\")(.*)(\")|\1\2 systemd.unit=${BROKEN_UNIT}\3|" \
                /etc/default/grub
        else
            printf 'GRUB_CMDLINE_LINUX_DEFAULT="systemd.unit=%s"\n' "$BROKEN_UNIT" >> /etc/default/grub
        fi
        # Deliberate kindness: guarantee the menu is visible, otherwise the
        # fault is unrecoverable without a rescue ISO.
        set_grub_kv GRUB_TIMEOUT 10
        set_grub_kv GRUB_TIMEOUT_STYLE menu
        regen_grub >/dev/null || true
        state_set GRUB_METHOD default-grub
    fi
    state_set FAULT_E applied
    log "Fault E armed (kernel command line carries systemd.unit=${BROKEN_UNIT})."
}

check_fault_e() {
    [[ "$(state_get FAULT_E)" == "applied" ]] || return 0
    # Persistent configuration must be clean...
    if has grubby && [[ -d /boot/loader/entries ]]; then
        grubby --info=ALL 2>/dev/null | grep -q "$BROKEN_UNIT" && return 1
    fi
    local cfg
    cfg="$(grub_cfg_path || true)"
    if [[ -n "$cfg" ]] && grep -q "$BROKEN_UNIT" "$cfg"; then return 1; fi
    if [[ -f /etc/default/grub ]] && grep -q "$BROKEN_UNIT" /etc/default/grub; then return 1; fi
    # ...and the currently running kernel must have booted without it.
    grep -q "$BROKEN_UNIT" /proc/cmdline && return 1
    return 0
}

restore_fault_e() {
    [[ "$(state_get FAULT_E)" == "applied" ]] || return 0
    if [[ "$(state_get GRUB_METHOD)" == "grubby" ]]; then
        grubby --update-kernel=ALL --remove-args="systemd.unit" >/dev/null 2>&1 || true
    else
        restore_file /etc/default/grub
        regen_grub >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Student briefing
# ---------------------------------------------------------------------------
briefing() {
    local mod
    mod="$(state_get MODULE)"; mod="${mod:-<module>}"

    heading "LPIC-1 v5.0 | Topic 1.1 System Architecture | BREAK & FIX BRIEFING"
    cat <<EOF
Four faults (five with --hard) are now live on this VM. Nothing else was
touched. Each one below states the SYMPTOM you can reproduce right now and the
OBJECTIVE that defines "fixed". Run '$0 check' at any time to grade yourself.

${C_BOLD}FAULT A - 101.1 Determine and configure hardware settings${C_RESET}
  Symptom : Loading the kernel module '${mod}' fails.
              # modprobe ${mod}
              modprobe: ERROR: could not insert '${mod}': ...
            'lsmod | grep ${mod}' returns nothing, yet 'modinfo ${mod}' proves
            the module file is installed on disk. The hardware/feature that
            depends on it is therefore unavailable.
  Objective: '${mod}' loads cleanly with 'modprobe ${mod}' and appears in
            'lsmod', and it will still load after the next reboot. Two separate
            directives are blocking it, in two different ways - find both.
  Think about: modprobe.d(5), 'modprobe -c', 'modprobe --show-depends',
            the difference between 'blacklist' and 'install <mod> /bin/false'.

${C_BOLD}FAULT B - 101.2 Boot the system${C_RESET}
  Symptom : As a normal (non-root) user, reading boot messages fails:
              \$ dmesg
              dmesg: read kernel buffer failed: Operation not permitted
            Root can still read it, so the ring buffer itself is intact.
  Objective: Any unprivileged user can run 'dmesg' again, and the change
            survives a reboot. Do not solve it by making users root.
  Think about: /proc/sys, sysctl(8), sysctl.d(5), 'sysctl -a | grep dmesg',
            'journalctl -k' as the alternative source of the same data.

${C_BOLD}FAULT C - 101.3 Change runlevels / boot targets${C_RESET}
  Symptom : # systemctl get-default
              ${BROKEN_UNIT}
            # systemctl isolate default.target
              Failed to isolate default.target: Unit ${BROKEN_UNIT} not found.
            WARNING: as it stands, the next boot will NOT reach a normal target.
  Objective: 'systemctl get-default' names a target that actually exists, and
            'systemctl cat \$(systemctl get-default)' prints a real unit file.
            Choose the target this machine is supposed to run (a host with an
            enabled display manager wants graphical.target; a server wants
            multi-user.target - runlevel 3 in SysV terms).
  Think about: 'ls -l /etc/systemd/system/default.target', 'systemctl
            set-default', 'systemctl list-units --type=target', runlevel(7).
  Escape hatch: if you reboot before fixing this and land in emergency mode,
            interrupt GRUB, press 'e', and append systemd.unit=multi-user.target
            to the linux line. That is objective 101.2 in action.

${C_BOLD}FAULT D - 101.3 Shutdown and reboot the system${C_RESET}
  Symptom : # systemctl reboot
              Failed to start reboot.target: Unit reboot.target is masked.
            'poweroff' still works, so the machine can be stopped but not
            cycled - the classic way to lose a remote host for good.
  Objective: 'systemctl reboot' is accepted again (do NOT test it until every
            other fault is fixed), and 'systemctl is-enabled reboot.target'
            no longer reports 'masked'.
  Think about: 'systemctl list-unit-files --state=masked', what a mask really
            is on disk (hint: 'ls -l /etc/systemd/system/reboot.target'),
            mask vs disable, and 'systemctl unmask'.

EOF

    if [[ "$(state_get FAULT_E)" == "applied" ]]; then
        cat <<EOF
${C_BOLD}FAULT E - 101.2 Boot the system (HARD MODE - console required)${C_RESET}
  Symptom : Nothing is wrong until you reboot. On the next boot the kernel is
            handed 'systemd.unit=${BROKEN_UNIT}', systemd cannot load it and
            drops into emergency mode asking for the root password (or loops).
            Confirm the trap without rebooting:
              # grep -o 'systemd.unit=[^ ]*' /proc/cmdline   (running kernel)
              # grubby --info=ALL   |or|   grep systemd.unit /boot/grub*/grub.cfg
  Objective: The VM boots unattended into its normal target, and neither the
            generated grub.cfg / BLS entries nor /etc/default/grub still carry
            the bogus parameter. 'grep ${BROKEN_UNIT} /proc/cmdline' must come
            back empty after that boot.
  Think about: editing an entry at the GRUB menu with 'e' is a ONE-TIME
            override - the permanent fix lives in /etc/default/grub plus
            grub-mkconfig/update-grub, or in grubby on BLS-based distros.
            grub-mkconfig(8), grubby(8), bootparam(7), /proc/cmdline.

EOF
    fi

    cat <<EOF
${C_BOLD}SUGGESTED TRIAGE ORDER${C_RESET}
  C and E first (they decide whether the machine comes back at all), then A,
  then B, then D. Verify with '$0 check' before you ever type 'reboot'.

  Grade yourself : sudo $0 check
  Give up (spoiler): sudo $0 restore
EOF
    hr
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_break() {
    preflight
    confirm
    heading "Injecting faults"
    state_set LAB "$LAB_ID"
    break_fault_a
    break_fault_b
    break_fault_c
    break_fault_d
    if [[ ${HARD_MODE} -eq 1 ]]; then
        break_fault_e
    else
        log "Fault E (bootloader) not armed. Re-run with --hard to include it."
    fi
    echo
    briefing
}

report() {
    local name="$1" desc="$2"
    if "check_fault_${name}"; then
        printf '  %s[FIXED]%s  Fault %s - %s\n' "$C_GREEN" "$C_RESET" "${name^^}" "$desc"
        return 0
    fi
    printf '  %s[OPEN ]%s  Fault %s - %s\n' "$C_RED" "$C_RESET" "${name^^}" "$desc"
    return 1
}

do_check() {
    [[ -f "$STATE_FILE" ]] || die "No lab state found. Run '$0 break' first."
    local open=0
    heading "Scoreboard"
    report a "kernel module '$(state_get MODULE)' loadable"        || open=$((open+1))
    report b "kernel ring buffer readable by normal users"         || open=$((open+1))
    report c "default.target resolves to a real unit"              || open=$((open+1))
    report d "reboot.target not masked"                            || open=$((open+1))
    if [[ "$(state_get FAULT_E)" == "applied" ]]; then
        report e "kernel command line clean, on disk and running"  || open=$((open+1))
    fi
    hr
    if [[ ${open} -eq 0 ]]; then
        ok "All faults repaired. Now prove it: reboot and re-run '$0 check'."
        return 0
    fi
    warn "${open} fault(s) still open."
    return 1
}

do_restore() {
    preflight
    heading "Restoring the original configuration (spoiler path)"
    restore_fault_e
    restore_fault_d
    restore_fault_c
    restore_fault_b
    restore_fault_a
    systemctl daemon-reload || true
    ok "System restored. Verify with '$0 check', then reboot to confirm."
}

usage() {
    sed -n '2,60p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
    exit 0
}

main() {
    local action="${1:-}"
    [[ $# -gt 0 ]] && shift || true
    local arg
    for arg in "$@"; do
        case "$arg" in
            --hard)  HARD_MODE=1 ;;
            --yes|-y) ASSUME_YES=1 ;;
            --force) FORCE=1 ;;
            *) die "Unknown option: $arg" ;;
        esac
    done

    case "$action" in
        break)   do_break ;;
        brief)   [[ -f "$STATE_FILE" ]] || die "No lab state found."; briefing ;;
        check)   do_check ;;
        restore) do_restore ;;
        -h|--help|help|"") usage ;;
        *) die "Unknown action '$action'. Try: $0 --help" ;;
    esac
}

main "$@"
exit 0

# =============================================================================
#  SOLUTION - DO NOT READ UNTIL '$0 check' REPORTS ZERO OPEN FAULTS
# =============================================================================
#
# -----------------------------------------------------------------------------
# STEP 0. Triage methodology (what a professional does before touching anything)
# -----------------------------------------------------------------------------
#   The single most useful reflex on a sabotaged box is "what changed recently
#   under /etc?". Nothing here required root-kit-level hiding, so:
#
#     # find /etc/modprobe.d /etc/sysctl.d /etc/systemd/system /etc/default \
#           -newermt '-2 hours' -printf '%T+ %p\n' 2>/dev/null | sort
#     2026-08-06+10:41:02 /etc/modprobe.d/99-lpic1-1.1.conf
#     2026-08-06+10:41:02 /etc/sysctl.d/99-lpic1-1.1.conf
#     2026-08-06+10:41:03 /etc/systemd/system/default.target
#     2026-08-06+10:41:03 /etc/systemd/system/reboot.target
#
#   Complement it with the four state questions of topic 1.1:
#     # systemctl get-default                 # which target do we boot into?
#     # systemctl --failed                    # what is broken right now?
#     # systemctl list-unit-files --state=masked
#     # cat /proc/cmdline                     # what did the kernel receive?
#     # systemd-analyze blame | head          # what cost us boot time?
#     # journalctl -k -b -p err               # kernel errors this boot
#
#   Note that dmesg vs journalctl -k read the SAME ring buffer through two
#   different interfaces; when one is denied, try the other before concluding
#   the data is gone.
#
# -----------------------------------------------------------------------------
# FAULT A - the module that will not load (objective 101.1)
# -----------------------------------------------------------------------------
#   Diagnosis. Prove the module exists on disk, then ask modprobe what rules it
#   is applying - do NOT just grep /etc/modprobe.d by hand, `modprobe -c` shows
#   the effective, merged configuration from every directory:
#
#     # modinfo dummy | head -3
#     filename:       /lib/modules/6.8.0-45-generic/kernel/drivers/net/dummy.ko.zst
#     alias:          rtnl-link-dummy
#     license:        GPL
#
#     # modprobe dummy
#     modprobe: ERROR: could not insert 'dummy': Operation not permitted
#
#     # modprobe -c | grep -w dummy
#     blacklist dummy
#     install dummy /bin/false
#
#     # modprobe --show-depends dummy
#     install /bin/false
#
#   Two distinct mechanisms are in play and they are NOT equivalent:
#     * `blacklist dummy` only suppresses AUTOMATIC loading (udev/alias-driven).
#       An explicit `modprobe dummy` would still succeed.
#     * `install dummy /bin/false` replaces the load action itself with a
#       command that always fails, which is what blocks the explicit attempt.
#   Removing only the blacklist line leaves the module still unloadable - that
#   is the trap, and it is a classic exam distinction.
#
#   Repair:
#     # grep -rn 'dummy' /etc/modprobe.d/ /lib/modprobe.d/ /run/modprobe.d/ 2>/dev/null
#     /etc/modprobe.d/99-lpic1-1.1.conf:3:blacklist dummy
#     /etc/modprobe.d/99-lpic1-1.1.conf:4:install dummy /bin/false
#
#     # rm -f /etc/modprobe.d/99-lpic1-1.1.conf     # or comment out both lines
#     # depmod -a                                   # rebuild modules.dep
#     # modprobe dummy
#     # lsmod | grep -w dummy
#     dummy                  16384  0
#
#   Verification that it also survives a reboot:
#     # modprobe -c | grep -w dummy      # must return nothing
#     # modprobe -r dummy && modprobe dummy && echo "reload OK"
#
#   Production note: on a real host you would first ask WHY the blacklist was
#   there. Vendors ship blacklists in /lib/modprobe.d and /usr/lib/modprobe.d;
#   files in /etc/modprobe.d override them by filename precedence. Deleting a
#   vendor blacklist for, say, nouveau on a machine running the proprietary
#   NVIDIA driver would replace one outage with a worse one.
#
# -----------------------------------------------------------------------------
# FAULT B - dmesg denied to unprivileged users (objective 101.2)
# -----------------------------------------------------------------------------
#   Diagnosis. "Operation not permitted" for a read that root can do points at
#   a kernel tunable, not at file permissions:
#
#     $ dmesg | tail -2
#     dmesg: read kernel buffer failed: Operation not permitted
#
#     # sysctl -a 2>/dev/null | grep -i dmesg
#     kernel.dmesg_restrict = 1
#
#     # cat /proc/sys/kernel/dmesg_restrict
#     1
#
#   /proc/sys/kernel/dmesg_restrict = 1 means CAP_SYSLOG is required to read the
#   ring buffer. Find where the value is being set persistently - sysctl reads,
#   in order: /etc/sysctl.d/, /run/sysctl.d/, /usr/lib/sysctl.d/, /etc/sysctl.conf.
#
#     # grep -rn dmesg_restrict /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ 2>/dev/null
#     /etc/sysctl.d/99-lpic1-1.1.conf:2:kernel.dmesg_restrict = 1
#
#   Repair - the runtime value AND the persistent one, in that order:
#     # rm -f /etc/sysctl.d/99-lpic1-1.1.conf
#     # sysctl -w kernel.dmesg_restrict=0
#     kernel.dmesg_restrict = 0
#     # sysctl --system | tail -3          # re-read every config directory
#     $ dmesg | tail -1                    # as a normal user again
#     [   12.884213] systemd[1]: Started Journal Service.
#
#   Fixing only the runtime value (`sysctl -w`) is the most common half-fix:
#   it reverts on the next boot. Fixing only the file leaves the box broken
#   until the next boot. Both, always.
#
#   Production note: dmesg_restrict=1 is a legitimate hardening setting shipped
#   by several distributions; `journalctl -k` served by systemd-journald, plus
#   membership in the 'adm'/'systemd-journal' group, is the correct way to give
#   operators read access without turning the tunable off globally.
#
# -----------------------------------------------------------------------------
# FAULT C - default.target points at a unit that does not exist (objective 101.3)
# -----------------------------------------------------------------------------
#   Diagnosis:
#     # systemctl get-default
#     lpic1-lab-broken.target
#
#     # ls -l /etc/systemd/system/default.target
#     lrwxrwxrwx 1 root root 45 Aug  6 10:41 /etc/systemd/system/default.target
#         -> /etc/systemd/system/lpic1-lab-broken.target
#
#     # systemctl cat lpic1-lab-broken.target
#     No files found for lpic1-lab-broken.target.
#
#   default.target is nothing but a symlink; systemd resolves it at boot and,
#   when it cannot, falls back to rescue/emergency mode - which on a headless
#   VM means "no network, root password prompt on the console only".
#
#   Decide the correct target first. Runlevel equivalences worth memorising:
#     runlevel 0 -> poweroff.target      runlevel 3 -> multi-user.target
#     runlevel 1 -> rescue.target        runlevel 5 -> graphical.target
#     runlevel 2,4 -> multi-user.target  runlevel 6 -> reboot.target
#
#     # systemctl list-units --type=target --all | head
#     # systemctl is-enabled gdm.service 2>/dev/null   # a display manager?
#
#   If a display manager is enabled the machine wants graphical.target;
#   otherwise multi-user.target. Repair:
#
#     # systemctl set-default multi-user.target
#     Removed /etc/systemd/system/default.target.
#     Created symlink /etc/systemd/system/default.target -> /usr/lib/systemd/system/multi-user.target.
#
#     # systemctl get-default
#     multi-user.target
#     # systemctl cat default.target | head -3
#     # /usr/lib/systemd/system/multi-user.target
#     [Unit]
#     Description=Multi-User System
#
#   The equivalent manual operation, useful when systemctl itself misbehaves:
#     # ln -sfn /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
#     # systemctl daemon-reload
#
#   To change target only for the current session (no persistence):
#     # systemctl isolate multi-user.target
#   To change it only for the NEXT boot, from the GRUB menu, append to the
#   linux line:  systemd.unit=multi-user.target
#
# -----------------------------------------------------------------------------
# FAULT D - reboot.target is masked (objective 101.3)
# -----------------------------------------------------------------------------
#   Diagnosis:
#     # systemctl reboot
#     Failed to start reboot.target: Unit reboot.target is masked.
#
#     # systemctl is-enabled reboot.target
#     masked
#     # systemctl list-unit-files --state=masked
#     reboot.target   masked   enabled
#     # ls -l /etc/systemd/system/reboot.target
#     lrwxrwxrwx 1 root root 9 Aug  6 10:41 /etc/systemd/system/reboot.target -> /dev/null
#
#   A mask is a symlink to /dev/null in /etc/systemd/system, which shadows the
#   vendor unit in /usr/lib/systemd/system and makes the unit impossible to
#   start by any means - including as a dependency. That is exactly how it
#   differs from `disable`, which only removes the wants/requires symlinks and
#   still allows a manual start.
#
#   Repair:
#     # systemctl unmask reboot.target
#     Removed /etc/systemd/system/reboot.target.
#     # systemctl is-enabled reboot.target
#     static
#
#   Escape hatch worth knowing for a real incident: `systemctl reboot --force`
#   bypasses the normal job (it kills processes and calls reboot(2) directly),
#   and `--force --force` / `reboot -ff` issues the syscall with no unmounting
#   at all - data-losing, last-resort, but it will always cycle the machine.
#
#   Sanity check the whole shutdown family before you trust it:
#     # systemctl list-unit-files 'poweroff.target' 'reboot.target' 'halt.target'
#     # shutdown -r +1 "LPIC-1 lab verification reboot"
#     # shutdown -c                       # cancel a pending shutdown
#
# -----------------------------------------------------------------------------
# FAULT E - poisoned kernel command line (objective 101.2, HARD MODE)
# -----------------------------------------------------------------------------
#   PHASE 1 - get the machine to boot at all (one-time override).
#     1. Reboot and interrupt GRUB (Esc / Shift on BIOS, arrow keys on EFI).
#     2. Highlight the normal entry and press 'e' to edit it in place.
#     3. Find the line starting with 'linux' (or 'linuxefi'). It ends with
#        something like:  ro quiet splash systemd.unit=lpic1-lab-broken.target
#     4. Delete the systemd.unit=... token. If you want a minimal, guaranteed
#        boot, also append:  systemd.unit=multi-user.target
#     5. Ctrl-x (or F10) to boot. This edit is NOT persistent - it exists only
#        in GRUB's memory for this one boot, which is precisely why it is the
#        safe first move.
#
#   PHASE 2 - confirm what you are looking at, from the booted system:
#     # cat /proc/cmdline
#     BOOT_IMAGE=/vmlinuz-6.8.0-45-generic root=UUID=... ro quiet splash
#     # systemd-analyze cat-config systemd/system.conf | head -5   # unrelated but handy
#
#   PHASE 3 - remove the parameter permanently. Which file is authoritative
#   depends on the distribution family:
#
#   (a) Debian / Ubuntu / openSUSE - /etc/default/grub drives grub-mkconfig:
#         # grep -n systemd.unit /etc/default/grub
#         6:GRUB_CMDLINE_LINUX_DEFAULT="quiet splash systemd.unit=lpic1-lab-broken.target"
#         # sed -i 's/ systemd.unit=lpic1-lab-broken.target//' /etc/default/grub
#         # update-grub            # wrapper for: grub-mkconfig -o /boot/grub/grub.cfg
#         Generating grub configuration file ...
#         Found linux image: /boot/vmlinuz-6.8.0-45-generic
#         done
#         # grep -c systemd.unit /boot/grub/grub.cfg
#         0
#       NEVER edit /boot/grub/grub.cfg by hand: it carries a "DO NOT EDIT THIS
#       FILE" banner and the next kernel upgrade regenerates it, silently
#       reintroducing the fault.
#
#   (b) Fedora / RHEL / CentOS Stream with BootLoaderSpec entries - the kernel
#       arguments live in /boot/loader/entries/*.conf and are managed by grubby:
#         # grubby --info=ALL | grep args
#         args="ro rhgb quiet systemd.unit=lpic1-lab-broken.target"
#         # grubby --update-kernel=ALL --remove-args="systemd.unit"
#         # grubby --info=ALL | grep args
#         args="ro rhgb quiet"
#       Editing /etc/default/grub alone on these systems fixes nothing for the
#       already-installed kernels - a very common real-world mistake.
#
#   PHASE 4 - prove it:
#         # reboot                      # unattended this time, no GRUB editing
#         ... after it comes back ...
#         # grep -c lpic1-lab-broken /proc/cmdline
#         0
#         # systemctl get-default && systemctl is-system-running
#         multi-user.target
#         running
#
#   Useful kernel parameters to recognise on the exam and in incidents
#   (bootparam(7), systemd(1) "Kernel Command Line"):
#     systemd.unit=<target>    boot into an arbitrary target for one boot
#     rd.break / init=/bin/bash    drop to a shell before/instead of PID 1
#     ro / rw                  initial root mount mode
#     quiet / debug            console verbosity
#     nomodeset                disable kernel mode setting (broken display)
#     systemd.log_level=debug  verbose PID 1, pairs with journalctl -b
#
# -----------------------------------------------------------------------------
# FINAL VERIFICATION
# -----------------------------------------------------------------------------
#     # sudo ./lpic1-1.1-break-and-fix.sh check
#       [FIXED]  Fault A - kernel module 'dummy' loadable
#       [FIXED]  Fault B - kernel ring buffer readable by normal users
#       [FIXED]  Fault C - default.target resolves to a real unit
#       [FIXED]  Fault D - reboot.target not masked
#       [FIXED]  Fault E - kernel command line clean, on disk and running
#     # sudo reboot            # the real exam: does it come back on its own?
#     # sudo ./lpic1-1.1-break-and-fix.sh check     # still all FIXED
#
#   The one-shot spoiler path, for when you are out of time:
#     # sudo ./lpic1-1.1-break-and-fix.sh restore
#   Originals are kept verbatim in /var/lib/lpic1-lab/topic-1.1/backup/.
#
# -----------------------------------------------------------------------------
# EXTRA CREDIT (same topic, no extra sabotage needed)
# -----------------------------------------------------------------------------
#   1. Inventory the hardware the way 101.1 expects: lspci -nnk, lsusb, lsmod,
#      lsblk, dmidecode -t system, and /proc/{cpuinfo,meminfo,interrupts,ioports}.
#      For each device found with lspci -k, name the kernel module driving it.
#   2. Measure the boot you just repaired: systemd-analyze, systemd-analyze
#      blame, systemd-analyze critical-chain, systemd-analyze plot > boot.svg.
#   3. Compare 'dmesg -T --level=err,warn' with 'journalctl -k -b -1 -p warning'
#      and explain why the second one survives a reboot and the first does not.
#   4. Re-run the lab with --hard, and this time fix Fault E without ever
#      editing the GRUB menu - only from a rescue ISO with chroot. That is the
#      skill that saves a machine whose bootloader menu is genuinely gone.
#
# Sources:
#   https://www.lpi.org/our-certifications/lpic-1-overview/
#   https://www.lpi.org/our-certifications/exam-101-objectives/
#   https://man7.org/linux/man-pages/man5/modprobe.d.5.html
#   https://man7.org/linux/man-pages/man8/sysctl.8.html
#   https://man7.org/linux/man-pages/man7/bootparam.7.html
#   https://www.freedesktop.org/software/systemd/man/systemd.special.html
#   https://www.gnu.org/software/grub/manual/grub/grub.html
# =============================================================================