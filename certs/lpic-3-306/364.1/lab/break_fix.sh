#!/usr/bin/env bash
#
# ============================================================================
#  teach-plat :: break & fix lab
#  Certification : LPIC-3 306 (exam 306-300, version 3.0)
#  Topic        : 364.1 — Hardware and Resource High Availability
#  Exam weight  : 3.33 (as tracked in this course)
#  Source       : https://www.lpi.org/our-certifications/exam-306-objectives/
# ----------------------------------------------------------------------------
#  LPI terms & utilities exercised here:
#    watchdog(8), /etc/watchdog.conf(5), /dev/watchdog, softdog kernel module,
#    modprobe / modules-load.d / modprobe.d blacklist, wdctl(8), lsmod,
#    systemctl, journalctl. (Sibling tools for this same objective — smartd,
#    ipmitool, sensors, edac-util — need real hardware and are not exercised
#    inside a plain VM.)
# ----------------------------------------------------------------------------
#  WHAT THIS LAB DOES
#    A production HA node relies on a *hardware watchdog* to self-fence: if the
#    kernel or the userspace watchdog daemon stops petting /dev/watchdog, the
#    watchdog timer expires and the machine resets, so Pacemaker/corosync can
#    recover the services elsewhere. If that protection is silently disabled,
#    a hung node stays hung and the cluster never fails over.
#
#    This script injects that exact silent failure into a DISPOSABLE lab VM:
#      1. It blacklists the `softdog` module so /dev/watchdog never appears.
#      2. It points `watchdog-device` in /etc/watchdog.conf at a device that
#         does not exist.
#    The watchdog daemon is left enabled, so it tries to start and fails.
#
#    SAFETY: the software watchdog is loaded lab-wide with `soft_noboot=1`, so
#    even a correctly-armed watchdog only *logs* instead of resetting the VM.
#    Nothing here can reboot the machine, delete data, or touch a real disk.
#    Run it ONLY on a throwaway VM you can roll back.
#
#  SYMPTOM the student will see:
#    - `systemctl status watchdog`  -> Active: failed (Result: exit-code)
#    - `journalctl -u watchdog -b`  -> "cannot open <device> (errno = 2 ...)"
#    - `ls -l /dev/watchdog*`       -> no such file (softdog absent)
#    - `lsmod | grep -i dog`        -> empty
#
#  GOAL the student must achieve (see verify + commented solution at the end):
#    - A working /dev/watchdog is present.
#    - /etc/watchdog.conf points at it.
#    - watchdog.service is active (running) and is holding the device open
#      (i.e. actually feeding the timer).
#    - The fix survives a reboot (module autoload restored, service enabled).
#
#  USAGE:
#    sudo ./break_fix.sh            # inject the fault + print the briefing
#    sudo ./break_fix.sh break      # same as default
#    sudo ./break_fix.sh briefing   # reprint the student briefing only
#    sudo ./break_fix.sh verify     # grade the student's fix (exit 0 == solved)
#    sudo ./break_fix.sh revert     # instructor reset to a healthy state
# ============================================================================

set -euo pipefail

# --- constants --------------------------------------------------------------
WD_CONF="/etc/watchdog.conf"
WD_CONF_BACKUP="/etc/watchdog.conf.teach-plat.orig"
BROKEN_DEV="/dev/watchdog-lab-missing"
GOOD_DEV="/dev/watchdog"
SAFE_MODOPTS="/etc/modprobe.d/zz-teach-plat-softdog-safety.conf"
BREAK_BLACKLIST="/etc/modprobe.d/teach-plat-364-1-break.conf"
MODLOAD_HINT="/etc/modules-load.d/softdog.conf"   # what a good fix would create
WD_LOGDIR="/var/log/watchdog"
STATE_DIR="/var/lib/teach-plat"
CONFIRM_TOKEN="yes-destroy-this-vm"

# --- output helpers ---------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED="$(tput setaf 1)"; C_GRN="$(tput setaf 2)"; C_YEL="$(tput setaf 3)"
  C_BLU="$(tput setaf 4)"; C_BLD="$(tput bold)"; C_RST="$(tput sgr0)"
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
rule() { printf '%s----------------------------------------------------------------------%s\n' "$C_BLD" "$C_RST"; }

