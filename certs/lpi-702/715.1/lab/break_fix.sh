#!/usr/bin/env bash
# ==============================================================================
# LPI 702 BSD Specialist (Exam 702-100 v1.0)
# Topic 715.1: Use the Shell and Work on the Command Line (Weight: 3.33)
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
#
# Production Break & Fix Lab Script
# Target: Disposable BSD / Linux Lab Environment
# ==============================================================================

set -euo pipefail

LAB_DIR="${HOME}/.lpi702_lab_715_1"
PROFILE_TARGET="${HOME}/.profile"
BACKUP_DIR="${LAB_DIR}/backups"

echo "========================================================================"
echo " [LPI 702 - Topic 715.1] SRE Break & Fix Challenge Setup"
echo "========================================================================"

# 1. Environment Preparation and Backups
mkdir -p "${BACKUP_DIR}"

if [[ -f "${PROFILE_TARGET}" ]]; then
    cp "${PROFILE_TARGET}" "${BACKUP_DIR}/.profile.orig"
else
    touch "${BACKUP_DIR}/.profile.orig"
fi

# 2. Injecting Controlled Environment Breaks
# Scenario:
# - Malformed PATH variable removing standard BSD/Linux binary directories (/bin, /sbin, /usr/bin, /usr/sbin).
# - Misconfigured environment variables (TERM set to non-existent entry, SHELL mismatch).
# - Overridden shell builtins/commands via conflicting aliases and function definitions.
# - Corrupted shell history settings and quoting errors in profile startup scripts.

cat << 'EOF' > "${LAB_DIR}/broken_profile_snippet"

# --- LPI 702 BREAKAGE INJECTED BELOW ---
# Issue 1: Path hijacking & truncation (Missing standard POSIX/BSD paths)
export PATH="/opt/custom/bin:/usr/local/games"

# Issue 2: Terminal definition corruption causing tty/ncurses failures
export TERM="unknown-xterm-invalid"

# Issue 3: Command masking via recursive or broken aliases & shell functions
alias ls='ls --color=auto'
alias cat='echo "ERROR: binary corrupted"; false'
which() { echo "which is disabled by policy"; return 1; }

# Issue 4: Exporting invalid variable syntax & quoting mismatch
export HISTFILESIZE=invalid_num
export PS1='[\u@\h \W]\$ '
# --- END BREAKAGE ---
EOF

cat "${LAB_DIR}/broken_profile_snippet" >> "${PROFILE_TARGET}"

# Export current broken environment into a lab subshell environment file
cat << EOF > "${LAB_DIR}/activate_broken_env.sh"
export PATH="/opt/custom/bin:/usr/local/games"
export TERM="unknown-xterm-invalid"
alias cat='echo "ERROR: binary corrupted"; false'
which() { echo "which is disabled by policy"; return 1; }
EOF

echo ""
echo "------------------------------------------------------------------------"
echo " LAB ENVIRONMENT BROKEN SUCCESSFULLY"
echo "------------------------------------------------------------------------"
echo "Symptom Summary for Student:"
echo " 1. Core utilities like 'grep', 'find', 'pkg', or 'sysctl' return 'command not found'."
echo " 2. Standard commands like 'cat' fail with error output."
echo " 3. Command resolution tools like 'which' or 'type' produce unexpected results."
echo " 4. Terminal rendering issues occur due to invalid TERM settings."
echo ""
echo "Student Objectives:"
echo " A. Diagnose the root cause in shell environment variables (PATH, TERM, PS1, aliases, functions)."
echo " B. Locate and fix the corrupted initialization file (~/.profile)."
echo " C. Restore POSIX/BSD standard binary search paths (/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin)."
echo " D. Unset or override broken aliases/functions in the active shell session."
echo " E. Verify fix by executing standard tools, builtins, and subshell executions."
echo ""
echo "To test the broken session in your current shell, run:"
echo "  source ${PROFILE_TARGET}"
echo "------------------------------------------------------------------------"
exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION (STUDENT REFERENCE & RECOVERY)
# ==============================================================================
#
# STEP 1: Inspect current environment variables and search paths
#   $ echo $PATH
#   $ echo $TERM
#
# STEP 2: Use absolute paths to run core commands when PATH is broken
#   $ /bin/cat ~/.profile
#   $ /usr/bin/which ls
#   $ /usr/bin/type cat
#
# STEP 3: Identify active shell aliases and functions masking commands
#   $ alias
#   $ declare -f
#   $ unalias cat
#   $ unset -f which
#
# STEP 4: Temporarily restore working PATH in current session
#   $ export PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
#   $ export TERM="xterm-256color"
#
# STEP 5: Clean up the corrupted startup file (~/.profile)
#   $ cp ~/.lpi702_lab_715_1/backups/.profile.orig ~/.profile
#   OR manually edit ~/.profile to remove the broken snippet:
#   $ vi ~/.profile
#
# STEP 6: Validate shell configuration reloading
#   $ source ~/.profile
#   $ which cat
#   $ type ls
#   $ sysctl -a | head -n 5
# ==============================================================================