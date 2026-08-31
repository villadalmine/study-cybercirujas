#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-1 (Exam 101-500 / 102-500, version 5.0)
#  Topic 106.3 -- Accessibility
#  Weight: 0 (deprecated in syllabus v5.0, still examinable knowledge on
#             legacy 4.0 material and *very* real in production desktops)
#
#  BREAK & FIX LAB -- accessibility subsystem sabotage
#
#  Reference: https://www.lpi.org/our-certifications/exam-101-objectives/
#             https://www.lpi.org/our-certifications/exam-102-objectives/
#
# ----------------------------------------------------------------------------
#  !!  DESTRUCTIVE  !!  RUN ONLY ON A DISPOSABLE LAB VM.
#  This script deliberately corrupts X11 / AccessX / AT-SPI / systemd-logind
#  configuration. Do NOT run it on a workstation you care about.
# ----------------------------------------------------------------------------
#
#  Author: Principal Platform Architect / Senior SRE Instructor track
#  Tested on: Debian 12, Ubuntu 22.04/24.04, Fedora 40+, openSUSE Leap 15.6
#  Requires: root, an X11 session or at least the X11 config tree present
# ============================================================================

set -o pipefail

# ---------------------------------------------------------------------------
# 0. Constants and helpers
# ---------------------------------------------------------------------------

LAB_NAME="lpic1-106.3-accessibility"
STATE_DIR="/var/tmp/${LAB_NAME}"
BACKUP_DIR="${STATE_DIR}/backup"
MANIFEST="${STATE_DIR}/manifest.txt"
LOGFILE="${STATE_DIR}/break.log"

XORG_CONF_D="/etc/X11/xorg.conf.d"
XORG_BROKEN_SNIPPET="${XORG_CONF_D}/99-lab-accessibility.conf"
ATSPI_SERVICE_DIR="/usr/share/dbus-1/services"
ATSPI_SERVICE="${ATSPI_SERVICE_DIR}/org.a11y.Bus.service"
ORCA_BIN="/usr/bin/orca"
ORCA_STASH="${STATE_DIR}/orca.real"
DEFAULT_LOCALE="/etc/default/locale"
ENV_D_DIR="/etc/environment.d"
ENV_D_BROKEN="${ENV_D_DIR}/90-lab-a11y.conf"
PROFILE_D_BROKEN="/etc/profile.d/zz-lab-a11y.sh"
GDM_CUSTOM="/etc/gdm3/custom.conf"
GDM_CUSTOM_ALT="/etc/gdm/custom.conf"
XKB_RULES_DIR="/usr/share/X11/xkb/rules"

C_RED=$'\033[1;31m'
C_YEL=$'\033[1;33m'
C_GRN=$'\033[1;32m'
C_CYA=$'\033[1;36m'
C_DIM=$'\033[2m'
C_OFF=$'\033[0m'

log()  { printf '%s[ lab ]%s %s\n' "$C_CYA" "$C_OFF" "$*" | tee -a "$LOGFILE"; }
warn() { printf '%s[warn ]%s %s\n' "$C_YEL" "$C_OFF" "$*" | tee -a "$LOGFILE"; }
die()  { printf '%s[fatal]%s %s\n' "$C_RED" "$C_OFF" "$*" | tee -a "$LOGFILE" >&2; exit 1; }
ok()   { printf '%s[  ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*" | tee -a "$LOGFILE"; }

# Record every file we touch so the student (and --restore) can find them all.
manifest_add() { printf '%s\n' "$1" >> "$MANIFEST"; }

# Back up a file only once, preserving mode/owner/SELinux context.
backup_file() {
    local src="$1"
    local dst="${BACKUP_DIR}${src}"
    [ -e "$src" ] || { printf 'ABSENT %s\n' "$src" >> "${BACKUP_DIR}/.absent"; return 0; }
    [ -e "$dst" ] && return 0
    mkdir -p "$(dirname "$dst")"
    cp -a --preserve=all "$src" "$dst"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This lab must run as root (try: sudo $0 $*)"
}

# Refuse to run on anything that smells like a real machine.
safety_gate() {
    local force="${LAB_FORCE:-0}"

    if [ "$force" != "1" ]; then
        # Heuristic 1: virtualization / container detection.
        local virt="none"
        command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt 2>/dev/null || echo none)"

        if [ "$virt" = "none" ]; then
            warn "systemd-detect-virt reports bare metal (virt=none)."
            warn "This lab rewrites X11, AT-SPI and logind configuration."
            printf '%sType exactly:%s I ACCEPT THE RISK  -> ' "$C_YEL" "$C_OFF"
            local answer; read -r answer
            [ "$answer" = "I ACCEPT THE RISK" ] || die "Aborted. Re-run inside a disposable VM."
        else
            log "Virtualization detected: ${virt} -- proceeding."
        fi

        # Heuristic 2: refuse if there are many real user home directories.
        local homes
        homes="$(find /home -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
        if [ "$homes" -gt 3 ]; then
            die "Found ${homes} home directories under /home. This looks like a shared host. Aborting."
        fi
    else
        warn "LAB_FORCE=1 -- safety gate bypassed by operator."
    fi
}

# Best-effort identification of the graphical user and their session.
detect_desktop_user() {
    local u=""
    if command -v loginctl >/dev/null 2>&1; then
        u="$(loginctl list-sessions --no-legend 2>/dev/null \
             | awk '{print $3}' | grep -v '^$' | head -n1)"
    fi
    [ -z "$u" ] && u="${SUDO_USER:-}"
    [ -z "$u" ] && u="$(awk -F: '$3>=1000 && $3<65000 {print $1; exit}' /etc/passwd)"
    printf '%s' "$u"
}

# ---------------------------------------------------------------------------
# 1. The breakages
#
#    Each break_* function is independent and idempotent: running the script
#    twice does not corrupt the backup set, because backup_file() only copies
#    a pristine original once.
# ---------------------------------------------------------------------------

