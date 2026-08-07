#!/usr/bin/env bash
# ==============================================================================
# LPI 702-100: BSD Specialist Certification (Version 1.0)
# Topic 712.4: Manage File Permissions and Ownership (Weight: 5)
# Production SRE Break & Fix Laboratory Scenario
#
# Official Reference:
# https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
#
# ARCHITECTURAL CONTEXT & SCENARIO OVERVIEW:
# ------------------------------------------
# You are managing a multi-tenant BSD enterprise infrastructure hosting a production
# telemetry collector service ("app_audit"). The service runs under unprivileged
# user 'appadmin' and group 'appgroup'.
#
# A junior administrator attempted to lock down file paths and resolve a permission
# issue, but inadvertently introduced a multi-layered permission breakdown involving:
# 1. BSD File Flags (uchg/schg immutable flags).
# 2. Missing Set-Group-ID (SGID) bit on shared data drop directories.
# 3. Missing Set-User-ID (SUID) bit on privileged auxiliary helper binaries.
# 4. Conflicting POSIX/NFSv4 Access Control Lists (ACLs).
#
# SYMPTOMS IN PRODUCTION:
# -----------------------
# Symptom A: 'appadmin' cannot append to '/var/tmp/lab_712_4/logs/audit.log'.
#            Even when 'root' attempts 'chown' or 'chmod', the system returns:
#            "Operation not permitted" (EPERM / errno 1).
# Symptom B: New files created inside '/var/tmp/lab_712_4/incoming/' inherit the
#            primary group of the creating user instead of 'appgroup', breaking
#            downstream daemon processing.
# Symptom C: The deployment runner '/var/tmp/lab_712_4/bin/deploy_runner' fails
#            with "FAILURE: Must be executed with effective root privileges".
# Symptom D: POSIX ACL entries override traditional UNIX ugo permission bits.
#
# DIAGNOSTIC TOOLS USED IN BSD:
# -----------------------------
# - ls -lo / ls -lO  : View BSD file flags (uchg, schg, uappnd, sappnd, nodump).
# - getfacl / ls -le : Inspect extended POSIX / NFSv4 Access Control Lists.
# - stat / namei -l  : Trace full permission paths and mode bits.
# - chflags / chattr : Modify file flags on BSD (or fallback extended attributes).
# - chmod / chown    : Adjust standard permission bits, SUID, SGID, and ownership.
# - setfacl          : Modify or wipe Access Control Lists.
#
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/tmp/lab_712_4"
TEST_USER="appadmin"
TEST_GROUP="appgroup"

echo "[+] Initializing LPI 702 Topic 712.4 Break & Fix Environment..."

# Ensure root privileges for lab setup
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] ERROR: Root privileges are required to configure the break state." >&2
    exit 1
fi

# Cleanup previous lab runs
rm -rf "${LAB_DIR}"

# Create test group across BSD (pw) and Linux (groupadd) platforms
if ! getent group "${TEST_GROUP}" >/dev/null 2>&1 && ! pw group show "${TEST_GROUP}" >/dev/null 2>&1; then
    if command -v pw >/dev/null 2>&1; then
        pw groupadd "${TEST_GROUP}"
    else
        groupadd "${TEST_GROUP}"
    fi
fi

# Create test user across BSD (pw) and Linux (useradd) platforms
if ! id "${TEST_USER}" >/dev/null 2>&1; then
    if command -v pw >/dev/null 2>&1; then
        pw useradd "${TEST_USER}" -g "${TEST_GROUP}" -s /bin/sh -d "${LAB_DIR}"
    else
        useradd -m -g "${TEST_GROUP}" -s /bin/bash "${TEST_USER}"
    fi
fi

# Setup directory structure
mkdir -p "${LAB_DIR}/logs"
mkdir -p "${LAB_DIR}/incoming"
mkdir -p "${LAB_DIR}/bin"

# ------------------------------------------------------------------------------
# INJECT BREAK 1: Immutable File Flags (BSD chflags uchg/schg)
# ------------------------------------------------------------------------------
echo "2026-08-06T20:33:00Z [INFO] System audit log initialized." > "${LAB_DIR}/logs/audit.log"
chown root:wheel "${LAB_DIR}/logs/audit.log" 2>/dev/null || chown root:root "${LAB_DIR}/logs/audit.log"
chmod 664 "${LAB_DIR}/logs/audit.log"

