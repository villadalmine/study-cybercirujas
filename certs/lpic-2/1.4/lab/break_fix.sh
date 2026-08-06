#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 (Exams 201-450 & 202-450 v4.5) Hands-On Lab: Filesystem and Devices
# Topic 201.4 / 1.4: Operating and Maintaining Linux Filesystems
# Weight: 7
# 
# Description: Production Break & Fix Lab Script
# This script creates a controlled failure scenario on a disposable lab VM:
#  1. Creates virtual loopback block devices.
#  2. Intentionally corrupts the primary ext4 superblock.
#  3. Injects a malformed entry into /etc/fstab with invalid UUID and options.
#  4. Prompts the student to diagnose, restore superblocks, and repair /etc/fstab.
# ==============================================================================

set -euo pipefail

# Color Codes for Output
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LAB_DIR="/var/tmp/lpic2_topic1.4_lab"
IMG_FILE="${LAB_DIR}/disk_ext4.img"
MOUNT_POINT="/mnt/lpic2_secure_data"
FSTAB_BACKUP="/etc/fstab.lpic2_bak"
LOOP_DEV=""

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed as root (sudo).${NC}" >&2
        exit 1
    fi
}

get_loop_device() {
    if [[ -f "${LAB_DIR}/loop_device.txt" ]]; then
        LOOP_DEV=$(cat "${LAB_DIR}/loop_device.txt")
    fi
}

cmd_break() {
    check_root
    echo -e "${BLUE}[+] Initializing LPIC-2 Topic 1.4 Break & Fix Scenario...${NC}"

    # Cleanup any prior run
    cmd_cleanup >/dev/null 2>&1 || true

    mkdir -p "${LAB_DIR}"
    mkdir -p "${MOUNT_POINT}"

    # Step 1: Create 250MB image file
    echo -e "${BLUE}[+] Creating 250MB raw disk image file at ${IMG_FILE}...${NC}"
    dd if=/dev/zero of="${IMG_FILE}" bs=1M count=250 status=none

    # Step 2: Attach to loop device
    LOOP_DEV=$(losetup --find --show "${IMG_FILE}")
    echo "${LOOP_DEV}" > "${LAB_DIR}/loop_device.txt"
    echo -e "${BLUE}[+] Attached ${IMG_FILE} to block device ${LOOP_DEV}.${NC}"

    # Step 3: Format as ext4 with specific volume label
    echo -e "${BLUE}[+] Formatting ${LOOP_DEV} with ext4 filesystem (Label: SECURE_DATA)...${NC}"
    mkfs.ext4 -F -L "SECURE_DATA" -b 4096 "${LOOP_DEV}" >/dev/null 2>&1

    # Extract real UUID
    REAL_UUID=$(blkid -s UUID -o value "${LOOP_DEV}")

    # Step 4: Inject Failure 1 - Primary Superblock Corruption
    # For 4096-byte block size ext4, primary superblock lives at byte offset 1024 (length 1024).
    # Zeroing out bytes 1024-4096 destroys primary superblock magic number 0xEF53.
    echo -e "${YELLOW}[!] Injecting Fault #1: Corrupting primary superblock on ${LOOP_DEV}...${NC}"
    dd if=/dev/zero of="${LOOP_DEV}" bs=1024 seek=1 count=3 conv=notrunc status=none

    # Step 5: Inject Failure 2 - Malformed /etc/fstab entry
    echo -e "${YELLOW}[!] Injecting Fault #2: Backing up /etc/fstab and appending invalid entry...${NC}"
    if [[ ! -f "${FSTAB_BACKUP}" ]]; then
        cp /etc/fstab "${FSTAB_BACKUP}"
    fi

    FAKE_UUID="c1a83f99-0000-4444-8888-deadbeef9999"
    # Appending bad UUID and invalid mount option "errors=invalid-option-xyz"
    echo "UUID=${FAKE_UUID}  ${MOUNT_POINT}  ext4  defaults,errors=invalid-option-xyz,nofail  0  2" >> /etc/fstab

    echo -e "${GREEN}====================================================================${NC}"
    echo -e "${GREEN}      LAB ENVIRONMENT BROKEN SUCCESSFULLY (LPIC-2 Topic 1.4)      ${NC}"
    echo -e "${GREEN}====================================================================${NC}"
    echo -e "${YELLOW}SYMPTOMS & TROUBLE TICKET:${NC}"
    echo -e " 1. The monitoring system reports mounting ${MOUNT_POINT} fails."
    echo -e " 2. Executing 'mount ${MOUNT_POINT}' or 'mount -a' yields critical errors."
    echo -e " 3. Directly inspecting the block device ${LOOP_DEV} indicates superblock / magic number corruption."
    echo -e ""
    echo -e "${YELLOW}STUDENT OBJECTIVES:${NC}"
    echo -e " Task 1: Identify the corrupted block device associated with file ${IMG_FILE}."
    echo -e " Task 2: Locate alternate/backup superblocks using dumpe2fs or mke2fs."
    echo -e " Task 3: Repair the ext4 filesystem on ${LOOP_DEV} using e2fsck and a backup superblock."
    echo -e " Task 4: Determine the correct UUID of ${LOOP_DEV} using blkid/lsblk."
    echo -e " Task 5: Fix /etc/fstab to use valid UUID (${REAL_UUID}) and standard mount options."
    echo -e " Task 6: Verify successful mount at ${MOUNT_POINT} with 'mount -a' and write test."
    echo -e ""
    echo -e "Run '${0} status' to check your progress or '${0} cleanup' when finished."
    echo -e "${GREEN}====================================================================${NC}"
}

