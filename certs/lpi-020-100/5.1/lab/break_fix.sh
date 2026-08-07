#!/usr/bin/env bash
# ==============================================================================
# LPI Security Essentials (Exam 020-100, Version 1.0)
# Topic 5.1: Identity and Privacy (Weight: 20)
# Production Break & Fix Lab Script
#
# Reference:
# https://www.lpi.org/our-certifications/security-essentials-overview/
# ==============================================================================

set -euo pipefail

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[0;36m"
COLOR_RESET="\033[0m"

TARGET_USER="sys_auditor"
TARGET_HOME="/home/${TARGET_USER}"
BACKUP_DIR="/var/backups/lpi_5_1_lab"

function check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${COLOR_RED}Error: This script must be executed as root.${COLOR_RESET}" >&2
        exit 1
    fi
}

function print_header() {
    echo -e "${COLOR_CYAN}======================================================================${COLOR_RESET}"
    echo -e "${COLOR_CYAN} LPI 020-100 (v1.0) | Topic 5.1: Identity and Privacy Break & Fix Lab ${COLOR_RESET}"
    echo -e "${COLOR_CYAN}======================================================================${COLOR_RESET}"
}

function show_symptoms() {
    echo -e "\n${COLOR_YELLOW}[+] LAB INCIDENT SUMMARY:${COLOR_RESET}"
    echo "The security automation pipeline reported multiple critical identity and privacy compliance failures:"
    echo "  1) User '${TARGET_USER}' cannot log in or execute su commands due to account shadow aging expiration."
    echo "  2) Sensitive system authentication files (/etc/shadow) have insecure permission settings, exposing password hashes."
    echo "  3) Default system user creation file creation mask (UMASK) in /etc/login.defs is improperly configured."
    echo "  4) User's OpenPGP key directory (${TARGET_HOME}/.gnupg) has unsafe permissions, breaking GPG privacy tools."
    echo "  5) PAM configuration for 'su' (/etc/pam.d/su) contains a misconfigured authentication rule blocking identity elevation."
    echo ""
    echo -e "${COLOR_YELLOW}[+] OBJECTIVES TO FIX:${COLOR_RESET}"
    echo "  - Fix /etc/shadow permissions and ownership so only authorized processes can access password hashes (mode 0640 or 0600, root:shadow or root:root)."
    echo "  - Update '${TARGET_USER}' shadow aging parameters using 'chage' so the account is active and not expired."
    echo "  - Correct the default UMASK setting in /etc/login.defs to a secure value (e.g., 027 or 077)."
    echo "  - Restore secure permissions on ${TARGET_HOME}/.gnupg (directory mode 0700 owned by ${TARGET_USER})."
    echo "  - Revert the invalid PAM rule in /etc/pam.d/su."
    echo ""
    echo -e "Run '${0} verify' to evaluate your fixes."
}

function do_break() {
    check_root
    print_header
    echo -e "${COLOR_YELLOW}[*] Applying production break-and-fix scenario...${COLOR_RESET}"

    # 1. Create backups
    mkdir -p "${BACKUP_DIR}"
    cp -a /etc/shadow "${BACKUP_DIR}/shadow.orig"
    cp -a /etc/login.defs "${BACKUP_DIR}/login.defs.orig"
    cp -a /etc/pam.d/su "${BACKUP_DIR}/pam_su.orig"

    # 2. Setup user
    if ! id "${TARGET_USER}" &>/dev/null; then
        useradd -m -s /bin/bash "${TARGET_USER}"
        echo "${TARGET_USER}:ComplexP@ssw0rd2026!" | chpasswd
    fi

    # 3. BREAK 1: Insecure /etc/shadow permissions (World readable - Privacy breach)
    chmod 0644 /etc/shadow

    # 4. BREAK 2: Expire user account password shadow aging
    chage -E 1970-01-01 "${TARGET_USER}"
    chage -M 10 "${TARGET_USER}"

    # 5. BREAK 3: Insecure system default umask in /etc/login.defs
    if grep -q "^UMASK" /etc/login.defs; then
        sed -i 's/^UMASK.*/UMASK\t000/' /etc/login.defs
    else
        echo -e "UMASK\t000" >> /etc/login.defs
    fi

    # 6. BREAK 4: Insecure GPG privacy directory permissions
    mkdir -p "${TARGET_HOME}/.gnupg"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.gnupg"
    chmod 0777 "${TARGET_HOME}/.gnupg"

    # 7. BREAK 5: PAM rule insertion in /etc/pam.d/su blocking user authentication
    if ! grep -q "pam_deny.so # LAB_BREAK_MARKER" /etc/pam.d/su; then
        sed -i '1i auth required pam_deny.so # LAB_BREAK_MARKER' /etc/pam.d/su
    fi

    echo -e "${COLOR_RED}[!] System intentionally broken for Topic 5.1 Identity and Privacy.${COLOR_RESET}"
    show_symptoms
}

