#!/usr/bin/env bash
# ==============================================================================
# LPI BSD Specialist (Exam 702-100 v1.0)
# Topic 712.6: Find Files and BSD Directory Layout (Weight: 3.33)
# Production SRE Break & Fix Laboratory Exercise
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
# WARNING: Run this script ONLY inside a disposable test laboratory VM.
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/tmp/lpi712_6_lab"
DB_PATH="/var/db/locate.database"
SYSLOG_AUDIT="/var/log/audit_archive.log"

print_header() {
    echo "======================================================================"
    echo " LPI-702 Topic 712.6: Find Files & BSD Directory Layout Lab"
    echo "======================================================================"
}

detect_os() {
    OS_NAME=$(uname -s)
    if [ "${OS_NAME}" != "FreeBSD" ] && [ "${OS_NAME}" != "OpenBSD" ] && [ "${OS_NAME}" != "NetBSD" ]; then
        echo "[!] Warning: Native BSD detected file flags (chflags) and locate.updatedb"
        echo "    behavior are optimized for BSD kernels. Running emulation mode on ${OS_NAME}."
    fi
}

inject_breakage() {
    echo "[+] Injecting controlled production configuration faults..."

    # Fault 1: BSD hier(7) layout violation for third-party software (/usr/local)
    # Rogue config put under non-standard /etc/local and /usr/local/bin standard path broken
    mkdir -p /usr/local/etc /etc/local /usr/local/libexec/app_v1
    touch /etc/local/custom_service.conf
    if [ ! -e /usr/local/bin/custom_tool ]; then
        echo '#!/bin/sh' > /usr/local/libexec/app_v1/custom_tool
        chmod 755 /usr/local/libexec/app_v1/custom_tool
        ln -sf /usr/local/libexec/app_v2/nonexistent_tool /usr/local/bin/custom_tool 2>/dev/null || true
    fi

    # Fault 2: locate(1) database update failure via chflags & owner permissions
    # BSD locate.updatedb drops privileges to 'nobody'. Restricting /var/db/locate.database
    # prevents periodic index generation (/etc/periodic/weekly/310.locate).
    touch "${DB_PATH}" 2>/dev/null || true
    chown root:wheel "${DB_PATH}" 2>/dev/null || chown root:root "${DB_PATH}" 2>/dev/null || true
    chmod 0400 "${DB_PATH}" 2>/dev/null || true
    if command -v chflags >/dev/null 2>&1; then
        chflags schg "${DB_PATH}" 2>/dev/null || true
    fi

    # Fault 3: System log file flagged with immutable flag (schg/uchg) breaking find -exec cleanups
    touch "${SYSLOG_AUDIT}"
    if command -v chflags >/dev/null 2>&1; then
        chflags uchg "${SYSLOG_AUDIT}" 2>/dev/null || true
    fi

    echo "[+] Breakage injection complete."
}

display_scenario() {
    cat << 'EOF'

----------------------------------------------------------------------
PROBLEM STATEMENT & INCIDENT REPORT
----------------------------------------------------------------------
Severity: P2 - Infrastructure Monitoring & File Search Utility Failure
Target Exam: LPI-702 (BSD Specialist), Topic 712.6

SCENARIO SUMMARY:
During routine SRE maintenance on a FreeBSD production host, several
automated scripts and administrator search utilities failed:

1. `locate(1)` queries fail or report out-of-date records. Re-running the
   indexing helper `/usr/libexec/locate.updatedb` throws permission/write
   errors even when executed with superuser privileges.
2. Third-party binary `custom_tool` installed under `/usr/local` is broken
   due to non-compliance with BSD `hier(7)` directory layout conventions.
   Configuration files were improperly stored outside `/usr/local/etc`.
3. Automated log pruning commands using `find /var/log -type f -mtime +7 -exec rm {} +`
   fail with "Operation not permitted" on `/var/log/audit_archive.log`.

YOUR OBJECTIVES:
A. Diagnose and resolve the `locate.updatedb` failure so `/var/db/locate.database`
   can be generated properly by user `nobody`.
B. Audit `/usr/local` according to `hier(7)` standards. Restore valid symlinks
   in `/usr/local/bin` pointing to `/usr/local/libexec/app_v1/custom_tool`
   and relocate `/etc/local/custom_service.conf` to its canonical BSD path.
C. Identify file flags on `/var/log/audit_archive.log` using BSD extended attributes
   (`ls -lo` / `chflags`) and clear the immutable attribute.
D. Validate solutions using `which(1)`, `whereis(1)`, `find(1)`, and `locate(1)`.

----------------------------------------------------------------------
EXPECTED CLI VERIFICATION OUTPUTS
----------------------------------------------------------------------
1. Check file flags on log archive:
   $ ls -lo /var/log/audit_archive.log
   -rw-r--r--  1 root  wheel  uchg 0 Aug  6 20:00 /var/log/audit_archive.log

2. Run locate indexer successfully:
   $ /usr/libexec/locate.updatedb
   (Returns 0 exit code, /var/db/locate.database updated)

3. Locate custom tool binary and manpage/config paths compliant with hier(7):
   $ which custom_tool
   /usr/local/bin/custom_tool
   $ whereis custom_tool
   custom_tool: /usr/local/bin/custom_tool

EOF
}