if command -v chflags >/dev/null 2>&1; then
    # BSD User Immutable flag (prevents modification/deletion even by owner/root without flag removal)
    chflags uchg "${LAB_DIR}/logs/audit.log"
elif command -v chattr >/dev/null 2>&1; then
    # Linux fallback equivalent
    chattr +i "${LAB_DIR}/logs/audit.log"
fi

# ------------------------------------------------------------------------------
# INJECT BREAK 2: Missing SGID Bit on Group Drop Directory
# ------------------------------------------------------------------------------
chown root:wheel "${LAB_DIR}/incoming" 2>/dev/null || chown root:root "${LAB_DIR}/incoming"
# Set standard 755 mode instead of 2775 (SGID missing)
chmod 755 "${LAB_DIR}/incoming"

# ------------------------------------------------------------------------------
# INJECT BREAK 3: Missing SUID Bit on Privileged Helper Script
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/bin/deploy_runner"
#!/bin/sh
EUID_VAL=$(id -u)
echo "Executing deployment runner... Effective UID: ${EUID_VAL}"
if [ "${EUID_VAL}" -eq 0 ]; then
    echo "SUCCESS: High-privilege task executed safely."
else
    echo "FAILURE: Must be executed with effective root privileges (SUID missing)."
    exit 1
fi
EOF
chown root:wheel "${LAB_DIR}/bin/deploy_runner" 2>/dev/null || chown root:root "${LAB_DIR}/bin/deploy_runner"
chmod 755 "${LAB_DIR}/bin/deploy_runner"

# ------------------------------------------------------------------------------
# INJECT BREAK 4: Conflicting Extended POSIX ACL
# ------------------------------------------------------------------------------
if command -v setfacl >/dev/null 2>&1; then
    setfacl -m g:"${TEST_GROUP}":r-- "${LAB_DIR}/logs" 2>/dev/null || true
    setfacl -m u:"${TEST_USER}":r-- "${LAB_DIR}/logs/audit.log" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# DISPLAY DIAGNOSTIC SUMMARY
# ------------------------------------------------------------------------------
echo "========================================================================"
echo " [!] LAB ENVIRONMENT BROKEN SUCCESSFULLY"
echo "========================================================================"
echo "Target Base Directory : ${LAB_DIR}"
echo "Target User           : ${TEST_USER}"
echo "Target Group          : ${TEST_GROUP}"
echo ""
echo "TEST THE SYMPTOMS AS USER '${TEST_USER}':"
echo "------------------------------------------------------------------------"
echo "1. Attempt to write to audit log:"
echo "   $ su -m ${TEST_USER} -c \"echo 'test' >> ${LAB_DIR}/logs/audit.log\""
echo "   --> Expected error: Operation not permitted"
echo ""
echo "2. Attempt to create a file in incoming/:"
echo "   $ su -m ${TEST_USER} -c \"touch ${LAB_DIR}/incoming/sample.dat\""
echo "   $ ls -l ${LAB_DIR}/incoming/sample.dat"
echo "   --> Observe: File group is NOT '${TEST_GROUP}' (SGID missing)."
echo ""
echo "3. Execute deployment helper binary:"
echo "   $ su -m ${TEST_USER} -c \"${LAB_DIR}/bin/deploy_runner\""
echo "   --> Expected output: FAILURE (SUID bit missing)."
echo ""
echo "4. Inspect BSD Flags and ACLs:"
echo "   $ ls -lo ${LAB_DIR}/logs/audit.log"
echo "   $ getfacl ${LAB_DIR}/logs/audit.log"
echo "------------------------------------------------------------------------"
echo "Solve the scenario by following the technical guide at the end of script."
echo "========================================================================"

exit 0