function do_verify() {
    check_root
    print_header
    echo -e "${COLOR_YELLOW}[*] Verifying system configuration against Topic 5.1 standards...${COLOR_RESET}\n"

    local PASSED=0
    local TOTAL=5

    # Check 1: /etc/shadow permissions
    local SHADOW_PERM
    SHADOW_PERM=$(stat -c "%a" /etc/shadow)
    if [[ "${SHADOW_PERM}" == "640" || "${SHADOW_PERM}" == "600" || "${SHADOW_PERM}" == "000" ]]; then
        echo -e "[${COLOR_GREEN}PASS${COLOR_RESET}] 1. /etc/shadow permissions are secure (${SHADOW_PERM})."
        ((PASSED++))
    else
        echo -e "[${COLOR_RED}FAIL${COLOR_RESET}] 1. /etc/shadow has insecure permissions (${SHADOW_PERM}). Expected 0640, 0600, or 0000."
    fi

    # Check 2: Account shadow expiration
    local EXP_DATE
    EXP_DATE=$(chage -l "${TARGET_USER}" | grep "Account expires" | cut -d: -f2 | xargs)
    if [[ "${EXP_DATE}" == "never" ]]; then
        echo -e "[${COLOR_GREEN}PASS${COLOR_RESET}] 2. Account '${TARGET_USER}' shadow aging expiration is resolved."
        ((PASSED++))
    else
        echo -e "[${COLOR_RED}FAIL${COLOR_RESET}] 2. Account '${TARGET_USER}' is still expired (${EXP_DATE}). Use 'chage -E -1 ${TARGET_USER}'."
    fi

    # Check 3: Default UMASK in /etc/login.defs
    local CURRENT_UMASK
    CURRENT_UMASK=$(grep "^UMASK" /etc/login.defs | awk '{print $2}')
    if [[ "${CURRENT_UMASK}" == "027" || "${CURRENT_UMASK}" == "077" || "${CURRENT_UMASK}" == "022" ]]; then
        echo -e "[${COLOR_GREEN}PASS${COLOR_RESET}] 3. /etc/login.defs UMASK is securely set to ${CURRENT_UMASK}."
        ((PASSED++))
    else
        echo -e "[${COLOR_RED}FAIL${COLOR_RESET}] 3. /etc/login.defs UMASK is set to '${CURRENT_UMASK}'. Secure values are 027, 077, or 022."
    fi

    # Check 4: GPG Directory Permissions
    local GPG_PERM
    if [[ -d "${TARGET_HOME}/.gnupg" ]]; then
        GPG_PERM=$(stat -c "%a" "${TARGET_HOME}/.gnupg")
        if [[ "${GPG_PERM}" == "700" ]]; then
            echo -e "[${COLOR_GREEN}PASS${COLOR_RESET}] 4. ${TARGET_HOME}/.gnupg permissions are secure (0700)."
            ((PASSED++))
        else
            echo -e "[${COLOR_RED}FAIL${COLOR_RESET}] 4. ${TARGET_HOME}/.gnupg mode is ${GPG_PERM}. Expected 0700."
        fi
    else
        echo -e "[${COLOR_RED}FAIL${COLOR_RESET}] 4. ${TARGET_HOME}/.gnupg directory does not exist."
    fi

    # Check 5: PAM su rule
    if grep -q "LAB_BREAK_MARKER" /etc/pam.d/su; then
        echo -e "[${COLOR_RED}FAIL${COLOR_RESET}] 5. Insecure PAM override still present in /etc/pam.d/su."
    else
        echo -e "[${COLOR_GREEN}PASS${COLOR_RESET}] 5. PAM su authentication rule configuration verified."
        ((PASSED++))
    fi

    echo ""
    if [[ "${PASSED}" -eq "${TOTAL}" ]]; then
        echo -e "${COLOR_GREEN}======================================================================${COLOR_RESET}"
        echo -e "${COLOR_GREEN} CONGRATULATIONS! All Identity & Privacy requirements satisfied!     ${COLOR_RESET}"
        echo -e "${COLOR_GREEN}======================================================================${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}Score: ${PASSED}/${TOTAL} objectives passed. Please review the failed items.${COLOR_RESET}"
    fi
}

function do_clean() {
    check_root
    print_header
    echo -e "${COLOR_YELLOW}[*] Restoring system configuration from backups...${COLOR_RESET}"

    if [[ -f "${BACKUP_DIR}/shadow.orig" ]]; then
        cp -a "${BACKUP_DIR}/shadow.orig" /etc/shadow
    fi
    if [[ -f "${BACKUP_DIR}/login.defs.orig" ]]; then
        cp -a "${BACKUP_DIR}/login.defs.orig" /etc/login.defs
    fi
    if [[ -f "${BACKUP_DIR}/pam_su.orig" ]]; then
        cp -a "${BACKUP_DIR}/pam_su.orig" /etc/pam.d/su
    fi

    if id "${TARGET_USER}" &>/dev/null; then
        userdel -r "${TARGET_USER}" &>/dev/null || true
    fi

    rm -rf "${BACKUP_DIR}"
    echo -e "${COLOR_GREEN}[+] Lab environment cleaned successfully.${COLOR_RESET}"
}

