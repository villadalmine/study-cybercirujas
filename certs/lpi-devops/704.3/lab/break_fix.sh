#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
# Topic 5.2: Log Management and Analysis (Weight: 6.66)
#
# LAB SCENARIO: PRODUCTION LOG PIPELINE INCIDENT ("BREAK & FIX")
# Author: Senior SRE / Principal Platform Architect
# Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
# ==============================================================================
# WARNING: Run this script ONLY on a disposable, non-production Linux VM.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. ROOT CHECK & DEPENDENCY VERIFICATION
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This lab script must be executed as root." >&2
    exit 1
fi

echo "[*] Initializing LPI 701-100 Topic 5.2 Lab Environment..."

# Ensure required packages exist
REQUIRED_PKGS=("rsyslog" "logrotate" "systemd")
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v "${pkg}" >/dev/null 2>&1 && ! dpkg -s "${pkg}" >/dev/null 2>&1 && ! rpm -q "${pkg}" >/dev/null 2>&1; then
        MISSING_PKGS+=("${pkg}")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo "[*] Installing missing dependencies: ${MISSING_PKGS[*]}..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq rsyslog logrotate systemd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q rsyslog logrotate systemd
    fi
fi

# ------------------------------------------------------------------------------
# 2. LAB SETUP: CREATING DUMMY PRODUCTION APPLICATION
# ------------------------------------------------------------------------------
APP_LOG_DIR="/var/log/payment-service"
APP_SCRIPT="/usr/local/bin/payment-service.sh"
SERVICE_FILE="/etc/systemd/system/payment-service.service"

mkdir -p "${APP_LOG_DIR}"

cat <<'EOF' > "${APP_SCRIPT}"
#!/usr/bin/env bash
while true; do
    echo "PAYMENT_PROCESSOR: transaction_id=$((RANDOM%900000+100000)) status=SUCCESS amount=$((RANDOM%500+1)).00 USD timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sleep 2
done
EOF
chmod +x "${APP_SCRIPT}"

cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=Payment Processing Daemon (Lab Mock)
After=network.target rsyslog.service

[Service]
Type=simple
ExecStart=${APP_SCRIPT}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=payment-service
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now payment-service.service >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 3. INJECTING CONTROLLED BREAKAGES
# ------------------------------------------------------------------------------
echo "[*] Injecting production configuration faults..."

# Breakage 1: Journald Rate-Limiting & Storage Mismatch
# Disables journal persistence and restricts rate-limiting to drop logs instantly.
JOURNALD_BREAK_CONF="/etc/systemd/journald.conf.d/99-lab-fault.conf"
mkdir -p /etc/systemd/journald.conf.d
cat <<EOF > "${JOURNALD_BREAK_CONF}"
[Journal]
Storage=volatile
RateLimitIntervalSec=1s
RateLimitBurst=1
SystemMaxUse=10M
EOF

# Breakage 2: Rsyslog Permission & Syntax Fault
# Uses invalid RainerScript syntax and sets output directory ownership to root:root 0700 while rsyslog drops privileges to user 'syslog' or 'nobody'.
RSYSLOG_BREAK_CONF="/etc/rsyslog.d/30-payment-service.conf"
cat <<EOF > "${RSYSLOG_BREAK_CONF}"
# INCORRECT RSYSLOG CONFIGURATION
if \$programname == 'payment-service' then {
    # Malformed action: missing quote in template, invalid path permission target, invalid property call
    action(type="omfile" File="${APP_LOG_DIR}/payment.log" Template="NonExistentTemplate" FileOwner="root" FileGroup="root" FileCreateMode="0600")
    stop
}
EOF

chown -R root:root "${APP_LOG_DIR}"
chmod 700 "${APP_LOG_DIR}"

# Breakage 3: Logrotate Fatal Configuration Fault
# Postrotate script references non-existent command without sharedscripts/continue, missing su directive for permission-restricted folder.
LOGROTATE_BREAK_CONF="/etc/logrotate.d/payment-service"
cat <<EOF > "${LOGROTATE_BREAK_CONF}"
${APP_LOG_DIR}/payment.log {
    daily
    rotate 5
    compress
    missingok
    notifempty
    create 0600 root root
    postrotate
        /usr/bin/systemctl-nonexistent-command reload payment-service
    endscript
}
EOF

# Restart services to apply breakages
systemctl restart systemd-journald
systemctl restart rsyslog
systemctl restart payment-service

