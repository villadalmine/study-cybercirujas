#!/usr/bin/env bash
#
# =============================================================================
#  LPIC-1 (Exams 101-500 / 102-500, version 5.0)
#  Topic 102.2 - Install a boot manager   (exam weight: 3.13)
#
#  BREAK & FIX LAB - GRUB 2 boot manager
#
#  This script deliberately breaks the boot manager of a DISPOSABLE lab VM,
#  prints the symptom the student will observe and the goal to reach, and
#  keeps a full backup of everything it touched. The step-by-step solution is
#  at the very bottom of this file, commented out.
#
#  Reference: https://www.lpi.org/our-certifications/exam-101-objectives/
#             https://www.gnu.org/software/grub/manual/grub/grub.html
#             https://wiki.debian.org/Grub
#
#  *** DO NOT RUN THIS ON A MACHINE YOU CARE ABOUT. ***
#  Take a VM snapshot first. Scenarios 4 and 5 leave the VM unbootable on
#  purpose and require rescue/live media to repair.
# =============================================================================

set -euo pipefail

PROGRAM_NAME="$(basename "$0")"
STATE_DIR="/root/breakfix-102.2"
BACKUP_DIR="${STATE_DIR}/backup"
STATE_FILE="${STATE_DIR}/state.env"
BRIEFING_FILE="${STATE_DIR}/briefing.txt"
BOOT_NOTE="/boot/BREAKFIX-102.2-README.txt"
CONFIRM_PHRASE="BREAK MY LAB VM"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED="$(printf '\033[1;31m')"; C_YEL="$(printf '\033[1;33m')"
    C_GRN="$(printf '\033[1;32m')"; C_CYA="$(printf '\033[1;36m')"
    C_OFF="$(printf '\033[0m')"
else
    C_RED=""; C_YEL=""; C_GRN=""; C_CYA=""; C_OFF=""
fi

log()  { printf '%s[*]%s %s\n' "$C_CYA" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "-------------------------------------------------------------------------------"; }

# -----------------------------------------------------------------------------
# Safety guards
# -----------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script must run as root (it writes to /boot and the boot sector)."
}

require_disposable_vm() {
    local virt="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null || true)"
        [[ -n "$virt" ]] || virt="none"
    fi
    log "Virtualization detected: ${virt}"
    if [[ "$virt" == "none" && "${BREAKFIX_FORCE:-}" != "1" ]]; then
        die "Bare metal (or undetectable) host. Refusing to run. Use a throwaway VM, or set BREAKFIX_FORCE=1 if you are absolutely sure."
    fi
    if [[ -n "$(who 2>/dev/null | awk '{print $1}' | sort -u | grep -v '^root$' || true)" ]]; then
        warn "Non-root users are logged in. This really should be a private lab VM."
    fi
}

require_confirmation() {
    local answer=""
    if [[ "${BREAKFIX_CONFIRM:-}" == "$CONFIRM_PHRASE" ]]; then
        return 0
    fi
    hr
    printf '%sThis will damage the boot configuration of THIS machine (%s).%s\n' \
        "$C_RED" "$(hostname)" "$C_OFF"
    printf 'Snapshot the VM now if you have not done so.\n'
    printf 'Type exactly:  %s\n> ' "$CONFIRM_PHRASE"
    read -r answer
    [[ "$answer" == "$CONFIRM_PHRASE" ]] || die "Confirmation phrase not matched. Nothing was changed."
}

# -----------------------------------------------------------------------------
# Environment detection: firmware, GRUB paths, tool names, boot disk
# -----------------------------------------------------------------------------
FIRMWARE=""
GRUB_DIR=""
GRUB_CFG=""
GRUB_DEFAULT_FILE="/etc/default/grub"
GRUB_D_DIR="/etc/grub.d"
MKCONFIG_BIN=""
INSTALL_BIN=""
EFI_MOUNT=""
BOOT_DISK=""

detect_firmware() {
    if [[ -d /sys/firmware/efi ]]; then
        FIRMWARE="uefi"
        EFI_MOUNT="$(findmnt -no TARGET --source "$(findmnt -no SOURCE /boot/efi 2>/dev/null || echo /nonexistent)" 2>/dev/null || true)"
        [[ -n "$EFI_MOUNT" ]] || EFI_MOUNT="/boot/efi"
    else
        FIRMWARE="bios"
    fi
}

