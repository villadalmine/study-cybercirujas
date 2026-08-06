#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Security (Exam 303-300, Version 3.0)
# Topic 332 / Operations Security: Host Hardening, Audit & Access Control
# Weight: 16.67 (Approx. 10 out of 60 exam questions)
#
# Reference Sources:
# - Official LPI LPIC-3 303 Overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/
# - Linux Audit Framework Documentation: https://man7.org/linux/man-pages/man8/auditd.8.html
# - Sudoers Manual & Security Guidelines: https://man7.org/linux/man-pages/man5/sudoers.5.html
# - Linux PAM faillock module: https://man7.org/linux/man-pages/man8/pam_faillock.8.html
# ==============================================================================
#
# DESCRIPTION:
# This script simulates a production incident on a disposable Linux laboratory VM.
# A junior administrator attempted to harden the system according to LPIC-3 303
# Operations Security standards but introduced three critical misconfigurations:
#
# 1. Broken Linux Audit Subsystem (`auditd` / `augenrules` syntax error).
# 2. Insecure Sudoers Policy Delegation (invalid file permissions & syntax error).
# 3. Malformed Pluggable Authentication Module (PAM) configuration (`faillock.conf`).
#
# OPERATIONAL SYMPTOMS FOR THE STUDENT:
# - `augenrules --load` or `systemctl restart auditd` fails with rule parsing errors.
# - Running `sudo` commands yields security warnings regarding file permissions
#   and syntax errors in `/etc/sudoers.d/99-ops-sec-hardening`.
# - PAM authentication logging reports invalid parameters in `/etc/security/faillock.conf`.
#
# STUDENT FIX OBJECTIVES:
# 1. Fix `/etc/audit/rules.d/50-operations_security.rules` so `augenrules --load` executes successfully.
# 2. Correct permissions and syntax in `/etc/sudoers.d/99-ops-sec-hardening`.
# 3. Repair parameter key/value formatting in `/etc/security/faillock.conf`.
# 4. Verify system compliance by running diagnostic checks.
# ==============================================================================

set -euo pipefail

# Color Codes for Output
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure Execution as Root
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be executed with root privileges (sudo).${NC}" >&2
    exit 1
fi

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}       LPIC-3 303 Operations Security: Break & Fix Scenario           ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "${YELLOW}[!] Initializing Lab Setup and Simulating Security Outage...${NC}"

# Backup Directory Setup
BACKUP_DIR="/var/backups/lpic3-303-breakfix"
mkdir -p "${BACKUP_DIR}"

# Step 1: Ensure Required Dependencies Are Installed
echo -e "${BLUE}[*] Verifying/Installing required security utilities...${NC}"
if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq auditd sudo libpam-modules &>/dev/null || true
elif command -v dnf &>/dev/null; then
    dnf install -y -q audit sudo pam &>/dev/null || true
fi

# Create a test service user for auditing and sudo tests
if ! id "secops_admin" &>/dev/null; then
    useradd -m -s /bin/bash secops_admin
    echo "secops_admin:SecOpsPass2026!" | chpasswd
fi

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 1: Invalid auditd rules in /etc/audit/rules.d/
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[!] Injecting Fault #1: Corrupting Audit Framework Rules...${NC}"

AUDIT_RULE_FILE="/etc/audit/rules.d/50-operations_security.rules"
if [[ -f "${AUDIT_RULE_FILE}" ]]; then
    cp "${AUDIT_RULE_FILE}" "${BACKUP_DIR}/50-operations_security.rules.bak"
fi

cat << 'EOF' > "${AUDIT_RULE_FILE}"
# LPIC-3 303 Operations Security Audit Rules
-D
-b 8192

# Monitoring Critical Files (FAIL: 'rwxa' is invalid permission mask; valid are r, w, x, a is invalid)
-w /etc/shadow -p rwxa -k shadow_modification

# Monitoring Execution of Privileged Commands (FAIL: 'sys_execve' is not a valid syscall name, must be 'execve')
-a always,exit -F arch=b64 -S sys_execve -F euid=0 -k privileged_execution
EOF

# Force reload to trigger failure state
augenrules --load &>/dev/null || true

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 2: Bad permissions & syntax error in /etc/sudoers.d/
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[!] Injecting Fault #2: Misconfiguring Sudoers Policy File...${NC}"

SUDO_FILE="/etc/sudoers.d/99-ops-sec-hardening"
if [[ -f "${SUDO_FILE}" ]]; then
    cp "${SUDO_FILE}" "${BACKUP_DIR}/99-ops-sec-hardening.bak"
fi

cat << 'EOF' > "${SUDO_FILE}"
# LPIC-3 303 Operations Security Sudo Delegation
# FAIL: Alias declaration syntax error (Missing '=')
User_Alias SECOPS_TEAM secops_admin

Cmnd_Alias AUDIT_TOOLS = /usr/sbin/ausearch, /usr/sbin/aureport, /sbin/augenrules

# FAIL: Undefined alias usage SECOPS_TEAMS (typo)
SECOPS_TEAMS ALL=(ALL) NOPASSWD: AUDIT_TOOLS
EOF

# FAIL: Sudoers drops MUST have 0440 mode. 0666 is world-writable and causes sudo to refuse loading it.
chmod 0666 "${SUDO_FILE}"

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 3: Invalid Key/Value in /etc/security/faillock.conf
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[!] Injecting Fault #3: Corrupting PAM Faillock Configuration...${NC}"

FAILLOCK_CONF="/etc/security/faillock.conf"
if [[ -f "${FAILLOCK_CONF}" ]]; then
    cp "${FAILLOCK_CONF}" "${BACKUP_DIR}/faillock.conf.bak"
