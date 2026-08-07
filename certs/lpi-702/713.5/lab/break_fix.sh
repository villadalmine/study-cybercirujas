#!/usr/bin/env bash
# ==============================================================================
# LPI-702 (Exam 702-100, v1.0) - Topic 713.5: Mail Transfer Agents (MTA) Basics
# Weight: 1.67
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
#
# Role: Principal Platform Architect & Senior SRE Instructor
# Exercise: Production Break & Fix - MTA Alias Lookup & Queue Delivery Failure
# WARNING: Run this script ONLY inside a disposable test VM.
# ==============================================================================

set -euo pipefail

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

if [[ ${EUID} -ne 0 ]]; then
    echo -e "${COLOR_RED}ERROR: This script must be executed with root privileges (sudo).${COLOR_RESET}" >&2
    exit 1
fi

echo -e "${COLOR_BLUE}[+] Preparing MTA environment for LPI-702 Topic 713.5 Break & Fix Lab...${COLOR_RESET}"

# Step 1: Ensure Postfix and mail utilities are available
if command -v pkg &>/dev/null; then
    # FreeBSD environment
    pkg install -y postfix mailutils &>/dev/null || true
elif command -v apt-get &>/dev/null; then
    # Debian/Ubuntu environment
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix mailutils &>/dev/null
elif command -v dnf &>/dev/null; then
    # RHEL/Fedora environment
    dnf install -y postfix mailx &>/dev/null
fi

POSTFIX_CONF_DIR="/etc/postfix"
MAIN_CF="${POSTFIX_CONF_DIR}/main.cf"
ALIASES_FILE="/etc/aliases"
ALIASES_DB="/etc/aliases.db"

if [[ ! -d "${POSTFIX_CONF_DIR}" ]]; then
    mkdir -p "${POSTFIX_CONF_DIR}"
fi

# Step 2: Backup original configuration
if [[ -f "${MAIN_CF}" && ! -f "${MAIN_CF}.bak_lpi702" ]]; then
    cp "${MAIN_CF}" "${MAIN_CF}.bak_lpi702"
fi

if [[ -f "${ALIASES_FILE}" && ! -f "${ALIASES_FILE}.bak_lpi702" ]]; then
    cp "${ALIASES_FILE}" "${ALIASES_FILE}.bak_lpi702"
fi

# Step 3: Inject controlled production breakage
echo -e "${COLOR_YELLOW}[!] Injecting failure into Postfix MTA configuration and local mail routing...${COLOR_RESET}"

# Create a baseline main.cf if minimal or non-existent
cat << 'EOF' > "${MAIN_CF}"
# Minimal Postfix configuration for LPI-702 Lab
smtpd_banner = $myhostname ESMTP $mail_name
biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 2

myhostname = mail.lab.internal
alias_maps = hash:/etc/aliases_broken
alias_database = hash:/etc/aliases
mydestination = $myhostname, localhost.$mydomain, localhost, mail.lab.internal
relayhost = 
mynetworks = 127.0.0.0/8 [::1]/128
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = loopback-only
inet_protocols = all
EOF

# Create aliases file with custom mapping
cat << 'EOF' > "${ALIASES_FILE}"
# /etc/aliases
postmaster: root
root: sysadmin
sysadmin: /dev/null
EOF

# Corrupt database mapping state
# 1. Point alias_maps to non-existent / unindexed table hash:/etc/aliases_broken
# 2. Lock permissions on existing /etc/aliases.db if present
touch "${ALIASES_DB}"
chmod 0000 "${ALIASES_DB}"

# Step 4: Restart/Reload Postfix service
systemctl restart postfix &>/dev/null || service postfix restart &>/dev/null || postfix reload &>/dev/null || true

# Step 5: Inject stuck messages into the MTA queue
echo "Subject: Test Alert System Failure" | sendmail -v root@localhost &>/dev/null || true
echo "Subject: System Report Deferral" | sendmail -v sysadmin@localhost &>/dev/null || true