detect_grub_paths() {
    local candidate
    for candidate in /boot/grub/grub.cfg /boot/grub2/grub.cfg \
                     /boot/efi/EFI/*/grub.cfg; do
        [[ -f "$candidate" ]] || continue
        if grep -q 'menuentry ' "$candidate" 2>/dev/null; then
            GRUB_CFG="$candidate"
            break
        fi
        [[ -n "$GRUB_CFG" ]] || GRUB_CFG="$candidate"
    done
    [[ -n "$GRUB_CFG" ]] || die "No grub.cfg found. This lab targets GRUB 2; GRUB Legacy (menu.lst) is not supported here."

    if [[ -d /boot/grub2 ]]; then GRUB_DIR="/boot/grub2"; else GRUB_DIR="/boot/grub"; fi

    MKCONFIG_BIN="$(command -v grub-mkconfig || command -v grub2-mkconfig || true)"
    INSTALL_BIN="$(command -v grub-install  || command -v grub2-install  || true)"
    [[ -n "$MKCONFIG_BIN" ]] || die "Neither grub-mkconfig nor grub2-mkconfig is installed."
}

detect_boot_disk() {
    local src parent current
    src="$(findmnt -no SOURCE /boot 2>/dev/null || findmnt -no SOURCE / )"
    current="$(basename "$(readlink -f "$src")")"
    # Walk up the block-device tree (partition -> disk, dm -> pv -> disk).
    while true; do
        parent="$(lsblk -no PKNAME "/dev/${current}" 2>/dev/null | head -n1 || true)"
        [[ -n "$parent" ]] || break
        current="$parent"
    done
    if [[ -b "/dev/${current}" ]]; then
        BOOT_DISK="/dev/${current}"
    else
        BOOT_DISK=""
    fi
}

print_environment() {
    hr
    log "Hostname .......: $(hostname)"
    log "Distribution ...: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
    log "Firmware .......: ${FIRMWARE}"
    log "GRUB directory .: ${GRUB_DIR}"
    log "Generated config: ${GRUB_CFG}"
    log "Defaults file ..: ${GRUB_DEFAULT_FILE}"
    log "mkconfig binary : ${MKCONFIG_BIN}"
    log "install binary .: ${INSTALL_BIN:-<not installed>}"
    log "Boot disk ......: ${BOOT_DISK:-<undetected>}"
    [[ "$FIRMWARE" == "uefi" ]] && log "ESP mountpoint .: ${EFI_MOUNT}"
    hr
}

# -----------------------------------------------------------------------------
# Backup / state helpers
# -----------------------------------------------------------------------------
init_state() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$STATE_DIR"
}

flat_name() { printf '%s' "$1" | sed 's#^/##; s#/#_#g'; }

backup_path() {
    local src="$1" dst
    dst="${BACKUP_DIR}/$(flat_name "$src")"
    if [[ -e "$dst" ]]; then
        log "Backup already present: ${dst}"
        return 0
    fi
    cp -a "$src" "$dst"
    ok "Backed up ${src} -> ${dst}"
}

restore_path() {
    local dst="$1" src
    src="${BACKUP_DIR}/$(flat_name "$dst")"
    [[ -e "$src" ]] || { warn "No backup for ${dst}, skipping."; return 0; }
    rm -rf "$dst"
    cp -a "$src" "$dst"
    ok "Restored ${dst}"
}

save_state() { printf '%s\n' "$1" >> "$STATE_FILE"; }

get_state() {
    [[ -f "$STATE_FILE" ]] || return 1
    grep -m1 "^${1}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || return 1
}

regen_grub() {
    log "Regenerating ${GRUB_CFG} with ${MKCONFIG_BIN} ..."
    "$MKCONFIG_BIN" -o "$GRUB_CFG" >/dev/null 2>&1 || die "grub-mkconfig failed."
    sync
    ok "grub.cfg regenerated."
}

set_default_key() {
    # set_default_key KEY VALUE  -> replace or append KEY=VALUE in /etc/default/grub
    local key="$1" value="$2"
    if grep -qE "^[#[:space:]]*${key}=" "$GRUB_DEFAULT_FILE"; then
        sed -i -E "s#^[#[:space:]]*${key}=.*#${key}=${value}#" "$GRUB_DEFAULT_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$GRUB_DEFAULT_FILE"
    fi
}

publish_briefing() {
    cp -f "$BRIEFING_FILE" "$BOOT_NOTE" 2>/dev/null || true
    sync
    hr
    cat "$BRIEFING_FILE"
    hr
    ok "Briefing saved to ${BRIEFING_FILE} and ${BOOT_NOTE}"
    ok "Backups in ${BACKUP_DIR}. Emergency restore: ${PROGRAM_NAME} --restore"
}

# =============================================================================
#  SCENARIOS
# =============================================================================

# --- 1: the generated configuration file disappears --------------------------
break_missing_cfg() {
    backup_path "$GRUB_CFG"
    mv "$GRUB_CFG" "${GRUB_CFG}.disabled-by-lab"
    sync
    save_state "SCENARIO=missing-cfg"
    save_state "GRUB_CFG=${GRUB_CFG}"

    cat > "$BRIEFING_FILE" <<EOF
SCENARIO 1 - "The menu never appears, I get a grub> prompt"
===========================================================================
WHAT WAS BROKEN
  The generated configuration file ${GRUB_CFG} was renamed.
  The GRUB core image and its modules are intact; only the menu definition
  is gone.

SYMPTOM YOU WILL SEE (after 'reboot')
  No boot menu, no countdown. GRUB stops at an interactive shell:

      GNU GRUB  version 2.xx
      Minimal BASH-like line editing is supported. [...]
      grub>

  Note the prompt: 'grub>' (full shell, modules loaded, no config) is NOT
  the same as 'grub rescue>' (core image could not load its modules).

YOUR GOAL
  1. From the grub> prompt, boot the installed system MANUALLY - without
     any configuration file. You must locate the partition holding
     /boot, load the kernel with the correct root= parameter, load the
     matching initramfs, and start it.
  2. Once the system is running, regenerate the configuration file so the
     menu comes back permanently.
  3. Prove it: reboot again and land on a normal menu.

USEFUL COMMANDS AT THE grub> PROMPT
  ls                      list devices/partitions:  (hd0) (hd0,gpt2) ...
  ls (hd0,gpt2)/          look inside a partition
  set                     show current variables (root, prefix)
  set pager=1             page long output
  linux / initrd / boot   load kernel, load initramfs, start
  insmod normal ; normal  try to return to the normal (menu) mode

DO NOT
  Do not reinstall the distribution, and do not run grub-install yet:
  nothing is wrong with the installed boot manager itself.
===========================================================================
EOF
    publish_briefing
}

restore_missing_cfg() {
    local cfg; cfg="$(get_state GRUB_CFG || echo "$GRUB_CFG")"
    [[ -f "${cfg}.disabled-by-lab" ]] && mv -f "${cfg}.disabled-by-lab" "$cfg"
    restore_path "$cfg"
    sync
}

# --- 2: wrong root= on the kernel command line -------------------------------
break_bad_root() {
    backup_path "$GRUB_DEFAULT_FILE"
    backup_path "$GRUB_CFG"
    local current
    current="$(grep -E '^GRUB_CMDLINE_LINUX=' "$GRUB_DEFAULT_FILE" | head -n1 | cut -d= -f2- | tr -d '"' || true)"
    set_default_key "GRUB_CMDLINE_LINUX" "\"${current} root=/dev/sdz9\""
    regen_grub
    save_state "SCENARIO=bad-root"

    cat > "$BRIEFING_FILE" <<EOF
SCENARIO 2 - "Kernel panic: unable to mount root fs"
===========================================================================
WHAT WAS BROKEN
  A bogus 'root=/dev/sdz9' was appended to GRUB_CMDLINE_LINUX in
  ${GRUB_DEFAULT_FILE}, and ${GRUB_CFG} was regenerated from it.
  The kernel honours the LAST root= on the command line, so it now looks
  for a device that does not exist.

SYMPTOM YOU WILL SEE (after 'reboot')
  The menu appears normally and the kernel starts, then either:

      ALERT! /dev/sdz9 does not exist. Dropping to a shell!
      (initramfs) _

  or, on an initramfs without a rescue shell:

      VFS: Cannot open root device "sdz9" or unknown-block(0,0)
      Kernel panic - not syncing: VFS: Unable to mount root fs on
      unknown-block(0,0)

YOUR GOAL
  1. Boot ONCE without touching any file: at the GRUB menu, edit the entry
     in place and remove/replace the wrong parameter, then start it. The
     edit is volatile by design - understand why.
  2. With the system running, find the real root device (UUID) and repair
     the persistent configuration in ${GRUB_DEFAULT_FILE}.
  3. Regenerate ${GRUB_CFG} and reboot with no manual intervention.

KEY IDEA TO INTERNALISE
  ${GRUB_CFG} is GENERATED. Editing it by hand "works" until the next
  kernel update overwrites it. The sources of truth are
  ${GRUB_DEFAULT_FILE} and ${GRUB_D_DIR}/.

HINTS
  At the menu:  highlight the entry, press 'e', navigate to the 'linux'
  line, fix it, then press Ctrl-x (or F10) to boot.
  Inside the system:  blkid, lsblk -f, findmnt -no SOURCE /, cat /proc/cmdline
===========================================================================
EOF
    publish_briefing
}

restore_bad_root() {
    restore_path "$GRUB_DEFAULT_FILE"
    regen_grub
}

# --- 3: the menu is hidden and the timeout is zero ---------------------------
break_hidden_menu() {
    backup_path "$GRUB_DEFAULT_FILE"
    backup_path "$GRUB_CFG"
    set_default_key "GRUB_TIMEOUT"        "0"
    set_default_key "GRUB_TIMEOUT_STYLE"  "hidden"
    set_default_key "GRUB_DISABLE_RECOVERY" "true"
    regen_grub
    save_state "SCENARIO=hidden-menu"

    cat > "$BRIEFING_FILE" <<EOF
SCENARIO 3 - "I cannot get into the boot menu any more"
===========================================================================
WHAT WAS BROKEN
  In ${GRUB_DEFAULT_FILE}:
      GRUB_TIMEOUT=0
      GRUB_TIMEOUT_STYLE=hidden
      GRUB_DISABLE_RECOVERY=true
  and ${GRUB_CFG} was regenerated. The system still boots - that is what
  makes this failure mode dangerous.

SYMPTOM YOU WILL SEE (after 'reboot')
  The firmware hands over to GRUB and the default entry starts instantly.
  No menu, no countdown, no recovery entry, no way to pick an older kernel
  or to append a parameter such as 'single' or 'systemd.unit=rescue.target'.
  This is exactly the situation you do NOT want to discover the day the
  newest kernel fails to boot.

YOUR GOAL
  1. Force the menu to appear on a single boot, without any rescue media.
     (On a BIOS machine: hold SHIFT during the GRUB hand-over. On UEFI:
     tap ESC repeatedly. Both are volatile - they change nothing on disk.)
  2. Make the menu permanent again: a visible countdown of a few seconds
     and a usable recovery entry.
  3. Verify from the running system that the generated file really contains
     the new timeout and the recovery entries.

VERIFICATION
  grep -E '^set timeout|timeout_style' ${GRUB_CFG}
  grep -c 'menuentry ' ${GRUB_CFG}
  awk -F\\' '/^menuentry|^ *menuentry/ {print NR": "\$2}' ${GRUB_CFG}
===========================================================================
EOF
    publish_briefing
}

restore_hidden_menu() {
    restore_path "$GRUB_DEFAULT_FILE"
    regen_grub
}

# --- 4: /etc/grub.d/ produces a menu with no Linux entries -------------------
break_broken_grubd() {
    local linux_script=""
    local candidate
    for candidate in "${GRUB_D_DIR}"/10_linux "${GRUB_D_DIR}"/10_linux_zfs; do
        [[ -f "$candidate" ]] && linux_script="$candidate" && break
    done
    [[ -n "$linux_script" ]] || die "Could not find ${GRUB_D_DIR}/10_linux on this system."

    backup_path "$GRUB_CFG"
    backup_path "$linux_script"
    chmod -x "$linux_script"
    # A second, quieter fault: a custom fragment that aborts the generator.
    cat > "${GRUB_D_DIR}/09_lab_fault" <<'FRAGMENT'
#!/bin/sh
# Installed by the 102.2 break & fix lab. Remove me.
exit 0
FRAGMENT
    chmod 755 "${GRUB_D_DIR}/09_lab_fault"
    regen_grub
    save_state "SCENARIO=broken-grubd"
    save_state "LINUX_SCRIPT=${linux_script}"

    cat > "$BRIEFING_FILE" <<EOF
SCENARIO 4 - "update-grub ran fine and now there is nothing to boot"
===========================================================================
WHAT WAS BROKEN
  ${linux_script} lost its execute permission, so grub-mkconfig silently
  skipped it, and ${GRUB_CFG} was regenerated WITHOUT a single Linux
  menu entry. A decoy file ${GRUB_D_DIR}/09_lab_fault was also dropped in.
  The generator exits 0: no error is printed anywhere.

SYMPTOM YOU WILL SEE (after 'reboot')
  GRUB starts and shows a menu containing only the leftovers - typically
  "UEFI Firmware Settings", "Memory test (memtest86+)", or an empty list -
  with no kernel entry at all. Selecting nothing useful gets you nowhere.

  *** THIS VM WILL NOT BOOT ON ITS OWN. ***

YOUR GOAL
  1. Get a running system again. Two legitimate routes - practise BOTH:
     a) From the GRUB shell (press 'c' at the menu), boot manually:
        set root, linux, initrd, boot.
     b) From a live/rescue ISO: mount the root filesystem, bind-mount
        /dev /proc /sys (and /boot, /boot/efi if separate), chroot in.
  2. Find WHY there are no entries. Do not guess: compare the scripts in
     ${GRUB_D_DIR} - which ones are executable? Run the generator and read
     its stderr.
  3. Repair the permission, delete the decoy, regenerate, reboot clean.

HINTS
  ls -l ${GRUB_D_DIR}
  run-parts --test ${GRUB_D_DIR}
  ${MKCONFIG_BIN} 2>&1 | head -n 30      # writes to stdout, logs to stderr
  A backup of the last good menu is in ${BACKUP_DIR} - read it to learn
  what the correct 'linux'/'initrd' lines look like before you type them
  at the grub> prompt.
===========================================================================
EOF
    publish_briefing
}

restore_broken_grubd() {
    local linux_script; linux_script="$(get_state LINUX_SCRIPT || echo "${GRUB_D_DIR}/10_linux")"
    rm -f "${GRUB_D_DIR}/09_lab_fault"
    restore_path "$linux_script"
    chmod 755 "$linux_script"
    regen_grub
}

# --- 5: the boot manager itself is gone from the disk / firmware -------------
break_wiped_bootcode() {
    if [[ "$FIRMWARE" == "bios" ]]; then
        [[ -n "$BOOT_DISK" ]] || die "Could not identify the boot disk; refusing to touch any MBR."
        [[ -b "$BOOT_DISK" ]] || die "${BOOT_DISK} is not a block device."
        log "Backing up the first 512 bytes of ${BOOT_DISK} ..."
        dd if="$BOOT_DISK" of="${BACKUP_DIR}/mbr-512.bin" bs=512 count=1 status=none
        sync
        # Wipe ONLY the 440-byte bootstrap area. The partition table (offset
        # 446..509) and the 0x55AA signature are left untouched on purpose.
        log "Wiping the 440-byte bootstrap code (partition table preserved) ..."
        dd if=/dev/zero of="$BOOT_DISK" bs=440 count=1 conv=notrunc status=none
        sync
        save_state "SCENARIO=wiped-bootcode"
        save_state "BOOT_DISK=${BOOT_DISK}"
        save_state "MBR_BACKUP=${BACKUP_DIR}/mbr-512.bin"
        local target_desc="the MBR bootstrap area of ${BOOT_DISK}"
        local symptom="      No bootable device -- insert boot disk and press any key
      (or: Operating System not found / PXE boot attempt / blinking cursor)"
        local goal_extra="  Reinstall the boot manager into the MBR of the correct disk from a
  chroot. Understand what grub-install actually writes: the boot.img in
  the 440-byte area, the core.img in the post-MBR gap, and the modules
  under ${GRUB_DIR}."
    else
        [[ -d "${EFI_MOUNT}/EFI" ]] || die "No ESP found at ${EFI_MOUNT}/EFI."
        local distro_dir=""
        for d in "${EFI_MOUNT}"/EFI/*; do
            [[ -d "$d" ]] || continue
            case "$(basename "$d" | tr 'A-Z' 'a-z')" in
                boot) continue ;;
                *) distro_dir="$d"; break ;;
            esac
        done
        [[ -n "$distro_dir" ]] || die "Could not find the distribution directory on the ESP."
        backup_path "$distro_dir"
        [[ -d "${EFI_MOUNT}/EFI/BOOT" ]] && backup_path "${EFI_MOUNT}/EFI/BOOT"
        if command -v efibootmgr >/dev/null 2>&1; then
            efibootmgr -v > "${BACKUP_DIR}/efibootmgr-v.txt" 2>/dev/null || true
            local bootnum
            bootnum="$(efibootmgr | awk '/'"$(basename "$distro_dir")"'|GRUB|grub/ {sub(/^Boot/,"",$1); sub(/\*$/,"",$1); print $1; exit}' || true)"
            if [[ -n "${bootnum:-}" ]]; then
                log "Deleting firmware boot entry Boot${bootnum} ..."
                efibootmgr -b "$bootnum" -B >/dev/null 2>&1 || warn "Could not delete Boot${bootnum}."
                save_state "EFI_ENTRY=${bootnum}"
            fi
        fi
        log "Removing the boot loader from the ESP ..."
        rm -rf "$distro_dir"
        rm -rf "${EFI_MOUNT}/EFI/BOOT"
        sync
        save_state "SCENARIO=wiped-bootcode"
        save_state "ESP_DIR=${distro_dir}"
        local target_desc="the loader directory on the EFI System Partition (${distro_dir}), the removable fallback ${EFI_MOUNT}/EFI/BOOT, and the NVRAM boot entry"
        local symptom="      No bootable device found / Boot Device Not Found
      (or the firmware setup screen, or a PXE/network boot attempt)"
        local goal_extra="  Reinstall the boot manager onto the ESP from a chroot and recreate the
  NVRAM entry. Understand the three pieces involved: the .efi loader on a
  FAT32 partition, the NVRAM BootOrder/BootXXXX variables, and the
  removable-media fallback path \\\\EFI\\\\BOOT\\\\BOOTX64.EFI."
    fi

    cat > "$BRIEFING_FILE" <<EOF
SCENARIO 5 - "The firmware says there is nothing to boot"
===========================================================================
WHAT WAS BROKEN
  This machine boots in ${FIRMWARE^^} mode. The lab destroyed
  ${target_desc}.
  The Linux installation, the kernels and ${GRUB_CFG} are all intact -
  only the stage that the firmware loads is missing.

SYMPTOM YOU WILL SEE (after 'reboot')
${symptom}

  GRUB never appears at all. Compare this with scenario 1: there, GRUB ran
  and had no menu; here, GRUB is never reached.

  *** THIS VM WILL NOT BOOT ON ITS OWN. You need rescue/live media. ***

YOUR GOAL
  1. Boot the VM from a live/rescue ISO of the same architecture.
  2. Identify the root filesystem, mount it, bind-mount the virtual
     filesystems, mount /boot (and the ESP, if this is UEFI) and chroot.
${goal_extra}
  3. Verify BEFORE rebooting - do not reboot hoping for the best.
  4. Reboot into a normal menu with no media attached.

HINTS
  lsblk -f ; blkid ; findmnt
  for d in /dev /proc /sys /run; do mount --bind \$d /mnt\$d; done
  chroot /mnt /bin/bash
  ${INSTALL_BIN:-grub-install} --help
  BIOS  : the 440-byte backup taken by this lab is in ${BACKUP_DIR}
  UEFI  : efibootmgr -v ; the previous output is in ${BACKUP_DIR}
===========================================================================
EOF
    publish_briefing
}

restore_wiped_bootcode() {
    if [[ "$FIRMWARE" == "bios" ]]; then
        local disk mbr
        disk="$(get_state BOOT_DISK || echo "$BOOT_DISK")"
        mbr="$(get_state MBR_BACKUP || echo "${BACKUP_DIR}/mbr-512.bin")"
        [[ -f "$mbr" && -b "$disk" ]] || die "Missing MBR backup or boot disk; restore manually with grub-install."
        # Restore only the bootstrap area, never the live partition table.
        dd if="$mbr" of="$disk" bs=440 count=1 conv=notrunc status=none
        sync
        ok "Bootstrap code restored on ${disk}"
    else
        local esp_dir; esp_dir="$(get_state ESP_DIR || true)"
        [[ -n "$esp_dir" ]] && restore_path "$esp_dir"
        [[ -e "${BACKUP_DIR}/$(flat_name "${EFI_MOUNT}/EFI/BOOT")" ]] && restore_path "${EFI_MOUNT}/EFI/BOOT"
        if [[ -n "$INSTALL_BIN" ]]; then
            log "Recreating the firmware boot entry ..."
            "$INSTALL_BIN" >/dev/null 2>&1 || warn "grub-install failed; recreate the entry with efibootmgr -c."
        fi
        sync
    fi
}

# =============================================================================
#  Dispatcher
# =============================================================================
usage() {
    cat <<EOF
${PROGRAM_NAME} - LPIC-1 102.2 "Install a boot manager" break & fix lab

USAGE
  ${PROGRAM_NAME} --list
  ${PROGRAM_NAME} --break <scenario>
  ${PROGRAM_NAME} --status
  ${PROGRAM_NAME} --restore
  ${PROGRAM_NAME} --briefing

SCENARIOS
  1 | missing-cfg     grub.cfg is gone            -> grub> prompt, no menu   [recoverable without media]
  2 | bad-root        wrong root= parameter       -> kernel panic / initramfs [recoverable without media]
  3 | hidden-menu     timeout 0 + hidden style    -> menu unreachable         [system still boots]
  4 | broken-grubd    /etc/grub.d entry skipped   -> menu with no kernels     [NEEDS grub shell or ISO]
  5 | wiped-bootcode  MBR / ESP loader destroyed  -> firmware finds no OS     [NEEDS rescue ISO]

ENVIRONMENT
  BREAKFIX_CONFIRM="${CONFIRM_PHRASE}"   skip the interactive confirmation
  BREAKFIX_FORCE=1                       allow running outside a VM (dangerous)

Backups and briefing live in ${STATE_DIR}.
EOF
}

show_status() {
    if [[ -f "$STATE_FILE" ]]; then
        log "Lab state:"; cat "$STATE_FILE"
    else
        ok "No scenario is currently active on this machine."
    fi
    hr
    log "Menu entries currently in ${GRUB_CFG}: $(grep -c '^\s*menuentry ' "$GRUB_CFG" 2>/dev/null || echo 0)"
    log "Current kernel command line: $(cat /proc/cmdline)"
    [[ -f "$GRUB_DEFAULT_FILE" ]] && { hr; grep -vE '^\s*#|^\s*$' "$GRUB_DEFAULT_FILE" || true; }
}

do_restore() {
    [[ -f "$STATE_FILE" ]] || die "No lab state found in ${STATE_FILE}; nothing to restore."
    local scenario; scenario="$(get_state SCENARIO || true)"
    log "Restoring scenario: ${scenario}"
    case "$scenario" in
        missing-cfg)     restore_missing_cfg ;;
        bad-root)        restore_bad_root ;;
        hidden-menu)     restore_hidden_menu ;;
        broken-grubd)    restore_broken_grubd ;;
        wiped-bootcode)  restore_wiped_bootcode ;;
        *) die "Unknown scenario '${scenario}'." ;;
    esac
    rm -f "$STATE_FILE" "$BOOT_NOTE"
    ok "Restored. Reboot to confirm the machine boots unattended."
}

main() {
    require_root
    detect_firmware
    detect_grub_paths
    detect_boot_disk
    init_state

    local action="${1:---list}"
    case "$action" in
        --list|-l|"")   usage ;;
        --status|-s)    print_environment; show_status ;;
        --briefing)     [[ -f "$BRIEFING_FILE" ]] && cat "$BRIEFING_FILE" || ok "No active briefing." ;;
        --restore|-r)   print_environment; do_restore ;;
        --break|-b)
            local scenario="${2:-}"
            [[ -n "$scenario" ]] || die "Missing scenario. Run '${PROGRAM_NAME} --list'."
            [[ -f "$STATE_FILE" ]] && die "A scenario is already active. Run '--restore' first."
            print_environment
            require_disposable_vm
            require_confirmation
            case "$scenario" in
                1|missing-cfg)    break_missing_cfg ;;
                2|bad-root)       break_bad_root ;;
                3|hidden-menu)    break_hidden_menu ;;
                4|broken-grubd)   break_broken_grubd ;;
                5|wiped-bootcode) break_wiped_bootcode ;;
                *) die "Unknown scenario '${scenario}'." ;;
            esac
            hr
            warn "Now reboot and work through the goal. Do not read the solution block at the bottom of this script until you are stuck."
            ;;
        --help|-h)      usage ;;
        *)              die "Unknown option '${action}'. Try --help." ;;
    esac
}

main "$@"

# =============================================================================
# =============================================================================
#
#   S O L U T I O N S   -   read only after you have tried
#
# =============================================================================
# =============================================================================
#
# -----------------------------------------------------------------------------
# GENERAL MAP OF THE TOPIC (know this before touching anything)
# -----------------------------------------------------------------------------
#   Firmware stage
#     BIOS : the 440-byte bootstrap in the MBR (boot.img) chain-loads core.img,
#            which lives in the post-MBR gap (BIOS boot partition on GPT).
#     UEFI : the firmware reads a FAT32 EFI System Partition and executes an
#            .efi binary listed in NVRAM (BootXXXX / BootOrder), typically
#            \EFI\<distro>\grubx64.efi, with \EFI\BOOT\BOOTX64.EFI as the
#            removable-media fallback.
#   GRUB stage
#     core.img/grubx64.efi loads modules from /boot/grub (or /boot/grub2)
#     and reads the GENERATED menu: /boot/grub/grub.cfg.
#   Sources of that generated file - the only files you edit by hand:
#     /etc/default/grub        key=value defaults
#     /etc/grub.d/*            executable fragments, run in name order
#                              00_header 10_linux 30_os-prober 40_custom
#   Regeneration:
#     Debian/Ubuntu : update-grub          (a wrapper) or
#                     grub-mkconfig -o /boot/grub/grub.cfg
#     RHEL/Fedora/SUSE : grub2-mkconfig -o /boot/grub2/grub.cfg
#                     (RHEL 8+/Fedora also accept grubby for one-off changes)
#   Installation of the boot manager itself:
#     BIOS : grub-install /dev/sda           (the DISK, never a partition)
#     UEFI : grub-install --target=x86_64-efi --efi-directory=/boot/efi \
#                         --bootloader-id=<distro>   [--removable]
#   GRUB Legacy (still in the objectives): /boot/grub/menu.lst, stanzas with
#     title/root (hd0,0)/kernel/initrd, and the interactive 'grub' shell with
#     root (hd0,0) ; setup (hd0). It is NOT regenerated from anything.
#
# -----------------------------------------------------------------------------
# SCENARIO 1 - grub.cfg is missing (grub> prompt)
# -----------------------------------------------------------------------------
#   At the grub> prompt, first look around:
#
#     grub> set pager=1
#     grub> ls
#     (hd0) (hd0,gpt2) (hd0,gpt1) (proc)
#     grub> ls (hd0,gpt2)/
#     lost+found/ boot/ etc/ home/ usr/ var/ ...
#
#   Find the partition that actually holds the kernels (it may be /boot on a
#   separate partition, in which case the paths below lose the /boot prefix):
#
#     grub> ls (hd0,gpt2)/boot
#     vmlinuz-6.1.0-18-amd64 initrd.img-6.1.0-18-amd64 grub/ ...
#
#   Point GRUB at it and boot manually. TAB completion works on every path:
#
#     grub> set root=(hd0,gpt2)
#     grub> linux /boot/vmlinuz-6.1.0-18-amd64 root=/dev/sda2 ro
#     grub> initrd /boot/initrd.img-6.1.0-18-amd64
#     grub> boot
#
#   (Using root=UUID=... is equally valid and more robust:
#      grub> linux /boot/vmlinuz-6.1.0-18-amd64 root=UUID=<uuid> ro
#    Get the UUID beforehand from the backup copy of grub.cfg, or use
#    'search --no-floppy --fs-uuid --set=root <uuid>' instead of set root=.)
#
#   Shortcut worth knowing - if the modules are fine, ask for the normal mode:
#
#     grub> insmod normal
#     grub> normal
#
#   Once the system is up, make it permanent:
#
#     # Debian/Ubuntu
#     update-grub                     # or: grub-mkconfig -o /boot/grub/grub.cfg
#     # RHEL/Fedora/SUSE
#     grub2-mkconfig -o /boot/grub2/grub.cfg
#
#   Verify, then reboot:
#
#     grep -c '^\s*menuentry ' /boot/grub/grub.cfg
#     grep '^set timeout' /boot/grub/grub.cfg
#     reboot
#
#   Or simply:  ./breakfix-102.2.sh --restore
#
# -----------------------------------------------------------------------------
# SCENARIO 2 - wrong root= (kernel panic / initramfs prompt)
# -----------------------------------------------------------------------------
#   A) One-shot boot from the menu (nothing is written to disk):
#
#      - At the menu, highlight the entry and press 'e'.
#      - Move to the line starting with 'linux' (it wraps; use the arrows).
#      - Delete the trailing  root=/dev/sdz9  (Ctrl-e goes to end of line,
#        Ctrl-k kills to end of line, Ctrl-a to start).
#      - Press Ctrl-x (or F10) to boot with the edited line.
#      - Press Esc to abandon the edit and return to the menu.
#
#      If you were dropped at the (initramfs) prompt instead, you can also do:
#
#        (initramfs) blkid                 # find the real root device
#        (initramfs) exit                  # some initramfs retry after this
#
#   B) Permanent repair from the running system:
#
#      findmnt -no SOURCE /                # e.g. /dev/sda2
#      blkid -s UUID -o value /dev/sda2    # its UUID
#      cat /proc/cmdline                   # what the kernel really got
#
#      vi /etc/default/grub
#        # remove the injected 'root=/dev/sdz9' from GRUB_CMDLINE_LINUX,
#        # leaving for example:
#        GRUB_CMDLINE_LINUX=""
#        GRUB_CMDLINE_LINUX_DEFAULT="quiet"
#
#      update-grub          # Debian/Ubuntu
#      grub2-mkconfig -o /boot/grub2/grub.cfg     # RHEL/Fedora/SUSE
#
#      grep -m1 'linux.*vmlinuz' /boot/grub/grub.cfg   # confirm a single root=
#      reboot
#
#   WHY the menu edit is volatile: GRUB keeps the edited entry in memory only;
#   the file on disk is untouched. That is a feature - a wrong experiment
#   cannot brick the machine. It is also why the fix must be repeated in
#   /etc/default/grub, never in grub.cfg.
#
# -----------------------------------------------------------------------------
# SCENARIO 3 - hidden menu, zero timeout
# -----------------------------------------------------------------------------
#   A) Reach the menu once:
#      BIOS : hold down SHIFT from the moment the firmware finishes POST.
#      UEFI : tap ESC repeatedly during hand-over.
#      With GRUB_TIMEOUT_STYLE=hidden this is the documented escape hatch.
#
#   B) Permanent repair:
#
#      vi /etc/default/grub
#        GRUB_TIMEOUT=5
#        GRUB_TIMEOUT_STYLE=menu
#        GRUB_DISABLE_RECOVERY=false
#        # optional, useful in a lab:
#        GRUB_DISABLE_SUBMENU=y        # flat list instead of nested submenus
#        GRUB_DEFAULT=saved            # remember the last chosen entry, with:
#        GRUB_SAVEDEFAULT=true
#
#      update-grub          # or grub2-mkconfig -o /boot/grub2/grub.cfg
#
#      grep -E '^set timeout|^set timeout_style' /boot/grub/grub.cfg
#      awk -F"'" '/^ *menuentry /{print ++i-1": "$2}' /boot/grub/grub.cfg
#      reboot
#
#   Note on GRUB_DEFAULT: it accepts an index (0,1,2...), the exact menuentry
#   title in quotes, an 'ID>subentry' path, or the literal 'saved'.
#   grub-set-default / grub-reboot change the saved value at runtime:
#      grub-reboot 2       # next boot only, then back to the default
#      grub-set-default 0  # persistent
#
# -----------------------------------------------------------------------------
# SCENARIO 4 - /etc/grub.d fragment skipped, menu without kernels
# -----------------------------------------------------------------------------
#   A) Get a shell. Fastest route: press 'c' at the GRUB menu and boot by hand
#      exactly as in scenario 1 (set root / linux / initrd / boot). The backup
#      copy of the previous grub.cfg in /root/breakfix-102.2/backup/ tells you
#      the exact filenames and root= value - read it before you break things,
#      that is what a maintenance window looks like in real life.
#
#      If the GRUB shell is not available, use a live ISO (see scenario 5 for
#      the full chroot recipe).
#
#   B) Diagnose - never guess:
#
#      ls -l /etc/grub.d/
#      -rwxr-xr-x 1 root root  9346 00_header
#      -rwxr-xr-x 1 root root   214 09_lab_fault      <-- does not belong here
#      -rw-r--r-- 1 root root 12894 10_linux          <-- NOT executable
#      -rwxr-xr-x 1 root root  1992 30_os-prober
#      -rwxr-xr-x 1 root root   214 40_custom
#
#      run-parts --test /etc/grub.d      # lists only what would actually run
#      grub-mkconfig 2>&1 | head -n 30   # config goes to stdout, log to stderr
#
#   C) Repair:
#
#      rm -f /etc/grub.d/09_lab_fault
#      chmod 755 /etc/grub.d/10_linux
#      update-grub          # or grub2-mkconfig -o /boot/grub2/grub.cfg
#      grep -c '^\s*menuentry ' /boot/grub/grub.cfg    # must be > 0
#      reboot
#
#   RULE: the mode bit is the switch. To disable a fragment permanently, the
#   supported way is 'chmod -x /etc/grub.d/30_os-prober' (or the matching
#   GRUB_DISABLE_OS_PROBER=true in /etc/default/grub) - and you must remember
#   that you did it, because nothing warns you at the next kernel update.
#   Custom entries belong in /etc/grub.d/40_custom, which is never overwritten.
#
# -----------------------------------------------------------------------------
# SCENARIO 5 - boot manager erased from the MBR / ESP
# -----------------------------------------------------------------------------
#   Boot the live/rescue ISO, open a root shell, and identify the layout:
#
#     lsblk -f
#     blkid
#     # example: /dev/sda1 = vfat ESP, /dev/sda2 = ext4 root, /dev/sda3 = swap
#
#   Mount and chroot (add /boot and /boot/efi only if they are separate):
#
#     mount /dev/sda2 /mnt
#     mount /dev/sda1 /mnt/boot/efi          # UEFI only
#     for d in /dev /dev/pts /proc /sys /run; do mount --bind $d /mnt$d; done
#     # UEFI additionally needs efivars visible inside the chroot:
#     mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars
#     chroot /mnt /bin/bash
#
#   If the root filesystem is on LVM or LUKS, activate it first:
#
#     cryptsetup open /dev/sda3 cryptroot
#     vgchange -ay
#     lvs                                     # then mount /dev/vg/root /mnt
#
#   --- BIOS: reinstall into the MBR of the DISK (never a partition) ---
#
#     grub-install /dev/sda                   # Debian/Ubuntu
#     grub2-install /dev/sda                  # RHEL/Fedora/SUSE
#     update-grub                             # or grub2-mkconfig -o ...
#
#     # Verify the 440-byte area is no longer zeroed:
#     dd if=/dev/sda bs=512 count=1 2>/dev/null | strings | head
#     # expect to see 'GRUB' and 'Geom Hard Disk Read Error'
#
#     # (Pure byte-level restore of the lab backup, equivalent here:
#     #  dd if=/root/breakfix-102.2/backup/mbr-512.bin of=/dev/sda \
#     #     bs=440 count=1 conv=notrunc
#     #  bs=440 protects the partition table at offset 446. Copying the whole
#     #  512 bytes would also overwrite the partition table - only correct if
#     #  the table has not changed since the backup.)
#
#   --- UEFI: reinstall onto the ESP and recreate the NVRAM entry ---
#
#     grub-install --target=x86_64-efi --efi-directory=/boot/efi \
#                  --bootloader-id=debian --recheck
#     # RHEL/Fedora/SUSE:
#     grub2-install --target=x86_64-efi --efi-directory=/boot/efi \
#                   --bootloader-id=fedora
#     grub-mkconfig -o /boot/grub/grub.cfg     # or the grub2 path
#
#     # If the firmware ignores NVRAM entries (common in cheap firmware and in
#     # some hypervisors), install to the removable fallback path as well:
#     grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
#     # -> writes /boot/efi/EFI/BOOT/BOOTX64.EFI
#
#     # Verify:
#     ls -R /boot/efi/EFI
#     efibootmgr -v
#     BootCurrent: 0003
#     BootOrder: 0001,0003
#     Boot0001* debian  HD(1,GPT,...)/File(\EFI\debian\shimx64.efi)
#
#     # Put it first if the order is wrong, or create it by hand:
#     efibootmgr -o 0001,0003
#     efibootmgr -c -d /dev/sda -p 1 -L "debian" -l '\EFI\debian\shimx64.efi'
#
#     # With Secure Boot enabled, the firmware loads shimx64.efi, which then
#     # loads grubx64.efi; installing grub without shim will fail to start.
#
#   Leave cleanly and reboot:
#
#     exit
#     umount -R /mnt          # -R unmounts the bind mounts too
#     reboot                  # detach the ISO first
#
#   VERIFY BEFORE REBOOTING, always:
#     - grub-install exited 0 and printed "Installation finished. No error reported."
#     - the menu file exists and has entries
#     - (UEFI) efibootmgr shows the entry and it is in BootOrder
#
# -----------------------------------------------------------------------------
# EXAM-SIZED CHECKLIST FOR 102.2
# -----------------------------------------------------------------------------
#   Files    : /boot/grub/grub.cfg (generated, do not edit)
#              /boot/grub2/grub.cfg (RHEL family)
#              /etc/default/grub, /etc/grub.d/*
#              /boot/grub/menu.lst, /boot/grub/grub.conf (GRUB Legacy)
#   Commands : grub-install / grub2-install
#              grub-mkconfig / grub2-mkconfig / update-grub
#              grub-set-default, grub-reboot, grub-mkpasswd-pbkdf2
#              efibootmgr, mkinitrd/mkinitramfs, dracut
#   Concepts : MBR vs ESP; boot.img / core.img / modules; chainloading;
#              GRUB shell vs GRUB rescue shell; (hdX,Y) numbering - disks from
#              0, partitions from 1; root= vs prefix; volatile menu editing;
#              GRUB_DEFAULT=saved and GRUB_SAVEDEFAULT.
# =============================================================================