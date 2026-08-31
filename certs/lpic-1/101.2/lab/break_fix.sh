#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 v5.0 — Exam 101-500 — Topic 101.2 "Boot the system" (weight: 4.69)
#  Break & Fix laboratory driver
# =============================================================================
#
#  Objective coverage (LPI 101.2 key knowledge areas):
#    * Provide common commands to the boot loader and options to the kernel
#      at boot time (GRUB 2 interactive editor, /proc/cmdline)
#    * Demonstrate knowledge of the boot sequence from BIOS/UEFI to boot
#      completion (firmware -> boot loader -> kernel -> initramfs -> init)
#    * Understanding of SysVinit and systemd
#    * Awareness of Upstart
#    * Check boot events in the log files (dmesg, journalctl -b)
#    Terms: dmesg, journalctl, /var/log/, initramfs, init, SysVinit, systemd
#    Source: https://www.lpi.org/our-certifications/exam-101-objectives/
#
#  WHAT THIS SCRIPT DOES
#    It performs ONE controlled, reversible sabotage of the boot path, writes a
#    briefing describing the symptom and the objective, and then grades the
#    student's repair with `verify`. Every modified file is backed up first and
#    `restore` puts the machine back exactly as it was found.
#
#  HARD REQUIREMENTS — read before running
#    1. A DISPOSABLE lab VM. Take a snapshot / checkpoint FIRST.
#    2. CONSOLE access (virt-manager, VirtualBox, vSphere, `virsh console`,
#       Proxmox noVNC). Scenarios 1, 2 and 4 stop the boot before sshd starts:
#       an SSH-only session WILL lock you out.
#    3. Root privileges.
#    4. Never on a machine that matters. There is no undo besides `restore`
#       and your snapshot.
#
#  USAGE
#    ./101.2-break-and-fix.sh list
#    ./101.2-break-and-fix.sh break cmdline|initramfs|default-target|fstab|random
#    ./101.2-break-and-fix.sh status
#    ./101.2-break-and-fix.sh verify        # run AFTER the student's repair
#    ./101.2-break-and-fix.sh restore       # instructor escape hatch
#    Flags: --yes (no interactive confirmation), --force (allow bare metal /
#           allow stacking a second scenario)
#
#  The complete step-by-step solution is at the BOTTOM of this file, commented.
#  Do not read it before you have tried. Instructors: `sed -n '/^# SOLUTION/,$p'`
# =============================================================================

set -Eeuo pipefail

readonly LAB_ID="101.2"
readonly LAB_DIR="/root/lab-${LAB_ID}"
readonly BACKUP_DIR="${LAB_DIR}/backup"
readonly STATE_FILE="${LAB_DIR}/STATE"
readonly BRIEFING="${LAB_DIR}/BRIEFING.txt"
readonly BRIEFING_ROOT="/BRIEFING-${LAB_ID}.txt"   # readable from an emergency shell
readonly GRUB_DEFAULTS="/etc/default/grub"
readonly PHANTOM_UUID="dead1012-0000-4000-8000-000000000101"
readonly PHANTOM_MNT="/mnt/lab-phantom"
readonly SABOTAGE_ARG="systemd.unit=emergency.target"
readonly INITRD_SUFFIX=".lab-${LAB_ID}-backup"

OPT_YES=0
OPT_FORCE=0
GRUB_CFG=""
GRUB_MKCONFIG=""
FIRMWARE=""
USES_BLS=0

# --- output helpers ----------------------------------------------------------
c_red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_cya()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
log()    { printf '[ %s ] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn()   { c_ylw "[WARN] $*" >&2; }
die()    { c_red  "[FATAL] $*" >&2; exit 1; }
rule()   { printf '%s\n' "-------------------------------------------------------------------------------"; }

trap 'die "aborted at line $LINENO (exit $?). Inspect ${STATE_FILE} and run: $0 restore"' ERR

# --- environment discovery ---------------------------------------------------
detect_environment() {
  [ "$(id -u)" -eq 0 ] || die "root privileges are required."

  if [ -d /sys/firmware/efi ]; then FIRMWARE="UEFI"; else FIRMWARE="BIOS (legacy)"; fi

  local candidate
  for candidate in /boot/grub/grub.cfg /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg; do
    if [ -f "$candidate" ]; then GRUB_CFG="$candidate"; break; fi
  done

  if   command -v update-grub    >/dev/null 2>&1; then GRUB_MKCONFIG="update-grub"
  elif command -v grub2-mkconfig >/dev/null 2>&1; then GRUB_MKCONFIG="grub2-mkconfig"
  elif command -v grub-mkconfig  >/dev/null 2>&1; then GRUB_MKCONFIG="grub-mkconfig"
  else GRUB_MKCONFIG=""; fi

  # BootLoaderSpec systems (RHEL/CentOS/Alma/Rocky 8+, Fedora): the kernel
  # command line lives in /boot/loader/entries/*.conf, NOT in grub.cfg, and is
  # managed with grubby. Regenerating grub.cfg there does not change the cmdline.
  if [ -d /boot/loader/entries ] && compgen -G "/boot/loader/entries/*.conf" >/dev/null \
     && command -v grubby >/dev/null 2>&1; then
    USES_BLS=1
  fi

  command -v systemctl >/dev/null 2>&1 || die "this lab targets systemd-based distributions."
}

safety_gate() {
  local virt="none"
  command -v systemd-detect-virt >/dev/null 2>&1 && virt="$(systemd-detect-virt || true)"

  case "$virt" in
    lxc|lxc-libvirt|docker|podman|systemd-nspawn|wsl|openvz)
      die "container detected ($virt). There is no boot loader or kernel of your own here." ;;
    none)
      if [ "$OPT_FORCE" -ne 1 ]; then
        die "no hypervisor detected — this looks like bare metal. Refusing. Use --force only on a machine you are willing to lose."
      fi
      warn "bare metal + --force. You accepted the consequences." ;;
    *)
      log "virtualization: ${virt} — good, this looks like a lab VM." ;;
  esac

  if [ -f "$STATE_FILE" ] && [ "$OPT_FORCE" -ne 1 ]; then
    c_ylw "A scenario is already active:"; sed -n 's/^/    /p' "$STATE_FILE"
    die "run '$0 verify' or '$0 restore' first (--force stacks a second break, which makes diagnosis unfair)."
  fi

  [ "$OPT_YES" -eq 1 ] && return 0

  rule
  c_red "  THIS SCRIPT WILL DELIBERATELY PREVENT THIS MACHINE FROM BOOTING NORMALLY."
  rule
  printf '  Host      : %s\n'  "$(hostname)"
  printf '  Kernel    : %s\n'  "$(uname -r)"
  printf '  Firmware  : %s\n'  "$FIRMWARE"
  printf '  Boot loader cfg : %s\n' "${GRUB_CFG:-<not found>}"
  printf '  BLS entries     : %s\n' "$( [ "$USES_BLS" -eq 1 ] && echo 'yes (grubby)' || echo 'no' )"
  rule
  printf '  You need CONSOLE access to recover. SSH alone is NOT enough.\n'
  printf '  Type SNAPSHOT-TAKEN to confirm you have a VM snapshot: '
  local answer; read -r answer
  [ "$answer" = "SNAPSHOT-TAKEN" ] || die "confirmation not given. Nothing was modified."
}