# --- BREAK 1 ---------------------------------------------------------------
# AccessX / Sticky Keys / Slow Keys / Bounce Keys forced ON at the X server
# level via an InputClass snippet. The student will see the keyboard behaving
# as if it were possessed: keys need to be held down before registering,
# repeated keystrokes are swallowed, and modifiers latch.
#
# The XKB "AccessX" options live in the xkbOptions InputClass property; the
# canonical names are documented in /usr/share/X11/xkb/rules/base.lst.
break_accessx_forced_on() {
    log "BREAK 1: forcing AccessX (Sticky/Slow/Bounce keys) at the X server layer"

    mkdir -p "$XORG_CONF_D"
    backup_file "$XORG_BROKEN_SNIPPET"

    cat > "$XORG_BROKEN_SNIPPET" <<'EOF'
# Installed by the LPIC-1 106.3 break & fix lab.
# Intentionally hostile AccessX defaults.
Section "InputClass"
    Identifier   "lab-accessibility-sabotage"
    MatchIsKeyboard "on"
    Driver       "libinput"
    # accessx        -> master switch for the AccessX extension
    # stickykeys     -> modifiers latch instead of requiring being held
    # slowkeys       -> a key must be held ~N ms before it registers
    # bouncekeys     -> repeated presses of the same key within N ms are dropped
    Option       "XkbOptions" "accessx:enable,shiftkeys:stickykeys,keypad:slowkeys,keypad:bouncekeys"
EndSection
EOF
    chmod 0644 "$XORG_BROKEN_SNIPPET"
    manifest_add "$XORG_BROKEN_SNIPPET"

    # Also latch it into the *running* session so the symptom is immediate and
    # the student does not have to reboot to see anything happen.
    local duser xauth disp
    duser="$(detect_desktop_user)"
    if [ -n "$duser" ]; then
        disp="$(sudo -u "$duser" bash -c 'echo ${DISPLAY:-:0}' 2>/dev/null || echo ':0')"
        xauth="/home/${duser}/.Xauthority"
        [ -f "$xauth" ] || xauth="$(getent passwd "$duser" | cut -d: -f6)/.Xauthority"
        if command -v xkbset >/dev/null 2>&1; then
            sudo -u "$duser" DISPLAY="$disp" XAUTHORITY="$xauth" \
                xkbset accessx sticky -twokey -latchlock slowkeys 600 bouncekeys 900 \
                >/dev/null 2>&1 && ok "runtime AccessX applied via xkbset on ${disp}"
        elif command -v setxkbmap >/dev/null 2>&1; then
            sudo -u "$duser" DISPLAY="$disp" XAUTHORITY="$xauth" \
                setxkbmap -option accessx:enable >/dev/null 2>&1 \
                && ok "runtime accessx option applied via setxkbmap on ${disp}"
        else
            warn "neither xkbset nor setxkbmap present; symptom appears after X restart"
        fi

        # GNOME/GTK toolkits read their own keys, not just XKB. Poison those too.
        if command -v gsettings >/dev/null 2>&1; then
            local bus="unix:path=/run/user/$(id -u "$duser")/bus"
            sudo -u "$duser" DBUS_SESSION_BUS_ADDRESS="$bus" bash -s <<'GSET' >/dev/null 2>&1
gsettings set org.gnome.desktop.a11y.keyboard stickykeys-enable true
gsettings set org.gnome.desktop.a11y.keyboard slowkeys-enable true
gsettings set org.gnome.desktop.a11y.keyboard slowkeys-delay 800
gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-enable true
gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-delay 900
gsettings set org.gnome.desktop.a11y.keyboard mousekeys-enable true
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
GSET
            manifest_add "gsettings:org.gnome.desktop.a11y.keyboard (user ${duser})"
            manifest_add "gsettings:org.gnome.desktop.a11y.applications (user ${duser})"
        fi
    else
        warn "no graphical user detected; only the persistent Xorg snippet was installed"
    fi
}

# --- BREAK 2 ---------------------------------------------------------------
# Kill the AT-SPI bus. Every assistive technology on a modern Linux desktop --
# Orca, the on-screen keyboard, magnifier bridges, GTK/Qt accessibility --
# talks over org.a11y.Bus. Removing the D-Bus service activation file makes
# every AT silently fail to start, which is a *very* common real incident.
break_atspi_bus() {
    log "BREAK 2: disabling the AT-SPI accessibility bus (org.a11y.Bus)"

    if [ -f "$ATSPI_SERVICE" ]; then
        backup_file "$ATSPI_SERVICE"
        # Point the activation at a binary that does not exist.
        sed -i 's|^Exec=.*|Exec=/usr/libexec/at-spi-bus-launcher-DISABLED-BY-LAB|' "$ATSPI_SERVICE"
        manifest_add "$ATSPI_SERVICE"
        ok "org.a11y.Bus activation redirected to a non-existent binary"
    else
        warn "$ATSPI_SERVICE not found -- creating a poisoned stub instead"
        mkdir -p "$ATSPI_SERVICE_DIR"
        cat > "$ATSPI_SERVICE" <<'EOF'
[D-BUS Service]
Name=org.a11y.Bus
Exec=/usr/libexec/at-spi-bus-launcher-DISABLED-BY-LAB
EOF
        manifest_add "$ATSPI_SERVICE"
    fi

    # And switch the global toolkit accessibility flag OFF, so even if the bus
    # came back, GTK and Qt would not connect to it.
    mkdir -p "$ENV_D_DIR"
    backup_file "$ENV_D_BROKEN"
    cat > "$ENV_D_BROKEN" <<'EOF'
# Installed by the LPIC-1 106.3 break & fix lab.
NO_AT_BRIDGE=1
GTK_MODULES=
QT_ACCESSIBILITY=0
GNOME_ACCESSIBILITY=0
EOF
    manifest_add "$ENV_D_BROKEN"

    # Belt and braces: /etc/environment.d is not honoured by every display
    # manager, so plant the same poison in a login-shell profile snippet.
    backup_file "$PROFILE_D_BROKEN"
    cat > "$PROFILE_D_BROKEN" <<'EOF'
# Installed by the LPIC-1 106.3 break & fix lab.
export NO_AT_BRIDGE=1
export QT_ACCESSIBILITY=0
export GNOME_ACCESSIBILITY=0
EOF
    chmod 0644 "$PROFILE_D_BROKEN"
    manifest_add "$PROFILE_D_BROKEN"

    # Mask the user-level systemd unit if this distro ships one.
    local duser
    duser="$(detect_desktop_user)"
    if [ -n "$duser" ] && command -v systemctl >/dev/null 2>&1; then
        local uid; uid="$(id -u "$duser" 2>/dev/null)"
        if [ -n "$uid" ]; then
            sudo -u "$duser" XDG_RUNTIME_DIR="/run/user/${uid}" \
                systemctl --user mask at-spi-dbus-bus.service >/dev/null 2>&1 \
                && { ok "masked --user at-spi-dbus-bus.service for ${duser}"
                     manifest_add "systemd --user mask: at-spi-dbus-bus.service (${duser})"; }
        fi
    fi
}

