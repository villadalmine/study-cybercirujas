#!/usr/bin/env bash
# ==============================================================================
# LPI 702-100 BSD Specialist Certification Lab
# Topic 712.1: BSD Partitioning and Disk Labels
# Target OS: FreeBSD (Tested on FreeBSD 13.x / 14.x)
# Official Specs: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Sanity Checks
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This lab script must be executed as root." >&2
    exit 1
fi

if ! command -v mdconfig &> /dev/null || ! command -v gpart &> /dev/null; then
    echo "[ERROR] Required BSD storage utilities (mdconfig, gpart) not found. Run this on a FreeBSD host/VM." >&2
    exit 1
fi

MD_UNIT="99"
MD_DEV="md${MD_UNIT}"
BACKUP_FILE="/tmp/md99s1_disklabel_backup.geom"
MOUNT_POINT="/mnt/bsd_lab_target"

# Clean up previous lab iterations if present
if mount | grep -q "${MOUNT_POINT}"; then
    umount -f "${MOUNT_POINT}" || true
fi
if [ -d "${MOUNT_POINT}" ]; then
    rmdir "${MOUNT_POINT}"
fi
if mdconfig -l | grep -q "${MD_DEV}"; then
    mdconfig -d -u "${MD_UNIT}" -o force 2>/dev/null || true
fi

echo "[+] Initializing safe lab memory disk (/dev/${MD_DEV})..."
mdconfig -a -t malloc -s 128M -u "${MD_UNIT}"

# ------------------------------------------------------------------------------
# 2. Provisioning Initial BSD Partition & Disklabel Structure
# ------------------------------------------------------------------------------
echo "[+] Creating MBR partition scheme on /dev/${MD_DEV}..."
gpart create -s MBR "${MD_DEV}"

echo "[+] Adding FreeBSD MBR slice (/dev/${MD_DEV}s1)..."
gpart add -t freebsd "${MD_DEV}"

echo "[+] Creating BSD Disklabel scheme inside slice /dev/${MD_DEV}s1..."
gpart create -s BSD "${MD_DEV}s1"

echo "[+] Creating BSD subpartitions (a: UFS root/data, b: Swap, d: UFS extra)..."
gpart add -t freebsd-ufs -s 64M "${MD_DEV}s1"   # /dev/md99s1a
gpart add -t freebsd-swap -s 32M "${MD_DEV}s1"  # /dev/md99s1b
gpart add -t freebsd-ufs "${MD_DEV}s1"           # /dev/md99s1d

echo "[+] Formatting /dev/${MD_DEV}s1a with UFS2 filesystem..."
newfs -U "/dev/${MD_DEV}s1a" > /dev/null

echo "[+] Mounting target partition and populating flag data..."
mkdir -p "${MOUNT_POINT}"
mount "/dev/${MD_DEV}s1a" "${MOUNT_POINT}"
echo "LPI_702_FLAG{BSD_DISKLABEL_GEOM_RECOVERY_SUCCESSFUL}" > "${MOUNT_POINT}/flag.txt"
umount "${MOUNT_POINT}"

# Save backup for solution recovery mechanism
gpart backup "${MD_DEV}s1" > "${BACKUP_FILE}"

# ------------------------------------------------------------------------------
# 3. Controlled Breakdown Phase
# ------------------------------------------------------------------------------
echo "[!] Injecting controlled disklabel corruption into /dev/${MD_DEV}s1..."
# Overwrite BSD disklabel sector metadata while preserving MBR slice container
dd if=/dev/zero of="/dev/${MD_DEV}s1" bs=512 count=16 status=none
gpart destroy -F "${MD_DEV}s1" 2>/dev/null || true

# Force GEOM re-taste
gpart commit "${MD_DEV}" 2>/dev/null || true

echo ""
echo "========================================================================"
echo " LAB CHALLENGE: BSD Partitioning and Disk Labels (Topic 712.1)"
echo "========================================================================"
echo " SITUATION:"
echo " A system administrator attempted to modify subpartitions on slice /dev/${MD_DEV}s1,"
echo " but corrupted the BSD disklabel header structure. The MBR slice container"
echo " is still present, but GEOM cannot read the subpartition layout."
echo ""
echo " EXPECTED SYMPTOMS:"
echo " 1. Partition device nodes like /dev/${MD_DEV}s1a are missing."
echo " 2. Running 'gpart show ${MD_DEV}s1' returns: 'gpart: No such geom: ${MD_DEV}s1.'"
echo " 3. Attempting to mount /dev/${MD_DEV}s1a yields 'No such file or directory'."
echo ""
echo " YOUR OBJECTIVE:"
echo " 1. Inspect device geom state with 'gpart show ${MD_DEV}'."
echo " 2. Restore or recreate the BSD disklabel header on /dev/${MD_DEV}s1."
echo " 3. Restore subpartition layout matching original offsets (Backup available at ${BACKUP_FILE})."
echo " 4. Mount /dev/${MD_DEV}s1a on ${MOUNT_POINT} and read flag.txt."
echo "========================================================================"
echo ""

exit 0

# ==============================================================================
# INSTRUCTOR STEP-BY-STEP SOLUTION (UNCOMMENT OR READ TO SOLVE)
# ==============================================================================
#
# STEP 1: Inspect current GEOM layout to confirm MBR slice presence.
# Command:
#   gpart show md99
# Expected Output:
#   =>      63  262081  md99  MBR  (128M)
#           63  262081     1  freebsd  (128M)
#
# STEP 2: Verify subpartition scheme state (shows corruption).
# Command:
#   gpart show md99s1
# Expected Output:
#   gpart: No such geom: md99s1.
#
# STEP 3: Re-create the BSD disklabel scheme on slice md99s1.
# Command:
#   gpart create -s BSD md99s1
# Expected Output:
#   md99s1 created
#
# STEP 4 (Option A - Preferred): Restore metadata partition table from backup.
# Command:
#   gpart restore md99s1 < /tmp/md99s1_disklabel_backup.geom
# Expected Output:
#   gpart show md99s1
#   =>      0  262081  md99s1  BSD  (128M)
#           0  131072       1  freebsd-ufs  (64M)
#      131072   65536       2  freebsd-swap (32M)
#      196608   65473       4  freebsd-ufs  (32M)
#
# STEP 4 (Option B - Manual Recreation): Manually re-add exact subpartitions if backup lost.
# Commands:
#   gpart add -t freebsd-ufs -s 64M md99s1   # Creates 'a' (index 1)
#   gpart add -t freebsd-swap -s 32M md99s1  # Creates 'b' (index 2)
#   gpart add -t freebsd-ufs md99s1          # Creates 'd' (index 4)
#
# STEP 5: Verify block device nodes in /dev.
# Command:
#   ls -l /dev/md99s1*
# Expected Output:
#   crw-r-----  1 root  operator  0x... /dev/md99s1
#   crw-r-----  1 root  operator  0x... /dev/md99s1a
#   crw-r-----  1 root  operator  0x... /dev/md99s1b
#   crw-r-----  1 root  operator  0x... /dev/md99s1d
#
# STEP 6: Run filesystem consistency check and mount.
# Commands:
#   fsck_ffs -p /dev/md99s1a
#   mkdir -p /mnt/bsd_lab_target
#   mount /dev/md99s1a /mnt/bsd_lab_target
#   cat /mnt/bsd_lab_target/flag.txt
# Expected Output:
#   LPI_702_FLAG{BSD_DISKLABEL_GEOM_RECOVERY_SUCCESSFUL}
#
# STEP 7: Cleanup lab memory disk when finished.
# Command:
#   umount /mnt/bsd_lab_target && mdconfig -d -u 99