# --- backup / state ----------------------------------------------------------
backup_file() {
  local src="$1" flat
  flat="$(printf '%s' "${src#/}" | tr '/' '_')"
  mkdir -p "$BACKUP_DIR"
  if [ -e "$src" ] && [ ! -e "${BACKUP_DIR}/${flat}.orig" ]; then
    cp -a "$src" "${BACKUP_DIR}/${flat}.orig"
    log "backed up ${src} -> ${BACKUP_DIR}/${flat}.orig"
  fi
}

restore_backup() {
  local src="$1" flat
  flat="$(printf '%s' "${src#/}" | tr '/' '_')"
  if [ -e "${BACKUP_DIR}/${flat}.orig" ]; then
    cp -a "${BACKUP_DIR}/${flat}.orig" "$src"
    log "restored ${src}"
  fi
}

state_put() { printf '%s=%q\n' "$1" "$2" >> "$STATE_FILE"; }
state_get() {
  [ -f "$STATE_FILE" ] || return 1
  # shellcheck disable=SC1090
  local key="$1" line
  line="$(grep -E "^${key}=" "$STATE_FILE" | tail -n 1 || true)"
  [ -n "$line" ] || return 1
  eval "printf '%s' ${line#*=}"
}

record_pre_state() {
  mkdir -p "$LAB_DIR" "$BACKUP_DIR"; chmod 700 "$LAB_DIR"
  : > "$STATE_FILE"
  state_put SCENARIO        "$1"
  state_put BREAK_AT        "$(date -Is)"
  state_put PRE_CMDLINE     "$(cat /proc/cmdline)"
  state_put PRE_KERNEL      "$(uname -r)"
  state_put PRE_TARGET      "$(systemctl get-default)"
  state_put PRE_BOOT_ID     "$(cat /proc/sys/kernel/random/boot_id)"
  state_put FIRMWARE        "$FIRMWARE"
  state_put GRUB_CFG        "${GRUB_CFG:-}"
  state_put USES_BLS        "$USES_BLS"
}

# --- boot loader helpers -----------------------------------------------------
grub_regen() {
  [ -n "$GRUB_MKCONFIG" ] || die "no grub-mkconfig/update-grub found; cannot rewrite ${GRUB_CFG}."
  log "regenerating boot loader configuration (${GRUB_MKCONFIG})"
  case "$GRUB_MKCONFIG" in
    update-grub) update-grub >/dev/null ;;
    *)           "$GRUB_MKCONFIG" -o "${GRUB_CFG:?grub.cfg location unknown}" >/dev/null 2>&1 ;;
  esac
}

# Make sure the student can actually reach the interactive GRUB editor.
# A hidden, zero-second menu turns a teachable failure into an unrecoverable one.
ensure_grub_menu_visible() {
  backup_file "$GRUB_DEFAULTS"
  local f="$GRUB_DEFAULTS"
  [ -f "$f" ] || return 0
  if grep -qE '^[[:space:]]*GRUB_TIMEOUT=' "$f"; then
    sed -ri 's|^[[:space:]]*GRUB_TIMEOUT=.*|GRUB_TIMEOUT=15|' "$f"
  else
    printf 'GRUB_TIMEOUT=15\n' >> "$f"
  fi
  if grep -qE '^[[:space:]]*GRUB_TIMEOUT_STYLE=' "$f"; then
    sed -ri 's|^[[:space:]]*GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|' "$f"
  else
    printf 'GRUB_TIMEOUT_STYLE=menu\n' >> "$f"
  fi
  log "GRUB menu forced visible for 15 s (this is a lab, not extra sabotage)."
}

grub_default_get_cmdline() {
  sed -rn 's/^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT="?([^"]*)"?.*/\1/p' "$GRUB_DEFAULTS" | tail -n 1
}

grub_default_set_cmdline() {
  local value="$1"
  if grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULTS"; then
    sed -ri "s|^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${value}\"|" "$GRUB_DEFAULTS"
  else
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$value" >> "$GRUB_DEFAULTS"
  fi
}