# --- BREAK 3 ---------------------------------------------------------------
# Shadow the screen reader binary with a stub that exits non-zero. The student
# must notice that `which orca` resolves to something in /usr/local/bin -- the
# classic PATH-shadowing incident -- rather than the packaged binary.
break_screen_reader() {
    log "BREAK 3: shadowing the Orca screen reader binary"

    if [ -x "$ORCA_BIN" ] || command -v orca >/dev/null 2>&1; then
        mkdir -p /usr/local/bin
        backup_file /usr/local/bin/orca
        cat > /usr/local/bin/orca <<'EOF'
#!/bin/sh
# Installed by the LPIC-1 106.3 break & fix lab.
echo "orca: cannot connect to the accessibility bus" >&2
exit 127
EOF
        chmod 0755 /usr/local/bin/orca
        manifest_add "/usr/local/bin/orca"
        ok "PATH-shadow stub planted at /usr/local/bin/orca"
    else
        warn "orca is not installed; skipping BREAK 3"
        warn "install it later with: apt-get install orca   (or dnf/zypper install orca)"
    fi
}

# --- BREAK 4 ---------------------------------------------------------------
# Break the high-contrast / large-text path and the display manager's
# accessibility menu. On GDM, 'Greeter' options control what the login screen
# offers; hiding the a11y menu means a blind user cannot even enable a screen
# reader before authenticating -- a genuinely serious production fault.
break_greeter_and_theme() {
    log "BREAK 4: hiding the accessibility menu in the display manager greeter"

    local gdm=""
    [ -f "$GDM_CUSTOM" ] && gdm="$GDM_CUSTOM"
    [ -z "$gdm" ] && [ -f "$GDM_CUSTOM_ALT" ] && gdm="$GDM_CUSTOM_ALT"

    if [ -n "$gdm" ]; then
        backup_file "$gdm"
        if grep -q '^\[greeter\]' "$gdm"; then
            sed -i '/^\[greeter\]/a IncludeAll=false\nBanner=Accessibility disabled by policy' "$gdm"
        else
            printf '\n[greeter]\nIncludeAll=false\nBanner=Accessibility disabled by policy\n' >> "$gdm"
        fi
        manifest_add "$gdm"
        ok "greeter section poisoned in ${gdm}"
    else
        warn "no GDM custom.conf found; skipping the greeter half of BREAK 4"
    fi

    # Force a theme that ignores the high-contrast and large-text settings.
    local duser
    duser="$(detect_desktop_user)"
    if [ -n "$duser" ] && command -v gsettings >/dev/null 2>&1; then
        local bus="unix:path=/run/user/$(id -u "$duser")/bus"
        sudo -u "$duser" DBUS_SESSION_BUS_ADDRESS="$bus" bash -s <<'GSET' >/dev/null 2>&1
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita'
gsettings set org.gnome.desktop.interface icon-theme 'Adwaita'
gsettings set org.gnome.desktop.interface text-scaling-factor 0.5
gsettings set org.gnome.desktop.a11y.magnifier mag-factor 1.0
gsettings set org.gnome.desktop.a11y always-show-universal-access-status false
GSET
        manifest_add "gsettings:org.gnome.desktop.interface text-scaling-factor (${duser})"
        manifest_add "gsettings:org.gnome.desktop.a11y.magnifier (${duser})"
        ok "text scaling forced to 0.5 and magnifier neutralised for ${duser}"
    fi
}

# --- BREAK 5 ---------------------------------------------------------------
# Braille: brltty is the daemon that drives refreshable braille displays and
# braille terminals. Stopping and masking it, plus corrupting its config, is
# the last layer of the sabotage.
break_braille() {
    log "BREAK 5: disabling braille support (brltty)"

    if systemctl list-unit-files 2>/dev/null | grep -q '^brltty'; then
        systemctl stop brltty.service >/dev/null 2>&1
        systemctl mask brltty.service >/dev/null 2>&1
        manifest_add "systemd: brltty.service (stopped + masked)"
        ok "brltty.service stopped and masked"
    else
        warn "brltty is not installed; skipping the daemon half of BREAK 5"
    fi

    if [ -f /etc/brltty.conf ]; then
        backup_file /etc/brltty.conf
        printf '\n# Installed by the LPIC-1 106.3 break & fix lab.\nbraille-driver no\napi-parameters Auth=none\n' \
            >> /etc/brltty.conf
        manifest_add "/etc/brltty.conf"
    fi
}

# ---------------------------------------------------------------------------
# 2. The briefing shown to the student
# ---------------------------------------------------------------------------

