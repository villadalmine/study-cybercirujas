#!/usr/bin/env bash
# ==============================================================================
# LPI-702: BSD Specialist Certification (Exam 702-100, Version 1.0)
# Topic 715.4: Use Simple Regular Expressions (Weight: 3.33)
# Official Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
#
# Production SRE Break & Fix Lab: BSD Authentication & Syslog Parser Fix
#
# Scenario:
# You are a Senior SRE managing BSD fleet infrastructure. A critical log parser
# pipeline script (`/tmp/lpi702_regex_lab/audit_pipeline.sh`) was written to parse
# BSD `/var/log/auth.log` files to extract failed login IP addresses, filter
# suspicious admin account names, and isolate process IDs (PIDs) for security audit.
#
# Due to several flawed Regular Expressions (BRE & ERE syntax errors, improper
# quantifier bounds, unescaped literals, missing anchors, and incorrect sed group
# capturing), the audit pipeline script is producing false positives and dropping
# critical audit metrics.
#
# Environment Safety:
# This script executes safely inside `/tmp/lpi702_regex_lab/` without modifying
# any global BSD system configurations or persistent log files.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi702_regex_lab"

echo "[+] Initializing LPI-702 Topic 715.4 Break & Fix Laboratory Environment..."

mkdir -p "${LAB_DIR}"

# ------------------------------------------------------------------------------
# Generate Synthetic BSD Authentication Log Data (/var/log/auth.log structure)
# ------------------------------------------------------------------------------
cat <<'EOF' > "${LAB_DIR}/auth.log"
Aug  6 12:01:02 bsd-host sshd[4012]: Failed password for root from 192.168.1.50 port 54321 ssh2
Aug  6 12:01:05 bsd-host sshd[4013]: Failed password for invalid user admin_123 from 10.0.45.999 port 54322 ssh2
Aug  6 12:01:10 bsd-host sshd[4014]: Accepted publickey for admin_999999 from 172.16.0.5 port 54323 ssh2
Aug  6 12:01:15 bsd-host sshd[4015]: Failed password for invalid user admin_4567 from 10.0.12.34 port 54324 ssh2
Aug  6 12:02:01 bsd-host cron[8812]: (root) CMD (/usr/libexec/atrun)
Aug  6 12:02:10 bsd-host newsyslog[8901]: logfile turned over
Aug  6 12:03:00 bsd-host sshd[4016]: Failed password for invalid user baduser_12 from 192.168.1.256 port 54325 ssh2
Aug  6 12:03:15 bsd-host pflogd[1042]: 2026-08-06 12:03:15.123456 rule 0/0(match): block in on em0: 192.168.1.50.80 > 10.0.0.1.443
EOF

# ------------------------------------------------------------------------------
# Create Broken Audit Pipeline Script
# ------------------------------------------------------------------------------
cat <<'EOF' > "${LAB_DIR}/audit_pipeline.sh"
#!/usr/bin/env bash
# Broken Audit Pipeline Script - Regular Expression Remediation Required

LOG_FILE="/tmp/lpi702_regex_lab/auth.log"

echo "=== Running Audit Pipeline Validation ==="
ERRORS=0

# ------------------------------------------------------------------------------
# Task 1: Strict IPv4 Extraction for Failed SSH Passwords
# Requirement: Match valid IPv4 addresses (octets between 0 and 255).
#               Exclude invalid IP strings such as 10.0.45.999 or 192.168.1.256.
# BROKEN REGEX: Uses naive quantifier `[0-9]+` with unescaped dots, capturing 999 & 256.
# ------------------------------------------------------------------------------
echo -n "[Testing Task 1 - Valid Failed SSH IPv4 Extraction] ... "
VALID_IPS=$(grep -E 'Failed password.*from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "${LOG_FILE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)

EXPECTED_IP_COUNT=2
ACTUAL_IP_COUNT=0

for ip in ${VALID_IPS}; do
  IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
  if [ "${o1}" -le 255 ] && [ "${o2}" -le 255 ] && [ "${o3}" -le 255 ] && [ "${o4}" -le 255 ]; then
    ACTUAL_IP_COUNT=$((ACTUAL_IP_COUNT + 1))
  else
    echo -e "\n[!] FAILURE: Regex matched out-of-range IP address: ${ip}"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ "${ACTUAL_IP_COUNT}" -eq "${EXPECTED_IP_COUNT}" ] && [ "${ERRORS}" -eq 0 ]; then
  echo "PASS"
else
  echo "FAIL (Captured invalid IPv4 octets)"
  ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------------------------------------------
