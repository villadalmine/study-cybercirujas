#!/usr/bin/env bash
# ==============================================================================
# LPIC-2 (Exam 202-450, v4.5) - Topic 208: E-Mail Services
# Production Break & Fix Lab Script: Postfix & Dovecot SASL/Relay Troubleshooting
# ==============================================================================
# Official Reference:
# - LPIC-2 Objectives: https://www.lpi.org/our-certifications/lpic-2-overview/
# - Postfix SASL README: http://www.postfix.org/SASL_README.html
# - Dovecot Documentation: https://doc.dovecot.org/
# ==============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Verify script is executed as root
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root in a disposable lab VM.${NC}" >&2
    exit 1
fi

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  LPIC-2 202-450 Topic 208: E-Mail Services - Break & Fix Scenario     ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo ""

# Helper function to detect package manager and install required packages
install_prerequisites() {
    echo -e "${YELLOW}[*] Verifying and installing required packages (Postfix, Dovecot, Mailutils)...${NC}"
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postfix dovecot-core dovecot-imapd mailutils &>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q postfix dovecot mailx &>/dev/null
    else
        echo -e "${RED}[ERROR] Unsupported package manager. Please use Debian/Ubuntu or RHEL/Rocky Linux.${NC}" >&2
        exit 1
    fi
}

# 1. Ensure services are running and backup original configuration
install_prerequisites

BACKUP_DIR="/var/backups/lpic2_email_lab_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${BACKUP_DIR}"

echo -e "${YELLOW}[*] Backing up configuration files to ${BACKUP_DIR}...${NC}"
cp /etc/postfix/main.cf "${BACKUP_DIR}/main.cf.bak"
[ -f /etc/dovecot/dovecot.conf ] && cp /etc/dovecot/dovecot.conf "${BACKUP_DIR}/dovecot.conf.bak"
[ -d /etc/dovecot/conf.d ] && cp -r /etc/dovecot/conf.d "${BACKUP_DIR}/conf.d.bak"

# 2. Inject Controlled Failure Scenario
echo -e "${YELLOW}[*] Injecting controlled configuration bugs into Postfix and Dovecot...${NC}"

# Bug 1: Misconfigure Postfix SASL socket path (relative vs absolute chroot path mismatch)
# Postfix runs chrooted under /var/spool/postfix, so relative path 'private/auth' refers to /var/spool/postfix/private/auth.
# We break it by setting an invalid absolute path '/var/run/dovecot/auth-userdb' outside chroot without socket access.
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = /var/run/dovecot/auth-userdb"
postconf -e "smtpd_sasl_auth_enable = yes"

# Bug 2: Misconfigure smtpd_relay_restrictions rule order
# Placing 'reject_unauth_destination' BEFORE 'permit_sasl_authenticated' causes relay rejection for authenticated remote users.
postconf -e "smtpd_relay_restrictions = reject_unauth_destination, permit_sasl_authenticated, permit_mynetworks"

# Bug 3: Introduce broken alias mapping without running postmap/newaliases
if ! grep -q "devops_alert:" /etc/aliases; then
    echo "devops_alert: root, non_existent_user_xyz" >> /etc/aliases
fi
# Deliberately do not run newaliases, leaving aliases.db out of sync or missing corrupt entry

# Bug 4: Break Dovecot Unix socket permission inside Dovecot master configuration
DOVECOT_10_MASTER="/etc/dovecot/conf.d/10-master.conf"
if [ -f "${DOVECOT_10_MASTER}" ]; then
    # Modify Postfix auth socket listener permissions to 0600 owned by root instead of postfix user
    sed -i '/unix_listener \/var\/spool\/postfix\/private\/auth {/,/}/s/mode = .*/mode = 0600/' "${DOVECOT_10_MASTER}" || true
    sed -i '/unix_listener \/var\/spool\/postfix\/private\/auth {/,/}/s/user = .*/user = root/' "${DOVECOT_10_MASTER}" || true
fi

# Restart services to apply broken state
systemctl restart postfix dovecot || true

echo -e "${GREEN}[+] Lab breakage completed successfully!${NC}"
echo ""

# 3. Present Problem Statement & Instructions to the Student
cat << 'EOF'
================================================================================
LAB PROBLEM STATEMENT (LPIC-2 Topic 208: E-Mail Services)
================================================================================

SCENARIO:
You are an SRE responding to an outage ticket for an enterprise mail gateway.
Users reporting issues state that:
  1. Authenticated SMTP clients cannot submit emails and receive "451 4.3.0 Temporary lookup failure"
     or SASL authentication failures.
  2. External mobile clients sending email to external domains receive "554 5.7.1 Relay access denied"
     even after passing SASL authentication credentials.
  3. Local mail sent to alias 'devops_alert' is failing or bouncing unexpectedly.

