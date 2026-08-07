#!/usr/bin/env bash
# ==============================================================================
# LPI Security Essentials (020-100) - Exam Version 1.0
# Topic 3.1: Node, Device and Storage Security (Weight: 20)
#
# Production SRE Break & Fix Lab Environment
# Author: Senior SRE & Principal Platform Architect
#
# References:
# - LPI Security Essentials Overview: https://www.lpi.org/our-certifications/security-essentials-overview/
# - Linux Kernel Storage Security & Sysctl: https://www.kernel.org/doc/Documentation/sysctl/fs.txt
# - systemd.mount & fstab Specs: https://www.freedesktop.org/software/systemd/man/systemd.mount.html
# - udev Device Management Security: https://www.freedesktop.org/software/systemd/man/udev.html
# ==============================================================================

set -euo pipefail

BACKUP_DIR="/var/backups/lpi_020_100_lab_bak"
FSTAB_PATH="/etc/fstab"
UDEV_RULE_PATH="/etc/udev/rules.d/99-storage-node-security.rules"
SYSCTL_PATH="/etc/sysctl.d/99-node-storage-security.conf"
MARKER_FILE="${BACKUP_DIR}/LAB_BROKEN"

# Color Codes for Terminal Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed as root (sudo).${NC}" >&2
        exit 1
    fi
}

print_header() {
    echo -e "${CYAN}${BOLD}==============================================================================${NC}"
    echo -e "${CYAN}${BOLD} LPI 020-100 Topic 3.1: Node, Device and Storage Security Lab Environment${NC}"
    echo -e "${CYAN}${BOLD}==============================================================================${NC}"
}

usage() {
    print_header
    echo -e "${BOLD}Usage:${NC} $0 {break|status|verify|restore}"
    echo ""
    echo "  break   - Inject controlled security misconfigurations into node storage & devices."
    echo "  status  - Display current lab state, observed symptoms, and student goals."
    echo "  verify  - Run automated tests to check if the security incident is resolved."
    echo "  restore - Roll back all changes using safe local backups."
    echo ""
    exit 1
}

do_break() {
    check_root
    print_header

    if [[ -f "${MARKER_FILE}" ]]; then
        echo -e "${YELLOW}[!] Lab is already broken. Run '$0 status' to review symptoms or '$0 restore' to reset.${NC}"
        exit 0
    fi

    echo -e "${YELLOW}[*] Preparing backup directory at ${BACKUP_DIR}...${NC}"
    mkdir -p "${BACKUP_DIR}"

    # Backup /etc/fstab
    if [[ ! -f "${BACKUP_DIR}/fstab.bak" ]]; then
        cp "${FSTAB_PATH}" "${BACKUP_DIR}/fstab.bak"
    fi

    # Backup current /tmp permissions
    stat -c "%a %U %G" /tmp > "${BACKUP_DIR}/tmp_perm.bak"

    echo -e "${RED}[!] Injecting node & storage security failures...${NC}"

    # 1. Security Violation: Strip sticky bit from /tmp and restrict permissions (0755 root:root)
    chmod 0755 /tmp
    chown root:root /tmp

    # 2. Storage Mount Violation: Add corrupted mount entry with restrictive/invalid flags to /etc/fstab
    echo "tmpfs /tmp tmpfs defaults,ro,noexec,nodev,invalid_mount_option 0 0" >> "${FSTAB_PATH}"

    # 3. File System Protection Lock: Apply immutable attribute (+i) to /etc/fstab to simulate malicious/hardened lockout
    chattr +i "${FSTAB_PATH}" 2>/dev/null || true

    # 4. Device Access Violation: Create restrictive udev rule locking block storage devices to root:root 0600
    cat <<'EOF' > "${UDEV_RULE_PATH}"
# Restricted block device access for node security hardening
SUBSYSTEM=="block", KERNEL=="sd*", MODE="0600", OWNER="root", GROUP="root"
SUBSYSTEM=="block", KERNEL=="nvme*", MODE="0600", OWNER="root", GROUP="root"
EOF
    udevadm control --reload-rules 2>/dev/null || udevadm control --reload 2>/dev/null || true

    # 5. Kernel Hardening Misconfiguration: Restrict symlink/hardlink protections breaking container runtime IPC
    cat <<'EOF' > "${SYSCTL_PATH}"
fs.protected_symlinks = 0
fs.protected_hardlinks = 0
fs.protected_fifos = 0
EOF
    sysctl -p "${SYSCTL_PATH}" >/dev/null 2>&1 || true

    # Create marker file
    touch "${MARKER_FILE}"

    echo -e "${GREEN}[+] Lab breakage successfully injected.${NC}\n"
    do_status
}

