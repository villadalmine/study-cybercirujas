#!/usr/bin/env bash
# ==============================================================================
# LPI 702-100: BSD Specialist Certification Production Study Material
# Topic 712.3: Control Mounting and Unmounting of File Systems (Weight: 3.33)
# 
# Author: Senior SRE Instructor & Principal Platform Architect
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# Documentation Reference: https://docs.freebsd.org/en/books/handbook/disks/#disks-fstab
# Manual Pages: mount(8), umount(8), fstat(1), fstab(5), mdconfig(8), devfs(8)
#
# PURPOSE:
# This script creates a controlled, safe "Break & Fix" scenario on a disposable
# BSD/Linux lab environment. It demonstrates VFS internal mechanics, mounting flags,
# stale vnode file lock contention (EBUSY), and /etc/fstab syntax corruption.
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/tmp/lpi_lab_712_3"
MOUNT_POINT="/mnt/secure_data"
IMG_FILE="${LAB_DIR}/disk.img"
FSTAB_PATH="/etc/fstab"
FSTAB_BAK="/etc/fstab.bak.lpi712_3"
LOCK_PID_FILE="${LAB_DIR}/locking_process.pid"

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "[ERROR] This lab script must be executed as root (sudo)." >&2
        exit 1
    fi
}

detect_os() {
    local os_name
    os_name=$(uname -s)
    echo "${os_name}"
}

create_loop_device() {
    local os
    os=$(detect_os)
    mkdir -p "${LAB_DIR}" "${MOUNT_POINT}"
    
    if [[ ! -f "${IMG_FILE}" ]]; then
        dd if=/dev/zero of="${IMG_FILE}" bs=1M count=64 status=none
    fi

    if [[ "${os}" == "FreeBSD" ]]; then
        if ! mdconfig -l | grep -q "md99"; then
            mdconfig -a -t vnode -f "${IMG_FILE}" -u 99
            newfs /dev/md99 >/dev/null 2>&1
        fi
        echo "/dev/md99"
    else
        # Linux fallback for hybrid lab testbeds
        local dev
        dev=$(losetup -f --show "${IMG_FILE}")
        if ! blkid "${dev}" | grep -q "ext4"; then
            mkfs.ext4 -F "${dev}" >/dev/null 2>&1
        fi
        echo "${dev}"
    fi
}

do_break() {
    check_root
    echo "========================================================================"
    echo " INJECTING PRODUCTION BREAKAGE: Topic 712.3 (FileSystem Mount/Umount) "
    echo "========================================================================"
    
    # 1. Backup /etc/fstab
    if [[ ! -f "${FSTAB_BAK}" ]]; then
        cp "${FSTAB_PATH}" "${FSTAB_BAK}"
    fi

    # 2. Setup storage device & mount point
    local dev
    dev=$(create_loop_device)

    # 3. Mount with restrictive flags (noexec, nosuid)
    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null || mount | grep -q "${MOUNT_POINT}"; then
        umount -f "${MOUNT_POINT}" 2>/dev/null || true
    fi
    
    mount -o noexec,nosuid "${dev}" "${MOUNT_POINT}"

    # 4. Inject Breakage A: Unlinked active file descriptor keeping VNODE locked (EBUSY)
    python3 -c "
import os, time, sys
path = '${MOUNT_POINT}/.orphaned_lock.tmp'
f = open(path, 'w+')
f.write('VNODE LOCK ACTIVE')
f.flush()
os.unlink(path)  # File is unlinked from directory hierarchy but vnode remains open!
with open('${LOCK_PID_FILE}', 'w') as pid_f:
    pid_f.write(str(os.getpid()))
time.sleep(86400)
" >/dev/null 2>&1 &

    sleep 1

    # 5. Inject Breakage B: Corrupt /etc/fstab with syntactically invalid mount flags
    # Real BSD fstab syntax: <device> <mountpoint> <fstype> <options> <dump> <pass>
    if ! grep -q "${MOUNT_POINT}" "${FSTAB_PATH}"; then
        echo -e "${dev}\t${MOUNT_POINT}\tufs\trw,noexec,nosuid,invalid_flag_xyz,failok\t2\t2" >> "${FSTAB_PATH}"
    fi

    # 6. Inject Breakage C: Copy a test executable script inside the mountpoint
    cat << 'EOF' > "${MOUNT_POINT}/deploy_app.sh"
#!/bin/sh
echo "SUCCESS: Binary executed successfully on secure_data mount!"
EOF
    chmod +x "${MOUNT_POINT}/deploy_app.sh"

    echo ""
    echo "[!] FAILURE SCENARIO SUCCESSFULLY INJECTED!"
    echo "========================================================================"
    echo "TECHNICAL CONTEXT & ARCHITECTURE OVERVIEW:"
    echo "In BSD systems (FreeBSD/OpenBSD/NetBSD), file system mounting interacts"
    echo "directly with the Kernel Virtual File System (VFS) layer. Mount flags like"
    echo "noexec and nosuid strip EXEC and SUID permissions at the vnode level."
    echo "Unmounting via umount(8) triggers dounmount() in the kernel, which fails"
    echo "with EBUSY (Device busy) if any process holds an open file handle, active"
    echo "mmap region, or current working directory on the mount point vnodes."
    echo ""
    echo "STUDENT TASK & SYMPTOMS TO DIAGNOSE:"
    echo "1. SYMPTOM 1 (Execution Blocked):"
    echo "   Attempting to execute '${MOUNT_POINT}/deploy_app.sh' fails with 'Permission denied'"
    echo "   even though file permissions are 0755."
    echo "   Command to test: ${MOUNT_POINT}/deploy_app.sh"
    echo ""
    echo "2. SYMPTOM 2 (Unmount Blocked / EBUSY):"
    echo "   Running 'umount ${MOUNT_POINT}' fails with 'Device busy' or 'Resource busy'."
    echo "   Standard tools (ls, find) won't show any active files because the locking"
    echo "   process holds an OPEN, UNLINKED file handle (an anonymous vnode)."
    echo ""
    echo "3. SYMPTOM 3 (Fstab Corruption):"
    echo "   Running 'mount -a' fails due to invalid mount options in ${FSTAB_PATH}."
    echo ""
    echo "GOAL TO FIX:"
    echo "a) Identify and terminate the orphan process holding the lock using fstat/lsof/fuser."
    echo "b) Cleanly unmount ${MOUNT_POINT} or remount it with 'exec' enabled using 'mount -u'."
    echo "c) Repair ${FSTAB_PATH} so 'mount -a' completes cleanly without syntax errors."
    echo "d) Verify that '${MOUNT_POINT}/deploy_app.sh' executes successfully."
    echo "========================================================================"
}

