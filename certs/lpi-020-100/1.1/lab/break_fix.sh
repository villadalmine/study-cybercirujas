#!/usr/bin/env bash
# ==============================================================================
# LPI Security Essentials (020-100 v1.0) - Lab Break & Fix Scenario
# Topic 1.1: Security Concepts (Weight: 20)
# Reference: https://www.lpi.org/our-certifications/security-essentials-overview/
# Target Audience: CNCF / SRE / Security Engineers
# ==============================================================================
# DISCLAIMER: Run this script ONLY on a disposable, non-production Linux VM.
# ==============================================================================

set -euo pipefail

# Color definitions for UI output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Ensure script is executed as root
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}[ERROR] This break & fix script must be run with root privileges (sudo).${NC}" >&2
    exit 1
fi

LOG_FILE="/var/log/security_lab_setup.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo -e "${CYAN}[*] Initializing LPI 020-100 Topic 1.1 Security Concepts Break & Fix Environment...${NC}"

# ==============================================================================
# PHASE 1: ENVIRONMENT SETUP
# ==============================================================================
setup_environment() {
    echo -e "${BLUE}[1/3] Setting up mock production application & audit controls...${NC}"

    # Create unprivileged lab user if not exists
    if ! id -u appdev &>/dev/null; then
        useradd -m -s /bin/bash appdev
        echo "appdev:LabPassword123!" | chpasswd
    fi

    # Create mock production directory structure
    mkdir -p /opt/finance-app/config
    mkdir -p /var/log/audit-archive

    # Create sensitive database credential file (Confidentiality target)
    cat <<'EOF' > /opt/finance-app/config/db_credentials.env
# PRODUCTION DATABASE CREDENTIALS - RESTRICTED ACCESS
DB_HOST=10.0.4.15
DB_PORT=5432
DB_NAME=production_ledger
DB_USER=ledger_admin
DB_PASS=S3cur3Pr0dP@ssw0rd!2026
EOF

    # Create critical system integrity file (Integrity target)
    cat <<'EOF' > /etc/security/app_integrity.sha256
5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8 /opt/finance-app/config/db_credentials.env
EOF

    # Enable auditd daemon if installed
    if systemctl is-active --quiet auditd &>/dev/null || systemctl enable auditd &>/dev/null; then
        systemctl restart auditd || true
    fi
}

# ==============================================================================
# PHASE 2: CONTROLLED SECURITY BREAKAGE
# ==============================================================================
break_environment() {
    echo -e "${YELLOW}[2/3] Injecting security concept violations into the environment...${NC}"

    # 1. BREAK CONFIDENTIALITY & LEAST PRIVILEGE:
    # Overly permissive file mode (world-readable/writable) on secret credentials
    chmod 0777 /opt/finance-app/config/db_credentials.env
    chown appdev:appdev /opt/finance-app/config/db_credentials.env

    # Sudoers misconfiguration violating Authorization & Principle of Least Privilege (PoLP)
    cat <<'EOF' > /etc/sudoers.d/99-appdev-overprivileged
# INSECURE RULE INSTALLED BY DEVOPS PIPELINE
appdev ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    chmod 0440 /etc/sudoers.d/99-appdev-overprivileged

    # 2. BREAK INTEGRITY:
    # Tamper with system profile to auto-execute untrusted code on root login
    cat <<'EOF' >> /etc/profile
# MALICIOUS MODIFICATION - BROKEN INTEGRITY
chmod u+s /usr/bin/find 2>/dev/null || true
EOF
    # Set SUID bit on binary creating a persistent privilege escalation path
    chmod u+s /usr/bin/find

    # Corrupt integrity checksum manifest
    echo "0000000000000000000000000000000000000000000000000000000000000000 /opt/finance-app/config/db_credentials.env" > /etc/security/app_integrity.sha256

    # 3. BREAK ACCOUNTING / AUDITING (AAA & Non-Repudiation):
    # Disable authentication auditing rules and mask audit system
    if command -v auditctl &>/dev/null; then
        auditctl -D &>/dev/null || true # Delete all audit rules
    fi

    # Wipe and lock out auth log permissions (breaking Accounting & Availability of logs)
    if [[ -f /var/log/auth.log ]]; then
        > /var/log/auth.log
        chmod 0000 /var/log/auth.log
    elif [[ -f /var/log/secure ]]; then
        > /var/log/secure
        chmod 0000 /var/log/secure
    fi

    echo -e "${RED}[!] Security posture compromised successfully.${NC}"
}