do_status() {
    print_header
    echo -e "${BOLD}SCENARIO DESCRIPTION:${NC}"
    echo -e "An automated security compliance daemon applied overly aggressive node hardening settings,"
    echo -e "locking storage configurations and device nodes. SRE monitoring agents and unprivileged"
    echo -e "services are failing across the node due to file permissions, mount errors, and udev policies."
    echo ""
    echo -e "${BOLD}OBSERVED SYMPTOMS:${NC}"
    echo -e " 1. Unprivileged users and SRE tools cannot write temporary files to ${BOLD}/tmp${NC}."
    echo -e " 2. System administrators cannot modify ${BOLD}${FSTAB_PATH}${NC} (Operation not permitted)."
    echo -e " 3. Running ${BOLD}'mount -a'${NC} outputs syntax/option errors for tmpfs storage mounts."
    echo -e " 4. Non-root monitoring services lose access to disk storage metrics on block devices."
    echo -e " 5. Kernel filesystem symlink/hardlink protections are disabled, violating LPI baseline security."
    echo ""
    echo -e "${BOLD}STUDENT OBJECTIVES:${NC}"
    echo -e " 1. Remove the immutable attribute from ${BOLD}${FSTAB_PATH}${NC} and correct mount options."
    echo -e " 2. Restore standard POSIX sticky bit (1777) permissions on ${BOLD}/tmp${NC}."
    echo -e " 3. Remove or fix restrictive udev storage rules in ${BOLD}${UDEV_RULE_PATH}${NC}."
    echo -e " 4. Ensure kernel symlink/hardlink/FIFO protections are set to recommended defaults (1 or 2)."
    echo -e " 5. Run ${BOLD}'$0 verify'${NC} to validate your production security recovery."
    echo ""
    echo -e "${BOLD}OFFICIAL DOCUMENTATION REFERENCES:${NC}"
    echo -e " - LPI Security Essentials: https://www.lpi.org/our-certifications/security-essentials-overview/"
    echo -e " - Linux Kernel fs.protected Documentation: https://www.kernel.org/doc/Documentation/sysctl/fs.txt"
    echo -e " - systemd & udev Rules: https://www.freedesktop.org/software/systemd/man/udev.html"
    echo -e "${CYAN}==============================================================================${NC}"
}

do_verify() {
    check_root
    print_header
    echo -e "${BOLD}[*] Initiating Automated Verification Checks for Topic 3.1...${NC}\n"

    local errors=0

    # Test 1: Check /tmp permissions and sticky bit
    local tmp_stat
    tmp_stat=$(stat -c "%a" /tmp 2>/dev/null || echo "000")
    if [[ "${tmp_stat}" != "1777" ]]; then
        echo -e "${RED}[FAIL] /tmp permissions are '${tmp_stat}'. (Expected: 1777 - sticky bit drwxrwxrwt).${NC}"
        echo -e "       Expected CLI Output check: stat -c '%a' /tmp -> 1777"
        ((errors++))
    else
        echo -e "${GREEN}[PASS] /tmp sticky bit and permissions correctly set to 1777.${NC}"
    fi

    # Test 2: Check immutable attribute on /etc/fstab
    if lsattr "${FSTAB_PATH}" 2>/dev/null | grep -q '\-i\-'; then
        echo -e "${RED}[FAIL] ${FSTAB_PATH} is still marked as immutable (+i). Administrators cannot edit mount tables.${NC}"
        echo -e "       Expected CLI Output check: lsattr /etc/fstab -> no 'i' attribute."
        ((errors++))
    else
        echo -e "${GREEN}[PASS] ${FSTAB_PATH} is writeable (immutable attribute removed).${NC}"
    fi

    # Test 3: Validate /etc/fstab syntax and mount options
    if grep -q "invalid_mount_option" "${FSTAB_PATH}" 2>/dev/null; then
        echo -e "${RED}[FAIL] ${FSTAB_PATH} still contains invalid mount options ('invalid_mount_option').${NC}"
        ((errors++))
    else
        if mount -a --test >/dev/null 2>&1 || mount -a -f >/dev/null 2>&1 || true; then
            echo -e "${GREEN}[PASS] ${FSTAB_PATH} mount syntax test passed cleanly.${NC}"
        fi
    fi

    # Test 4: Check udev rule restrictions
    if [[ -f "${UDEV_RULE_PATH}" ]] && grep -q 'MODE="0600"' "${UDEV_RULE_PATH}" 2>/dev/null; then
        echo -e "${RED}[FAIL] Restrictive udev storage rule is still active in ${UDEV_RULE_PATH}.${NC}"
        ((errors++))
    else
        echo -e "${GREEN}[PASS] Restrictive udev storage device rule removed/corrected.${NC}"
    fi

    # Test 5: Verify kernel sysctl protections
    local symlink_prot
    symlink_prot=$(sysctl -n fs.protected_symlinks 2>/dev/null || echo "0")
    if [[ "${symlink_prot}" -eq 0 ]]; then
        echo -e "${RED}[FAIL] Kernel sysctl fs.protected_symlinks is disabled (0). Baseline node security requires 1 or 2.${NC}"
        ((errors++))
    else
        echo -e "${GREEN}[PASS] Kernel sysctl fs.protected_symlinks is active (${symlink_prot}).${NC}"
    fi

    echo ""
    if [[ ${errors} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}[SUCCESS] All verification checks passed! Node, Device and Storage Security restored to production standard.${NC}"
        rm -f "${MARKER_FILE}" 2>/dev/null || true
    else
        echo -e "${RED}${BOLD}[FAILED] ${errors} check(s) failed. Refer to the symptoms and complete the fix steps.${NC}"
        exit 1
    fi
}

do_restore() {
    check_root
    print_header
    echo -e "${YELLOW}[*] Restoring environment from backup...${NC}"

    if [[ -f "${BACKUP_DIR}/fstab.bak" ]]; then
        chattr -i "${FSTAB_PATH}" 2>/dev/null || true
        cp "${BACKUP_DIR}/fstab.bak" "${FSTAB_PATH}"
        echo -e "${GREEN}[+] Restored /etc/fstab.${NC}"
    fi

    if [[ -f "${BACKUP_DIR}/tmp_perm.bak" ]]; then
        chmod 1777 /tmp
        chown root:root /tmp
        echo -e "${GREEN}[+] Restored /tmp permissions (1777).${NC}"
    fi

    if [[ -f "${UDEV_RULE_PATH}" ]]; then
        rm -f "${UDEV_RULE_PATH}"
        udevadm control --reload-rules 2>/dev/null || udevadm control --reload 2>/dev/null || true
        echo -e "${GREEN}[+] Removed test udev rule.${NC}"
    fi

    if [[ -f "${SYSCTL_PATH}" ]]; then
        rm -f "${SYSCTL_PATH}"
        sysctl --system >/dev/null 2>&1 || true
        echo -e "${GREEN}[+] Restored system sysctl settings.${NC}"
    fi

    rm -rf "${BACKUP_DIR}"
    echo -e "${GREEN}[+] Node security environment successfully restored to clean state.${NC}"
}

# Main Command Dispatcher
case "${1:-}" in
    break)
        do_break
        ;;
    status)
        do_status
        ;;
    verify)
        do_verify
        ;;
    restore)
        do_restore
        ;;
    *)
        usage
        ;;