print_briefing() {
cat <<BRIEF

${C_RED}================================================================${C_OFF}
${C_RED}  LPIC-1 106.3 -- ACCESSIBILITY : BREAK & FIX LAB IS NOW ARMED  ${C_OFF}
${C_RED}================================================================${C_OFF}

${C_YEL}THE TICKET (as it would arrive in your queue)${C_OFF}

  Priority: P2
  Reporter: Accessibility Compliance Officer
  Subject:  "Nothing assistive works on the lab desktop any more"

  A user who relies on assistive technology reports that after last
  night's 'configuration hardening' change, the workstation has become
  unusable. Support could not reproduce it because they logged in with
  their own profile. Your job is to restore the accessibility stack.

${C_YEL}SYMPTOMS YOU WILL OBSERVE${C_OFF}

  1. ${C_CYA}The keyboard feels broken.${C_OFF} Characters only appear if you hold
     a key down for the better part of a second. Typing the same letter
     twice ("ll", "ss", "tt") drops the second one. Shift, Ctrl and Alt
     latch: press Shift once and everything is uppercase until you press
     it again. A beep may accompany each modifier latch.

  2. ${C_CYA}Every assistive technology refuses to start.${C_OFF} Launching the
     screen reader prints an error about the accessibility bus and exits
     with status 127. The on-screen keyboard and the magnifier do nothing.
     Applications no longer expose their widget tree to accessibility
     tooling at all.

  3. ${C_CYA}Text is microscopic and high contrast has no effect.${C_OFF} The
     Universal Access status indicator has vanished from the top bar,
     and the accessibility menu is gone from the login screen -- so a
     blind user cannot turn a screen reader on *before* authenticating.

  4. ${C_CYA}Braille output is dead.${C_OFF} The refreshable display attached to
     the VM (or the brltty daemon that would drive it) is not running,
     and will not come back across a reboot.

${C_YEL}YOUR OBJECTIVE${C_OFF}

  Restore the machine to a state where ALL of the following are true.
  Verify each one, do not assume it:

    [ ] A single quick keypress registers exactly one character, and
        pressing the same key twice in rapid succession produces two
        characters. Modifiers do not latch.
    [ ] 'setxkbmap -query' shows no accessx / stickykeys / slowkeys /
        bouncekeys options, and nothing in /etc/X11/xorg.conf.d re-adds
        them on the next X start.
    [ ] The AT-SPI bus is reachable: an accessibility client can obtain
        org.a11y.Bus from the session bus, and NO_AT_BRIDGE is not set
        anywhere in the login environment.
    [ ] 'command -v orca' resolves to the packaged binary and the
        screen reader starts without a bus error.
    [ ] Text scaling is back to 1.0, the magnifier responds, and the
        Universal Access indicator is visible.
    [ ] The display manager greeter offers the accessibility menu again.
    [ ] brltty.service is unmasked and either running or cleanly
        startable ('systemctl is-enabled brltty' must not say 'masked').

${C_YEL}RULES OF ENGAGEMENT${C_OFF}

  * You may NOT run '$0 --restore' until you have fixed it by hand.
    That flag exists to reset the lab, not to solve it.
  * Everything that was changed is listed in:
        ${MANIFEST}
    Read it only if you get truly stuck -- it is the answer key to
    'which files', though not to 'why' or 'how'.
  * Pristine copies of every modified file are in:
        ${BACKUP_DIR}
  * Some changes are per-user (gsettings / dbus), some are system-wide
    (/etc/X11, /etc/environment.d, /usr/share/dbus-1). A fix that only
    addresses one layer will appear to work until the next login. Test
    by logging out and back in.

${C_YEL}TOOLS THAT WILL EARN THEIR KEEP${C_OFF}

  setxkbmap(1)  xkbset(1)  xset(1)  gsettings(1)  dbus-send(1)
  loginctl(1)   systemctl(1)  orca(1)  brltty(1)
  /usr/share/X11/xkb/rules/base.lst   <- the canonical XKB option names

${C_GRN}Good hunting. Log out and back in when you think you are done.${C_OFF}

BRIEF
}

# ---------------------------------------------------------------------------
# 3. Verification harness -- lets the student self-grade
# ---------------------------------------------------------------------------

verify_lab() {
    local pass=0 fail=0
    local duser; duser="$(detect_desktop_user)"
    local uid;   uid="$(id -u "$duser" 2>/dev/null || echo 0)"
    local bus="unix:path=/run/user/${uid}/bus"

    check() {
        local label="$1"; shift
        if "$@" >/dev/null 2>&1; then
            printf '  %s[PASS]%s %s\n' "$C_GRN" "$C_OFF" "$label"; pass=$((pass+1))
        else
            printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$label"; fail=$((fail+1))
        fi
    }

    printf '\n%s--- 106.3 accessibility verification ---%s\n\n' "$C_CYA" "$C_OFF"

    check "no sabotage snippet in /etc/X11/xorg.conf.d" \
        bash -c "! test -f '$XORG_BROKEN_SNIPPET'"

    check "no AccessX options in the live XKB config" \
        bash -c "! sudo -u '$duser' DISPLAY=:0 setxkbmap -query 2>/dev/null | grep -Eq 'accessx|stickykeys|slowkeys|bouncekeys'"

    check "org.a11y.Bus activation points at a real binary" \
        bash -c "! grep -q 'DISABLED-BY-LAB' '$ATSPI_SERVICE' 2>/dev/null"

    check "NO_AT_BRIDGE is not forced system-wide" \
        bash -c "! grep -rqs 'NO_AT_BRIDGE=1' /etc/environment.d /etc/profile.d /etc/environment"

    check "at-spi-dbus-bus.service is not masked" \
        bash -c "! sudo -u '$duser' XDG_RUNTIME_DIR=/run/user/${uid} systemctl --user is-enabled at-spi-dbus-bus.service 2>/dev/null | grep -q masked"

    check "orca is not shadowed by a stub in /usr/local/bin" \
        bash -c "! test -f /usr/local/bin/orca"

    check "text scaling factor is 1.0" \
        bash -c "sudo -u '$duser' DBUS_SESSION_BUS_ADDRESS='$bus' gsettings get org.gnome.desktop.interface text-scaling-factor 2>/dev/null | grep -q '^1'"

    check "sticky/slow/bounce keys are off in GNOME a11y settings" \
        bash -c "! sudo -u '$duser' DBUS_SESSION_BUS_ADDRESS='$bus' gsettings list-recursively org.gnome.desktop.a11y.keyboard 2>/dev/null | grep -Eq '(stickykeys|slowkeys|bouncekeys)-enable true'"

    check "greeter accessibility menu is not suppressed" \
        bash -c "! grep -qs 'Accessibility disabled by policy' '$GDM_CUSTOM' '$GDM_CUSTOM_ALT'"

    check "brltty.service is not masked" \
        bash -c "! systemctl is-enabled brltty.service 2>/dev/null | grep -q masked"

    printf '\n  %s%d passed%s, %s%d failed%s\n\n' "$C_GRN" "$pass" "$C_OFF" "$C_RED" "$fail" "$C_OFF"
    [ "$fail" -eq 0 ] && { ok "Lab complete. The accessibility stack is restored."; return 0; }
    warn "Not there yet. Re-read the symptom list and keep digging."
    return 1
}