echo ""
echo -e "${COLOR_RED}==============================================================================${COLOR_RESET}"
echo -e "${COLOR_RED}               LPI-702 TOPIC 713.5 LAB SCENARIO INJECTED                      ${COLOR_RESET}"
echo -e "${COLOR_RED}==============================================================================${COLOR_RESET}"
echo -e "${COLOR_YELLOW}LAB SYMPTOMS OBSERVED:${COLOR_RESET}"
echo "  1. Local system mail sent to 'root' or 'sysadmin' is failing to deliver."
echo "  2. The MTA mail queue contains deferred messages with lookup database errors."
echo "  3. System logs (/var/log/maillog or journalctl -u postfix) show fatal table errors."
echo ""
echo -e "${COLOR_YELLOW}STUDENT OBJECTIVES:${COLOR_RESET}"
echo "  1. Diagnose the exact cause of mail queue deferrals using standard MTA CLI tools."
echo "  2. Fix the Postfix alias map configuration in /etc/postfix/main.cf."
echo "  3. Rebuild the Berkley DB alias lookup index (/etc/aliases.db) with proper permissions."
echo "  4. Flush the MTA mail queue and verify 100% successful queue processing."
echo ""
echo -e "${COLOR_YELLOW}VERIFICATION COMMANDS TO USE:${COLOR_RESET}"
echo "  - mailq (or postqueue -p)"
echo "  - postfix check"
echo "  - postconf alias_maps alias_database"
echo "  - postqueue -f (to flush the queue after fixing)"
echo -e "${COLOR_RED}==============================================================================${COLOR_RESET}"
echo ""

exit 0

# ==============================================================================
#                        STEP-BY-STEP SOLUTION & RCA
# ==============================================================================
#
# STEP 1: INSPECT THE MTA MAIL QUEUE & LOGS
# ------------------------------------------------------------------------------
# Run 'mailq' or 'postqueue -p' to see queued deferred messages:
#   $ mailq
# Output example:
#   -Queue ID- --Size-- ----Arrival Time---- -Sender/Recipient-------
#   8B310A1F08     312 Thu Aug  6 20:45:01  root@mail.lab.internal
#   (cannot open database /etc/aliases_broken.db: No such file or directory)
#                                         root@localhost
#
# Check system mail logs for detailed diagnostics:
#   $ tail -n 30 /var/log/maillog
#   # Or on systemd platforms:
#   $ journalctl -u postfix -n 30 --no-pager
#
# STEP 2: AUDIT POSTFIX ALIAS CONFIGURATION
# ------------------------------------------------------------------------------
# Run 'postconf' to query active Postfix configuration parameters:
#   $ postconf alias_maps alias_database
# Output:
#   alias_database = hash:/etc/aliases
#   alias_maps = hash:/etc/aliases_broken
#
# Notice that 'alias_maps' points to '/etc/aliases_broken', which does not exist!
#
# STEP 3: FIX /etc/postfix/main.cf
# ------------------------------------------------------------------------------
# Edit /etc/postfix/main.cf to ensure both alias parameters reference /etc/aliases:
#   $ sed -i 's|alias_maps = hash:/etc/aliases_broken|alias_maps = hash:/etc/aliases|g' /etc/postfix/main.cf
#
# Validate configuration syntax:
#   $ postfix check
#
# STEP 4: REBUILD ALIASES DATABASE & FIX PERMISSIONS
# ------------------------------------------------------------------------------
# Check permissions on /etc/aliases.db:
#   $ ls -l /etc/aliases.db
# Notice permissions are set to 0000. Fix file permissions:
#   $ chmod 0644 /etc/aliases.db
#
# Regenerate the indexed binary lookup table (/etc/aliases.db) from /etc/aliases:
#   $ newaliases
#   # (Alternatively: postalias /etc/aliases)
#
# Verify that /etc/aliases.db updated timestamp and read permissions:
#   $ ls -l /etc/aliases.db
#   -rw-r--r-- 1 root root 12288 Aug  6 20:46 /etc/aliases.db
#
# STEP 5: RELOAD POSTFIX & FLUSH QUEUE
# ------------------------------------------------------------------------------
# Reload Postfix daemon configuration:
#   $ postfix reload
#   # Or: systemctl reload postfix
#
# Force delivery of all messages currently deferred in the mail queue:
#   $ postqueue -f
#   # (Alternatively: postfix flush)
#
# STEP 6: VERIFY QUEUE IS EMPTY
# ------------------------------------------------------------------------------
# Check the queue state again:
#   $ mailq
# Output expected:
#   Mail queue is empty
# ==============================================================================