running_initrd_path() {
  local kver; kver="$(uname -r)"
  local p
  for p in "/boot/initrd.img-${kver}" "/boot/initramfs-${kver}.img" "/boot/initrd-${kver}"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# --- briefing ----------------------------------------------------------------
write_briefing() {
  local scenario="$1" symptom="$2" goal="$3" hints="$4" rules="$5"
  {
    printf '===============================================================================\n'
    printf ' LPIC-1 101.2 "Boot the system" — BREAK & FIX — scenario: %s\n' "$scenario"
    printf ' Broken at: %s   Host: %s   Firmware: %s\n' "$(date -Is)" "$(hostname)" "$FIRMWARE"
    printf '===============================================================================\n\n'
    printf 'SYMPTOM YOU ARE ABOUT TO SEE\n%s\n\n' "$symptom"
    printf 'WHAT YOU MUST ACHIEVE\n%s\n\n' "$goal"
    printf 'TOOLS AND PLACES TO LOOK\n%s\n\n' "$hints"
    printf 'RULES OF THE EXERCISE\n%s\n\n' "$rules"
    printf 'GRADING\n'
    printf '  When you believe the system is repaired, run as root:\n'
    printf '      %s verify\n' "$LAB_DIR/$(basename "$0")"
    printf '  The grader checks the running state, not just the files: it requires a\n'
    printf '  successful reboot into the original default target with a clean cmdline.\n\n'
    printf 'ESCAPE HATCH (instructor)\n'
    printf '      %s restore     # undoes every change made by this script\n' "$LAB_DIR/$(basename "$0")"
    printf '  Machine state before the break is recorded in %s\n' "$STATE_FILE"
  } > "$BRIEFING"
  cp -f "$BRIEFING" "$BRIEFING_ROOT"
  cp -f "$0" "${LAB_DIR}/$(basename "$0")" 2>/dev/null || true
  chmod 0644 "$BRIEFING_ROOT"
  cat "$BRIEFING"
  rule
  c_cya "Briefing saved to ${BRIEFING} and to ${BRIEFING_ROOT} (reachable from a rescue shell)."
}

countdown_reboot() {
  rule
  c_ylw "The machine will reboot into the broken state in 20 seconds."
  c_ylw "Switch to the VM CONSOLE now. Ctrl-C cancels the reboot (the break stays applied)."
  local i
  for i in $(seq 20 -1 1); do printf '\r  rebooting in %2d s ' "$i"; sleep 1; done
  printf '\n'
  systemctl reboot
}

# =============================================================================
#  SCENARIO 1 — cmdline: the kernel command line forces emergency mode
# =============================================================================
break_cmdline() {
  record_pre_state cmdline
  ensure_grub_menu_visible

  if [ "$USES_BLS" -eq 1 ]; then
    state_put SABOTAGE_METHOD grubby
    backup_file /etc/kernel/cmdline
    log "injecting '${SABOTAGE_ARG}' into every BLS entry with grubby"
    grubby --update-kernel=ALL --args="${SABOTAGE_ARG}" >/dev/null
    grubby --update-kernel=ALL --remove-args="quiet rhgb" >/dev/null || true
  else
    state_put SABOTAGE_METHOD grub-defaults
    backup_file "$GRUB_DEFAULTS"
    local cur new
    cur="$(grub_default_get_cmdline || true)"
    new="$(printf '%s' "$cur" | sed -re 's/\bquiet\b//g; s/\bsplash\b//g; s/\brhgb\b//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
    new="${new:+$new }${SABOTAGE_ARG}"
    grub_default_set_cmdline "$new"
    log "GRUB_CMDLINE_LINUX_DEFAULT is now: ${new}"
    grub_regen
  fi

  write_briefing "cmdline (difficulty: 2/5 — ~15 min)" \
"  The machine no longer reaches a login prompt. After the GRUB menu the kernel
  boots normally (you WILL see kernel messages now — 'quiet' was removed on
  purpose), systemd starts, and then everything stops at:

      You are in emergency mode. After logging in, type \"journalctl -xb\" to view
      system logs, \"systemctl reboot\" to reboot, \"systemctl default\" or \"exit\"
      to boot into default mode.
      Give root password for maintenance (or press Control-D to continue):

  No network, no sshd, no getty on tty2. The root filesystem IS mounted and
  healthy — nothing is corrupted. Note carefully that this is NOT a disk error:
  systemd was *told* to stop here." \
"  1. Prove WHY it stopped, from inside the machine, without guessing: the
     evidence is on the kernel command line the running kernel received.
  2. Get this single boot to reach the normal default target WITHOUT rebooting,
     from the emergency shell.
  3. Make the fix permanent so the next reboot is clean, editing the boot
     loader configuration source — not the generated file by hand.
  4. Reboot and confirm the machine comes up on its own.
  Success = 'systemctl get-default' unchanged from before, /proc/cmdline free of
  the injected parameter, and a normal multi-user boot." \
"  * /proc/cmdline                 — what the running kernel was actually given
  * GRUB menu -> press 'e'        — edit the boot entry for ONE boot only
                                     (Ctrl-x or F10 boots the edited entry)
  * systemctl default | systemctl isolate multi-user.target
  * systemctl get-default / set-default
  * journalctl -b / journalctl -xb / dmesg
  * ${GRUB_DEFAULTS} , then update-grub | grub2-mkconfig -o ${GRUB_CFG:-/boot/grub2/grub.cfg}
  * On RHEL/Fedora with BootLoaderSpec: grubby --info=ALL , /boot/loader/entries/
  * The root password for maintenance is the normal root password of this VM." \
"  * Do NOT restore the VM snapshot; that teaches nothing.
  * Do NOT edit ${GRUB_CFG:-grub.cfg} directly — it is a generated file.
  * Editing the GRUB entry with 'e' is the correct emergency action, but it is
    NOT the permanent fix; both steps are required."
}

# =============================================================================
#  SCENARIO 2 — initramfs: the initial RAM filesystem of the running kernel is gone
# =============================================================================
break_initramfs() {
  local initrd kver
  kver="$(uname -r)"
  initrd="$(running_initrd_path)" || die "no initramfs found for ${kver}; this kernel may boot without one — pick another scenario."

  record_pre_state initramfs
  ensure_grub_menu_visible
  state_put INITRD_PATH "$initrd"
  state_put INITRD_BACKUP "${initrd}${INITRD_SUFFIX}"

  local kcount
  kcount="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -o -maxdepth 1 -name 'vmlinux-*' | wc -l)"
  [ "$kcount" -gt 1 ] || warn "only one kernel is installed: the ONLY recovery path is the backup initramfs left in /boot."

  # The backup deliberately stays inside /boot so that GRUB can load it from the
  # interactive editor. That is the intended rescue path.
  cp -a "$initrd" "${initrd}${INITRD_SUFFIX}"
  rm -f "$initrd"
  log "removed ${initrd} (copy kept as ${initrd}${INITRD_SUFFIX})"
  grub_regen || true

  write_briefing "initramfs (difficulty: 4/5 — ~30 min)" \
"  GRUB starts, you pick the default entry, and the boot dies immediately with
  something very close to:

      error: file '/boot/initrd.img-${kver}' not found.
      Press any key to continue...

  and then, a second later, the kernel itself panics because it has no root
  filesystem driver stack and no /sbin/init:

      VFS: Cannot open root device \"...\" or unknown-block(0,0): error -6
      Please append a correct \"root=\" boot option
      Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)

  You never reach a shell. There is no emergency mode here — userspace never
  started. Everything you do at first must be done from GRUB itself." \
"  1. Understand what stage of the boot sequence failed and why the kernel
     cannot mount / without this file (firmware -> GRUB -> kernel -> initramfs
     -> /sbin/init: name the broken arrow).
  2. Boot the system ONCE, by hand. Two legitimate routes:
       a) select an older kernel from 'Advanced options for ...', or
       b) press 'e' and point the 'initrd' line at the intact backup image that
          is still present in /boot (list it from the GRUB command line with
          'ls (hd0,gpt2)/' or 'ls /boot/').
  3. Once running, REBUILD the missing initramfs for kernel ${kver} with the
     distribution's own tool. Copying the backup over it is accepted only if
     you can also show the rebuild command that would have produced it.
  4. Reboot on the default entry and confirm you are running ${kver}." \
"  * GRUB menu: 'e' to edit, 'c' for the GRUB command line, TAB completion works
  * GRUB reads /boot itself: ls, cat, set root=, linux, initrd, boot
  * Debian/Ubuntu : update-initramfs -c -k ${kver}   (or -u to update)
                    lsinitramfs /boot/initrd.img-${kver} | head
  * RHEL/Fedora   : dracut --force /boot/initramfs-${kver}.img ${kver}
                    lsinitrd /boot/initramfs-${kver}.img | head
  * uname -r , ls -l /boot , dmesg | head -40 , journalctl -b -k
  * Remember: after any manual /boot change on non-BLS systems, regenerate the
    boot loader config (update-grub | grub2-mkconfig -o ...)." \
"  * The backup image ${initrd}${INITRD_SUFFIX} exists on purpose: it is your
    rescue rope, not the solution. Leave a properly named, freshly built
    initramfs behind.
  * If you end up at 'grub rescue>' instead of 'grub>', say so — that is a
    different failure (missing modules/prefix) and not what this lab caused."
}

