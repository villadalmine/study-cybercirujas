#!/usr/bin/env bash
# ==============================================================================
# LPI-702 (BSD Specialist Exam 702-100 v1.0) - Topic 713.4: System Logging
# Advanced Production Break & Fix Laboratory Scenario
# Target OS: FreeBSD / NetBSD / OpenBSD (BSD-family)
# Role: Senior SRE & Principal Platform Architect
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
# WARNING: Run this script ONLY inside a disposable laboratory VM/Container.
# Usage:
#   sudo bash lab_713.4_break_fix.sh          # To inject the fault
#   sudo bash lab_713.4_break_fix.sh --restore  # To restore the original state
# ==============================================================================

set -euo pipefail

BACKUP_DIR="/var/backups/lpi702_topic713.4"
SYSLOG_CONF="/etc/syslog.conf"
RC_CONF="/etc/rc.conf"
NEWSYSLOG_CONF="/etc/newsyslog.conf"
AUTH_LOG="/var/log/auth.log"

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_CYAN="\033[0;36m"
COLOR_RESET="\033[0m"

log_info() {
    printf "${COLOR_CYAN}[INFO]${COLOR_RESET} %s\n" "$1"
}

log_warn() {
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET} %s\n" "$1"
}

log_error() {
    printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$1"
}

log_success() {
    printf "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} %s\n" "$1"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be executed as root (UID 0)."
        exit 1
    fi
}

restore_environment() {
    log_info "Restoring original configuration from ${BACKUP_DIR}..."

    if [ -f "${BACKUP_DIR}/syslog.conf.bak" ]; then
        cp "${BACKUP_DIR}/syslog.conf.bak" "${SYSLOG_CONF}"
        log_info "Restored ${SYSLOG_CONF}"
    fi

    if [ -f "${BACKUP_DIR}/rc.conf.bak" ]; then
        cp "${BACKUP_DIR}/rc.conf.bak" "${RC_CONF}"
        log_info "Restored ${RC_CONF}"
    fi

    if [ -f "${BACKUP_DIR}/newsyslog.conf.bak" ]; then
        cp "${BACKUP_DIR}/newsyslog.conf.bak" "${NEWSYSLOG_CONF}"
        log_info "Restored ${NEWSYSLOG_CONF}"
    fi

    if [ -f "${AUTH_LOG}" ]; then
        chflags noschg "${AUTH_LOG}" 2>/dev/null || true
        chmod 600 "${AUTH_LOG}" 2>/dev/null || true
    fi

    # Restart syslogd service safely across BSD variants
    if command -v service >/dev/null 2>&1; then
        service syslogd restart || true
    elif [ -x /etc/rc.d/syslogd ]; then
        /etc/rc.d/syslogd restart || true
    fi

    log_success "Environment restored to clean baseline state."
    exit 0
}

inject_faults() {
    log_info "Initiating LPI-702 Topic 713.4 Break Scenario..."

    # Step 1: Backup baseline configurations
    mkdir -p "${BACKUP_DIR}"
    [ -f "${SYSLOG_CONF}" ] && cp "${SYSLOG_CONF}" "${BACKUP_DIR}/syslog.conf.bak"
    [ -f "${RC_CONF}" ] && cp "${RC_CONF}" "${BACKUP_DIR}/rc.conf.bak"
    [ -f "${NEWSYSLOG_CONF}" ] && cp "${NEWSYSLOG_CONF}" "${BACKUP_DIR}/newsyslog.conf.bak"

    # Step 2: Inject Break #1 - Syntax & Space-separation breakage in syslog.conf
    # BSD syslogd requires strictly TAB separators between selector and action target.
    # We replace TAB with spaces and introduce an invalid facility selector alias.
    log_info "Injecting misconfiguration into ${SYSLOG_CONF}..."
    cat << 'EOF' > "${SYSLOG_CONF}"
# LPI-702 Laboratory System Logging Configuration
*.err;kern.warning;auth.notice;mail.crit              /dev/console
*.notice;auth.none;kernel.none;mail.none;cron.none    /var/log/messages
security.*                                            /var/log/security
auth.info;authpriv.info                               /var/log/auth.log
mail.info                                             /var/log/maillog
lpr.info                                              /var/log/lpd-errs
ftp.info                                              /var/log/xferlog
cron.*                                                /var/log/cron
!-devd
*.emerg                                               *
# Fault 1A: Spaces used instead of strict TAB delimiters on remote logger target
local0.info                                    @192.168.1.50
# Fault 1B: Invalid selector delimiter and malformed priority
authpriv.*                                    /var/log/auth.log
EOF

    # Step 3: Inject Break #2 - Modify /etc/rc.conf daemon flags
    # We pass '-s -s -u' flags to syslogd via rc.conf.
    # '-s -s' forces maximum security mode, binding NO network sockets (disabling UDP syslog receive).
    # '-u' disables the default local domain socket (/var/run/log or /dev/log), breaking local 'logger' CLI.
    log_info "Injecting breaking flags into ${RC_CONF}..."
    if grep -q "syslogd_flags=" "${RC_CONF}"; then
        sed -i '' 's/syslogd_flags=.*/syslogd_flags="-s -s -u"/' "${RC_CONF}"
    else
        echo 'syslogd_flags="-s -s -u"' >> "${RC_CONF}"
    fi

    # Step 4: Inject Break #3 - File Flags / Immutable attribute on target log file
    # Sets System Immutable flag (schg) on auth.log to prevent writes/rotations even by root.
    touch "${AUTH_LOG}"
    chmod 600 "${AUTH_LOG}"
    if command -v chflags >/dev/null 2>&1; then
        chflags schg "${AUTH_LOG}" 2>/dev/null || true
    fi

    # Step 5: Restart daemon to apply broken state
    log_info "Restarting syslogd daemon..."
    if command -v service >/dev/null 2>&1; then
        service syslogd restart || true
    elif [ -x /etc/rc.d/syslogd ]; then
        /etc/rc.d/syslogd restart || true
    fi

    cat << EOF

================================================================================
  [LAB BROKEN] LPI-702 Topic 713.4: System Logging Diagnostic Challenge
================================================================================

INCIDENT TICKET: #INC-7134-8902
SEVERITY: P1 - Critical Telemetry Breakdown
AFFECTED SERVICE: BSD Native Logging Subsystem (syslogd / newsyslog)

INCIDENT SUMMARY:
The SIEM operations team reports that local security authentication logs are no
longer recorded in /var/log/auth.log. Simultaneously, the remote log collector
(192.168.1.50) has lost telemetry from this BSD node. Furthermore, SRE engineers
attempting to send test messages via the 'logger' utility get write errors or silence.

STUDENT OBJECTIVES:
1. Identify why local processes sending logs via 'logger' or Unix domain sockets
   fail to communicate with syslogd.
2. Fix syslogd runtime flags so local Unix domain sockets and UDP syslog input
   operate according to BSD standards.
3. Diagnose and fix parsing issues inside /etc/syslog.conf (delimiter & selector rules).
4. Resolve file permission/flag impediments blocking syslogd from appending to
   /var/log/auth.log.
5. Validate newsyslog dry-run behavior for log rotation compliance.

DIAGNOSTIC VERIFICATION COMMANDS TO EXECUTE:
  $ logger -p auth.info "Test LPI-702 Auth Log Message"
  $ sockstat -4 -6 -c -l -p 514 -u
  $ syslogd -d
  $ newsyslog -n -v -f /etc/newsyslog.conf

Do NOT run --restore until you have diagnosed and attempted to fix the environment!
================================================================================
EOF
}