EXPECTED OBJECTIVES TO ACHIEVE:
  [ ] Fix Postfix SASL authentication integration with Dovecot so SASL works via unix socket.
  [ ] Fix Postfix relay restrictions so authenticated users can relay mail to off-site domains.
  [ ] Ensure local alias database /etc/aliases is updated and valid.
  [ ] Verify both postfix and dovecot services start cleanly without warnings or errors.

DIAGNOSTIC HINTS & COMMANDS TO USE:
  - Check Postfix current configuration: postconf -n
  - Check mail logs: journalctl -u postfix -u dovecot --no-pager -n 50 (or /var/log/mail.log)
  - Verify Dovecot socket status: ls -la /var/spool/postfix/private/auth
  - Test SMTP Auth via CLI: testsaslauthd, openssl s_client, or nc/telnet localhost 25
  - Rebuild alias database: newaliases

Good luck! Read the step-by-step solution commented out at the bottom of this script when done.
================================================================================
EOF

exit 0

# ==============================================================================
# COMPREHENSIVE STEP-BY-STEP SOLUTION (LPIC-2 EXAM & SRE GUIDE)
# ==============================================================================
#
# STEP 1: Diagnose SASL Socket Communication Failure
# ------------------------------------------------------------------------------
# Run journalctl to observe the error when an SMTP client attempts SASL auth:
#   journalctl -u postfix -n 30 --no-pager
# Error seen in logs:
#   postfix/smtpd[...]: warning: SASL authentication failure: cannot connect to Dovecot auth socket /var/run/dovecot/auth-userdb: No such file or directory
#   postfix/smtpd[...]: fatal: no SASL authentication mechanisms
#
# Root Cause 1:
#   Postfix is chrooted under /var/spool/postfix. When smtpd_sasl_path is set to a relative path
#   like 'private/auth', Postfix prepends /var/spool/postfix, opening /var/spool/postfix/private/auth.
#   Setting it to an absolute path outside the chroot breaks communication.
#
# Fix Bug 1 (Postfix main.cf):
#   postconf -e "smtpd_sasl_path = private/auth"
#
# Root Cause 2 (Dovecot 10-master.conf socket permissions):
#   Inspect Dovecot auth socket configuration in /etc/dovecot/conf.d/10-master.conf:
#   Ensure the unix_listener block inside service auth matches Postfix chroot requirements:
#
#   service auth {
#     unix_listener /var/spool/postfix/private/auth {
#       mode = 0660
#       user = postfix
#       group = postfix
#     }
#   }
#
# Fix Bug 2:
#   Edit /etc/dovecot/conf.d/10-master.conf to restore mode = 0660 and user/group = postfix.
#   Then restart Dovecot: systemctl restart dovecot
#
# ------------------------------------------------------------------------------
# STEP 2: Diagnose and Fix Relay Access Denied Bug
# ------------------------------------------------------------------------------
# Run postconf to inspect active relay restrictions:
#   postconf smtpd_relay_restrictions
# Current value:
#   smtpd_relay_restrictions = reject_unauth_destination, permit_sasl_authenticated, permit_mynetworks
#
# Root Cause:
#   Postfix evaluates restriction rules sequentially from left to right.
#   Because 'reject_unauth_destination' comes FIRST, any email destined for a domain NOT in
#   relay_domains or mydestination is immediately rejected, NEVER reaching 'permit_sasl_authenticated'.
#
# Fix Rule Order:
#   postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
#
# ------------------------------------------------------------------------------
# STEP 3: Rebuild Aliases Database
# ------------------------------------------------------------------------------
# Check for unindexed changes in /etc/aliases:
#   newaliases
# Output expected:
#   /etc/aliases: 15 aliases, longest 10 bytes, total 150 bytes
#
# ------------------------------------------------------------------------------
# STEP 4: Verification Commands & Expected Output
# ------------------------------------------------------------------------------
# 1. Restart services cleanly:
#    systemctl restart dovecot postfix
#    systemctl status postfix dovecot --no-pager
#
# 2. Verify socket existence and permissions:
#    ls -la /var/spool/postfix/private/auth
#    Expected output:
#    srw-rw---- 1 postfix postfix 0 Aug 6 10:00 /var/spool/postfix/private/auth
#
# 3. Test SMTP EHLO SASL capability output via CLI:
#    nc -C 127.0.0.1 25 << 'EOF'
#    EHLO localhost
#    QUIT
#    EOF
#
#    Expected output includes:
#    250-2.0.0 Hostname
#    250-AUTH LOGIN PLAIN
#    250-AUTH=LOGIN PLAIN
#    250 2.0.0 Ok
# ==============================================================================