# =============================================================================
#  SCENARIO 3 — default target: systemd boots into rescue.target
# =============================================================================
break_default_target() {
  record_pre_state default-target
  local pre; pre="$(systemctl get-default)"
  backup_file /etc/systemd/system/default.target
  log "current default target: ${pre} -> rescue.target"
  systemctl set-default rescue.target >/dev/null
  # A second, subtler layer: mask the graphical target so a naive
  # 'set-default graphical.target' is not enough on a desktop VM.
  if [ "$pre" = "graphical.target" ]; then
    systemctl mask graphical.target >/dev/null
    state_put MASKED_GRAPHICAL 1
    log "graphical.target masked as well"
  fi

  write_briefing "default-target (difficulty: 1/5 — ~10 min)" \
"  The machine boots to completion — no panic, no emergency, the disk is fine —
  but it stops at:

      You are in rescue mode. After logging in, type \"journalctl -xb\" to view
      system logs...
      Give root password for maintenance (or press Control-D to continue):

  After logging in you find: no network (NetworkManager/systemd-networkd not
  started), no sshd, no display manager, only one console. 'systemctl
  list-units --type=target' shows rescue.target reached and multi-user.target
  NOT reached. Nothing in dmesg looks wrong, because nothing IS wrong at the
  kernel level: this is a policy failure, not a hardware or filesystem one." \
"  1. Say precisely which systemd unit the machine was told to reach and where
     that decision is stored on disk (hint: it is a symbolic link).
  2. Bring the CURRENT boot up to the normal target without rebooting.
  3. Restore the permanent default so that the next boot is normal. It was
     '${pre}' before the break.
  4. If a unit was masked, detect that (it is not the same as 'disabled') and
     unmask it.
  5. Reboot and confirm.
  Success = 'systemctl get-default' returns '${pre}', the target is active, and
  the system is reachable again over the network." \
"  * systemctl get-default / set-default <target>
  * ls -l /etc/systemd/system/default.target        (the link is the truth)
  * systemctl list-units --type=target --all
  * systemctl isolate multi-user.target | systemctl default
  * systemctl is-enabled <unit>   -> 'masked' vs 'disabled' vs 'enabled'
  * systemctl unmask <unit> ; ls -l /etc/systemd/system/<unit>  (-> /dev/null)
  * systemd targets vs SysVinit runlevels: runlevel3 -> multi-user.target,
    runlevel5 -> graphical.target, runlevel1/S -> rescue.target, and
    'systemctl rescue' / 'systemctl emergency' are the modern 'telinit 1'
  * journalctl -b -o short-monotonic | tail -40" \
"  * You may also force one boot from GRUB with systemd.unit=... — worth trying
    to prove you understand the precedence: kernel cmdline beats default.target.
  * Do not disable or delete rescue.target; it must stay usable."
}

# =============================================================================
#  SCENARIO 4 — fstab: a phantom device blocks local-fs.target
# =============================================================================
break_fstab() {
  record_pre_state fstab
  backup_file /etc/fstab
  mkdir -p "$PHANTOM_MNT"
  printf '\n# lab %s — phantom device (added by the break & fix script)\nUUID=%s  %s  ext4  defaults  0 2\n' \
    "$LAB_ID" "$PHANTOM_UUID" "$PHANTOM_MNT" >> /etc/fstab
  systemctl daemon-reload
  log "phantom UUID=${PHANTOM_UUID} added to /etc/fstab for ${PHANTOM_MNT}"

  write_briefing "fstab (difficulty: 3/5 — ~20 min)" \
"  The boot appears to hang. For about 90 seconds you see (or, if 'quiet' is
  set, you see nothing until the timeout expires):

      A start job is running for /dev/disk/by-uuid/${PHANTOM_UUID} (1min 30s / no limit)

  then:

      Timed out waiting for device /dev/disk/by-uuid/${PHANTOM_UUID}.
      [DEPEND] Dependency failed for ${PHANTOM_MNT}.
      [DEPEND] Dependency failed for Local File Systems.
      You are in emergency mode...

  The root filesystem is intact and already mounted (read-write or read-only
  depending on the distribution — check before you try to save a file)." \
"  1. Identify the exact failing unit. systemd generated it from a file; name
     both the unit and the file, and explain the .mount/.device naming rule
     (the escaping of '/' and '-').
  2. Repair the boot WITHOUT rebooting: make the current boot reach the default
     target from the emergency shell.
  3. Choose and justify a permanent fix: remove the entry, or keep it and make
     it non-fatal. If you keep it, the boot must never again block for 90 s.
  4. Validate the file BEFORE rebooting — rebooting to test /etc/fstab is how
     one 90-second outage becomes three.
  5. Reboot and confirm a clean boot with no failed units.
  Success = no failed units, ${PHANTOM_MNT} no longer required at boot, and
  'systemctl is-system-running' returns 'running'." \
"  * systemctl --failed ; systemctl status 'mnt-lab\\\\x2dphantom.mount'
  * systemd-escape -p --suffix=mount ${PHANTOM_MNT}
  * journalctl -xb -p err ; journalctl -b -u systemd-fstab-generator
  * mount -o remount,rw /        (the emergency shell often starts read-only)
  * findmnt --verify --verbose   (validates /etc/fstab offline — use this)
  * mount -a                     (must be silent before you reboot)
  * systemctl daemon-reload      (mandatory after editing /etc/fstab)
  * fstab options worth knowing: nofail, noauto, x-systemd.device-timeout=10s,
    x-systemd.automount — and blkid / lsblk -f to see the UUIDs that DO exist
  * The 6 fstab fields: device, mountpoint, fstype, options, dump, fsck-order —
    the last field is why a phantom entry is fatal instead of merely ignored." \
"  * Fix the cause in /etc/fstab; do not 'solve' it by masking local-fs.target.
  * Leave ${PHANTOM_MNT} either gone from fstab or provably harmless at boot."
}