case "${1:-break}" in
    break)
        do_break
        ;;
    verify)
        do_verify
        ;;
    clean|reset)
        do_clean
        ;;
    *)
        echo "Usage: $0 {break|verify|clean}"
        exit 1
        ;;
esac

# ==============================================================================
# STEP-BY-STEP SOLUTION GUIDE (LPI 020-100 Topic 5.1: Identity and Privacy)
# ==============================================================================
#
# OBJECTIVE OVERVIEW:
# In Linux Security Essentials, Identity and Privacy management entails proper
# file permissions for password stores (/etc/shadow), managing account expiration
# with shadow suite utilities (chage), setting default privacy umask controls in
# /etc/login.defs, securing user cryptography keystores (~/.gnupg), and configuring
# Linux Pluggable Authentication Modules (PAM).
#
# Official Reference: https://www.lpi.org/our-certifications/security-essentials-overview/
#
# ------------------------------------------------------------------------------
# STEP 1: Diagnose and Fix /etc/shadow File Permissions
# ------------------------------------------------------------------------------
# Symptom Inspection:
# $ ls -l /etc/shadow
# Expected output (broken): -rw-r--r-- 1 root shadow ... /etc/shadow
# Reason: Mode 0644 allows non-root local users to read hashed passwords, enabling
# offline dictionary/brute-force attacks and violating data privacy principles.
#
# Remediation Command:
# # chmod 0640 /etc/shadow
# # chown root:shadow /etc/shadow
#
# Verification:
# # ls -l /etc/shadow
# Expected output: -rw-r----- 1 root shadow ... /etc/shadow
#
# ------------------------------------------------------------------------------
# STEP 2: Diagnose and Fix Account Password Aging & Expiration
# ------------------------------------------------------------------------------
# Symptom Inspection:
# # chage -l sys_auditor
# Output showing: Account expires: Jan 01, 1970
#
# Remediation Command:
# Remove the explicit account expiration date so the account remains active indefinitely,
# and set reasonable password aging options:
# # chage -E -1 sys_auditor
# # chage -M 90 -m 7 -W 14 sys_auditor
#
# Verification:
# # chage -l sys_auditor | grep "Account expires"
# Expected output: Account expires : never
#
# ------------------------------------------------------------------------------
# STEP 3: Secure System Default Creation Mask (UMASK) in /etc/login.defs
# ------------------------------------------------------------------------------
# Symptom Inspection:
# # grep "^UMASK" /etc/login.defs
# Output showing: UMASK 000 (meaning newly created files are 0666 / world-writable)
#
# Remediation Command:
# Edit /etc/login.defs and change the UMASK parameter to 027 (or 077 for strict privacy):
# # sed -i 's/^UMASK.*/UMASK\t027/' /etc/login.defs
#
# Verification:
# # grep "^UMASK" /etc/login.defs
# Expected output: UMASK 027
#
# ------------------------------------------------------------------------------
# STEP 4: Fix OpenPGP Keystore Permissions for Data Privacy
# ------------------------------------------------------------------------------
# Symptom Inspection:
# # ls -ld /home/sys_auditor/.gnupg
# Output showing: drwxrwxrwx 2 sys_auditor sys_auditor ... /home/sys_auditor/.gnupg
# Reason: GPG mandates strict directory permissions (0700). Open permissions permit
# unauthorized access to private encryption keys.
#
# Remediation Command:
# # chmod 0700 /home/sys_auditor/.gnupg
# # chown -R sys_auditor:sys_auditor /home/sys_auditor/.gnupg
#
# Verification:
# # ls -ld /home/sys_auditor/.gnupg
# Expected output: drwx------ 2 sys_auditor sys_auditor ... /home/sys_auditor/.gnupg
#
# ------------------------------------------------------------------------------
# STEP 5: Diagnose and Fix PAM Misconfiguration in /etc/pam.d/su
# ------------------------------------------------------------------------------
# Symptom Inspection:
# # head -n 5 /etc/pam.d/su
# Output showing rogue line: auth required pam_deny.so # LAB_BREAK_MARKER
#
# Remediation Command:
# Remove the pam_deny line from /etc/pam.d/su:
# # sed -i '/LAB_BREAK_MARKER/d' /etc/pam.d/su
#
# ------------------------------------------------------------------------------
# FINAL STEP: Run Lab Verification Script
# ------------------------------------------------------------------------------
# # ./lab_5_1_identity_privacy.sh verify
# Expected output: 5/5 objectives passed!
# ==============================================================================