# --- guards -----------------------------------------------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This lab must run as root (it loads modules and edits /etc). Use sudo."
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "systemctl not found. This lab targets systemd-based distributions."
    exit 1
  fi
}

confirm_disposable() {
  # Refuse on any host explicitly flagged as non-lab.
  if [ -e /etc/teach-plat-nolab ] || [ -e /etc/no-teach-plat ]; then
    err "Refusing: this host is flagged as NON-lab (/etc/teach-plat-nolab present)."
    exit 1
  fi
  local virt="unknown"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  fi
  if [ "$virt" = "none" ]; then
    warn "systemd-detect-virt reports BARE METAL (virt=none)."
    warn "This lab is intended for a disposable VM. Continue at your own risk."
  else
    info "Virtualization detected: ${virt}."
  fi
  # Non-interactive runs require an explicit opt-in token.
  if [ "${TEACH_PLAT_LAB_CONFIRM:-}" = "$CONFIRM_TOKEN" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    err "Non-interactive run without confirmation."
    err "Re-run with:  TEACH_PLAT_LAB_CONFIRM=${CONFIRM_TOKEN} sudo -E $0"
    exit 1
  fi
  printf '%sThis will break the hardware watchdog on THIS machine.%s\n' "$C_YEL" "$C_RST"
  printf 'Type the VM hostname (%s) to proceed: ' "$(hostname)"
  local answer; read -r answer
  if [ "$answer" != "$(hostname)" ]; then
    err "Hostname did not match. Aborting for safety."
    exit 1
  fi
}

# --- distro / packages ------------------------------------------------------
pkg_install() {
  # Best-effort install; the lab is still diagnosable if a package is missing.
  local pkgs="watchdog lsof psmisc"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs || warn "apt-get install partially failed."
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y $pkgs || warn "dnf install partially failed (RHEL needs EPEL for 'watchdog')."
  elif command -v yum >/dev/null 2>&1; then
    yum install -y $pkgs || warn "yum install partially failed (RHEL needs EPEL for 'watchdog')."
  elif command -v zypper >/dev/null 2>&1; then
    zypper -n install $pkgs || warn "zypper install partially failed."
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm watchdog lsof psmisc || warn "pacman install partially failed."
  else
    warn "No known package manager found. Ensure 'watchdog' is installed manually."
  fi
}

# --- lab scaffolding --------------------------------------------------------
ensure_safety_modopts() {
  # Guarantees the software watchdog can never reset this VM during the lab.
  cat > "$SAFE_MODOPTS" <<'EOF'
# teach-plat lab safety (364.1). Do NOT rely on this in production.
# soft_noboot=1 -> softdog only LOGS on timeout instead of resetting the box.
options softdog soft_noboot=1 soft_margin=60 nowayout=0
EOF
  ok "Lab safety installed: softdog will not reboot this VM (soft_noboot=1)."
}

write_watchdog_conf() {
  local dev="$1"
  cat > "$WD_CONF" <<EOF
# /etc/watchdog.conf — managed by teach-plat lab 364.1
# Userspace watchdog daemon config. See: man 5 watchdog.conf
watchdog-device = $dev
watchdog-timeout = 60
interval        = 1
# Reboot thresholds kept deliberately high so normal lab load never trips them.
max-load-1      = 24
max-load-5      = 18
min-memory      = 1
realtime        = yes
priority        = 1
log-dir         = $WD_LOGDIR
EOF
}

# --- BREAK ------------------------------------------------------------------
do_break() {
  require_root
  require_systemd
  confirm_disposable

  mkdir -p "$STATE_DIR" "$WD_LOGDIR"

  info "Installing prerequisites (idempotent)..."
  pkg_install

  ensure_safety_modopts

  # Back up the shipped config exactly once so 'revert' is faithful.
  if [ -f "$WD_CONF" ] && [ ! -f "$WD_CONF_BACKUP" ]; then
    cp -a "$WD_CONF" "$WD_CONF_BACKUP"
    ok "Original ${WD_CONF} saved to ${WD_CONF_BACKUP}."
  fi

  info "Injecting fault #1: blacklisting the softdog module..."
  cat > "$BREAK_BLACKLIST" <<'EOF'
# Injected fault (teach-plat 364.1). Someone "hardened" the node and stopped
# the software watchdog from loading at boot, so /dev/watchdog never appears.
blacklist softdog
EOF
  # Remove any autoload hint and unload the module now (device must vanish).
  rm -f "$MODLOAD_HINT" 2>/dev/null || true
  systemctl stop watchdog 2>/dev/null || true
  if lsmod | grep -q '^softdog'; then
    modprobe -r softdog 2>/dev/null || warn "Could not unload softdog (device busy?)."
  fi

  info "Injecting fault #2: pointing watchdog-device at a missing node..."
  write_watchdog_conf "$BROKEN_DEV"

  info "Leaving the daemon enabled so the failure is loud, not silent..."
  systemctl enable watchdog >/dev/null 2>&1 || true
  systemctl restart watchdog >/dev/null 2>&1 || true   # expected to FAIL

  date > "${STATE_DIR}/364.1.broken" 2>/dev/null || true

  rule
  ok "Fault injected. The watchdog protection on this node is now DISABLED."
  rule
  print_briefing
}

# --- STUDENT BRIEFING -------------------------------------------------------
print_briefing() {
  cat <<EOF

${C_BLD}================= STUDENT BRIEFING — LPIC-3 306 / 364.1 =================${C_RST}
${C_BLD}Hardware and Resource High Availability — the watchdog is dead${C_RST}

SCENARIO
  This node is a member of a Pacemaker/corosync HA cluster. Cluster fencing
  depends on the local hardware watchdog: if the node hangs, the watchdog must
  reset it so services can move elsewhere. After a "hardening" change, the
  watchdog service no longer starts and the box is now UNPROTECTED — a hang
  here would freeze the whole service, because nothing fences a wedged node.

SYMPTOM (confirm it yourself)
  $ systemctl status watchdog        -> Active: failed
  $ journalctl -u watchdog -b        -> "cannot open ${BROKEN_DEV} (errno = 2 ...)"
  $ ls -l /dev/watchdog*             -> No such file or directory
  $ lsmod | grep -i dog              -> (nothing)

YOUR GOAL
  Restore working watchdog protection, and make it PERSIST across reboots:
    1. Make a real /dev/watchdog exist again.
    2. Make /etc/watchdog.conf point at a device that actually exists.
    3. Get watchdog.service to Active: running AND holding the device open
       (that is what proves the timer is being fed).
    4. Ensure it all comes back automatically after 'reboot'
       (module autoloaded + service enabled).

WHERE TO LOOK (hints, not the answer)
  - Kernel module state ......... lsmod, modprobe, /etc/modprobe.d/
  - Persistent module loading ... /etc/modules-load.d/
  - The device node ............. ls -l /dev/watchdog*, wdctl
  - Daemon config ............... /etc/watchdog.conf  (man 5 watchdog.conf)
  - Service + logs .............. systemctl status watchdog, journalctl -u watchdog -b

CHECK YOUR WORK
  $ sudo $0 verify     # exits 0 when every success criterion is met

NOTE (lab safety)
  The software watchdog is loaded with soft_noboot=1, so it will only LOG a
  timeout instead of resetting this VM. In production it would reboot the node
  on purpose — that is the whole point of the mechanism.
${C_BLD}========================================================================${C_RST}

EOF
}

# --- VERIFY (grader) --------------------------------------------------------
conf_device() {
  [ -f "$WD_CONF" ] || { echo ""; return; }
  grep -E '^[[:space:]]*watchdog-device[[:space:]]*=' "$WD_CONF" 2>/dev/null \
    | tail -n1 | cut -d= -f2- | tr -d '[:space:]'
}

device_is_held() {
  # True if some process holds the watchdog device open (i.e. is feeding it).
  local dev="$1"
  if command -v fuser >/dev/null 2>&1; then
    fuser "$dev" >/dev/null 2>&1 && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -- "$dev" >/dev/null 2>&1 && return 0
  fi
  # Fallback: daemon active and a watchdog process exists.
  systemctl is-active --quiet watchdog && pgrep -x watchdog >/dev/null 2>&1
}

persistence_ok() {
  # Blacklist must be gone, and the module must come back at boot by some means.
  [ -f "$BREAK_BLACKLIST" ] && return 1
  grep -rqs '^[[:space:]]*softdog' /etc/modules-load.d/ 2>/dev/null && return 0
  grep -qs 'softdog' /etc/modules 2>/dev/null && return 0
  grep -qs 'watchdog_module=.*softdog' /etc/default/watchdog 2>/dev/null && return 0
  # Built-in softdog (compiled =y) or a real/virtual hardware watchdog also persists.
  if [ -c "$GOOD_DEV" ] && ! lsmod | grep -q '^softdog'; then return 0; fi
  return 1
}

do_verify() {
  require_root
  require_systemd
  local fails=0

  rule
  info "Grading topic 364.1 fix..."
  rule

  # 1) A watchdog device exists.
  local dev; dev="$(conf_device)"
  if [ -c "$GOOD_DEV" ] || { [ -n "$dev" ] && [ -c "$dev" ]; }; then
    ok "A watchdog character device exists."
  else
    err "No usable /dev/watchdog device found."; fails=$((fails+1))
  fi

  # 2) Config points at an existing device (and not at the injected bogus one).
  if [ -n "$dev" ] && [ "$dev" != "$BROKEN_DEV" ] && [ -c "$dev" ]; then
    ok "watchdog.conf points at an existing device: ${dev}"
  else
    err "watchdog-device in ${WD_CONF} is missing/bogus (currently: '${dev:-unset}')."
    fails=$((fails+1))
  fi

  # 3) Service running and actually feeding the device.
  if systemctl is-active --quiet watchdog; then
    ok "watchdog.service is active (running)."
    if device_is_held "${dev:-$GOOD_DEV}"; then
      ok "The device is held open by the daemon (timer is being fed)."
    else
      err "Service is up but nothing holds the watchdog device open."; fails=$((fails+1))
    fi
  else
    err "watchdog.service is not active."; fails=$((fails+1))
  fi

  # 4) Persistence across reboot.
  if systemctl is-enabled --quiet watchdog 2>/dev/null; then
    ok "watchdog.service is enabled at boot."
  else
    err "watchdog.service is not enabled (won't start after reboot)."; fails=$((fails+1))
  fi
  if persistence_ok; then
    ok "Watchdog module will be present after a reboot."
  else
    err "Blacklist still present or no autoload configured — fix won't survive reboot."
    fails=$((fails+1))
  fi

  rule
  if [ "$fails" -eq 0 ]; then
    ok "${C_BLD}PASS${C_RST} — watchdog protection fully restored. Well done."
    return 0
  fi
  err "${C_BLD}NOT YET${C_RST} — ${fails} check(s) failing. Keep going (hints in 'briefing')."
  return 1
}

# --- REVERT (instructor reset) ---------------------------------------------
do_revert() {
  require_root
  require_systemd
  info "Reverting lab 364.1 to a healthy state..."

  rm -f "$BREAK_BLACKLIST"
  if [ -f "$WD_CONF_BACKUP" ]; then
    cp -a "$WD_CONF_BACKUP" "$WD_CONF"
    info "Restored original ${WD_CONF}."
  else
    write_watchdog_conf "$GOOD_DEV"
    info "Wrote a healthy ${WD_CONF} (no original backup was found)."
  fi
  # Make sure it points at a real device even if the backup was broken.
  if ! [ -c "$(conf_device)" ]; then
    write_watchdog_conf "$GOOD_DEV"
  fi

  ensure_safety_modopts
  echo softdog > "$MODLOAD_HINT"
  modprobe softdog 2>/dev/null || warn "softdog may be built-in or already present."
  systemctl enable watchdog >/dev/null 2>&1 || true
  systemctl restart watchdog 2>/dev/null || warn "Could not start watchdog.service."

  rm -f "${STATE_DIR}/364.1.broken" 2>/dev/null || true
  ok "Revert complete. (Lab safety file ${SAFE_MODOPTS} left in place.)"
  systemctl --no-pager --full status watchdog 2>/dev/null | sed -n '1,6p' || true
}

# --- dispatch ---------------------------------------------------------------
main() {
  case "${1:-break}" in
    break|"")   do_break ;;
    briefing)   print_briefing ;;
    verify)     do_verify ;;
    revert)     do_revert ;;
    *) err "Unknown action: $1"; echo "Usage: $0 [break|briefing|verify|revert]" >&2; exit 2 ;;
  esac
}
main "${1:-}"

