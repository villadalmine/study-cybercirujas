#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Exam 303-300 (v3.0) - Topic 303.1 / Theme 2.1: Access Control
# Enterprise Production Break & Fix Lab Script
# ==============================================================================
# Target OS: RHEL 8/9, Rocky Linux, AlmaLinux, Debian 11/12, Ubuntu 22.04/24.04
# Role: Senior SRE / Principal Security Architect
# Purpose: Simulates a multi-layered production breakage involving PAM, POSIX ACLs,
#          File Extended Attributes (chattr), and Mandatory Access Control (SELinux/AppArmor).
# Reference: https://www.lpi.org/our-certifications/lpic-3-303-overview/
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LAB_USER="sre_operator"
LAB_DIR="/srv/secure_app"
CONFIG_FILE="${LAB_DIR}/production.env"
PAM_ACCESS_CONF="/etc/security/access.conf"
PAM_SSHD_CONF="/etc/pam.d/sshd"
BACKUP_DIR="/var/tmp/lpic3_303_backup_$(date +%s)"

ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}[ERROR] This break-and-fix lab script must be executed with root privileges.${NC}" >&2
        exit 1
    fi
}

backup_configurations() {
    echo -e "${CYAN}[+] Creating environment backup in ${BACKUP_DIR}...${NC}"
    mkdir -p "${BACKUP_DIR}"
    [[ -f "${PAM_ACCESS_CONF}" ]] && cp "${PAM_ACCESS_CONF}" "${BACKUP_DIR}/access.conf.bak"
    [[ -f "${PAM_SSHD_CONF}" ]] && cp "${PAM_SSHD_CONF}" "${BACKUP_DIR}/sshd.pam.bak"
}

setup_lab_environment() {
    echo -e "${CYAN}[+] Setting up initial user and application directory...${NC}"
    
    # Create lab user if non-existent
    if ! id "${LAB_USER}" &>/dev/null; then
        useradd -m -s /bin/bash "${LAB_USER}"
        echo "${LAB_USER}:Password123!" | chpasswd
    fi

    # Create app workspace
    mkdir -p "${LAB_DIR}"
    cat <<'EOF' > "${CONFIG_FILE}"
DATABASE_URL="postgresql://db_admin:SecretPass2026@localhost:5432/prod_db"
SECRET_KEY="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
MAX_CONNECTIONS=100
EOF

    # Set base DAC ownership
    chown -R root:root "${LAB_DIR}"
    chmod 755 "${LAB_DIR}"
    chmod 640 "${CONFIG_FILE}"
}

inject_faults() {
    echo -e "${YELLOW}[!] Injecting multi-layered access control faults...${NC}"

    # Fault 1: PAM Layer (pam_access constraint)
    # Configure pam_access in PAM sshd stack if absent, and deny login for sre_operator in access.conf
    if [[ -f "${PAM_SSHD_CONF}" ]]; then
        if ! grep -q "pam_access.so" "${PAM_SSHD_CONF}"; then
            echo "account    required     pam_access.so" >> "${PAM_SSHD_CONF}"
        fi
    fi
    echo "- : ${LAB_USER} : ALL EXCEPT LOCAL" >> "${PAM_ACCESS_CONF}"

    # Fault 2: POSIX ACL & Mask Restriction
    # Grant explicit user permission, but set restrictive ACL mask overriding effective rights
    setfacl -m "u:${LAB_USER}:rw-" "${CONFIG_FILE}"
    setfacl -m "m::r--" "${CONFIG_FILE}"

    # Fault 3: Extended File Attributes (Immutable bit)
    # Set immutable flag preventing any modification even by root or owner
    chattr +i "${CONFIG_FILE}"

    # Fault 4: MAC Layer (SELinux Security Context Mismatch, if SELinux is active)
    if command -v chcon &>/dev/null && sestatus 2>/dev/null | grep -q "enabled"; then
        # Change file context to an incompatible context (e.g., user_tmp_t or samba_share_t)
        chcon -t samba_share_t "${CONFIG_FILE}" || true
    fi

    echo -e "${GREEN}[+] Fault injection complete.${NC}"
}