# ---------------------------------------------------------------------------
# 4. Restore -- the reset button, NOT the solution
# ---------------------------------------------------------------------------

restore_lab() {
    [ -d "$BACKUP_DIR" ] || die "No backup directory at ${BACKUP_DIR}; nothing to restore."

    log "Restoring from ${BACKUP_DIR}"

    # Files that existed before: copy the pristine version back.
    if [ -d "${BACKUP_DIR}/etc" ] || [ -d "${BACKUP_DIR}/usr" ]; then
        (cd "$BACKUP_DIR" && find . -path ./.absent -prune -o -type f -print) \
        | sed 's|^\.||' | while read -r rel; do
            [ -n "$rel" ] || continue
            cp -a --preserve=all "${BACKUP_DIR}${rel}" "$rel" \
                && log "restored ${rel}"
        done
    fi

    # Files that did NOT exist before: delete them.
    if [ -f "${BACKUP_DIR}/.absent" ]; then
        while read -r _tag path; do
            [ -n "$path" ] && rm -f "$path" && log "removed ${path}"
        done < "${BACKUP_DIR}/.absent"
    fi

    rm -f "$XORG_BROKEN_SNIPPET" "$ENV_D_BROKEN" "$PROFILE_D_BROKEN" /usr/local/bin/orca

    systemctl unmask brltty.service >/dev/null 2>&1
    systemctl start   brltty.service >/dev/null 2>&1

    local duser; duser="$(detect_desktop_user)"
    if [ -n "$duser" ]; then
        local uid; uid="$(id -u "$duser")"
        sudo -u "$duser" XDG_RUNTIME_DIR="/run/user/${uid}" \
            systemctl --user unmask at-spi-dbus-bus.service >/dev/null 2>&1
        local bus="unix:path=/run/user/${uid}/bus"
        sudo -u "$duser" DBUS_SESSION_BUS_ADDRESS="$bus" bash -s <<'GSET' >/dev/null 2>&1
for k in stickykeys slowkeys bouncekeys mousekeys; do
    gsettings reset org.gnome.desktop.a11y.keyboard "${k}-enable"
done
gsettings reset org.gnome.desktop.a11y.keyboard slowkeys-delay
gsettings reset org.gnome.desktop.a11y.keyboard bouncekeys-delay
gsettings reset org.gnome.desktop.a11y.applications screen-keyboard-enabled
gsettings reset org.gnome.desktop.interface text-scaling-factor
gsettings reset org.gnome.desktop.a11y.magnifier mag-factor
gsettings reset org.gnome.desktop.a11y always-show-universal-access-status
GSET
        DISPLAY=:0 sudo -u "$duser" setxkbmap -option >/dev/null 2>&1
    fi

    ok "Restore finished. Log out and back in to rebuild the session environment."
}

# ---------------------------------------------------------------------------
# 5. Entry point
# ---------------------------------------------------------------------------

usage() {
cat <<USAGE
Usage: $0 [--break | --verify | --restore | --help]

  --break     Arm the lab: sabotage the accessibility stack and print the
              student briefing. (default)
  --verify    Self-grade: check every objective and report pass/fail.
  --restore   Reset the lab from the pristine backups. This is the reset
              button, not the solution -- use it only after you have tried.
  --help      This message.

Environment:
  LAB_FORCE=1   Skip the "is this really a disposable VM?" safety gate.

Lab state lives in: ${STATE_DIR}
USAGE
}

main() {
    local action="${1:---break}"

    case "$action" in
        --help|-h) usage; exit 0 ;;
    esac

    require_root "$@"
    mkdir -p "$STATE_DIR" "$BACKUP_DIR"
    touch "$MANIFEST" "$LOGFILE" "${BACKUP_DIR}/.absent"
    chmod 0700 "$STATE_DIR"

    case "$action" in
        --break)
            safety_gate
            log "Arming ${LAB_NAME} at $(date -Is)"
            break_accessx_forced_on
            break_atspi_bus
            break_screen_reader
            break_greeter_and_theme
            break_braille
            print_briefing
            ;;
        --verify)
            verify_lab
            ;;
        --restore)
            restore_lab
            ;;
        *)
            usage; exit 2 ;;
    esac
}

main "$@"