do_check() {
    check_root
    echo "========================================================================"
    echo " VERIFYING STUDENT SOLUTION: Topic 712.3 "
    echo "========================================================================"
    local errors=0

    # Test 1: Check fstab syntax via mount -a / dry run
    echo -n "[1/4] Checking /etc/fstab syntax... "
    if mount -a >/dev/null 2>&1; then
        echo "PASS"
    else
        echo "FAIL (mount -a returned errors; check fstab options)"
        errors=$((errors + 1))
    fi

    # Test 2: Check if invalid_flag_xyz is removed from /etc/fstab
    echo -n "[2/4] Validating fstab flags... "
    if grep -q "invalid_flag_xyz" "${FSTAB_PATH}"; then
        echo "FAIL (Corrupted flag 'invalid_flag_xyz' still present in ${FSTAB_PATH})"
        errors=$((errors + 1))
    else
        echo "PASS"
    fi

    # Test 3: Check binary execution on mount
    echo -n "[3/4] Testing binary execution on ${MOUNT_POINT}... "
    if "${MOUNT_POINT}/deploy_app.sh" >/dev/null 2>&1; then
        echo "PASS"
    else
        echo "FAIL (Cannot execute binary; mount still has 'noexec' flag active)"
        errors=$((errors + 1))
    fi

    # Test 4: Check if unmount works without EBUSY
    echo -n "[4/4] Testing clean unmount capability... "
    if umount "${MOUNT_POINT}" >/dev/null 2>&1; then
        echo "PASS"
        # Remount back for consistency
        local dev
        if detect_os | grep -q "FreeBSD"; then dev="/dev/md99"; else dev=$(losetup -j "${IMG_FILE}" | cut -d: -f1 | head -n1); fi
        mount "${dev}" "${MOUNT_POINT}"
    else
        echo "FAIL (umount returned EBUSY; lock process is still running)"
        errors=$((errors + 1))
    fi

    echo "========================================================================"
    if [[ "${errors}" -eq 0 ]]; then
        echo "RESULT: CONGRATULATIONS! ALL MOUNTING/UNMOUNTING ISSUES RESOLVED!"
        echo "You demonstrate production readiness for LPI 702-100 Topic 712.3."
    else
        echo "RESULT: VERIFICATION FAILED (${errors} errors found)."
        echo "Please review the diagnostic steps and try again."
    fi
    echo "========================================================================"
}