print_student_briefing() {
    cat <<EOF

================================================================================
  LPIC-3 303-300 (Topic 303.1 / Theme 2.1) - ADVANCED LAB BRIEFING
================================================================================

[SCENARIO DESCRIPTION]
You are an SRE on-call resolving a critical incident. The automation account
'${LAB_USER}' can no longer SSH into the application node or update the 
production environment config file located at:
  ${CONFIG_FILE}

Multiple security layers (PAM, POSIX ACLs, chattr attributes, SELinux/MAC) 
were modified during an emergency hardening pass, leaving the system in an 
inconsistent state.

[OBSERVED SYMPTOMS]
1. SSH login attempts as user '${LAB_USER}' fail instantly during authentication, 
   even with the correct credentials.
2. Local attempts to edit '${CONFIG_FILE}' fail with "Permission denied" or 
   "Operation not permitted", even when using elevated privileges or valid ACLs.
3. System logs record security access violations.

[YOUR OBJECTIVE]
1. Identify and remove the PAM login restriction blocking '${LAB_USER}'.
2. Diagnose why file edits fail on '${CONFIG_FILE}', resolving POSIX ACL 
   effective permission masks and file system attributes.
3. Ensure '${CONFIG_FILE}' has valid SELinux labeling (if SELinux is enabled).
4. Verify '${LAB_USER}' can read '${CONFIG_FILE}' and append data to it.

[DIAGNOSTIC TOOLKIT]
- Linux PAM: /etc/pam.d/, /etc/security/access.conf, /var/log/auth.log or /var/log/secure
- POSIX ACLs: getfacl, setfacl
- File Attributes: lsattr, chattr
- SELinux / MAC: sestatus, getenforce, ls -Z, restorecon, semanage fcontext, audit2allow

[OFFICIAL REFERENCE SOURCES]
- LPIC-3 Exam 303-300 Overview: https://www.lpi.org/our-certifications/lpic-3-303-overview/
- PAM access.conf man page: man 5 access.conf
- POSIX ACL man pages: man 1 getfacl, man 1 setfacl
- Extended attributes man pages: man 1 lsattr, man 1 chattr
- SELinux Documentation: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/

================================================================================
EOF
}

main() {
    ensure_root
    backup_configurations
    setup_lab_environment
    inject_faults
    print_student_briefing
}

main "$@"

# ==============================================================================
#                          STEP-BY-STEP SOLUTION GUIDE
#                  (DO NOT LOOK UNTIL YOU HAVE ATTEMPTED TO FIX)
# ==============================================================================
#
# STEP 1: DIAGNOSE AND FIX PAM ACCESS CONTROL
# ------------------------------------------------------------------------------
# Symptom: 'sre_operator' denied access upon authentication.
# Inspection:
#   # Check PAM authentication logs:
#   $ tail -n 20 /var/log/secure   # (RHEL/CentOS)
#   $ tail -n 20 /var/log/auth.log # (Debian/Ubuntu)
#   Expected log entry: "pam_access(sshd:auth): access denied for user `sre_operator`"
#
#   # Inspect PAM access rules:
#   $ cat /etc/security/access.conf
#   Notice the trailing line: "- : sre_operator : ALL EXCEPT LOCAL"
#
# Remediation:
#   # Remove or comment out the restriction in /etc/security/access.conf:
#   $ sed -i '/- : sre_operator : ALL EXCEPT LOCAL/d' /etc/security/access.conf
#
#
# STEP 2: DIAGNOSE AND FIX FILE EXTENDED ATTRIBUTES (chattr)
# ------------------------------------------------------------------------------
# Symptom: Cannot edit file even as root ("Operation not permitted").
# Inspection:
#   $ lsattr /srv/secure_app/production.env
#   Output: "----i---------e--- /srv/secure_app/production.env"
#   The 'i' attribute designates the file as Immutable.
#
# Remediation:
#   # Remove the immutable attribute using chattr:
#   $ chattr -i /srv/secure_app/production.env
#
#
# STEP 3: DIAGNOSE AND FIX POSIX ACL MASK RESTRICTION
# ------------------------------------------------------------------------------
# Symptom: 'sre_operator' has user ACL rule but effective permission is read-only or denied.
# Inspection:
#   $ getfacl /srv/secure_app/production.env
#   Output shows:
#     user:sre_operator:rw- #effective:r--
#     mask::r--
#
#   Explanation: The ACL mask defines the maximum permissions for all non-owner
#   named users and groups. A mask of r-- caps sre_operator at read-only.
#
# Remediation:
#   # Update the ACL mask to allow read/write or recalculate mask:
#   $ setfacl -m m::rw- /srv/secure_app/production.env
#   # Alternatively, grant full rw- permissions to the user while recalculating mask:
#   $ setfacl -m u:sre_operator:rw- /srv/secure_app/production.env
#
#
# STEP 4: DIAGNOSE AND FIX MANDATORY ACCESS CONTROL (SELinux)
# ------------------------------------------------------------------------------
# Symptom: AVC denial logs present when service accesses file.
# Inspection:
#   $ ls -Z /srv/secure_app/production.env
#   Context shows: system_u:object_r:samba_share_t:s0 (Incompatible context)
#   $ ausearch -m avc -ts recent   OR   journalctl -t audit
#
# Remediation:
#   # Restore default SELinux policy context based on path specs:
#   $ restorecon -vF /srv/secure_app/production.env
#   # If custom persistent context rule is needed:
#   $ semanage fcontext -a -t default_t "/srv/secure_app(/.*)?"
#   $ restorecon -R -v /srv/secure_app
#
#
# STEP 5: VERIFICATION
# ------------------------------------------------------------------------------
# 1. Test SSH login:
#    $ ssh sre_operator@localhost
# 2. Test file write capabilities:
#    $ su - sre_operator -c "echo 'LOG_LEVEL=DEBUG' >> /srv/secure_app/production.env"
# 3. Verify content update:
#    $ cat /srv/secure_app/production.env
# ==============================================================================