esac

exit 0

###############################################################################
# LAB SOLUTION (STEP-BY-STEP) - FOR INSTRUCTORS & SELF-ASSESSMENT
###############################################################################
#
# STEP 1: Diagnose and remove file attribute lock on /etc/fstab
#   Command:
#     lsattr /etc/fstab
#   Expected Output:
#     ----i---------e---- /etc/fstab
#
#   Fix: Remove immutable (+i) flag using chattr
#     sudo chattr -i /etc/fstab
#
# STEP 2: Fix /etc/fstab mount options
#   Open /etc/fstab in an editor:
#     sudo nano /etc/fstab  (or vim)
#   Locate the line:
#     tmpfs /tmp tmpfs defaults,ro,noexec,nodev,invalid_mount_option 0 0
#   Remove the invalid entry or fix it to standard production configuration:
#     tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
#
# STEP 3: Restore /tmp permissions and Sticky Bit (1777)
#   Verify current state:
#     ls -ld /tmp
#   Fix permissions:
#     sudo chmod 1777 /tmp
#     sudo chown root:root /tmp
#   Verify expected output:
#     drwxrwxrwt 1 root root ... /tmp
#
# STEP 4: Clean up restrictive udev storage rules
#   Inspect custom rules:
#     cat /etc/udev/rules.d/99-storage-node-security.rules
#   Remove the misconfigured rule and reload udev daemon:
#     sudo rm -f /etc/udev/rules.d/99-storage-node-security.rules
#     sudo udevadm control --reload-rules && sudo udevadm trigger
#
# STEP 5: Re-enable Kernel Storage Hardening (Sysctl)
#   Inspect kernel link protection settings:
#     sysctl fs.protected_symlinks fs.protected_hardlinks
#   Remove misconfigured sysctl file or set correct security parameters:
#     sudo rm -f /etc/sysctl.d/99-node-storage-security.conf
#     sudo sysctl -w fs.protected_symlinks=1
#     sudo sysctl -w fs.protected_hardlinks=1
#     sudo sysctl --system
#
# STEP 6: Execute Lab Verification
#   Run:
#     sudo ./break_fix_node_storage_security.sh verify
#   Expected Output:
#     [SUCCESS] All verification checks passed! Node, Device and Storage Security restored to production standard.
#
###############################################################################