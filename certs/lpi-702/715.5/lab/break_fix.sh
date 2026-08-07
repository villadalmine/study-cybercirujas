#!/usr/bin/env bash
# ==============================================================================
# CNCF / LPI-702 BSD Specialist Certification (Exam 702-100, Version 1.0)
# Topic 715.5: Perform basic file editing operations
# Exam Weight: 3.34
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
# ==============================================================================
# BREAK & FIX LAB: Production File Editing, Line Editors, and Environment Faults
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/tmp/lpi715_5_lab"
TARGET_CONF="${LAB_DIR}/etc/sysdaemon.conf"
CORRUPT_PATCH="${LAB_DIR}/patches/sysdaemon_v2.patch"
EXRC_FILE="${HOME}/.exrc"
PROFILE_FILE="${LAB_DIR}/etc/profile.d/editor.sh"
BACKUP_DIR="${LAB_DIR}/.backup"

COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[0;36m"
COLOR_RESET="\033[0m"

log_info()  { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $1"; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"; }
log_succ()  { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"; }

init_lab() {
    mkdir -p "${LAB_DIR}/etc" "${LAB_DIR}/patches" "${BACKUP_DIR}"
}

break_environment() {
    init_lab
    log_info "Injecting controlled faults for Topic 715.5 (Perform basic file editing operations)..."

    # Save backups if present
    [ -f "${EXRC_FILE}" ] && cp "${EXRC_FILE}" "${BACKUP_DIR}/.exrc.bak" || true

    # Fault 1: Corrupt vi / ex initialization file (.exrc)
    cat << 'EOF' > "${EXRC_FILE}"
" Broken exrc initialization file
set showmode
set tabstop=4
set invalid_option_flag_8923
set autoindent
EOF

    # Fault 2: Misconfigured environment variables for default editors & terminal capability
    cat << 'EOF' > "${PROFILE_FILE}"
# Global Editor Configuration
export EDITOR="/usr/local/bin/non_existent_editor"
export VISUAL="/bin/false"
export TERM="unknown_vt999_invalid"
EOF

    # Fault 3: Target production config file with syntax error and carriage returns (^M)
    printf "daemon_enable=\"YES\"\r\ndaemon_flags=\"-d -p 8080\"\r\ndaemon_user=\"sysdaemon\"\r\ndaemon_timeout=\"30\"\r\n" > "${TARGET_CONF}"

    # Fault 4: Malformed unified diff patch file for 'patch' utility
    cat << 'EOF' > "${CORRUPT_PATCH}"
--- sysdaemon.conf.orig	2026-08-06 20:00:00.000000000 +0000
+++ sysdaemon.conf	2026-08-06 20:05:00.000000000 +0000
@@ -1,4 +1,4 @@
 daemon_enable="YES"
-daemon_flags="-d -p 8080"
+daemon_flags="-d -p 8443 --ssl"
 daemon_user="sysdaemon"
-daemon_timeout="30"
+daemon_timeout="60"
BAD_LINE_HEADER_MISSING_PLUS_MINUS
EOF

    log_succ "Environment successfully broken!"
    print_briefing
}

print_briefing() {
    cat << EOF

================================================================================
                      LAB TROUBLESHOOTING BRIEFING
================================================================================
Certification Target : LPI-702 (BSD Specialist, Exam 702-100 v1.0)
Topic                : 715.5 Perform basic file editing operations
Weight               : 3.34
Official Docs        : https://www.lpi.org/our-certifications/bsd-specialist-overview/

[SCENARIO]
A junior administrator attempted to update production configuration files using
batch editing scripts, patch utilities, and ex/vi editor configurations. Following
their changes, automated maintenance scripts (crontab, vipw, ee, vi, patch) are 
failing across the system.

[SYMPTOMS]
1. Attempting to run 'vi' or 'ex' emits initialization errors regarding invalid options.
2. Utilities relying on \$EDITOR or \$VISUAL (e.g., 'crontab -e', 'vipw') fail immediately
   or exit silently with return code 1.
3. Interactive visual editors (vi, ee) fail or misbehave due to corrupted TERM definitions.
4. Target config file '${TARGET_CONF}' contains Windows CRLF (\r\n) line endings,
   causing POSIX parser failures.
5. Executing 'patch -p0 < ${CORRUPT_PATCH}' fails with malformed patch format errors.

[STUDENT OBJECTIVES]
1. Fix '${EXRC_FILE}' so 'vi'/'ex' initialize cleanly without startup errors.
2. Source or repair '${PROFILE_FILE}' so \$EDITOR points to 'vi' (or 'ee') and \$VISUAL
   points to 'vi', ensuring terminal capability (\$TERM) is set to a valid terminal 
   type (e.g., 'xterm-256color' or 'vt100').
3. Convert '${TARGET_CONF}' from CRLF format to standard POSIX LF format using line 
   editing tools (sed, tr, or vi/ex non-interactive commands).
4. Repair '${CORRUPT_PATCH}' so that running:
     patch -p0 "${TARGET_CONF}" < "${CORRUPT_PATCH}"
   applies the patch cleanly without reject files (.rej) or syntax errors.

[VERIFICATION]
Run this script with '--verify' to check if your fixes satisfy production criteria.
================================================================================
EOF
}

verify_lab() {
    log_info "Executing verification test suite..."
    local errors=0

    # Test 1: Check .exrc for syntax errors using ex non-interactive execution
    if EXINIT="" ex -s "${TARGET_CONF}" -c "quit" 2>&1 | grep -E -i "unknown|invalid|error" >/dev/null; then
        log_error "Test 1 Failed: ex/vi initialization file (${EXRC_FILE}) still contains invalid parameters."
        errors=$((errors + 1))
    else
        log_succ "Test 1 Passed: ex/vi initialization is clean."
    fi

    # Test 2: Verify environment variables in profile
    source "${PROFILE_FILE}" || true
    if [ "${EDITOR:-}" != "/usr/bin/vi" ] && [ "${EDITOR:-}" != "/usr/bin/ee" ] && [ "${EDITOR:-}" != "/bin/ed" ] && [ "${EDITOR:-}" != "vi" ]; then
        log_error "Test 2 Failed: \$EDITOR in ${PROFILE_FILE} is invalid (${EDITOR:-unset}). Expected 'vi' or 'ee'."
        errors=$((errors + 1))
    elif [ "${TERM:-}" == "unknown_vt999_invalid" ]; then
        log_error "Test 2 Failed: \$TERM is still set to an invalid terminal type (${TERM})."
        errors=$((errors + 1))
    else
        log_succ "Test 2 Passed: Editor and terminal environment variables are properly configured."
    fi

    # Test 3: Check for CRLF (\r) in target config file
    if file "${TARGET_CONF}" | grep -i "CRLF" >/dev/null || grep -q $'\r' "${TARGET_CONF}"; then
        log_error "Test 3 Failed: Target config file (${TARGET_CONF}) still contains CRLF (DOS) line endings."
        errors=$((errors + 1))
    else
        log_succ "Test 3 Passed: Target config file uses clean POSIX LF line endings."
    fi

    # Test 4: Test patch application
    if ! patch --dry-run -s -p0 "${TARGET_CONF}" < "${CORRUPT_PATCH}" >/dev/null 2>&1; then
        log_error "Test 4 Failed: Patch file (${CORRUPT_PATCH}) cannot be applied cleanly to ${TARGET_CONF}."
        errors=$((errors + 1))
    else
        log_succ "Test 4 Passed: Patch file format is syntactically valid and applies cleanly."
    fi

    echo ""
    if [ ${errors} -eq 0 ]; then
        log_succ "=========================================================="
        log_succ " ALL VERIFICATION TESTS PASSED! CONGRATULATIONS!           "
        log_succ " Topic 715.5 File Editing Competency Verified.             "
        log_succ "=========================================================="
    else
        log_error "=========================================================="
        log_error " VERIFICATION FAILED: ${errors} test(s) require attention.   "
        log_error " Review the objectives and try again.                      "
        log_error "=========================================================="
        exit 1
    fi
}

cleanup() {
    log_info "Restoring backup state and cleaning temporary files..."
    rm -rf "${LAB_DIR}"
    if [ -f "${BACKUP_DIR}/.exrc.bak" ]; then
        mv "${BACKUP_DIR}/.exrc.bak" "${EXRC_FILE}"
    else
        rm -f "${EXRC_FILE}"
    fi
    log_succ "Cleanup complete."
}

case "${1:-}" in
    --break)
        break_environment
        ;;
    --verify)
        verify_lab
        ;;
    --clean)
        cleanup
        ;;
    *)
        break_environment
        ;;