cmd_status() {
    check_root
    get_loop_device
    echo -e "${BLUE}[+] Evaluating Lab Resolution Status...${NC}"

    ERRORS=0

    if [[ -z "${LOOP_DEV}" ]] || [[ ! -b "${LOOP_DEV}" ]]; then
        echo -e "${RED}[FAIL] Loop block device is not active. Did you run 'break'?${NC}"
        return 1
    fi

    # Test 1: Check filesystem integrity
    if e2fsck -n "${LOOP_DEV}" >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS] Task 1-3: Filesystem on ${LOOP_DEV} is clean and repaired.${NC}"
    else
        echo -e "${RED}[FAIL] Task 1-3: Filesystem on ${LOOP_DEV} still contains errors or superblock corruption.${NC}"
        ERRORS=$((ERRORS + 1))
    fi

    # Test 2: Check fstab syntax and mount status
    if mountpoint -q "${MOUNT_POINT}"; then
        echo -e "${GREEN}[PASS] Task 4-6: Target ${MOUNT_POINT} is currently mounted.${NC}"
    else
        echo -e "${YELLOW}[-] Target ${MOUNT_POINT} is not mounted. Attempting 'mount -a'...${NC}"
        if mount -a >/dev/null 2>&1 && mountpoint -q "${MOUNT_POINT}"; then
            echo -e "${GREEN}[PASS] Task 4-6: 'mount -a' succeeded and mounted ${MOUNT_POINT}.${NC}"
        else
            echo -e "${RED}[FAIL] Task 4-6: Unable to mount ${MOUNT_POINT}. Check /etc/fstab syntax or UUID.${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Test 3: Write test
    if mountpoint -q "${MOUNT_POINT}"; then
        if touch "${MOUNT_POINT}/test_write.tmp" >/dev/null 2>&1; then
            rm -f "${MOUNT_POINT}/test_write.tmp"
            echo -e "${GREEN}[PASS] Read/Write test on ${MOUNT_POINT} succeeded.${NC}"
        else
            echo -e "${RED}[FAIL] ${MOUNT_POINT} is mounted but read-only or permission denied.${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    if [[ ${ERRORS} -eq 0 ]]; then
        echo -e "\n${GREEN}CONGRATULATIONS! You have successfully solved the LPIC-2 Topic 1.4 Lab!${NC}"
    else
        echo -e "\n${YELLOW}Keep troubleshooting! ${ERRORS} issue(s) remaining.${NC}"
    fi
}

