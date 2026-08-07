#!/usr/bin/env bash
# ==============================================================================
# LPI 702-100 (BSD Specialist) - Topic 713.6: Manage Printing and Print Jobs
# Break & Fix Production Laboratory Scenario
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
#
# DESCRIPTION:
# This script injects controlled, production-grade failure states into the BSD
# Line Printer Daemon (LPD) / CUPS print spooling subsystem on a test laboratory VM.
#
# TARGET TOPICS COVERED:
# - /etc/printcap syntax and spool directory capabilities (:sd:, :lp:, :lf:)
# - Spool directory permissions and ownership (/var/spool/lpd/*)
# - Daemon lockfiles and state controls (lpc status, enable/disable, start/stop)
# - Print job management and queue diagnostics (lpr, lpq, lprm, lpc)
# ==============================================================================

set -euo pipefail

# Ensure script is executed with root privileges
if [ "${EUID}" -ne 0 ]; then
    echo "ERROR: This laboratory break script must be executed as root." >&2
    exit 1
fi

PRINTER_NAME="sre_office_lp"
SPOOL_DIR="/var/spool/lpd/${PRINTER_NAME}"
PRINTCAP_FILE="/etc/printcap"
LOG_FILE="/var/log/lpd-errs"

echo "======================================================================"
echo " LPI-702 Topic 713.6: BSD Printing Subsystem - Break Phase Initializing"
echo "======================================================================"

# Step 1: Ensure base log file exists
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

# Step 2: Provision a realistic /etc/printcap configuration (backing up existing)
if [ -f "${PRINTCAP_FILE}" ] && [ ! -f "${PRINTCAP_FILE}.bak" ]; then
    cp "${PRINTCAP_FILE}" "${PRINTCAP_FILE}.bak"
fi

cat <<EOF > "${PRINTCAP_FILE}"
# /etc/printcap - BSD Line Printer Spooler Database
${PRINTER_NAME}|Production High-Throughput Line Printer:\\
	:sh:\\
	:lp=/dev/null:\\
	:sd=${SPOOL_DIR}:\\
	:lf=${LOG_FILE}:\\
	:mx#0:
EOF

# Step 3: Create spool directory structure
mkdir -p "${SPOOL_DIR}"

# Step 4: Inject Failure Modes (Multi-layered Production Outage)

# Failure Mode A: Incorrect Spool Directory Ownership and Strict Permissions
# BSD lpd daemon runs under user 'daemon' or 'root' depending on flavor, but requires daemon:daemon ownership.
chown root:wheel "${SPOOL_DIR}"
chmod 0700 "${SPOOL_DIR}"

# Failure Mode B: Stale / Invalid Daemon Lock File Injection
# Simulates an ungraceful crash leaving an active pid lock file owned by root.
echo "99999" > "${SPOOL_DIR}/lock"
chown root:wheel "${SPOOL_DIR}/lock"
chmod 0400 "${SPOOL_DIR}/lock"

# Failure Mode C: Disable queue and spooling using lpc (if lpc is present)
if command -v lpc >/dev/null 2>&1; then
    lpc disable "${PRINTER_NAME}" >/dev/null 2>&1 || true
    lpc stop "${PRINTER_NAME}" >/dev/null 2>&1 || true
fi

# Step 5: Attempt to submit a test print job to trigger symptom generation
if command -v lpr >/dev/null 2>&1; then
    echo "LPI-702 Test Print Document - Production Diagnostics" | lpr -P"${PRINTER_NAME}" 2>/dev/null || true
fi

echo ""
echo "----------------------------------------------------------------------"
echo " INJECTED FAILURE SCENARIO SUMMARY FOR STUDENT"
echo "----------------------------------------------------------------------"
echo "Scenario: Users report that print jobs submitted to '${PRINTER_NAME}' fail,"
echo "hang indefinitely, or return 'Permission denied' / 'spool queue disabled'."
echo ""
echo "STUDENT OBJECTIVES:"
echo "1. Diagnose the status of print queue '${PRINTER_NAME}' using lpq and lpc."
echo "2. Inspect system log files (${LOG_FILE}) and /etc/printcap parameters."
echo "3. Identify ownership/permission issues on spool directory '${SPOOL_DIR}'."
echo "4. Remove stale lockfiles preventing print daemon processing."
echo "5. Re-enable queuing and printing controls using lpc commands."
echo "6. Submit a test job with lpr and verify queue clearing with lpq."
echo "----------------------------------------------------------------------"
echo ""

# Display initial broken state symptoms
echo "=== CURRENT SYSTEM SYMPTOMS ==="
if command -v lpq >/dev/null 2>&1; then
    echo "$ lpq -P${PRINTER_NAME}"
    lpq -P"${PRINTER_NAME}" || true
fi
echo ""
if command -v lpc >/dev/null 2>&1; then
    echo "$ lpc status ${PRINTER_NAME}"
    lpc status "${PRINTER_NAME}" || true
fi

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & VERIFICATION GUIDE (STUDENT REFERENCE)
# ==============================================================================
#
# STEP 1: Verify system queue status using standard BSD print tools
#   $ lpq -P sre_office_lp
#   $ lpc status sre_office_lp
#   Expected output will show: "queuing is disabled", "printing is disabled", or
#   cannot access spool directory errors.
#
# STEP 2: Inspect /etc/printcap file configuration
#   $ cat /etc/printcap
#   Verify spool directory parameter (:sd=): /var/spool/lpd/sre_office_lp
#   Verify log file parameter (:lf=): /var/log/lpd-errs
#
# STEP 3: Inspect log files for permission or daemon errors
#   $ tail -n 20 /var/log/lpd-errs
#
# STEP 4: Fix ownership and permissions on the spool directory
#   The BSD lpd spool directory must be owned by user 'daemon' and group 'daemon',
#   with directory mode 0770 or 0755 so the print daemon can write lock/cf/df files.
#   $ chown -R daemon:daemon /var/spool/lpd/sre_office_lp
#   $ chmod 770 /var/spool/lpd/sre_office_lp
#
# STEP 5: Clear stale daemon lock file if daemon is not running
#   $ rm -f /var/spool/lpd/sre_office_lp/lock
#
# STEP 6: Use lpc to re-enable queuing and restart printer daemon processing
#   $ lpc enable sre_office_lp
#   $ lpc start sre_office_lp
#   (Alternatively, use 'lpc up sre_office_lp' to enable both queuing and printing)
#
# STEP 7: Verify status and clear stuck/invalid print jobs if needed
#   $ lpq -P sre_office_lp
#   $ lprm -P sre_office_lp -   # (Removes all jobs from queue if necessary)
#
# STEP 8: Test end-to-end print job execution
#   $ echo "SRE Production Print Test OK" | lpr -P sre_office_lp
#   $ lpq -P sre_office_lp
#   Expected output: "no entries" (indicating job was processed into /dev/null successfully).
# ==============================================================================