esac

# ==============================================================================
# STEP-BY-STEP SOLUTION (EXAM STUDY GUIDE & RECOVERY REFERENCE)
# ==============================================================================
#
# STEP 1: Repair the ex/vi initialization file (~/.exrc)
# ------------------------------------------------------------------------------
# Open ~/.exrc and remove or correct the invalid option line.
# Command:
#   sed -i '' '/invalid_option_flag_8923/d' ~/.exrc
# Or using ex non-interactively:
#   ex -s -c 'g/invalid_option_flag_8923/d' -c 'wq' ~/.exrc
#
# STEP 2: Fix environment variable overrides in profile script
# ------------------------------------------------------------------------------
# Edit /var/tmp/lpi715_5_lab/etc/profile.d/editor.sh to set valid variables:
# Command:
#   cat << 'EOF' > /var/tmp/lpi715_5_lab/etc/profile.d/editor.sh
#   export EDITOR="/usr/bin/vi"
#   export VISUAL="/usr/bin/vi"
#   export TERM="xterm-256color"
#   EOF
#   source /var/tmp/lpi715_5_lab/etc/profile.d/editor.sh
#
# STEP 3: Strip DOS carriage return (^M / \r) characters from target config file
# ------------------------------------------------------------------------------
# Using sed (BSD / POSIX compatible):
#   sed -i '' 's/'"$(printf '\r')"'$//' /var/tmp/lpi715_5_lab/etc/sysdaemon.conf
# Or using tr:
#   tr -d '\r' < /var/tmp/lpi715_5_lab/etc/sysdaemon.conf > /tmp/sysdaemon.tmp \
#     && mv /tmp/sysdaemon.tmp /var/tmp/lpi715_5_lab/etc/sysdaemon.conf
# Or using ex / vi line editor mode:
#   ex -s -c '%s/\r//g' -c 'wq' /var/tmp/lpi715_5_lab/etc/sysdaemon.conf
#
# STEP 4: Repair corrupted unified diff patch file
# ------------------------------------------------------------------------------
# Edit /var/tmp/lpi715_5_lab/patches/sysdaemon_v2.patch to remove the corrupt
# trailing header line 'BAD_LINE_HEADER_MISSING_PLUS_MINUS'.
# Command:
#   sed -i '' '/BAD_LINE_HEADER_MISSING_PLUS_MINUS/d' /var/tmp/lpi715_5_lab/patches/sysdaemon_v2.patch
#
# STEP 5: Apply patch and verify
# ------------------------------------------------------------------------------
# Command:
#   patch -p0 /var/tmp/lpi715_5_lab/etc/sysdaemon.conf < /var/tmp/lpi715_5_lab/patches/sysdaemon_v2.patch
#   /var/tmp/lpi715_5_lab/break_fix.sh --verify
# ==============================================================================