# Task 2: Suspicious Admin Username Filter
# Requirement: Match usernames starting with "admin_" followed by EXACTLY 3 to 5 digits.
#               Valid match examples: admin_123, admin_4567.
#               Invalid match examples: admin_999999 (6 digits, should NOT match).
# BROKEN REGEX: Uses un-bounded quantifier `admin_[0-9]+` matching any digit count.
# ------------------------------------------------------------------------------
echo -n "[Testing Task 2 - Suspicious Username Bounding] ... "
MATCHED_USERS=$(grep -E 'admin_[0-9]+' "${LOG_FILE}" | grep -oE 'admin_[0-9]+' || true)

EXPECTED_USERS="admin_123 admin_4567"
ACTUAL_USERS=$(echo "${MATCHED_USERS}" | tr '\n' ' ' | xargs)

if [ "${ACTUAL_USERS}" = "${EXPECTED_USERS}" ]; then
  echo "PASS"
else
  echo "FAIL"
  echo "  Expected: ${EXPECTED_USERS}"
  echo "  Got:      ${ACTUAL_USERS}"
  ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------------------------------------------
# Task 3: Extract SSHD Daemon PIDs using sed
# Requirement: Parse log lines containing sshd and extract ONLY the numerical PID.
#               Target output lines: 4012, 4013, 4014, 4015, 4016.
# BROKEN REGEX: Incorrect BRE group parentheses escaping and missing replacement scope.
# ------------------------------------------------------------------------------
echo -n "[Testing Task 3 - Daemon PID Extraction via sed] ... "
EXTRACTED_PIDS=$(sed -n 's/.*sshd[\([0-9]\+\)]:/\1/p' "${LOG_FILE}" || true)

EXPECTED_PIDS="4012
4013
4014
4015
4016"

if [ "${EXTRACTED_PIDS}" = "${EXPECTED_PIDS}" ]; then
  echo "PASS"
else
  echo "FAIL"
  echo "  Expected PIDs:"
  echo "${EXPECTED_PIDS}"
  echo "  Got PIDs:"
  echo "${EXTRACTED_PIDS}"
  ERRORS=$((ERRORS + 1))
fi

echo "=========================================="
if [ "${ERRORS}" -eq 0 ]; then
  echo "RESULT: ALL AUDIT CHECKS PASSED SUCCESSFULLY!"
  exit 0
else
  echo "RESULT: AUDIT PIPELINE FAILED WITH ${ERRORS} ERROR(S)."
  exit 1
fi
EOF

chmod +x "${LAB_DIR}/audit_pipeline.sh"

echo "[+] Lab Environment Setup Complete."
echo ""
echo "=========================================================================="
echo " INSTRUCTORS BRIEFING & STUDENT OBJECTIVES"
echo "=========================================================================="
echo "Target Audit Script : ${LAB_DIR}/audit_pipeline.sh"
echo "Target Log Dataset  : ${LAB_DIR}/auth.log"
echo ""
echo "Symptom Verification Output:"
"${LAB_DIR}/audit_pipeline.sh" || true
echo ""
echo "Student Tasks to Achieve Fix:"
echo "1. Task 1 (Strict IPv4 Regex): Update grep ERE pattern to validate octets"
echo "   ranging from 0-255 using regex alternation (e.g. 25[0-5]|2[0-4][0-9]|...)."
echo "2. Task 2 (Quantifier Bounding): Use explicit range quantification {3,5}"
echo "   and word boundaries \\b to filter out admin_999999."
echo "3. Task 3 (Sed Group Capturing): Fix sed BRE syntax \\(...\\) or switch to"
echo "   sed Extended Regular Expression flag (-E / -r) to cleanly extract SSHD PIDs."
echo "4. Execute ${LAB_DIR}/audit_pipeline.sh until all tests pass."
echo "=========================================================================="