# =============================================================================
#  Verification (grading)
# =============================================================================
verify() {
  [ -f "$STATE_FILE" ] || die "no active scenario. Nothing to verify."
  local scenario pre_target pre_boot pre_kernel now_boot fails=0

  scenario="$(state_get SCENARIO)"
  pre_target="$(state_get PRE_TARGET)"
  pre_boot="$(state_get PRE_BOOT_ID)"
  pre_kernel="$(state_get PRE_KERNEL)"
  now_boot="$(cat /proc/sys/kernel/random/boot_id)"

  rule; c_cya "Grading scenario: ${scenario}"; rule

  check() { # check <description> <0|1 result>
    if [ "$2" -eq 0 ]; then c_grn "  PASS  $1"; else c_red "  FAIL  $1"; fails=$((fails+1)); fi
  }

  # --- checks common to every scenario ---
  [ "$now_boot" != "$pre_boot" ] && check "the machine was rebooted after the break (new boot id)" 0 \
                                 || check "the machine was rebooted after the break (new boot id)" 1

  [ "$(systemctl get-default)" = "$pre_target" ] \
    && check "default target is back to ${pre_target}" 0 \
    || check "default target is ${pre_target} (found: $(systemctl get-default))" 1

  case "$(systemctl is-system-running || true)" in
    running|degraded) check "systemd reached a normal target (not rescue/emergency/maintenance)" 0 ;;
    *)                check "systemd reached a normal target (found: $(systemctl is-system-running || true))" 1 ;;
  esac

  grep -qE 'systemd\.unit=(emergency|rescue)\.target|(^| )(single|1|s|S)( |$)' /proc/cmdline \
    && check "running kernel command line has no single-user/emergency override" 1 \
    || check "running kernel command line has no single-user/emergency override" 0

  # --- per-scenario checks ---
  case "$scenario" in
    cmdline)
      grep -q "$SABOTAGE_ARG" /proc/cmdline \
        && check "/proc/cmdline is clean of '${SABOTAGE_ARG}'" 1 \
        || check "/proc/cmdline is clean of '${SABOTAGE_ARG}'" 0
      if [ "$(state_get USES_BLS)" = "1" ]; then
        grubby --info=ALL 2>/dev/null | grep -q "$SABOTAGE_ARG" \
          && check "no BLS entry still carries the parameter (grubby --info=ALL)" 1 \
          || check "no BLS entry still carries the parameter (grubby --info=ALL)" 0
      else
        grep -q "$SABOTAGE_ARG" "$GRUB_DEFAULTS" \
          && check "${GRUB_DEFAULTS} no longer contains the parameter" 1 \
          || check "${GRUB_DEFAULTS} no longer contains the parameter" 0
        if [ -n "${GRUB_CFG}" ] && [ -f "$GRUB_CFG" ]; then
          grep -q "$SABOTAGE_ARG" "$GRUB_CFG" \
            && check "${GRUB_CFG} was regenerated (parameter gone)" 1 \
            || check "${GRUB_CFG} was regenerated (parameter gone)" 0
        fi
      fi
      ;;
    initramfs)
      local ip; ip="$(state_get INITRD_PATH)"
      [ -s "$ip" ] && check "the initramfs ${ip} exists and is not empty" 0 \
                   || check "the initramfs ${ip} exists and is not empty" 1
      [ "$(uname -r)" = "$pre_kernel" ] \
        && check "the system booted the original kernel ${pre_kernel}" 0 \
        || check "the system booted the original kernel ${pre_kernel} (found $(uname -r))" 1
      if [ -s "$ip" ]; then
        local age; age="$(( $(date +%s) - $(stat -c %Y "$ip") ))"
        [ "$age" -lt 86400 ] && check "the image is recent (rebuilt or restored in this session)" 0 \
                             || check "the image is recent (rebuilt or restored in this session)" 1
      fi
      ;;
    default-target)
      [ -L /etc/systemd/system/default.target ] \
        && check "/etc/systemd/system/default.target is a symlink to ${pre_target}" 0 \
        || check "/etc/systemd/system/default.target is a symlink to ${pre_target}" 1
      systemctl is-active "$pre_target" >/dev/null 2>&1 \
        && check "${pre_target} is active right now" 0 \
        || check "${pre_target} is active right now" 1
      if [ "$(state_get MASKED_GRAPHICAL 2>/dev/null || echo 0)" = "1" ]; then
        [ "$(systemctl is-enabled graphical.target 2>/dev/null || true)" = "masked" ] \
          && check "graphical.target was unmasked" 1 \
          || check "graphical.target was unmasked" 0
      fi
      ;;
    fstab)
      grep -q "$PHANTOM_UUID" /etc/fstab && grep "$PHANTOM_UUID" /etc/fstab | grep -qv nofail \
        && check "the phantom entry is gone from /etc/fstab, or carries nofail" 1 \
        || check "the phantom entry is gone from /etc/fstab, or carries nofail" 0
      findmnt --verify >/dev/null 2>&1 \
        && check "findmnt --verify accepts /etc/fstab" 0 \
        || check "findmnt --verify accepts /etc/fstab" 1
      [ "$(systemctl --failed --no-legend | wc -l)" -eq 0 ] \
        && check "no failed units" 0 \
        || { check "no failed units" 1; systemctl --failed --no-legend | sed 's/^/        /'; }
      ;;
  esac

  rule
  if [ "$fails" -eq 0 ]; then
    c_grn "ALL CHECKS PASSED — scenario '${scenario}' repaired."
    c_grn "Clearing the lab state. Run '$0 break <scenario>' for the next one."
    rm -f "$BRIEFING_ROOT"; rm -f "$STATE_FILE"
    return 0
  fi
  c_red "${fails} check(s) failed — keep working, or ask for the solution."
  return 1
}