main() {
    print_header
    detect_os
    inject_breakage
    display_scenario
}

main "$@"

# ==============================================================================
# STEP-BY-STEP SOLUTION & SRE POST-MORTEM GUIDE (KEEP COMMENTED)
# ==============================================================================
#
# STEP 1: Fix locate(1) Database Permissions and File Flags
# ------------------------------------------------------------------------------
# Mechanics: In BSD systems, /usr/libexec/locate.updatedb drops privileges to
# user 'nobody' (or configured user in /etc/locate.rc). If /var/db/locate.database
# has the system immutable flag (schg) set or restrictive root-only permissions,
# locate.updatedb will fail.
#
# Commands:
#   # Check file status and BSD flags
#   ls -lo /var/db/locate.database
#
#   # Remove immutable flag if present (requires root)
#   chflags noschg /var/db/locate.database 2>/dev/null || true
#   chflags nouchg /var/db/locate.database 2>/dev/null || true
#
#   # Adjust permissions and owner so 'nobody' can overwrite the database
#   chown nobody:nobody /var/db/locate.database
#   chmod 644 /var/db/locate.database
#
#   # Force database update manually or wait for periodic weekly script
#   /usr/libexec/locate.updatedb
#
#   # Verify index functionality
#   locate custom_service.conf
#
# ------------------------------------------------------------------------------
# STEP 2: Enforce BSD hier(7) Directory Layout Standards for Third-Party Apps
# ------------------------------------------------------------------------------
# Mechanics: Per hier(7), base OS files reside in /bin, /sbin, /usr/bin, /usr/sbin,
# and /etc. Third-party ports and packages MUST strictly isolate their binaries into
# /usr/local/bin, configuration into /usr/local/etc, and internal libraries into
# /usr/local/libexec.
#
# Commands:
#   # Relocate misnamed configuration to canonical BSD location
#   mv /etc/local/custom_service.conf /usr/local/etc/custom_service.conf
#   rmdir /etc/local 2>/dev/null || true
#
#   # Repair broken binary symlink in /usr/local/bin
#   ln -sf /usr/local/libexec/app_v1/custom_tool /usr/local/bin/custom_tool
#
#   # Verify binary lookup using BSD which(1) and whereis(1)
#   which custom_tool
#   whereis custom_tool
#
# ------------------------------------------------------------------------------
# STEP 3: Diagnose and Remove File Flags Blocking find -exec Execution
# ------------------------------------------------------------------------------
# Mechanics: BSD file flags (schg, uchg, nodump, sappnd, uappnd) override traditional
# POSIX read/write/execute permissions. Even root cannot delete or modify a file
# with 'schg' or 'uchg' set until the flag is cleared via chflags(1).
#
# Commands:
#   # Find files containing specific BSD file flags under /var/log
#   find /var/log -flags +uchg -o -flags +schg
#
#   # Inspect flags using long format (-o displays flags field)
#   ls -lo /var/log/audit_archive.log
#
#   # Clear user immutable flag (uchg)
#   chflags nouchg /var/log/audit_archive.log
#
#   # Test automated cleanup command with find
#   find /var/log -name "audit_archive.log" -exec rm -f {} +
#
# ------------------------------------------------------------------------------
# VERIFICATION & REFERENCES:
# - FreeBSD Manual Pages: hier(7), find(1), locate(1), locate.updatedb(8), chflags(1)
# - Official LPI BSD Specialist Objectives: Topic 712.6
#   https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================