if [ "${1:-}" = "--restore" ]; then
    check_root
    restore_environment
else
    check_root
    inject_faults
fi

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & TECHNICAL ARCHITECTURE REFERENCE
# (Keep commented out for self-assessment)
# ==============================================================================
#
# ROOT CAUSE ANALYSIS (RCA) & BSD MECHANICS:
#
# 1. Daemon Flag Misconfiguration (/etc/rc.conf):
#    - 'syslogd_flags="-s -s -u"' was injected into /etc/rc.conf.
#    - In BSD syslogd:
#        * '-s' (single) puts syslogd in secure mode (does not listen on UDP port 514 for remote logs).
#        * '-s -s' (double) prevents syslogd from binding ANY network socket, breaking network-based logging.
#        * '-u' disables listening on the local Unix domain socket (/var/run/log or /dev/log).
#          Because 'logger' and libc syslog() write to /var/run/log, '-u' renders local socket logging impossible.
#    - FIX: Change syslogd_flags in /etc/rc.conf to allowable parameters (e.g. syslogd_flags="-ss" if isolated,
#      or syslogd_flags="-4" / syslogd_flags="" depending on networking requirements).
#
# 2. Syntax & Delimiter Errors in /etc/syslog.conf:
#    - Traditional BSD syslogd parser strictly enforces TAB characters ('\t') between log selectors
#      (e.g., auth.info) and action destinations (e.g., /var/log/auth.log or @192.168.1.50). Using spaces
#      causes syslogd to misinterpret or ignore the line completely.
#    - Selector 'authpriv.info' is invalid in standard BSD syslogd (unlike Linux rsyslog where authpriv is common).
#      BSD uses 'auth.info' or 'security.*'.
#    - FIX: Convert space-separated action fields to true TAB characters in /etc/syslog.conf. Correct invalid selectors.
#
# 3. System File Flags (chflags):
#    - The file /var/log/auth.log was locked with the system immutable flag 'schg' (System Immutable).
#    - Even root cannot write to, truncate, or append to a file marked with 'schg' when securelevel >= 1.
#    - FIX: Execute 'chflags noschg /var/log/auth.log' to clear the immutable flag.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP RESOLUTION PROCEDURE:
# ------------------------------------------------------------------------------
#
# Step 1: Diagnose socket listening status
#   # sockstat -u -l -j 0 | grep syslogd
#   (Notice no /var/run/log socket listed because of -u flag)
#
# Step 2: Fix /etc/rc.conf flags
#   # sysrc syslogd_flags="-v"
#   OR manually edit /etc/rc.conf to remove "-s -s -u" from syslogd_flags.
#
# Step 3: Remove System Immutable File Flag on auth.log
#   # ls -lo /var/log/auth.log
#   (Output displays 'schg')
#   # chflags noschg /var/log/auth.log
#   # chmod 600 /var/log/auth.log
#
# Step 4: Fix /etc/syslog.conf syntax
#   Edit /etc/syslog.conf:
#   - Replace all space gaps between selectors and filenames/IP targets with TAB characters:
#     local0.info<TAB><TAB>@192.168.1.50
#     auth.info<TAB><TAB>/var/log/auth.log
#   - Remove unparseable 'authpriv.*' line or change to valid BSD facility 'auth.info;auth.notice'.
#
# Step 5: Validate and Restart syslogd
#   # syslogd -d  (Runs in foreground debug mode to verify rule ingestion without parsing errors)
#   # service syslogd restart
#
# Step 6: Verify Log Ingestion and Rotation
#   # logger -p auth.info "LPI-702 Verification Successful"
#   # tail -n 1 /var/log/auth.log
#   (Expected output: timestamp host logger: LPI-702 Verification Successful)
#   # newsyslog -n -v -f /etc/newsyslog.conf
#   (Verifies log rotation syntax and schedule without actually rotating files)
# ==============================================================================