#!/usr/bin/env bash
# ==============================================================================
# LPI BSD Specialist (Exam 702-100, v1.0)
# Topic 713.2: Automate System Administration Tasks by Scheduling Jobs
# Lab Exercise: "Break & Fix" Production Job Scheduling Breakdown
#
# Official References:
# - FreeBSD Manual Pages: cron(8) - https://man.freebsd.org/cgi/man.cgi?query=cron&sektion=8
# - FreeBSD Manual Pages: periodic(8) - https://man.freebsd.org/cgi/man.cgi?query=periodic&sektion=8
# - FreeBSD Manual Pages: at(1) - https://man.freebsd.org/cgi/man.cgi?query=at&sektion=1
# - FreeBSD Manual Pages: newsyslog.conf(5) - https://man.freebsd.org/cgi/man.cgi?query=newsyslog.conf&sektion=5
# ==============================================================================

set -euo pipefail

# Ensure the script runs with root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This break-and-fix lab script must be run as root." >&2
    exit 1
fi

echo "========================================================================"
echo " [LPI-702 Topic 713.2] Automate System Administration Tasks - Lab Setup"
echo "========================================================================"
echo "Injecting real-world production misconfigurations..."

# ------------------------------------------------------------------------------
# STEP 1: Setup test directory and simulation targets
# ------------------------------------------------------------------------------
TARGET_DIR="/var/log/app_backups"
SCRIPTS_DIR="/usr/local/etc/periodic/daily"

mkdir -p "${TARGET_DIR}"
mkdir -p "${SCRIPTS_DIR}"

# Create dummy backup script intended to run via periodic(8)
CAT_SCRIPT="${SCRIPTS_DIR}/990.app-backup"
cat << 'EOF' > "${CAT_SCRIPT}"
#!/bin/sh
# Daily Application Log Backup Task
echo "[$(date)] Running daily application backup..." >> /var/log/app_backups/backup.log
EOF

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 1: Cron Crontab File Security & Mode Invalidation
# Cron requires strict 0600 permissions and root ownership on spool tabs.
# Setting 0666 makes cron reject the file due to security ('WRONG FILE MODE').
# ------------------------------------------------------------------------------
CRON_TAB_FILE="/var/cron/tabs/root"
if [ ! -f "${CRON_TAB_FILE}" ]; then
    echo "* * * * * root /usr/bin/touch /tmp/cron_heartbeat.tmp" > "${CRON_TAB_FILE}"
fi

# Corrupt permissions and ownership
chmod 0666 "${CRON_TAB_FILE}"
chown 1001:1001 "${CRON_TAB_FILE}" 2>/dev/null || true

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 2: Periodic Script Execution Bit Missing
# Periodic(8) scans directories and executes scripts marked executable (+x).
# Removing execution permissions causes periodic to skip execution silently.
# ------------------------------------------------------------------------------
chmod 0644 "${CAT_SCRIPT}"

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 3: Access Control Breakdown for 'at(1)' Jobs
# Restrict access by placing user 'operator' or all users into /etc/at.deny
# and altering permissions on /var/at/jobs.
# ------------------------------------------------------------------------------
mkdir -p /var/at/jobs
echo "ALL" > /etc/at.deny
chmod 0700 /var/at/jobs
chown 999:999 /var/at/jobs 2>/dev/null || true

# Restart cron daemon to pickup state (if service exists)
if command -v service >/dev/null 2>&1; then
    service cron restart >/dev/null 2>&1 || true
fi

echo "
======================================================================
 [LAB SCENARIO INJECTED SUCCESSFULLY]
======================================================================

PROBLEM STATEMENT & SYMPTOMS:
1. Scheduled root jobs configured in /var/cron/tabs/root fail to execute.
   System logs (/var/log/cron) report errors regarding file mode/security.
2. The custom daily periodic task '/usr/local/etc/periodic/daily/990.app-backup'
   is not producing log entries in /var/log/app_backups/backup.log when
   'periodic daily' is triggered manually or by cron.
3. System operators report that queuing one-off jobs via 'at(1)' fails with
   permission denied or queue access errors.

OBJECTIVES TO COMPLETE:
- Fix the ownership, permissions, and security model of /var/cron/tabs/root.
- Enable execution for the daily periodic script and verify periodic discovery.
- Restore access permissions for at(1) and fix /var/at/jobs queue directory security.
- Verify job execution using CLI tools (crontab, periodic, at, atq).

Do NOT scroll down unless you are ready to review the solution!
======================================================================
"
exit 0


# ==============================================================================
# STEP-BY-STEP SOLUTION GUIDE (DON'T READ UNTIL YOU TRY DISCOVERY & FIXES!)
# ==============================================================================
#
# DIAGNOSIS & REPAIR INSTRUCTIONS:
#
# --- TASK 1: Diagnose & Fix cron Spool Permissions ---
# 1. Check /var/log/cron to identify why root's crontab is skipped:
#    $ grep -i "root" /var/log/cron
#    Expected output: "... (*system*) WRONG FILE MODE (/var/cron/tabs/root)"
#
# 2. Inspect file attributes:
#    $ ls -l /var/cron/tabs/root
#
# 3. Fix ownership (must be root:wheel or root:crontab depending on OS variant):
#    $ chown root:wheel /var/cron/tabs/root
#
# 4. Fix permissions (must be 0600):
#    $ chmod 0600 /var/cron/tabs/root
#
# 5. Reload/restart cron service:
#    $ service cron restart
#
# --- TASK 2: Fix Periodic Daily Task Execution ---
# 1. Verify script discovery in periodic directory:
#    $ ls -l /usr/local/etc/periodic/daily/990.app-backup
#    Notice missing executable permissions (-rw-r--r--).
#
# 2. Grant execution flag:
#    $ chmod +x /usr/local/etc/periodic/daily/990.app-backup
#
# 3. Test execution by manually triggering periodic daily runner:
#    $ periodic daily
#
# 4. Verify log creation:
#    $ cat /var/log/app_backups/backup.log
#
# --- TASK 3: Fix at(1) Authorization & Directory Permissions ---
# 1. Inspect at permissions and deny configuration:
#    $ cat /etc/at.deny
#    $ ls -ld /var/at/jobs
#
# 2. Clear blocklist entry from /etc/at.deny (or configure /etc/at.allow):
#    $ rm -f /etc/at.deny
#
# 3. Fix directory owner and permissions for /var/at/jobs (must be daemon:wheel or _at:wheel, mode 0700/0755):
#    $ chown -R daemon:wheel /var/at/jobs
#    $ chmod 0700 /var/at/jobs
#
# 4. Test at job creation:
#    $ echo "touch /tmp/at_test.tmp" | at now + 1 minute
#    $ atq
# ==============================================================================