# ============================================================================
# ============================================================================
#
#                        S O L U T I O N   K E Y
#
#              Do not read this until you have genuinely tried.
#              Everything below is commented out on purpose.
#
# ============================================================================
# ============================================================================
#
# ---------------------------------------------------------------------------
# STEP 0 -- Triage before touching anything
# ---------------------------------------------------------------------------
#
# The single most useful reflex in an accessibility incident is to decide,
# first, WHICH LAYER is broken. There are four, and they fail differently:
#
#   Layer 1  X server / XKB      -> AccessX: sticky, slow, bounce, mouse keys
#   Layer 2  Session environment -> NO_AT_BRIDGE, GTK_MODULES, QT_ACCESSIBILITY
#   Layer 3  D-Bus / AT-SPI      -> org.a11y.Bus, at-spi2-registryd
#   Layer 4  The ATs themselves  -> orca, brltty, on-screen keyboard, magnifier
#
# A symptom that survives a logout is layer 1 or 2 (persistent config).
# A symptom that vanishes on logout was only applied at runtime.
#
#   # What is the session and who owns it?
#   loginctl list-sessions
#   loginctl show-session "$XDG_SESSION_ID" -p Type -p Display -p Remote
#
#   # X11 or Wayland? This changes every command that follows.
#   echo "$XDG_SESSION_TYPE"
#
#   # What did the X server actually load?
#   grep -Ei 'inputclass|xkboption|(WW)|(EE)' /var/log/Xorg.0.log
#   # On systemd-journal distros the log is in the journal instead:
#   journalctl -b _COMM=Xorg | grep -Ei 'inputclass|xkb'
#
# ---------------------------------------------------------------------------
# STEP 1 -- Fix the keyboard: AccessX at the X/XKB layer  (SYMPTOM 1)
# ---------------------------------------------------------------------------
#
# Diagnose. `setxkbmap -query` prints the *effective* rules/model/layout/
# options; the sabotage put its markers in the options field:
#
#   setxkbmap -query
#   # rules:      evdev
#   # model:      pc105
#   # layout:     us
#   # options:    accessx:enable,shiftkeys:stickykeys,keypad:slowkeys
#                                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ the smell
#
# `xkbset q` is the more precise tool -- it reports the AccessX control bits
# and their timings, which setxkbmap cannot show:
#
#   xkbset q
#   # Sticky Keys      = On
#   #    TwoKeys       = Off
#   #    LatchLock     = On
#   # Slow Keys        = On     Delay 600 ms
#   # Bounce Keys      = On     Delay 900 ms
#   # Mouse Keys       = On
#
# Clear them in the live session. `setxkbmap -option` with an EMPTY argument
# resets the option list -- this is the part people forget; passing a new
# option merely APPENDS to the existing set:
#
#   setxkbmap -option                       # clear ALL options, then re-apply
#   setxkbmap -layout us -option terminate:ctrl_alt_bksp   # your real options
#
#   xkbset -accessx                          # master AccessX switch off
#   xkbset -sticky -twokey -latchlock
#   xkbset -slowkeys
#   xkbset -bouncekeys
#   xkbset -mousekeys -mousekeysaccel
#
#   # xkbset has an expiry timer that can silently re-enable things; kill it:
#   xkbset exp 1 '=sticky' '=twokey' '=latchlock' '=slowkeys' '=bouncekeys'
#
# `xset` covers the two AccessX bits that are not XKB options:
#
#   xset -r                                  # if autorepeat itself is wrong
#   xset r rate 500 30                       # sane delay/rate, then verify:
#   xset q | sed -n '/Keyboard Control/,/^$/p'
#
# Now make it survive a restart -- the runtime fix is worthless if the X
# server re-applies the snippet on the next start:
#
#   ls -l /etc/X11/xorg.conf.d/
#   cat /etc/X11/xorg.conf.d/99-lab-accessibility.conf
#   rm -f /etc/X11/xorg.conf.d/99-lab-accessibility.conf
#
#   # Do not forget the legacy monolithic file, if the distro still has one:
#   grep -n 'XkbOptions' /etc/X11/xorg.conf 2>/dev/null
#
#   # Debian/Ubuntu also carry a console-level keyboard config that feeds the
#   # X layout via systemd-localed. Check it before declaring victory:
#   cat /etc/default/keyboard
#   localectl status
#   # Fix with the proper tool rather than by hand:
#   localectl set-x11-keymap us pc105 "" ""
#
# The toolkit layer keeps its OWN copy of these settings, independent of XKB.
# On GNOME they are GSettings keys; the desktop re-applies them at login and
# will happily undo your setxkbmap work:
#
#   gsettings list-recursively org.gnome.desktop.a11y.keyboard
#   gsettings set org.gnome.desktop.a11y.keyboard stickykeys-enable false
#   gsettings set org.gnome.desktop.a11y.keyboard slowkeys-enable   false
#   gsettings set org.gnome.desktop.a11y.keyboard bouncekeys-enable false
#   gsettings set org.gnome.desktop.a11y.keyboard mousekeys-enable  false
#   # Or, better, drop the overrides entirely and inherit the schema default:
#   for k in stickykeys slowkeys bouncekeys mousekeys; do
#       gsettings reset org.gnome.desktop.a11y.keyboard "${k}-enable"
#   done
#   gsettings reset org.gnome.desktop.a11y.keyboard slowkeys-delay
#   gsettings reset org.gnome.desktop.a11y.keyboard bouncekeys-delay
#
#   # KDE Plasma equivalent lives in an INI file, not dconf:
#   kwriteconfig5 --file kaccessrc --group Bindings --key StickyKeys false
#   # ...or just: rm -f ~/.config/kaccessrc && restart the session
#
#   # The canonical list of valid XKB option names -- worth knowing for the
#   # exam and for real work:
#   grep -A40 '! option' /usr/share/X11/xkb/rules/base.lst | head -60
#
# ---------------------------------------------------------------------------
# STEP 2 -- Fix the session environment  (part of SYMPTOM 2)
# ---------------------------------------------------------------------------
#
# NO_AT_BRIDGE=1 tells GTK not to load the atk-bridge module, which is what
# exposes a GTK application's widget tree over AT-SPI. QT_ACCESSIBILITY=0 is
# the Qt equivalent. With either set, a screen reader connects to the bus and
# then finds an empty accessible tree -- the app "has no content".
#
#   # Find every place it is being set. Do NOT stop at the first hit.
#   grep -rns 'NO_AT_BRIDGE\|QT_ACCESSIBILITY\|GNOME_ACCESSIBILITY' \
#        /etc/environment /etc/environment.d /etc/profile /etc/profile.d \
#        /etc/X11/Xsession.d /etc/gdm3 /etc/gdm ~/.pam_environment \
#        ~/.profile ~/.bashrc ~/.xsessionrc 2>/dev/null
#
#   rm -f /etc/environment.d/90-lab-a11y.conf
#   rm -f /etc/profile.d/zz-lab-a11y.sh
#
#   # Verify from INSIDE the graphical session, not from your ssh shell --
#   # they have different environments:
#   systemctl --user show-environment | grep -i at_bridge
#   cat /proc/$(pgrep -u "$USER" -f gnome-shell | head -1)/environ \
#       | tr '\0' '\n' | grep -Ei 'AT_BRIDGE|ACCESSIB|GTK_MODULES'
#
#   # If a stale value is stuck in the systemd user manager, unset it there:
#   systemctl --user unset-environment NO_AT_BRIDGE
#
#   # The positive setting, for reference (this is what SHOULD be true):
#   #   GTK_MODULES may contain 'gail:atk-bridge' on older stacks
#   #   QT_ACCESSIBILITY=1
#   #   NO_AT_BRIDGE unset (not 0 -- unset)
#
# ---------------------------------------------------------------------------
# STEP 3 -- Fix the AT-SPI bus  (the core of SYMPTOM 2)
# ---------------------------------------------------------------------------
#
# AT-SPI2 is a D-Bus service. The session bus activates org.a11y.Bus on
# demand from a .service file; that file's Exec= line was redirected to a
# binary that does not exist, so activation fails with a NameHasNoOwner
# style error and every AT dies at startup.
#
#   # Ask the session bus whether the name can be activated at all:
#   dbus-send --session --print-reply --dest=org.freedesktop.DBus \
#             /org/freedesktop/DBus org.freedesktop.DBus.ListActivatableNames \
#     | grep -i a11y
#
#   # Try to actually reach it; this is the definitive test:
#   dbus-send --session --print-reply --dest=org.a11y.Bus \
#             /org/a11y/bus org.a11y.Bus.GetAddress
#   # BROKEN: Error org.freedesktop.DBus.Error.Spawn.ExecFailed
#   # FIXED : string "unix:path=/run/user/1000/at-spi/bus_0,guid=..."
#
#   # Inspect the activation file and find the bogus Exec=:
#   cat /usr/share/dbus-1/services/org.a11y.Bus.service
#   # [D-BUS Service]
#   # Name=org.a11y.Bus
#   # Exec=/usr/libexec/at-spi-bus-launcher-DISABLED-BY-LAB   <-- does not exist
#
#   # Where does the real launcher live on this distro?
#   ls -l /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher 2>/dev/null
#   dpkg -S at-spi-bus-launcher          # Debian/Ubuntu
#   rpm -qf  /usr/libexec/at-spi-bus-launcher   # Fedora/RHEL/openSUSE
#
#   # Repair the line by hand...
#   sed -i 's|^Exec=.*|Exec=/usr/libexec/at-spi-bus-launcher --launch-immediately|' \
#          /usr/share/dbus-1/services/org.a11y.Bus.service
#
#   # ...or, far better, let the package manager restore the pristine file:
#   apt-get install --reinstall at-spi2-core     # Debian/Ubuntu
#   dnf reinstall at-spi2-core                   # Fedora/RHEL
#   zypper install -f at-spi2-core               # openSUSE
#
#   # Debian/Ubuntu can also verify integrity without reinstalling:
#   dpkg --verify at-spi2-core
#   rpm -V at-spi2-core
#
#   # Unmask the user unit that was masked, then start it:
#   systemctl --user unmask at-spi-dbus-bus.service
#   systemctl --user daemon-reload
#   systemctl --user start  at-spi-dbus-bus.service
#   systemctl --user status at-spi-dbus-bus.service
#
#   # And the global accessibility toggle that GNOME still honours:
#   gsettings set org.gnome.desktop.interface toolkit-accessibility true
#
#   # Confirm the registry daemon is alive -- this is the process that keeps
#   # the tree of accessible objects:
#   pgrep -a at-spi2-registryd
#   pgrep -a at-spi-bus-launcher
#
#   # End-to-end proof, if python3-pyatspi is available:
#   python3 -c 'import pyatspi; print(pyatspi.Registry.getDesktop(0).childCount)'
#   # A number > 0 means applications are actually registering. 0 means the
#   # bus is up but the bridge is still disabled -- go back to STEP 2.
#
# ---------------------------------------------------------------------------
# STEP 4 -- Fix the screen reader  (the exit-127 half of SYMPTOM 2)
# ---------------------------------------------------------------------------
#
# Classic PATH shadowing. /usr/local/bin precedes /usr/bin in the default
# PATH on every mainstream distro, so a file dropped there wins.
#
#   command -v orca
#   # /usr/local/bin/orca        <-- WRONG
#
#   type -a orca                 # shows EVERY match, in PATH order
#   # orca is /usr/local/bin/orca
#   # orca is /usr/bin/orca
#
#   file /usr/local/bin/orca && head -5 /usr/local/bin/orca
#   # a 4-line /bin/sh stub, not the real Python application
#
#   # Confirm it belongs to no package -- unowned files in /usr/local are
#   # always locally installed, by definition of the FHS:
#   dpkg -S /usr/local/bin/orca   # -> "no path found matching pattern"
#
#   rm -f /usr/local/bin/orca
#   hash -r                       # flush the shell's command-location cache
#   command -v orca               # -> /usr/bin/orca
#
#   # Start it and watch it connect:
#   orca --replace --debug-file=/tmp/orca.log &
#   grep -i 'a11y\|bus\|error' /tmp/orca.log | head
#
#   # Orca's own settings live per-user; a corrupted profile is the other
#   # common cause of "the screen reader will not start":
#   ls -l ~/.local/share/orca/user-settings.conf
#   # Reset by moving it aside, never by editing blindly:
#   mv ~/.local/share/orca ~/.local/share/orca.bak
#
#   # Make the desktop agree that a screen reader should run:
#   gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
#
# ---------------------------------------------------------------------------
# STEP 5 -- Fix visual accessibility and the greeter  (SYMPTOM 3)
# ---------------------------------------------------------------------------
#
#   # Text scaling was pushed to 0.5 (half size). 1.0 is the default; the key
#   # is a double, so 'reset' is safer than guessing the literal:
#   gsettings get   org.gnome.desktop.interface text-scaling-factor    # 0.5
#   gsettings reset org.gnome.desktop.interface text-scaling-factor
#   gsettings get   org.gnome.desktop.interface text-scaling-factor    # 1.0
#
#   # High contrast, large text and the magnifier:
#   gsettings set org.gnome.desktop.a11y.interface high-contrast true
#   gsettings set org.gnome.desktop.interface gtk-theme 'HighContrast'
#   gsettings set org.gnome.desktop.interface icon-theme 'HighContrast'
#   gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled true
#   gsettings set org.gnome.desktop.a11y.magnifier mag-factor 2.0
#
#   # Bring the Universal Access indicator back to the top bar:
#   gsettings set org.gnome.desktop.a11y always-show-universal-access-status true
#
#   # See every accessibility key at once -- useful for spotting what else
#   # was tampered with:
#   gsettings list-recursively | grep -E '^org\.gnome\.desktop\.a11y'
#
#   # dconf is the backing store; a system-wide lock or default can override
#   # anything the user sets. Always check these two directories:
#   ls -l /etc/dconf/db/local.d/ /etc/dconf/db/local.d/locks/ 2>/dev/null
#   dconf dump /org/gnome/desktop/a11y/
#   # If a lock is present, remove it and rebuild the database:
#   #   rm -f /etc/dconf/db/local.d/locks/a11y
#   #   dconf update
#
#   # The greeter: GDM reads its own config and its own dconf profile.
#   grep -n -A5 '\[greeter\]' /etc/gdm3/custom.conf   # or /etc/gdm/custom.conf
#   # Remove the lines the lab appended:
#   sed -i '/IncludeAll=false/d;/Accessibility disabled by policy/d' \
#          /etc/gdm3/custom.conf
#   systemctl restart gdm    # WARNING: this kills the graphical session
#
#   # LightDM equivalent, for distros that use it:
#   grep -n 'greeter-show-manual-login\|a11y' /etc/lightdm/lightdm.conf
#   # SDDM (KDE):
#   grep -rn 'Accessibility' /etc/sddm.conf /etc/sddm.conf.d/ 2>/dev/null
#
# ---------------------------------------------------------------------------
# STEP 6 -- Fix braille  (SYMPTOM 4)
# ---------------------------------------------------------------------------
#
#   systemctl is-enabled brltty.service
#   # masked            <-- a symlink to /dev/null; 'enable' alone will NOT fix it
#
#   systemctl unmask brltty.service
#   systemctl enable --now brltty.service
#   systemctl status brltty.service --no-pager
#
#   # Undo the config sabotage. 'braille-driver no' disables driver probing
#   # entirely, so the daemon starts and then does nothing:
#   grep -n 'braille-driver\|api-parameters' /etc/brltty.conf
#   sed -i '/braille-driver no/d;/api-parameters Auth=none/d' /etc/brltty.conf
#   # Autodetect is the sane default:
#   #   braille-driver auto
#   #   braille-device  usb:,serial:/dev/ttyS0
#
#   # Prove BrlAPI is reachable (this is what Orca talks to for braille):
#   brltty -v
#   ls -l /var/lib/BrlAPI/ /etc/brlapi.key
#   journalctl -u brltty -b --no-pager | tail -20
#
#   # udev rules are what bind a USB braille display to the daemon:
#   ls -l /usr/lib/udev/rules.d/*brltty* /etc/udev/rules.d/*brltty*
#   udevadm control --reload-rules && udevadm trigger
#
# ---------------------------------------------------------------------------
# STEP 7 -- Prove it, then prove it again after a logout
# ---------------------------------------------------------------------------
#
# Accessibility bugs love to come back at the next login, because the desktop
# re-applies GSettings and the display manager rebuilds the environment. A
# fix is not a fix until it survives a session restart.
#
#   sudo /path/to/this-script.sh --verify      # the built-in self-grader
#
#   loginctl terminate-user "$USER"            # force a clean logout
#   # ...log back in, then:
#   sudo /path/to/this-script.sh --verify      # must still be 10/10
#
# Manual confirmation, in order of increasing confidence:
#
#   setxkbmap -query | grep -i option          # no accessx/sticky/slow/bounce
#   xkbset q | grep -E 'Sticky|Slow|Bounce'    # all Off
#   dbus-send --session --print-reply --dest=org.a11y.Bus \
#             /org/a11y/bus org.a11y.Bus.GetAddress   # returns an address
#   type -a orca                               # /usr/bin/orca only
#   gsettings get org.gnome.desktop.interface text-scaling-factor   # 1.0
#   systemctl is-enabled brltty                # enabled, not masked
#   pgrep -a at-spi2-registryd                 # running
#
# ---------------------------------------------------------------------------
# WHAT TO CARRY OUT OF THIS LAB
# ---------------------------------------------------------------------------
#
# 1. Accessibility is a STACK, not a setting. XKB, the session environment,
#    D-Bus/AT-SPI and the AT applications each fail independently and each
#    produces a plausible-looking "accessibility is broken" report. Identify
#    the layer before you touch a config file.
#
# 2. Runtime and persistent state are separate everywhere on a Linux desktop.
#    setxkbmap fixes now; /etc/X11/xorg.conf.d fixes next boot; gsettings
#    fixes next login. Fixing one and testing only that one is the single
#    most common way an accessibility ticket gets reopened.
#
# 3. `setxkbmap -option` with no argument CLEARS the option list. Passing an
#    option appends. This asymmetry is examinable and is a real trap.
#
# 4. `systemctl enable` does not undo `systemctl mask`. Masking creates a
#    symlink to /dev/null that only `unmask` removes.
#
# 5. NO_AT_BRIDGE is the quietest failure in the whole stack: the bus is up,
#    the reader runs, and every application simply appears empty.
#
# 6. /usr/local/bin precedes /usr/bin. `type -a` beats `which` because it
#    shows all matches; `hash -r` after removing a shadow, or the shell will
#    keep calling the file you just deleted.
#
# 7. Never verify from an ssh shell what happens in a graphical session.
#    Read /proc/<pid>/environ of a real session process instead.
#
# ---------------------------------------------------------------------------
# OFFICIAL SOURCES
# ---------------------------------------------------------------------------
#
#   LPI Exam 101-500 objectives
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#   LPI Exam 102-500 objectives (topic 106 lives here)
#     https://www.lpi.org/our-certifications/exam-102-objectives/
#   X.Org -- setxkbmap(1), xset(1), xorg.conf(5), xorg.conf.d
#     https://www.x.org/releases/current/doc/man/man1/setxkbmap.1.xhtml
#     https://www.x.org/releases/current/doc/man/man5/xorg.conf.5.xhtml
#   XKB configuration and the AccessX options
#     https://www.x.org/wiki/XKB/
#   AT-SPI2 / at-spi2-core (GNOME)
#     https://gitlab.gnome.org/GNOME/at-spi2-core
#     https://docs.gtk.org/atk/
#   Orca screen reader
#     https://help.gnome.org/users/orca/stable/
#     https://gitlab.gnome.org/GNOME/orca
#   GNOME Universal Access
#     https://help.gnome.org/users/gnome-help/stable/a11y.html
#   BRLTTY
#     https://brltty.app/doc/Manual-BRLTTY/English/BRLTTY.html
#   GDM configuration
#     https://help.gnome.org/admin/gdm/stable/configuration.html
#   systemd -- systemctl(1) mask/unmask, environment.d(5)
#     https://www.freedesktop.org/software/systemd/man/systemctl.html
#     https://www.freedesktop.org/software/systemd/man/environment.d.html
#
# ============================================================================