cmd_cleanup() {
    check_root
    echo -e "${BLUE}[+] Cleaning up lab environment...${NC}"

    get_loop_device

    if mountpoint -q "${MOUNT_POINT}"; then
        umount -f "${MOUNT_POINT}" || true
    fi

    if [[ -n "${LOOP_DEV}" ]] && [[ -b "${LOOP_DEV}" ]]; then
        losetup -d "${LOOP_DEV}" || true
    fi

    if [[ -f "${FSTAB_BACKUP}" ]]; then
        cp "${FSTAB_BACKUP}" /etc/fstab
        rm -f "${FSTAB_BACKUP}"
        echo -e "${BLUE}[+] Restored original /etc/fstab.${NC}"
    fi

    rm -rf "${LAB_DIR}"
    rm -rf "${MOUNT_POINT}"

    echo -e "${GREEN}[+] Cleanup complete.${NC}"
}

usage() {
    echo "Usage: $0 {break|status|cleanup}"
    echo "  break   - Inject production failures into disposable lab environment"
    echo "  status  - Validate if student resolved all issues"
    echo "  cleanup - Remove lab devices, files, and restore /etc/fstab"
    exit 1
}

case "${1:-break}" in
    break)
        cmd_break
        ;;
    status)
        cmd_status
        ;;
    cleanup)
        cmd_cleanup
        ;;
    *)
        usage
        ;;
esac