# ==============================================================================
# INSTRUCTOR & STUDENT SOLUTION GUIDE (STEP-BY-STEP)
# ==============================================================================
#
# To manually resolve the Break & Fix lab, inspect and modify the regular
# expressions in `/tmp/lpi702_regex_lab/audit_pipeline.sh`:
#
# ------------------------------------------------------------------------------
# 1. TASK 1 SOLUTION (Strict IPv4 Octet Matching 0-255 in ERE)
# ------------------------------------------------------------------------------
# Explanation:
# The pattern `[0-9]+` matches 1 or more digits, allowing `999` and `256`.
# A standard POSIX ERE regex for an IPv4 octet (0 to 255) uses alternation:
#   (25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)
#
# Replace the grep matching lines in Task 1 with:
#
# OCTET='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
# IPV4_REGEX="${OCTET}\.${OCTET}\.${OCTET}\.${OCTET}"
# VALID_IPS=$(grep -E "Failed password.*from ${IPV4_REGEX}" "${LOG_FILE}" | grep -oE "${IPV4_REGEX}" || true)
#
# ------------------------------------------------------------------------------
# 2. TASK 2 SOLUTION (Quantifier Bounding & Word Anchors)
# ------------------------------------------------------------------------------
# Explanation:
# `admin_[0-9]+` matches `admin_999999` because `+` is unbounded greedy matching.
# Using POSIX ERE interval quantifiers `{3,5}` with word boundaries `\b`:
#   \badmin_[0-9]{3,5}\b
#
# Replace the grep matching line in Task 2 with:
#
# MATCHED_USERS=$(grep -E '\badmin_[0-9]{3,5}\b' "${LOG_FILE}" | grep -oE '\badmin_[0-9]{3,5}\b' || true)
#
# ------------------------------------------------------------------------------
# 3. TASK 3 SOLUTION (BSD/POSIX sed Group Capture Mechanics)
# ------------------------------------------------------------------------------
# Explanation:
# Standard BSD `sed` defaults to Basic Regular Expressions (BRE).
# In BRE:
#   - Group capturing requires escaped parentheses: `\(` and `\)`
#   - Unescaped `(` or `[` causes regex execution failure or literal character matching.
#   - One-or-more quantifier in BRE requires `[0-9][0-9]*` or using `sed -E` (ERE).
#
# Option A (Standard POSIX BRE sed):
# EXTRACTED_PIDS=$(sed -n 's/.*sshd\[\([0-9][0-9]*\)\]:.*/\1/p' "${LOG_FILE}" || true)
#
# Option B (POSIX Extended Regular Expressions sed -E):
# EXTRACTED_PIDS=$(sed -nE 's/.*sshd\[([0-9]+)\]:.*/\1/p' "${LOG_FILE}" || true)
#
# ------------------------------------------------------------------------------
# AUTOMATED ONE-LINER SOLUTION PATCH (RUN TO APPLY SOLUTION):
# ------------------------------------------------------------------------------
# cat << 'EOF_SOLUTION' > /tmp/lpi702_regex_lab/audit_pipeline.sh
# #!/usr/bin/env bash
# LOG_FILE="/tmp/lpi702_regex_lab/auth.log"
# echo "=== Running Audit Pipeline Validation ==="
# ERRORS=0
#
# echo -n "[Testing Task 1 - Valid Failed SSH IPv4 Extraction] ... "
# OCTET='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
# IPV4_REGEX="${OCTET}\.${OCTET}\.${OCTET}\.${OCTET}"
# VALID_IPS=$(grep -E "Failed password.*from ${IPV4_REGEX}" "${LOG_FILE}" | grep -oE "${IPV4_REGEX}" || true)
# EXPECTED_IP_COUNT=2
# ACTUAL_IP_COUNT=0
# for ip in ${VALID_IPS}; do
#   IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
#   if [ "${o1}" -le 255 ] && [ "${o2}" -le 255 ] && [ "${o3}" -le 255 ] && [ "${o4}" -le 255 ]; then
#     ACTUAL_IP_COUNT=$((ACTUAL_IP_COUNT + 1))
#   else
#     ERRORS=$((ERRORS + 1))
#   fi
# done
# if [ "${ACTUAL_IP_COUNT}" -eq "${EXPECTED_IP_COUNT}" ] && [ "${ERRORS}" -eq 0 ]; then
#   echo "PASS"
# else
#   echo "FAIL"
#   ERRORS=$((ERRORS + 1))
# fi
#
# echo -n "[Testing Task 2 - Suspicious Username Bounding] ... "
# MATCHED_USERS=$(grep -E '\badmin_[0-9]{3,5}\b' "${LOG_FILE}" | grep -oE '\badmin_[0-9]{3,5}\b' || true)
# EXPECTED_USERS="admin_123 admin_4567"
# ACTUAL_USERS=$(echo "${MATCHED_USERS}" | tr '\n' ' ' | xargs)
# if [ "${ACTUAL_USERS}" = "${EXPECTED_USERS}" ]; then
#   echo "PASS"
# else
#   echo "FAIL"
#   ERRORS=$((ERRORS + 1))
# fi
#
# echo -n "[Testing Task 3 - Daemon PID Extraction via sed] ... "
# EXTRACTED_PIDS=$(sed -nE 's/.*sshd\[([0-9]+)\]:.*/\1/p' "${LOG_FILE}" || true)
# EXPECTED_PIDS="4012
# 4013
# 4014
# 4015
# 4016"
# if [ "${EXTRACTED_PIDS}" = "${EXPECTED_PIDS}" ]; then
#   echo "PASS"
# else
#   echo "FAIL"
#   ERRORS=$((ERRORS + 1))
# fi
#
# echo "=========================================="
# if [ "${ERRORS}" -eq 0 ]; then
#   echo "RESULT: ALL AUDIT CHECKS PASSED SUCCESSFULLY!"
#   exit 0
# else
#   echo "RESULT: AUDIT PIPELINE FAILED WITH ${ERRORS} ERROR(S)."
#   exit 1
# fi
# EOF_SOLUTION
# chmod +x /tmp/lpi702_regex_lab/audit_pipeline.sh
# /tmp/lpi702_regex_lab/audit_pipeline.sh
# ==============================================================================