fi

cat << 'EOF' >> "${FAILLOCK_CONF}"

# LPIC-3 303 Hardening Injections
# FAIL: unlock_time expects an integer in seconds, string "infinite_lockoutoutout" is invalid
unlock_time = infinite_lockoutoutout
# FAIL: deny expects a positive integer, string "three_attempts" is invalid
deny = three_attempts
EOF

# ------------------------------------------------------------------------------
# BRIEFING & DIAGNOSTIC INSTRUCTIONS FOR THE STUDENT
# ------------------------------------------------------------------------------
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}           INCIDENT DEPLOYED SUCCESSFULLY - YOUR TURN!               ${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e "System state has been modified. Analyze the following operational symptoms:\n"
echo -e "${YELLOW}1. AUDIT SUBSYSTEM CHECK:${NC}"
echo -e "   Run: ${BLUE}augenrules --load${NC} or ${BLUE}systemctl restart auditd${NC}"
echo -e "   Symptom: Audit rules fail to load due to syntax errors in rule definitions.\n"

echo -e "${YELLOW}2. SUDO DELEGATION CHECK:${NC}"
echo -e "   Run: ${BLUE}sudo -u secops_admin sudo -l${NC}"
echo -e "   Symptom: Sudo outputs parsing warnings about mode permissions and syntax errors.\n"

echo -e "${YELLOW}3. PAM SECURITY HARDENING CHECK:${NC}"
echo -e "   Run: ${BLUE}faillock --user secops_admin${NC}"
echo -e "   Symptom: Configuration error messages regarding invalid values in /etc/security/faillock.conf.\n"

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} Objective: Fix all 3 issues and verify system integrity.            ${NC}"
echo -e "${BLUE}======================================================================${NC}"

exit 0

# ==============================================================================
#                         STEP-BY-STEP SOLUTION (GURU GUIDE)
# ==============================================================================
#
# --- ISSUE 1: Linux Audit Framework Rules (/etc/audit/rules.d/50-operations_security.rules) ---
# Diagnostic Command:
#   # augenrules --load
# Output Error Analysis:
#   - "-p rwxa" -> The permission mask flags for file watches accept only:
#       r = read, w = write, x = execute, a = attribute change.
#       Notice that "rwxa" has 'a' placed incorrectly or repeated. Actually, valid flags are 'r', 'w', 'x', 'a'.
#       However, '-p rwxa' contains 'a' which stands for attribute. If 'a' is valid, what is wrong?
#       Check: '-S sys_execve' -> The 64-bit x86_64 Linux system call is named 'execve', NOT 'sys_execve'.
#
# Fix Step 1:
# Edit /etc/audit/rules.d/50-operations_security.rules:
#   - Change '-w /etc/shadow -p rwxa -k shadow_modification' to:
#     -w /etc/shadow -p wa -k shadow_modification
#   - Change '-a always,exit -F arch=b64 -S sys_execve -F euid=0 -k privileged_execution' to:
#     -a always,exit -F arch=b64 -S execve -F euid=0 -k privileged_execution
#
# Verification Step 1:
#   # augenrules --load
#   # auditctl -l
# Expected output: Audit rules load with zero errors.
#
# --- ISSUE 2: Sudoers Delegation Policy (/etc/sudoers.d/99-ops-sec-hardening) ---
# Diagnostic Command:
#   # sudo -u secops_admin sudo -l
# Output Error Analysis:
#   - "sudo: /etc/sudoers.d/99-ops-sec-hardening is world writable" -> Sudo strictly ignores files
#     in /etc/sudoers.d that have permissions other than 0440 or 0400.
#   - "syntax error near User_Alias SECOPS_TEAM secops_admin" -> User_Alias requires an equals sign (=).
#   - "SECOPS_TEAMS: alias not found" -> Typo in User_Alias name.
#
# Fix Step 2:
# 1. Correct file permissions:
#    # chmod 0440 /etc/sudoers.d/99-ops-sec-hardening
# 2. Fix syntax with visudo:
#    # visudo -f /etc/sudoers.d/99-ops-sec-hardening
#    Change contents to:
#      User_Alias SECOPS_TEAM = secops_admin
#      Cmnd_Alias AUDIT_TOOLS = /usr/sbin/ausearch, /usr/sbin/aureport, /sbin/augenrules
#      SECOPS_TEAM ALL=(ALL) NOPASSWD: AUDIT_TOOLS
#
# Verification Step 2:
#   # visudo -c
#   # sudo -u secops_admin sudo -l
# Expected output: "User secops_admin may run the following commands on this host: (ALL) NOPASSWD: AUDIT_TOOLS"
#
# --- ISSUE 3: PAM Faillock Hardening (/etc/security/faillock.conf) ---
# Diagnostic Command:
#   # faillock --user secops_admin
# Output Error Analysis:
#   - "faillock: /etc/security/faillock.conf: unlock_time = infinite_lockoutoutout is invalid"
#   - "faillock: /etc/security/faillock.conf: deny = three_attempts is invalid"
#   The pam_faillock configuration file requires integer parameters for numerical directives.
#
# Fix Step 3:
# Edit /etc/security/faillock.conf and correct the appended values:
#   - Change 'unlock_time = infinite_lockoutoutout' to 'unlock_time = 900' (or 0 for manual unlock).
#   - Change 'deny = three_attempts' to 'deny = 3'.
#
# Verification Step 3:
#   # faillock --user secops_admin
# Expected output: Clean execution displaying user login attempts without config parsing errors.
# ==============================================================================