echo "[+] Breakage injection complete!"
echo "================================================================================"
echo "                   LPI 701-100 TOPIC 5.2 - INCIDENT BRIEFING                    "
echo "================================================================================"
echo "SEVERITY: HIGH"
echo "AFFECTED SYSTEM: Production Log Pipeline (Journald -> Rsyslog -> Logrotate)"
echo ""
echo "SYMPTOMS REPORTED BY MONITORING:"
echo " 1. 'payment-service' logs are NOT being written to '${APP_LOG_DIR}/payment.log'."
echo " 2. 'journalctl -u payment-service' drops log entries under load due to rate limiting."
echo " 3. The system log daemon 'rsyslog' emits syntax error warnings during startup."
echo " 4. Manual execution of logrotate ('logrotate -f /etc/logrotate.d/payment-service')"
echo "    fails with a fatal execution error."
echo ""
echo "STUDENT OBJECTIVES:"
echo " 1. Fix systemd-journald configuration so logs persist across reboots without"
echo "    synthetic rate-limiting drops."
echo " 2. Correct '/etc/rsyslog.d/30-payment-service.conf' syntax using valid RainerScript"
echo "    or legacy syntax to route 'payment-service' logs to '${APP_LOG_DIR}/payment.log'."
echo " 3. Fix directory and file permissions so rsyslog can write to '${APP_LOG_DIR}/payment.log'."
echo " 4. Fix '/etc/logrotate.d/payment-service' so log rotation executes without errors."
echo " 5. Verify the full pipeline end-to-end using systemd/rsyslog diagnostic CLI tools."
echo ""
echo "Official Reference Documentation:"
echo " - LPI Overview: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/"
echo " - Systemd Journald: https://www.freedesktop.org/software/systemd/man/journald.conf.html"
echo " - Rsyslog Documentation: https://www.rsyslog.com/doc/"
echo " - Logrotate Documentation: https://linux.die.net/man/8/logrotate"
echo "================================================================================"
echo ""

# Exit successfully to leave system in broken state for student
exit 0

# ==============================================================================
#                               STEP-BY-STEP SOLUTION
# ==============================================================================
# (The student should diagnose and resolve the issue without viewing this part first)
#
# STEP 1: DIAGNOSE & FIX SYSTEMD-JOURNALD
# ------------------------------------------------------------------------------
# Check journald current configuration and drop-in files:
#   systemctl status systemd-journald
#   cat /etc/systemd/journald.conf.d/99-lab-fault.conf
#
# Resolution: Remove or correct the drop-in file to ensure persistent logging:
#   rm -f /etc/systemd/journald.conf.d/99-lab-fault.conf
#   # Or edit it to contain valid persistent settings:
#   mkdir -p /var/log/journal
#   systemctl restart systemd-journald
#   journalctl --verify
#
# STEP 2: DIAGNOSE & FIX RSYSLOG CONFIGURATION & PERMISSIONS
# ------------------------------------------------------------------------------
# Check rsyslog service status and test configuration syntax:
#   systemctl status rsyslog
#   rsyslogd -N1   # Checks syntax of rsyslog rules
#
# Observe syntax error in /etc/rsyslog.d/30-payment-service.conf (invalid template name, invalid params).
# Also inspect ownership of output directory:
#   ls -ld /var/log/payment-service
#
# Determine rsyslog user (usually 'syslog' on Debian/Ubuntu, 'root' on RHEL/CentOS):
#   ps aux | grep rsyslog
#
# Fix Directory Ownership:
#   chown -R syslog:adm /var/log/payment-service  # (Debian/Ubuntu)
#   # OR for RHEL/CentOS: chown -R root:root /var/log/payment-service
#   chmod 755 /var/log/payment-service
#
# Replace /etc/rsyslog.d/30-payment-service.conf with valid RainerScript:
#   cat <<'EOF' > /etc/rsyslog.d/30-payment-service.conf
#   if $programname == 'payment-service' then {
#       action(type="omfile" file="/var/log/payment-service/payment.log")
#       stop
#   }
#   EOF
#
# Restart rsyslog:
#   systemctl restart rsyslog
#   rsyslogd -N1
#
# STEP 3: DIAGNOSE & FIX LOGROTATE CONFIGURATION
# ------------------------------------------------------------------------------
# Run logrotate in debug mode to identify errors:
#   logrotate -d /etc/logrotate.d/payment-service
# Run logrotate force test:
#   logrotate -f /etc/logrotate.d/payment-service
#
# Fix /etc/logrotate.d/payment-service:
#   cat <<'EOF' > /etc/logrotate.d/payment-service
#   /var/log/payment-service/payment.log {
#       daily
#       rotate 5
#       compress
#       delaycompress
#       missingok
#       notifempty
#       create 0640 syslog adm
#       sharedscripts
#       postrotate
#           /usr/bin/systemctl reload rsyslog >/dev/null 2>&1 || true
#       endscript
#   }
#   EOF
#
# Validate logrotate syntax again:
#   logrotate -d /etc/logrotate.d/payment-service
#   logrotate -f /etc/logrotate.d/payment-service
#
# STEP 4: END-TO-END PIPELINE VERIFICATION
# ------------------------------------------------------------------------------
# 1. Verify journal log streaming:
#    journalctl -u payment-service.service -n 10 --no-pager
#
# 2. Verify file log generation by rsyslog:
#    tail -f /var/log/payment-service/payment.log
#
# 3. Verify logrotate execution:
#    ls -la /var/log/payment-service/
#    # Should display payment.log and payment.log.1 (or compressed .gz file)
# ==============================================================================