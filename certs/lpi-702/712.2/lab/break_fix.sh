#!/usr/bin/env bash
# ==============================================================================
# LPI-702 BSD Specialist Certification (Exam 702-100, v1.0)
# Topic 712.2: Create File Systems and Maintain their Integrity (Weight: 1.67)
# Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
#
# Production Break & Fix Lab: Primary Superblock Corruption & Alternate Recovery
# ==============================================================================
# CAUTION: Run this script only inside a disposable lab virtual machine (FreeBSD/BSD).
# ==============================================================================

set -euo pipefail

LAB_IMG="/var/tmp/lpi702_ffs.img"
MD_DEV="md99"
MOUNT_POINT="/mnt/lpi702_lab"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR] This script must be executed as root.${NC}" >&2
    exit 1
fi

echo -e "${CYAN}[+] Setting up disposable UFS2 file system lab...${NC}"

# Clean up previous lab state if present
if mount | grep -q "${MOUNT_POINT}"; then
    umount -f "${MOUNT_POINT}" || true
fi
if [ -c "/dev/${MD_DEV}" ]; then
    mdconfig -d -u "${MD_DEV#md}" || true
fi
rm -f "${LAB_IMG}"
mkdir -p "${MOUNT_POINT}"

# 1. Create a 250MB sparse file image and attach it as a vnode memory disk
dd if=/dev/zero of="${LAB_IMG}" bs=1M count=250 status=none
mdconfig -a -t vnode -f "${LAB_IMG}" -u "${MD_DEV#md}"

# 2. Build a UFS2 filesystem with Soft Updates enabled using newfs
echo -e "${CYAN}[+] Initializing UFS2 file system on /dev/${MD_DEV} with Soft Updates...${NC}"
newfs -U -O 2 "/dev/${MD_DEV}" > /dev/null

# 3. Populate filesystem with critical production test data
mount "/dev/${MD_DEV}" "${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}/production_data"
echo "CRITICAL_PAYLOAD_LPI_702_VALIDATION_TOKEN=712_2_PASSED" > "${MOUNT_POINT}/production_data/state.db"
sync
umount "${MOUNT_POINT}"

# 4. Inject low-level corruption into the primary superblock (offset 64KB for UFS2)
echo -e "${CYAN}[+] Simulating storage array sector degradation (Zeroing primary UFS2 superblock)...${NC}"
dd if=/dev/zero of="/dev/${MD_DEV}" bs=512 seek=128 count=32 status=none

echo -e "\n${RED}==============================================================================${NC}"
echo -e "${RED} [!] BREAK & FIX SCENARIO ACTIVATED: TOPIC 712.2 FS INTEGRITY FAILURE ${NC}"
echo -e "${RED}==============================================================================${NC}"
echo -e "${YELLOW}INCIDENT REPORT:${NC}"
echo -e "An ungraceful power loss or disk failure damaged the primary superblock of target device: /dev/${MD_DEV}"
echo -e ""
echo -e "${YELLOW}SYMPTOMS:${NC}"
echo -e " 1. Attempting to mount /dev/${MD_DEV} fails with: 'mount: /dev/${MD_DEV}: Incorrect super block'"
echo -e " 2. Standard 'fsck /dev/${MD_DEV}' fails with: 'fsck_ffs: /dev/${MD_DEV}: Cannot find file system superblock'"
echo -e ""
echo -e "${YELLOW}STUDENT OBJECTIVE:${NC}"
echo -e " 1. Diagnose the file system architecture using UFS utilities (newfs -N / dumpfs)."
echo -e " 2. Determine alternate (backup) superblock locations calculated at creation time."
echo -e " 3. Restore the primary superblock using fsck_ffs specifying an alternate superblock location."
echo -e " 4. Safely mount /dev/${MD_DEV} to ${MOUNT_POINT} and confirm data integrity of /production_data/state.db."
echo -e ""
echo -e "${CYAN}Run 'fsck -y /dev/${MD_DEV}' or 'mount /dev/${MD_DEV} ${MOUNT_POINT}' now to begin diagnostic.${NC}"
echo -e "${RED}==============================================================================${NC}\n"

# ==============================================================================
# STEP-BY-STEP SOLUTION & SRE PRODUCTION EXPLANATION (COMMENTED OUT BELOW)
# ==============================================================================
#
# TECHNICAL MECHANICS & ARCHITECTURE:
# ----------------------------------
# Unix File System (UFS2/FFS) structures the disk into cylinder groups. The primary
# superblock resides at a fixed offset (64KB in UFS2, sector 128). To provide fault
# tolerance against media corruption, newfs duplicates the superblock metadata across
# multiple cylinder groups during filesystem creation.
#
# If the primary superblock is corrupted, standard tools cannot read the geometry or
# inode maps. However, alternate superblocks (located at predictable block offsets like
# 160, 19200, 38240, etc.) can be passed to fsck_ffs using the -b flag to restore the
# filesystem headers.
#
# STEP-BY-STEP SOLUTION COMMANDS:
# -------------------------------
# Step 1: Verify the failure symptom
#   # mount /dev/md99 /mnt/lpi702_lab
#   mount: /dev/md99: Incorrect super block
#
#   # fsck_ffs /dev/md99
#   Cannot find file system superblock
#
# Step 2: Extract alternate superblock offsets without touching existing disk structures
#   The 'newfs -N' command acts as a dry-run query, outputting geometry parameters and
#   alternate superblock block numbers without overwriting the disk.
#
#   # newfs -N /dev/md99
#   /dev/md99: 250.0MB (512000 sectors) block size 32768, fragment size 4096
#           using 4 cylinder groups of 62.53MB, 2001 blks, 8000 inodes.
#   super-block backups (for fsck_ffs -b #) at:
#    160, 128224, 256288, 384352
#
# Step 3: Execute fsck_ffs using an alternate superblock (-b flag)
#   Pass one of the alternate block numbers (e.g., 160 or 128224) to repair the primary superblock:
#
#   # fsck_ffs -y -b 160 /dev/md99
#   ** /dev/md99 (NO WRITE)
#   LOOKING FOR ALTERNATE SUPERBLOCKS...
#   USING ALTERNATE SUPERBLOCK AT 160
#   ** Phase 1 - Check Blocks and Sizes
#   ** Phase 2 - Check Pathnames
#   ** Phase 3 - Check Connectivity
#   ** Phase 4 - Check Reference Counts
#   ** Phase 5 - Check Cyl groups
#   FREE BLK COUNT(S) FIXED
#   4 files, 1533 used, 60882 free
#   ***** FILE SYSTEM WAS MODIFIED *****
#   ***** MARK FILE SYSTEM CLEAN *****
#
# Step 4: Verify filesystem integrity and mount
#   # fsck_ffs -p /dev/md99
#   /dev/md99: FILE SYSTEM CLEAN; SKIPPING CHECKS
#
#   # mount /dev/md99 /mnt/lpi702_lab
#   # cat /mnt/lpi702_lab/production_data/state.db
#   CRITICAL_PAYLOAD_LPI_702_VALIDATION_TOKEN=712_2_PASSED
#
# Step 5: Clean up lab resources (Post-Fix)
#   # umount /mnt/lpi702_lab
#   # mdconfig -d -u 99
#   # rm -f /var/tmp/lpi702_ffs.img
# ==============================================================================