# =============================================================================
#  Restore (instructor escape hatch)
# =============================================================================
restore() {
  [ -f "$STATE_FILE" ] || { warn "no active scenario recorded; restoring any backups found."; }
  local scenario; scenario="$(state_get SCENARIO 2>/dev/null || echo unknown)"
  log "restoring scenario: ${scenario}"

  case "$scenario" in
    cmdline)
      if [ "$(state_get SABOTAGE_METHOD 2>/dev/null || true)" = "grubby" ]; then
        grubby --update-kernel=ALL --remove-args="${SABOTAGE_ARG}" >/dev/null || true
        grubby --update-kernel=ALL --args="quiet" >/dev/null || true
      fi
      restore_backup "$GRUB_DEFAULTS"; grub_regen || true
      ;;
    initramfs)
      local ip bk; ip="$(state_get INITRD_PATH)"; bk="$(state_get INITRD_BACKUP)"
      [ -f "$bk" ] && { cp -a "$bk" "$ip"; rm -f "$bk"; log "initramfs restored to ${ip}"; }
      restore_backup "$GRUB_DEFAULTS"; grub_regen || true
      ;;
    default-target)
      [ "$(state_get MASKED_GRAPHICAL 2>/dev/null || echo 0)" = "1" ] && systemctl unmask graphical.target >/dev/null || true
      systemctl set-default "$(state_get PRE_TARGET)" >/dev/null
      ;;
    fstab)
      restore_backup /etc/fstab; systemctl daemon-reload
      rmdir "$PHANTOM_MNT" 2>/dev/null || true
      ;;
    *)
      restore_backup "$GRUB_DEFAULTS"; restore_backup /etc/fstab; grub_regen || true
      ;;
  esac

  rm -f "$BRIEFING_ROOT"; rm -f "$STATE_FILE"
  c_grn "Restore complete. Reboot to confirm the machine is healthy again."
}

status() {
  if [ -f "$STATE_FILE" ]; then
    rule; c_cya "Active scenario"; rule; cat "$STATE_FILE"
    rule; c_cya "Live boot facts"; rule
    printf '  uname -r            : %s\n' "$(uname -r)"
    printf '  /proc/cmdline       : %s\n' "$(cat /proc/cmdline)"
    printf '  default target      : %s\n' "$(systemctl get-default)"
    printf '  is-system-running   : %s\n' "$(systemctl is-system-running || true)"
    printf '  failed units        : %s\n' "$(systemctl --failed --no-legend | wc -l)"
  else
    c_grn "No active scenario. The machine is (as far as this script knows) healthy."
  fi
}

list_scenarios() {
  cat <<'EOF'
Scenarios for LPIC-1 101.2 "Boot the system":

  cmdline          [2/5, ~15 min]  A kernel parameter forces emergency mode.
                                   Teaches: /proc/cmdline, the GRUB 'e' editor,
                                   generated vs source boot loader config,
                                   systemd.unit= precedence, grubby/BLS.

  initramfs        [4/5, ~30 min]  The initramfs of the running kernel is gone.
                                   Teaches: the firmware->GRUB->kernel->initramfs
                                   ->init chain, GRUB command line (ls/linux/
                                   initrd/boot), update-initramfs / dracut,
                                   reading a VFS kernel panic.

  default-target   [1/5, ~10 min]  systemd's default target is rescue.target.
                                   Teaches: targets vs SysVinit runlevels,
                                   default.target symlink, isolate, mask vs
                                   disable, journalctl -b.

  fstab            [3/5, ~20 min]  A phantom UUID in /etc/fstab stalls the boot
                                   and fails local-fs.target.
                                   Teaches: systemd-fstab-generator, .mount and
                                   .device unit naming/escaping, nofail and
                                   x-systemd.device-timeout, findmnt --verify.

  random                           Picks one of the four at random.
EOF
}

usage() { sed -n '2,60p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; }

# =============================================================================
#  Entry point
# =============================================================================
main() {
  local cmd="" scenario="" arg
  for arg in "$@"; do
    case "$arg" in
      --yes|-y)   OPT_YES=1 ;;
      --force)    OPT_FORCE=1 ;;
      -h|--help)  usage; exit 0 ;;
      break|verify|restore|status|list) [ -z "$cmd" ] && cmd="$arg" || scenario="$arg" ;;
      *)          scenario="$arg" ;;
    esac
  done
  [ -n "$cmd" ] || { usage; exit 1; }

  case "$cmd" in
    list)    list_scenarios; exit 0 ;;
    status)  detect_environment; status; exit 0 ;;
    verify)  detect_environment; verify; exit $? ;;
    restore) detect_environment; restore; exit 0 ;;
    break)   : ;;
    *)       usage; exit 1 ;;
  esac

  detect_environment

  if [ "$scenario" = "random" ] || [ -z "$scenario" ]; then
    local all=(cmdline initramfs default-target fstab)
    scenario="${all[$((RANDOM % 4))]}"
    log "random scenario selected: ${scenario}"
  fi

  safety_gate

  case "$scenario" in
    cmdline)         break_cmdline ;;
    initramfs)       break_initramfs ;;
    default-target)  break_default_target ;;
    fstab)           break_fstab ;;
    *) die "unknown scenario '${scenario}'. Run '$0 list'." ;;
  esac

  countdown_reboot
}