# ==============================================================================
# PHASE 3: INCIDENT BRIEFING & TASK DESCRIPTION
# ==============================================================================
print_briefing() {
    echo -e "\n${CYAN}==============================================================================${NC}"
    echo -e "${YELLOW}  SECURITY INCIDENT BRIEFING: LPI 020-100 TOPIC 1.1 (SECURITY CONCEPTS)  ${NC}"
    echo -e "${CYAN}==============================================================================${NC}"
    cat <<'EOF'

SCENARIO OVERVIEW:
An automated security scanner flagged multiple critical policy violations on this node.
A rogue pipeline script compromised core security principles across the system:
  1. CIA Triad (Confidentiality, Integrity, Availability)
  2. AAA Framework (Authentication, Authorization, Accounting)
  3. Principle of Least Privilege (PoLP) & Defense in Depth

YOUR MISSION / REQUIREMENTS:
----------------------------
1. CONFIDENTIALITY & LEAST PRIVILEGE:
   - Audit '/opt/finance-app/config/db_credentials.env'. Secure file permissions so
     ONLY owner 'root' has read/write access (0600).
   - Audit '/etc/sudoers.d/'. Identify and purge any rules granting unprivileged
     users ('appdev') unrestricted NOPASSWD root access. Enforce Least Privilege.

2. INTEGRITY & THREAT REMEDIATION:
   - Inspect '/etc/profile' for malicious append operations and remove any unauthorized modifications.
   - Detect SUID binaries created on the filesystem. Remove the insecure SUID bit from
     '/usr/bin/find' (restore to 0755).
   - Recalculate and update the genuine SHA-256 checksum in '/etc/security/app_integrity.sha256'.

3. ACCOUNTING & NON-REPUDIATION (AAA):
   - Restore access control permissions on system authentication log files
     ('/var/log/auth.log' or '/var/log/secure') to standard secure modes (0640 owner root:adm or root:root).
   - Verify audit logging services are functioning and capture security events.

VERIFICATION COMMANDS TO TEST YOUR FIXES:
  $ ls -la /opt/finance-app/config/db_credentials.env  # Should be -rw------- root root
  $ sudo -u appdev sudo -l                             # Should DENY appdev root escalation
  $ find /usr/bin -perm -4000                          # '/usr/bin/find' must NOT appear
  $ sha256sum -c /etc/security/app_integrity.sha256    # Must return OK
  $ ls -la /var/log/auth.log /var/log/secure           # Should be readable by security logs service

Official Reference: https://www.lpi.org/our-certifications/security-essentials-overview/
==============================================================================
EOF
}

# Main Execution Flow
setup_environment
break_environment
print_briefing

exit 0

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
# DO NOT READ THIS SECTION UNTIL YOU HAVE ATTEMPTED TO SOLVE THE INCIDENT!
# ==============================================================================
#
# STEP 1: FIX CONFIDENTIALITY & LEAST PRIVILEGE (PoLP)
# ---------------------------------------------------
# 1.1 Fix permissions on secret credentials file:
#     # chown root:root /opt/finance-app/config/db_credentials.env
#     # chmod 0600 /opt/finance-app/config/db_credentials.env
#
# 1.2 Audit and remove unauthorized sudoers delegation:
#     # rm -f /etc/sudoers.d/99-appdev-overprivileged
#     # visudo -c  # Validate syntax of sudoers files
#
# STEP 2: FIX INTEGRITY VIOLATIONS & REMOVE SUID BACKDOOR
# --------------------------------------------------------
# 2.1 Locate SUID binaries across the system:
#     # find / -xdev -type f -perm -4000 2>/dev/null
#     Notice '/usr/bin/find' has SUID set, allowing arbitrary file read/write & shell execution.
#
# 2.2 Strip SUID bit from /usr/bin/find:
#     # chmod u-s /usr/bin/find
#     # chmod 0755 /usr/bin/find
#
# 2.3 Clean /etc/profile malicious persistence:
#     # sed -i '/chmod u+s \/usr\/bin\/find/d' /etc/profile
#
# 2.4 Regenerate file integrity baseline:
#     # sha256sum /opt/finance-app/config/db_credentials.env > /etc/security/app_integrity.sha256
#     # sha256sum -c /etc/security/app_integrity.sha256
#
# STEP 3: RESTORE ACCOUNTING & NON-REPUDIATION (AAA)
# --------------------------------------------------
# 3.1 Repair authentication log permissions:
#     # if [ -f /var/log/auth.log ]; then
#           chmod 0640 /var/log/auth.log
#           chown root:adm /var/log/auth.log
#       elif [ -f /var/log/secure ]; then
#           chmod 0600 /var/log/secure
#           chown root:root /var/log/secure
#       fi
#
# 3.2 Reload audit subsystem rules:
#     # if command -v auditctl &>/dev/null; then
#           auditctl -w /etc/sudoers -p wa -k identity_changes
#           systemctl restart auditd
#       fi
#
# STEP 4: FINAL SYSTEM AUDIT VERIFICATION
# ----------------------------------------
# Execute these checks to ensure full remediation:
#   # stat -c "%a %U:%G %n" /opt/finance-app/config/db_credentials.env
#   # Expected: 600 root:root /opt/finance-app/config/db_credentials.env
#
#   # sudo -u appdev sudo -l
#   # Expected: User appdev may not run sudo on <hostname>.
#
#   # sha256sum -c /etc/security/app_integrity.sha256
#   # Expected: /opt/finance-app/config/db_credentials.env: OK
# ==============================================================================