# ==============================================================================
# LPIC-2 EXAM 201-450 TOPIC 1.4 DETAILED STUDY MATERIAL & STEP-BY-STEP SOLUTION
# ==============================================================================
#
# --- 1. ARCHITECTURAL MECHANICS & PRODUCTION BACKGROUND ---
#
# A. EXT4 Block Group Structure & Superblock Redundancy:
#    - An ext4 filesystem is divided into Block Groups to reduce fragmentation.
#    - Block Group 0 contains the Primary Superblock at byte offset 1024.
#    - The Superblock stores critical filesystem metadata: magic number (0xEF53),
#      block size, total inode/block counts, feature flags, and state flags.
#    - If the primary superblock is corrupted (e.g., storage bit rot, interrupted
#      dd operation, SAN metadata overwrite), ext4 cannot be mounted.
#    - Redundant backup superblocks are automatically placed in specific block
#      groups (sparse superblock feature stores copies in group 0, 1, and powers of
#      3, 5, 7: e.g., blocks 32768, 98304, 163840 for 4KiB block size).
#
# B. Systemd Filesystem Mounting & /etc/fstab Parsing:
#    - Modern Linux distributions translate /etc/fstab into systemd mount units
#      (via systemd-fstab-generator during boot or 'systemctl daemon-reload').
#    - An incorrect UUID or unsupported mount option in /etc/fstab blocks boot
#      or causes systemd to drop into Emergency Mode unless the 'nofail' or
#      'x-systemd.device-timeout' options are properly configured.
#
# --- 2. STEP-BY-STEP DIAGNOSTIC AND RESOLUTION WALKTHROUGH ---
#
# STEP 1: Identify Mount Failures & System Symptoms
# Command:
#   $ sudo mount /mnt/lpic2_secure_data
# Output:
#   mount: /mnt/lpic2_secure_data: wrong fs type, bad option, bad superblock on /dev/loop0, missing codepage or helper program, or other error.
#
# Command:
#   $ sudo mount -a
# Output:
#   mount: /mnt/lpic2_secure_data: wrong fs type, bad option, bad superblock on /dev/loop0...
#
# STEP 2: Inspect Block Devices and File System Metadata
# Command:
#   $ sudo blkid /dev/loop0
# Output (Primary magic missing, blkid fails to report ext4 type or UUID):
#   /dev/loop0: PTUUID="..." PTTYPE="dos"
#
# Command:
#   $ sudo e2fsck /dev/loop0
# Expected Output:
#   e2fsck 1.46.5 (30-Dec-2021)
#   e2fsck: Bad magic number in super-block while trying to open /dev/loop0
#   The superblock could not be read or does not describe a valid ext2/ext3/ext4
#   filesystem.  If the device is valid and it really contains an ext2/ext3/ext4
#   filesystem (and not swap or ufs or something else), then the superblock
#   is corrupt, and you might try running e2fsck with an alternate superblock:
#       e2fsck -b 8193 <device>
#   or
#       e2fsck -b 32768 <device>
#
# STEP 3: Discover Backup Superblock Locations
# Use 'mke2fs -n' (dry-run format) to output exact backup superblock block numbers
# without writing to disk:
# Command:
#   $ sudo mke2fs -n -b 4096 /dev/loop0
# Expected Output:
#   Creating filesystem with 64000 4k blocks and 64000 inodes
#   Superblock backups stored on blocks:
#       32768
#
# STEP 4: Restore Superblock & Repair Filesystem
# Execute e2fsck referencing the backup block number 32768:
# Command:
#   $ sudo e2fsck -b 32768 -y /dev/loop0
# Expected Output:
#   e2fsck 1.46.5 (30-Dec-2021)
#   Restoring superblock backup from block 32768...
#   SECURE_DATA: Group descriptor 0 checksum is 0x1234.  FIXED.
#   SECURE_DATA: Pass 1: Checking inodes, blocks, and sizes
#   SECURE_DATA: Pass 2: Checking directory structure
#   SECURE_DATA: Pass 3: Checking directory connectivity
#   SECURE_DATA: Pass 4: Checking reference counts
#   SECURE_DATA: Pass 5: Checking group summary information
#   SECURE_DATA: ***** FILE SYSTEM WAS MODIFIED *****
#   SECURE_DATA: 11/64000 files (0.0% non-contiguous), 5221/64000 blocks
#
# STEP 5: Verify Filesystem and Extract Real UUID
# Command:
#   $ sudo blkid /dev/loop0
# Expected Output:
#   /dev/loop0: LABEL="SECURE_DATA" UUID="a1b2c3d4-e5f6-7890-abcd-1234567890ab" TYPE="ext4"
#
# STEP 6: Fix /etc/fstab Misconfiguration
# Inspect /etc/fstab:
# Command:
#   $ tail -n 1 /etc/fstab
# Output:
#   UUID=c1a83f99-0000-4444-8888-deadbeef9999  /mnt/lpic2_secure_data  ext4  defaults,errors=invalid-option-xyz,nofail  0  2
#
# Edit /etc/fstab to replace fake UUID and remove invalid option 'errors=invalid-option-xyz':
# Correct line format:
#   UUID=a1b2c3d4-e5f6-7890-abcd-1234567890ab  /mnt/lpic2_secure_data  ext4  defaults,nofail  0  2
#
# STEP 7: Validate Resolution
# Commands:
#   $ sudo systemctl daemon-reload
#   $ sudo mount -a
#   $ sudo mountpoint /mnt/lpic2_secure_data
# Expected Output:
#   /mnt/lpic2_secure_data is a mountpoint
#
# Command:
#   $ sudo ./lpic2_break_fix.sh status
# Expected Output:
#   [PASS] Task 1-3: Filesystem on /dev/loop0 is clean and repaired.
#   [PASS] Task 4-6: 'mount -a' succeeded and mounted /mnt/lpic2_secure_data.
#   [PASS] Read/Write test on /mnt/lpic2_secure_data succeeded.
#   CONGRATULATIONS! You have successfully solved the LPIC-2 Topic 1.4 Lab!
#
# --- 3. PRODUCTION TRADE-OFFS & BEST PRACTICES ---
#  - XFS vs. EXT4 Superblock Recovery:
#    EXT4 maintains multiple redundant superblocks accessible via 'e2fsck -b'.
#    XFS keeps primary allocation group metadata at AG 0. If AG 0 is completely zeroed,
#    'xfs_repair' uses AG 1/2 backups, but severe AG 0 damage may require 'xfs_repair -L'
#    which zeroes the log and risks data loss.
#  - Cloud Mount Resilience ('nofail' vs 'fail'):
#    Always append 'nofail,x-systemd.device-timeout=10s' in /etc/fstab for non-root cloud
#    data volumes (EBS, GCP PD). Without 'nofail', a missing volume halts the systemd boot
#    sequence and triggers emergency mode.
#
# --- 4. OFFICIAL REFERENCES & CITATIONS ---
#  - LPIC-2 Exam 201-450 Detailed Objectives:
#    https://www.lpi.org/our-certifications/lpic-2-overview/
#  - Linux Kernel Documentation - ext4 Filesystem:
#    https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html
#  - e2fsck(8) Man Page:
#    https://man7.org/linux/man-pages/man8/e2fsck.8.html
#  - fstab(5) Man Page:
#    https://man7.org/linux/man-pages/man5/fstab.5.html
# ==============================================================================