# ==============================================================================
# COMPREHENSIVE STEP-BY-STEP SOLUTION (LPI 702-100 TOPIC 712.4)
# ==============================================================================
#
# STEP 1: DIAGNOSE & REMOVE BSD FILE FLAGS (chflags)
# ------------------------------------------------------------------------------
# Underlying Mechanism:
# BSD file flags add security controls beyond standard Unix ugo permissions.
# Flags like 'uchg' (user immutable) or 'schg' (system immutable) block all
# modifications, truncations, renames, and deletions—even by UID 0 (root).
#
# Diagnostic Verification:
#   # ls -lo /var/tmp/lab_712_4/logs/audit.log
#   Expected Output (FreeBSD):
#   -rw-rw-r--+ 1 root wheel uchg 54 Aug  6 20:33 /var/tmp/lab_712_4/logs/audit.log
#
# Notice the 'uchg' flag present in the flags column.
#
# Remediation Command:
#   # chflags nouchg /var/tmp/lab_712_4/logs/audit.log
#   (If system immutable flag 'schg' was set: # chflags noschg /var/tmp/lab_712_4/logs/audit.log)
#   (Linux fallback: # chattr -i /var/tmp/lab_712_4/logs/audit.log)
#
# ------------------------------------------------------------------------------
# STEP 2: REMOVE CONFLICTING ACLS AND RESTORE POSIX PERMISSIONS & OWNERSHIP
# ------------------------------------------------------------------------------
# Underlying Mechanism:
# Extended ACLs (POSIX/NFSv4) take precedence or act as additional enforcement
# masks over standard UNIX mode bits. The '+' sign in 'ls -l' output indicates ACLs.
#
# Diagnostic Verification:
#   # getfacl /var/tmp/lab_712_4/logs/audit.log
#   Expected Output:
#   # file: /var/tmp/lab_712_4/logs/audit.log
#   # owner: root
#   # group: wheel
#   user:appadmin:r--
#   user::rw-
#   group::rw-
#   mask::r--
#   other::r--
#
# Remediation Commands:
#   # setfacl -b /var/tmp/lab_712_4/logs/audit.log
#   # setfacl -b /var/tmp/lab_712_4/logs
#   # chown -R appadmin:appgroup /var/tmp/lab_712_4/logs
#   # chmod 775 /var/tmp/lab_712_4/logs
#   # chmod 664 /var/tmp/lab_712_4/logs/audit.log
#
# ------------------------------------------------------------------------------
# STEP 3: CONFIGURE SGID BIT FOR DIRECTORY GROUP INHERITANCE
# ------------------------------------------------------------------------------
# Underlying Mechanism:
# When the SGID bit (Set-Group-ID, octal 2000 / g+s) is applied to a DIRECTORY,
# any file or directory created within it automatically inherits the group owner
# of the parent directory, rather than the primary group of the active user.
#
# Remediation Commands:
#   # chown -R appadmin:appgroup /var/tmp/lab_712_4/incoming
#   # chmod 2775 /var/tmp/lab_712_4/incoming
#   (Or: # chmod g+s /var/tmp/lab_712_4/incoming)
#
# Diagnostic Verification:
#   # ls -ld /var/tmp/lab_712_4/incoming
#   Expected Output:
#   drwxrwsr-x 2 appadmin appgroup 512 Aug 6 20:33 /var/tmp/lab_712_4/incoming
#
# ------------------------------------------------------------------------------
# STEP 4: CONFIGURE SUID BIT FOR PRIVILEGED EXECUTION
# ------------------------------------------------------------------------------
# Underlying Mechanism:
# When the SUID bit (Set-User-ID, octal 4000 / u+s) is set on an executable BINARY,
# it executes with the permissions of the file OWNER (UID) rather than the EXECUTOR.
#
# Remediation Commands:
#   # chown root:appgroup /var/tmp/lab_712_4/bin/deploy_runner
#   # chmod 4755 /var/tmp/lab_712_4/bin/deploy_runner
#   (Or: # chmod u+s /var/tmp/lab_712_4/bin/deploy_runner)
#
# Diagnostic Verification:
#   # ls -l /var/tmp/lab_712_4/bin/deploy_runner
#   Expected Output:
#   -rwsr-xr-x 1 root appgroup 210 Aug 6 20:33 /var/tmp/lab_712_4/bin/deploy_runner
#
# ------------------------------------------------------------------------------
# FULL SYSTEM VERIFICATION SUITE
# ------------------------------------------------------------------------------
# Run these commands as root to verify complete resolution:
#
# 1. Test log write access:
#    # su -m appadmin -c "echo '$(date -u) Log write successful' >> /var/tmp/lab_712_4/logs/audit.log"
#    # tail -n 1 /var/tmp/lab_712_4/logs/audit.log
#
# 2. Test SGID inheritance:
#    # su -m appadmin -c "touch /var/tmp/lab_712_4/incoming/test_drop.csv"
#    # ls -l /var/tmp/lab_712_4/incoming/test_drop.csv
#    (Group column MUST show 'appgroup')
#
# 3. Test SUID execution:
#    # su -m appadmin -c "/var/tmp/lab_712_4/bin/deploy_runner"
#    Expected Output:
#    Executing deployment runner... Effective UID: 0
#    SUCCESS: High-privilege task executed safely.
# ==============================================================================