#!/usr/bin/env bash
# ==============================================================================
# LPI 702-100 (BSD Specialist) - Topic 711.1: BSD Operating System Installation
# Lab Break & Fix Exercise: Boot Loader & Root Mount Failure Simulation
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
#
# WARNING: Run this script ONLY inside a disposable test/lab FreeBSD VM.
# Do NOT run this on production systems or non-disposable environments.
# ==============================================================================

set -euo pipefail

# Ensure script is executed as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This lab scenario script must be executed as root (uid 0)." >&2
    exit 1
fi

echo "======================================================================"
echo " LPI 702-100 Topic 711.1: BSD OS Installation & Boot Config Break & Fix"
echo "======================================================================"
echo ""
echo "SCENARIO OVERVIEW:"
echo "During a FreeBSD post-installation hardening script execution, an invalid"
echo "kernel loader variable and corrupted partition boot flag were applied."
echo "Upon reboot, the system fails to mount the root filesystem automatically"
echo "and hangs at the bootloader or mountroot prompt."
echo ""
echo "SYMPTOMS TO OBSERVE UPON REBOOT:"
echo "1. The loader menu loads, but boot stalls or fails when initializing vfs."
echo "2. System prints: 'Trying to mount root from ufs:/dev/gpt/nonexistent_root_slice [...]'"
echo "   followed by the 'mountroot>' error prompt."
echo "3. Partition active/boot flags are misconfigured on the primary storage controller."
echo ""
echo "STUDENT GOALS:"
echo "1. Intercept the boot stage at the FreeBSD loader prompt (OK prompt) or single-user mode."
echo "2. Use gpart(8), loader.conf(5), and mountroot diagnostic commands to locate valid slices."
echo "3. Restore correct vfs.root.mountfrom entries and ensure partition boot flags are active."
echo "4. Achieve a clean multi-user boot into FreeBSD."
echo ""
echo "Press CTRL+C within 5 seconds to abort, or press ENTER to break system..."
read -r -t 5 || true

echo ""
echo "[+] Creating backup directory at /var/backups/lpi711_lab_backup..."
mkdir -p /var/backups/lpi711_lab_backup

# Backup current critical configuration files if they exist
[ -f /boot/loader.conf ] && cp /boot/loader.conf /var/backups/lpi711_lab_backup/loader.conf.bak
[ -f /etc/fstab ] && cp /etc/fstab /var/backups/lpi711_lab_backup/fstab.bak

echo "[+] Injecting Fault 1: Injecting invalid root mount target into /boot/loader.conf..."
cat << 'EOF' >> /boot/loader.conf

# --- INJECTED LAB FAULT (LPI 702-100 Topic 711.1) ---
vfs.root.mountfrom="ufs:/dev/gpt/nonexistent_root_slice"
autoboot_delay="3"
EOF

echo "[+] Injecting Fault 2: Disabling active partition boot flags via gpart(8)..."
PRIMARY_DISK=""
for disk in vtbd0 ada0 da0 nvd0; do
    if gpart show "$disk" >/dev/null 2>&1; then
        PRIMARY_DISK="$disk"
        break
    fi
done

if [ -n "${PRIMARY_DISK}" ]; then
    echo "[+] Target disk detected: /dev/${PRIMARY_DISK}"
    # Unset active flag on MBR or bootme attribute on GPT if present
    gpart unset -a active -i 1 "${PRIMARY_DISK}" 2>/dev/null || true
    gpart unset -a bootme -i 2 "${PRIMARY_DISK}" 2>/dev/null || true
    echo "[+] Storage boot attributes modified on ${PRIMARY_DISK}."
else
    echo "[!] Warning: No standard disk device (vtbd0/ada0/da0/nvd0) found for gpart modification."
fi

echo ""
echo "======================================================================"
echo " [SUCCESS] System broken as intended for Topic 711.1 exercises."
echo " REBOOT THE VM NOW to begin the diagnosis and repair process."
echo "======================================================================"

# ==============================================================================
# STEP-BY-STEP SOLUTION (Keep commented for student review)
# ==============================================================================
#
# DIAGNOSIS & REPAIR PROCEDURE:
#
# STEP 1: INTERCEPT THE BOOTLOADER STAGE
# ------------------------------------------------------------------------------
# 1. Reboot the FreeBSD VM.
# 2. When the FreeBSD Beastie Boot Menu appears, press '3' or 'Escape' to drop
#    into the loader interactive command prompt:
#
#    Type:
#      OK show vfs.root.mountfrom
#    Output:
#      vfs.root.mountfrom=ufs:/dev/gpt/nonexistent_root_slice
#
# 3. Unset the bad loader variable and boot temporarily:
#      OK unset vfs.root.mountfrom
#      OK boot
#
# STEP 2: ALTERNATIVE RECOVERY AT MOUNTROOT PROMPT
# ------------------------------------------------------------------------------
# If the kernel reaches mountroot prompt:
#    mountroot> ?
#
# List valid block storage devices printed (e.g., ufs:/dev/ada0p2 or ufs:/dev/vtbd0p2).
# Enter the valid path manually:
#    mountroot> ufs:/dev/vtbd0p2
#
# STEP 3: RE-MOUNT ROOT & FIX PERMANENT CONFIGURATION
# ------------------------------------------------------------------------------
# Once logged into single-user shell:
#
# 1. Remount root filesystem as read-write:
#      # mount -o rw /
#      # mount -a
#
# 2. Inspect and fix /boot/loader.conf:
#      # vi /boot/loader.conf
#
#    Remove or correct the line:
#      vfs.root.mountfrom="ufs:/dev/gpt/nonexistent_root_slice"
#
# 3. Verify partition table health and boot flags using gpart(8):
#      # gpart show
#      # gpart status
#
#    Re-enable active partition flag if MBR scheme was used:
#      # gpart set -a active -i 1 vtbd0
#
#    If bootcode was damaged, re-install gpart bootcode for BIOS/GPT:
#      # gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 vtbd0
#
# 4. Verify `/etc/fstab` mapping:
#      # cat /etc/fstab
#
# 5. Perform clean system reboot:
#      # sync
#      # reboot
# ==============================================================================