# ============================================================================
#  SOLUTION — step-by-step (instructor reference; do not read before trying)
# ============================================================================
#
#  0. Confirm the diagnosis. Two independent faults were injected.
#       systemctl status watchdog
#       journalctl -u watchdog -b --no-pager
#         -> "cannot open /dev/watchdog-lab-missing (errno = 2 = 'No such
#             file or directory')"   ... fault #2 (wrong device path)
#       ls -l /dev/watchdog*         -> nothing                ... fault #1
#       lsmod | grep -i dog          -> nothing                ... fault #1
#       ls -l /etc/modprobe.d/ | grep teach-plat
#         -> teach-plat-364-1-break.conf contains "blacklist softdog"
#
#  1. Remove the module blacklist so softdog can load again.
#       rm -f /etc/modprobe.d/teach-plat-364-1-break.conf
#       depmod -a            # refresh module dependency/blacklist state
#
#  2. Load the software watchdog now, and prove the device appears.
#       modprobe softdog
#       lsmod | grep softdog
#       ls -l /dev/watchdog /dev/watchdog0
#       wdctl /dev/watchdog          # shows timeout, identity, flags
#     (In this lab softdog loads with soft_noboot=1 from the safety file, so it
#      will only log on timeout. That is a LAB setting; production omits it.)
#
#  3. Make the module load automatically on every boot (persistence).
#       echo softdog > /etc/modules-load.d/softdog.conf
#     (Debian alternative: set watchdog_module="softdog" in /etc/default/watchdog.)
#
#  4. Fix the daemon config to point at the real device.
#       # edit /etc/watchdog.conf:
#       #   watchdog-device = /dev/watchdog
#       sed -i 's|^\s*watchdog-device.*|watchdog-device = /dev/watchdog|' /etc/watchdog.conf
#
#  5. Start and enable the service, then confirm it is healthy.
#       systemctl restart watchdog
#       systemctl enable watchdog
#       systemctl status watchdog            # -> Active: running
#       journalctl -u watchdog -b --no-pager # -> keep-alive activity, no errors
#
#  6. Prove the timer is actually being fed (the daemon holds the device open).
#       sudo fuser -v /dev/watchdog          # shows the 'watchdog' process
#       #   or:  sudo lsof /dev/watchdog
#
#  7. Grade it.
#       sudo ./break_fix.sh verify           # exits 0 when all checks pass
#
#  WHY THIS MATTERS (production framing)
#    - Only ONE process may hold /dev/watchdog. If systemd's own runtime
#      watchdog is enabled (RuntimeWatchdogSec in /etc/systemd/system.conf),
#      it grabs the device and the watchdog daemon fails with EBUSY. Pick one
#      owner. In an SBD/Pacemaker setup, sbd is usually that owner.
#    - `nowayout` (module/config) decides whether closing the device stops the
#      countdown. With nowayout=1 the box WILL reset even if the daemon exits
#      cleanly — safer for real HA, dangerous for a lab, hence soft_noboot=1.
#    - The bug was "silent": the URL/service existed but protection was off.
#      Always verify the watchdog is *held open and fed*, not merely installed.
#
#  Reset the lab for the next student:
#       sudo ./break_fix.sh revert
# ============================================================================