do_cleanup() {
    check_root
    echo "[*] Cleaning up lab environment..."
    
    if [[ -f "${LOCK_PID_FILE}" ]]; then
        kill -9 "$(cat "${LOCK_PID_FILE}")" 2>/dev/null || true
        rm -f "${LOCK_PID_FILE}"
    fi

    pkill -f "${MOUNT_POINT}/.orphaned_lock.tmp" 2>/dev/null || true

    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null || mount | grep -q "${MOUNT_POINT}"; then
        umount -f "${MOUNT_POINT}" 2>/dev/null || true
    fi

    local os
    os=$(detect_os)
    if [[ "${os}" == "FreeBSD" ]]; then
        if mdconfig -l | grep -q "md99"; then
            mdconfig -d -u 99 2>/dev/null || true
        fi
    else
        local dev
        dev=$(losetup -j "${IMG_FILE}" 2>/dev/null | cut -d: -f1 | head -n1 || true)
        if [[ -n "${dev}" ]]; then
            losetup -d "${dev}" 2>/dev/null || true
        fi
    fi

    if [[ -f "${FSTAB_BAK}" ]]; then
        mv "${FSTAB_BAK}" "${FSTAB_PATH}"
    fi

    rm -rf "${LAB_DIR}" "${MOUNT_POINT}"
    echo "[+] Cleanup complete. System restored."
}

case "${1:-}" in
    break)
        do_break
        ;;
    check)
        do_check
        ;;
    cleanup)
        do_cleanup
        ;;
    *)
        echo "Usage: $0 {break|check|cleanup}"
        exit 1
        ;;
esac

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & ARCHITECTURAL GUIDANCE (FOR STUDENT REFERENCE)
# ==============================================================================
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# Topic 712.3: Control Mounting and Unmounting of File Systems
#
# DIAGNOSTIC STEP 1: Diagnose the EBUSY Unmount Failure
# ------------------------------------------------------------------------------
# When running `umount /mnt/secure_data`, the kernel returns `EBUSY` (Device busy).
# Standard `ls -la /mnt/secure_data` shows no active files. Why?
# Because a process holds an open file descriptor on an unlinked file (anonymous vnode).
#
# Command to inspect open vnodes / file handles on BSD:
#   # FreeBSD native tool:
#   fstat -f /mnt/secure_data
#
#   # Cross-platform / Linux tool:
#   fuser -mv /mnt/secure_data
#   OR
#   lsof +D /mnt/secure_data
#
# Expected CLI Output from fstat:
#   USER     CMD          PID   FD MOUNT        INUM MODE         SZ|DV R/W
#   root     python3    41205    3 /mnt/secure_data   4 -rw-------      17  w
#
# Explanation: PID 41205 holds file descriptor 3 open on the mountpoint.
#
# Action to resolve:
#   kill -9 41205
#   # or using fuser directly:
#   fuser -k -9 /mnt/secure_data
#
# ------------------------------------------------------------------------------
# DIAGNOSTIC STEP 2: Resolve Execution Blocked by Mount Flags (noexec)
# ------------------------------------------------------------------------------
# Running `/mnt/secure_data/deploy_app.sh` results in:
#   sh: /mnt/secure_data/deploy_app.sh: Permission denied
#
# Check current mount options:
#   mount | grep /mnt/secure_data
#
# Expected Output:
#   /dev/md99 on /mnt/secure_data (ufs, local, noexec, nosuid, mounted by root)
#
# In BSD, you can dynamically update mount flags on a live file system without
# unmounting it using the `-u` (update) flag:
#
# Command:
#   mount -u -o exec,suid /mnt/secure_data
#
# Verification:
#   /mnt/secure_data/deploy_app.sh
# Expected Output:
#   SUCCESS: Binary executed successfully on secure_data mount!
#
# ------------------------------------------------------------------------------
# DIAGNOSTIC STEP 3: Repair Corrupted /etc/fstab File Syntax
# ------------------------------------------------------------------------------
# Running `mount -a` displays:
#   mount: /mnt/secure_data: bad option invalid_flag_xyz
#
# Inspect /etc/fstab:
#   cat /etc/fstab | grep secure_data
#
# Output:
#   /dev/md99   /mnt/secure_data   ufs   rw,noexec,nosuid,invalid_flag_xyz,failok   2   2
#
# Fix: Edit /etc/fstab using vi/nano to remove `invalid_flag_xyz` and update flags to `rw,exec,suid,failok`:
#   /dev/md99   /mnt/secure_data   ufs   rw,exec,suid,failok   2   2
#
# Validate with:
#   mount -a
#   echo $?  # Should return 0
#
# ------------------------------------------------------------------------------
# SUMMARY OF KEY BSD MOUNT COMMANDS & OPTIONS FOR LPI 702-100:
# - mount -a                     : Mounts all file systems listed in /etc/fstab (except those marked 'noauto').
# - mount -u -o <opts> <mount>   : Updates flags on an already mounted file system atomically.
# - umount -f <mount>            : Forces unmount (invalidates vnodes even if open handles exist; use with caution in production).
# - fstat -f <path>              : Displays active file handles across vnodes on specified BSD filesystem.
# - fstab(5) fields              : <device> <mountpoint> <type> <options> <dump_freq> <pass_num>
# - Important BSD flags          : late (delays mount until network/daemons ready), failok (prevents boot drop to single-user mode), noatime, noexec, nosuid, ro, rw.
# ==============================================================================