main "$@"

# =============================================================================
# SOLUTION — DO NOT READ UNTIL YOU HAVE TRIED
# =============================================================================
#
# -----------------------------------------------------------------------------
# SCENARIO 1 — cmdline (kernel parameter forces emergency mode)
# -----------------------------------------------------------------------------
# The chain to keep in mind: firmware (BIOS/UEFI) -> boot loader (GRUB 2) ->
# kernel + initramfs -> PID 1 (systemd). Here every stage succeeded. systemd
# started, read its command line, saw systemd.unit=emergency.target and obeyed.
#
#  1) Log in at the emergency prompt with the root password, then read the
#     evidence — the kernel's own copy of what it was launched with:
#
#         # cat /proc/cmdline
#         BOOT_IMAGE=/vmlinuz-6.1.0-18-amd64 root=UUID=8f3a... ro systemd.unit=emergency.target
#                                                                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
#     Confirm it from systemd's own point of view:
#         # systemctl get-default
#         graphical.target            <- the DEFAULT is fine; the cmdline overrode it
#         # journalctl -b | grep -i 'emergency\|Reached target'
#     Precedence rule to memorise: systemd.unit= on the kernel command line
#     BEATS /etc/systemd/system/default.target. The disk was never the problem.
#
#  2) Recover the CURRENT boot without rebooting:
#         # systemctl default                       # go to the configured default
#         # systemctl isolate multi-user.target     # or an explicit target
#     The machine finishes booting: network up, sshd up, getty on the ttys.
#
#  3) Make it permanent. Two families of systems:
#
#     (a) Debian/Ubuntu/openSUSE and any non-BLS GRUB 2 system — edit the SOURCE,
#         never /boot/grub/grub.cfg (it is generated and will be overwritten):
#             # cp /etc/default/grub /etc/default/grub.bak
#             # vi /etc/default/grub
#               GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"     <- remove the injected arg
#             # update-grub                    # Debian/Ubuntu wrapper
#             # grub2-mkconfig -o /boot/grub2/grub.cfg        # RHEL-family equivalent
#             Generating grub configuration file ...
#             Found linux image: /boot/vmlinuz-6.1.0-18-amd64
#             done
#
#     (b) RHEL/CentOS/Alma/Rocky 8+ and Fedora (BootLoaderSpec): grub.cfg does
#         NOT hold the command line; /boot/loader/entries/*.conf does.
#             # grubby --info=ALL | grep args
#             # grubby --update-kernel=ALL --remove-args="systemd.unit=emergency.target"
#             # grubby --update-kernel=ALL --args="quiet"
#             # grubby --info=ALL | grep args        # verify
#         (/etc/kernel/cmdline is the template used for NEW kernels there.)
#
#  4) Reboot and prove it:
#         # systemctl reboot
#         # cat /proc/cmdline        # the parameter is gone
#         # systemctl is-system-running -> running
#
#  Exam-relevant variant you should also be able to do: the ONE-BOOT fix from
#  the GRUB menu — highlight the entry, press 'e', move to the line starting
#  with 'linux' (or 'linuxefi'), delete the offending parameter (or append
#  systemd.unit=multi-user.target, or 'single' / 'init=/bin/bash' for a rescue),
#  then Ctrl-x / F10 to boot. Nothing typed in that editor is persistent; that
#  is exactly why it is safe, and exactly why step 3 is still required.
#
# -----------------------------------------------------------------------------
# SCENARIO 2 — initramfs (missing initial RAM filesystem)
# -----------------------------------------------------------------------------
# Broken arrow: kernel -> initramfs. GRUB loads vmlinuz fine, then fails to load
# the cpio archive that contains the storage/LVM/RAID/crypt modules and the
# early /init. Without it the kernel has no driver for the root device, so
# "Unable to mount root fs on unknown-block(0,0)" and panic.
#
#  1) Recover ONE boot. Either:
#     (a) GRUB menu -> "Advanced options for <distro>" -> pick an OLDER kernel,
#         which still has its own initramfs; or
#     (b) point this entry at the backup image. Press 'e' and change:
#             initrd  /boot/initrd.img-6.1.0-18-amd64
#         to
#             initrd  /boot/initrd.img-6.1.0-18-amd64.lab-101.2-backup
#         Ctrl-x to boot. If you are unsure of the exact filename, press 'c' for
#         the GRUB command line and explore — GRUB has its own filesystem drivers:
#             grub> ls
#             (hd0) (hd0,gpt1) (hd0,gpt2)
#             grub> ls (hd0,gpt2)/boot/
#             grub> set root=(hd0,gpt2)
#             grub> linux /boot/vmlinuz-6.1.0-18-amd64 root=UUID=8f3a... ro
#             grub> initrd /boot/initrd.img-6.1.0-18-amd64.lab-101.2-backup
#             grub> boot
#
#  2) Rebuild the real image with the distribution's tool:
#         Debian/Ubuntu:
#             # update-initramfs -c -k 6.1.0-18-amd64     # create
#             # update-initramfs -u -k all                # or update all
#             update-initramfs: Generating /boot/initrd.img-6.1.0-18-amd64
#             # lsinitramfs /boot/initrd.img-6.1.0-18-amd64 | head
#         RHEL/Fedora:
#             # dracut --force /boot/initramfs-$(uname -r).img $(uname -r)
#             # lsinitrd /boot/initramfs-$(uname -r).img | head
#     Then verify size and ownership:
#             # ls -lh /boot/initrd.img-*        # tens of MB, root:root, 0600/0644
#
#  3) On non-BLS systems refresh the boot loader config so the menu points at the
#     correct file, and remove the rescue copy:
#             # update-grub          (or: grub2-mkconfig -o /boot/grub2/grub.cfg)
#             # rm -f /boot/initrd.img-*.lab-101.2-backup
#
#  4) Reboot on the DEFAULT entry, then confirm the early boot from the logs:
#             # uname -r
#             # dmesg | head -40
#             # journalctl -b -k | grep -i 'Freeing initrd\|Unpacking initramfs'
#
#  Note the difference you may have met on the way: 'grub>' is the full GRUB
# shell (modules loaded, you can boot by hand as above); 'grub rescue>' is the
# minimal one — there you must 'set prefix=(hdX,Y)/boot/grub', 'insmod normal',
# 'normal', and afterwards run grub-install + update-grub from the running system.
#
# -----------------------------------------------------------------------------
# SCENARIO 3 — default target (rescue.target)
# -----------------------------------------------------------------------------
#  1) Diagnose:
#         # systemctl get-default
#         rescue.target
#         # ls -l /etc/systemd/system/default.target
#         lrwxrwxrwx 1 root root 40 ... /etc/systemd/system/default.target -> /lib/systemd/system/rescue.target
#         # systemctl list-units --type=target --all | head
#         # journalctl -b | grep 'Reached target'
#     'systemctl get-default' simply reads that symlink; 'set-default' rewrites it.
#
#  2) Fix the current boot:
#         # systemctl isolate multi-user.target      # or graphical.target
#     ('isolate' starts that target and stops everything not required by it —
#      the systemd equivalent of 'telinit 3' / 'telinit 5'.)
#
#  3) Fix it permanently:
#         # systemctl set-default multi-user.target
#         Removed /etc/systemd/system/default.target.
#         Created symlink /etc/systemd/system/default.target -> /lib/systemd/system/multi-user.target
#     On a desktop VM the target was graphical.target and it was ALSO masked:
#         # systemctl is-enabled graphical.target
#         masked
#         # ls -l /etc/systemd/system/graphical.target
#         lrwxrwxrwx 1 root root 9 ... /etc/systemd/system/graphical.target -> /dev/null
#         # systemctl unmask graphical.target
#         # systemctl set-default graphical.target
#     masked (symlink to /dev/null, cannot be started even as a dependency) is
#     strictly stronger than disabled (not started at boot, but startable).
#
#  4) Reboot and check:
#         # systemctl get-default ; systemctl is-system-running ; systemctl --failed
#
#     Runlevel map worth memorising for the exam: 0 -> poweroff.target,
#     1/s/single -> rescue.target, 2/3/4 -> multi-user.target,
#     5 -> graphical.target, 6 -> reboot.target; 'runlevel' and 'telinit' still
#     work through systemd's compatibility layer. On a SysVinit system the same
#     permanent change would be the 'initdefault' line in /etc/inittab
#     (id:3:initdefault:), and on Upstart, /etc/init/rc-sysinit.conf.
#
# -----------------------------------------------------------------------------
# SCENARIO 4 — fstab (phantom device blocks local-fs.target)
# -----------------------------------------------------------------------------
# systemd-fstab-generator turns every /etc/fstab line into a .mount unit at boot,
# and a fsck-order (6th field) that is not 0 plus the absence of 'nofail' makes
# that mount REQUIRED by local-fs.target. The device never appears, the .device
# unit times out after 90 s, local-fs.target fails, and systemd falls into
# emergency mode.
#
#  1) Diagnose from the emergency shell:
#         # systemctl --failed
#         UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
#         mnt-lab\x2dphantom.mount    loaded failed failed /mnt/lab-phantom
#         # journalctl -xb -p err
#         Timed out waiting for device /dev/disk/by-uuid/dead1012-...
#         Dependency failed for /mnt/lab-phantom.
#         # systemd-escape -p --suffix=mount /mnt/lab-phantom
#         mnt-lab\x2dphantom.mount
#         # blkid            # the UUID in fstab is nowhere in this list
#         # lsblk -f
#
#  2) The emergency shell frequently gives you / read-only. Before editing:
#         # mount -o remount,rw /
#
#  3) Repair /etc/fstab — remove the line, or keep it and make it non-fatal:
#         # vi /etc/fstab
#           # either delete the entry, or:
#           UUID=dead1012-...  /mnt/lab-phantom  ext4  defaults,nofail,x-systemd.device-timeout=10s  0 0
#     'nofail' = do not fail the boot if it is missing; the timeout caps the wait
#     at 10 s instead of 90; setting the 6th field to 0 keeps fsck out of the way.
#     For a genuinely optional or slow device, 'noauto,x-systemd.automount' is the
#     production answer: mount on first access, never at boot.
#
#  4) VALIDATE BEFORE REBOOTING — this is the part that separates an operator
#     from a gambler:
#         # findmnt --verify --verbose
#         Success, no errors or warnings detected
#         # systemctl daemon-reload      # regenerate the .mount units from fstab
#         # mount -a                     # must print nothing
#         # systemctl reset-failed
#
#  5) Finish the current boot and then reboot:
#         # systemctl default
#         # systemctl reboot
#         # systemctl is-system-running          -> running
#         # systemctl --failed                   -> 0 loaded units listed
#         # journalctl -b -p err                 -> empty
#
# -----------------------------------------------------------------------------
# GENERAL DEBUGGING TOOLKIT FOR 101.2 (applies to all four scenarios)
# -----------------------------------------------------------------------------
#   cat /proc/cmdline                 what the running kernel was actually given
#   dmesg | less                      kernel ring buffer (early boot, drivers)
#   dmesg -T -l err,warn              human timestamps, errors only
#   journalctl -b                     this boot;  -b -1 the previous one
#   journalctl -xb -p err             errors of this boot with unit explanations
#   journalctl -k                     kernel messages only (= dmesg, persistent)
#   systemd-analyze                   total boot time, firmware/loader/kernel split
#   systemd-analyze blame             slowest units — where 90 s hangs show up
#   systemd-analyze critical-chain    the dependency path that determined the time
#   systemctl list-jobs               what is stuck RIGHT NOW during a hang
#   /var/log/boot.log , /var/log/messages , /var/log/syslog   (non-journal distros)
#   Useful one-boot kernel arguments typed in the GRUB editor:
#     systemd.unit=rescue.target | emergency.target   choose the boot target
#     single                                          single user (SysVinit style)
#     init=/bin/bash                                  bypass init entirely (rw remount needed)
#     systemd.log_level=debug systemd.log_target=console   verbose PID 1
#     rd.break (dracut) / break (Debian initramfs)    stop inside the initramfs
#     nomodeset                                       blank-screen graphics failures
#
# Reference: LPI Exam 101-500 objectives, topic 101.2 —
#   https://www.lpi.org/our-certifications/exam-101-objectives/
#   https://www.gnu.org/software/grub/manual/grub/grub.html
#   https://www.freedesktop.org/software/systemd/man/latest/bootup.html
#   https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
#   https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
# =============================================================================