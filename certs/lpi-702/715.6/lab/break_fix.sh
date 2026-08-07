#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (702-100) - Topic 715.6: Customize or Write Simple Scripts
# Exam Weight: 3.34
# Official References:
#   - https://www.lpi.org/our-certifications/bsd-specialist-overview/
#   - https://www.gnu.org/software/bash/manual/bash.html
# ==============================================================================
# LAB SCENARIO: PRODUCTION LOG AGGREGATION & SERVICE HEALTH CHECK SCRIPT
# ------------------------------------------------------------------------------
# Author: Senior SRE & Principal Platform Architect
# System Requirements: Linux/BSD VM with Bash 4.4+ installed.
# Safe Execution: Creates isolated lab directory under /tmp/lpi_715_6_lab
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_715_6_lab"
TARGET_SCRIPT="${LAB_DIR}/bin/telemetry_processor.sh"
LOG_SOURCE_DIR="${LAB_DIR}/var/log/services"
METRICS_OUT_DIR="${LAB_DIR}/var/metrics"

# Color formatting for terminal output
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function print_header() {
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${BLUE}  LPI 702-100 Topic 715.6 - Break & Fix Laboratory Setup${NC}"
    echo -e "${BLUE}======================================================================${NC}"
}

function setup_environment() {
    echo -e "${YELLOW}[+] Preparing isolated lab environment in ${LAB_DIR}...${NC}"
    rm -rf "${LAB_DIR}"
    mkdir -p "${LAB_DIR}/bin" "${LOG_SOURCE_DIR}" "${METRICS_OUT_DIR}"

    # Generate synthetic log files with realistic edge cases (spaces in filenames, zero errors, high volume)
    cat <<'EOF' > "${LOG_SOURCE_DIR}/auth_service.log"
2026-08-07T03:00:01Z [INFO] User login attempt uid=1002
2026-08-07T03:00:02Z [WARN] Rate limit threshold reached for IP 192.168.1.50
2026-08-07T03:00:05Z [INFO] User login success uid=1002
EOF

    cat <<'EOF' > "${LOG_SOURCE_DIR}/payment gateway API.log"
2026-08-07T03:01:00Z [INFO] Processing transaction tx_9921
2026-08-07T03:01:02Z [ERROR] Gateway timeout responding to bank endpoint
2026-08-07T03:01:03Z [ERROR] Failed retry 1 for tx_9921
EOF

    cat <<'EOF' > "${LOG_SOURCE_DIR}/database_pool.log"
2026-08-07T03:02:10Z [INFO] Pool size 20, active connections 4
2026-08-07T03:02:15Z [INFO] Health check ping latency 1.2ms
EOF

    # Create the BROKEN script that the student must fix
    cat <<'EOF' > "${TARGET_SCRIPT}"
#!/usr/bin/env bash
# BROKEN PRODUCTION TELEMETRY PROCESSOR SCRIPT
# Topic 715.6 - Student Task: Fix bugs and make script production-grade.

set -e

LOG_DIR=""
OUTPUT_DIR=""
VERBOSE=0

# Parse options
while getopts "l:o:v" opt; do
  case $opt in
    l) LOG_DIR=$OPTARG ;;
    o) OUTPUT_DIR=$OPTARG ;;
    v) VERBOSE=1 ;;
  esac
done

# Bug 1: Hardcoded unsafe temporary file creation instead of mktemp
TEMP_FILE="/tmp/telemetry_working_scratch.tmp"

# Bug 2: Unquoted variable expansion and ls-parsing causes failure on spaces in filenames
LOG_FILES=$(ls $LOG_DIR/*.log)

TOTAL_ERRORS=0
PROCESSED_FILES=0

echo "Beginning telemetry processing..." > $TEMP_FILE

for file in $LOG_FILES; do
    echo "Processing $file" >> $TEMP_FILE
    
    # Bug 3: grep returning 1 when no ERROR is found combined with set -e causes premature exit
    # Bug 4: Subshell execution via pipe resets TOTAL_ERRORS inside the loop
    grep "ERROR" $file | while read -r line; do
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        echo "Found error: $line" >> $TEMP_FILE
    done

    PROCESSED_FILES=$((PROCESSED_FILES + 1))
done

# Write final metrics summary
# Bug 5: No validation of required arguments, no cleanup trap for $TEMP_FILE
cat <<REPORT > ${OUTPUT_DIR}/summary.json
{
  "processed_files": ${PROCESSED_FILES},
  "total_errors": ${TOTAL_ERRORS},
  "status": "COMPLETED"
}
REPORT

rm -f $TEMP_FILE
exit 0
EOF

    chmod +x "${TARGET_SCRIPT}"
    echo -e "${GREEN}[+] Environment ready. Broken script written to ${TARGET_SCRIPT}${NC}\n"
}

function print_lab_instructions() {
    print_header
    cat <<EOF
SRE / DEVOPS PROBLEM STATEMENT:
------------------------------------------------------------------------------
The automated telemetry processor script (${TARGET_SCRIPT}) is responsible for 
scanning service log files, parsing ERROR occurrences, and writing a clean JSON 
summary report to disk.

When deployed in production, the script silently fails, leaves stray lock/scratch 
files in /tmp, produces invalid metrics (0 errors reported), and crashes 
abruptly whenever a clean log file (with no ERROR lines) or filenames with spaces 
are encountered.

SYMPTOMS OBSERVED IN PRODUCTION:
1. Script crashes immediately on clean logs (e.g., database_pool.log).
2. Word splitting breaks processing for 'payment gateway API.log'.
3. The resulting summary.json always reports total_errors: 0 due to subshell scoping.
4. Temporary file collision vulnerability in multi-tenant runners.
5. Exit status is non-zero on clean log scans, causing CI/CD pipeline triggers to fail.

YOUR OBJECTIVE:
Refactor and fix '${TARGET_SCRIPT}' so that:
- It uses 'getopts' with proper flag validation (-l <log_dir>, -o <out_dir>).
- Employs 'mktemp' for secure temporary file creation and sets up an explicit 'trap' 
  to clean up temporary files on EXIT/SIGINT/SIGTERM.
- Implements robust Bash array expansion to safely handle whitespace in paths.
- Avoids pipeline subshell variable loss during line count aggregation.
- Properly handles 'grep' return codes without prematurely terminating under 'set -e'.
- Implements 'set -euo pipefail' for deterministic error propagation.

TEST YOUR FIX:
Run the script manually:
  ${TARGET_SCRIPT} -l ${LOG_SOURCE_DIR} -o ${METRICS_OUT_DIR}

VERIFY SOLUTION:
Run this lab setup script with the --verify flag:
  $0 --verify

------------------------------------------------------------------------------
EOF
}

function verify_solution() {
    print_header
    echo -e "${YELLOW}[*] Running SRE Automated Verification Suite against ${TARGET_SCRIPT}...${NC}\n"

    if [[ ! -f "${TARGET_SCRIPT}" ]]; then
        echo -e "${RED}[FAIL] Target script ${TARGET_SCRIPT} does not exist.${NC}"
        exit 1
    fi

    # Test 1: Run execution against the generated lab files
    rm -f "${METRICS_OUT_DIR}/summary.json"
    
    set +e
    EXEC_OUTPUT=$("${TARGET_SCRIPT}" -l "${LOG_SOURCE_DIR}" -o "${METRICS_OUT_DIR}" 2>&1)
    EXIT_CODE=$?
    set -e

    if [[ $EXIT_CODE -ne 0 ]]; then
        echo -e "${RED}[FAIL] Script failed with non-zero exit code: ${EXIT_CODE}${NC}"
        echo -e "${RED}Execution log:${NC}\n${EXEC_OUTPUT}"
        exit 1
    fi
    echo -e "${GREEN}[PASS] Script executed with exit code 0.${NC}"

    # Test 2: Verify summary.json content correctness
    SUMMARY_FILE="${METRICS_OUT_DIR}/summary.json"
    if [[ ! -f "${SUMMARY_FILE}" ]]; then
        echo -e "${RED}[FAIL] ${SUMMARY_FILE} was not created.${NC}"
        exit 1
    fi

    PROCESSED_COUNT=$(grep -o '"processed_files": [0-9]*' "${SUMMARY_FILE}" | grep -o '[0-9]*' || true)
    TOTAL_ERRORS_COUNT=$(grep -o '"total_errors": [0-9]*' "${SUMMARY_FILE}" | grep -o '[0-9]*' || true)

    if [[ "${PROCESSED_COUNT}" -ne 3 ]]; then
        echo -e "${RED}[FAIL] Incorrect processed_files count: expected 3, got '${PROCESSED_COUNT}' (whitespace/globbing issue).${NC}"
        exit 1
    fi
    echo -e "${GREEN}[PASS] Correctly processed all 3 log files (handles spaces in path names).${NC}"

    if [[ "${TOTAL_ERRORS_COUNT}" -ne 2 ]]; then
        echo -e "${RED}[FAIL] Incorrect total_errors count: expected 2, got '${TOTAL_ERRORS_COUNT}' (subshell variable scope bug).${NC}"
        exit 1
    fi
    echo -e "${GREEN}[PASS] Accurately aggregated 2 ERROR lines across all files.${NC}"

    # Test 3: Temporary file leak verification
    LEAKED_TMP=$(find /tmp -maxdepth 1 -name "telemetry_working_scratch.tmp" 2>/dev/null | wc -l)
    if [[ "${LEAKED_TMP}" -gt 0 ]]; then
        echo -e "${RED}[FAIL] Found legacy hardcoded temporary file /tmp/telemetry_working_scratch.tmp. Must use mktemp + trap cleanup.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[PASS] No predictable hardcoded temporary file leaks detected.${NC}"

    echo -e "\n${GREEN}======================================================================${NC}"
    echo -e "${GREEN}  CONGRATULATIONS! Solution verified successfully.${NC}"
    echo -e "${GREEN}  Topic 715.6 Scripting requirements fully met.${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    exit 0
}

# Main execution router
if [[ "${1:-}" == "--verify" ]]; then
    verify_solution
else
    setup_environment
    print_lab_instructions
fi

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & DEEP TECHNICAL ANALYSIS
# ==============================================================================
# (Keep this commented out for student self-study)
#
# STEP 1: UNDERSTANDING THE MECHANICAL FAILURES & DEVOPS TRAPS
# ------------------------------------------------------------------------------
# Bug 1: `set -e` vs `grep` return codes
# Mechanics: In Bash, `set -e` (errexit) causes the shell to exit immediately if
# a pipeline or simple command returns a non-zero exit status. `grep` returns 0 
# if a match is found, 1 if no match is found, and >1 for errors. When processing
# 'auth_service.log' (which contains zero ERROR lines), `grep "ERROR" file` 
# evaluates to exit code 1. `set -e` triggers immediately and aborts the script.
# Remediation: Use `grep "ERROR" "$file" || true` or process file line-by-line using 
# native Bash pattern matching [[ "$line" =~ ERROR ]].
#
# Bug 2: Subshell Variable Isolation in Pipelines
# Mechanics: In standard POSIX shell & Bash, each command in a pipeline 
# (`cmd1 | cmd2`) runs in a separate subshell environment. Modifications to 
# variables inside a `while read` loop piped from `grep` (`grep ... | while ...`) 
# alter the subshell's variable copy. Once the pipeline terminates, the parent 
# shell retains the original value of `TOTAL_ERRORS=0`.
# Remediation: Use process substitution `< <(grep ...)` or read directly from the file.
#
# Bug 3: Word Splitting & Unquoted Globbing
# Mechanics: `LOG_FILES=$(ls $LOG_DIR/*.log)` fails catastrophically when paths contain
# spaces (e.g. 'payment gateway API.log'). The shell splits the output on IFS (space/tab/newline),
# passing 'payment', 'gateway', and 'API.log' as separate non-existent parameters.
# Remediation: Use Bash arrays with nullglob: `shopt -s nullglob; LOG_FILES=("${LOG_DIR}"/*.log)`
#
# Bug 4: Insecure Temporary Files & Signal Traps
# Mechanics: Hardcoded paths like `/tmp/telemetry_working_scratch.tmp` are subject 
# to symlink attacks, permission conflicts, and dirty state persistence if the 
# script crashes before reaching `rm -f`.
# Remediation: Create temp file via `TEMP_FILE=$(mktemp)` and register cleanup:
# `trap 'rm -f "${TEMP_FILE}"' EXIT INT TERM`
#
# ------------------------------------------------------------------------------
# FULLY SYNTACTICALLY VALID & PRODUCTION-READY REFACTORED SCRIPT SOLUTION:
# ------------------------------------------------------------------------------
#
# #!/usr/bin/env bash
# set -euo pipefail
# shopt -s nullglob
#
# LOG_DIR=""
# OUTPUT_DIR=""
# VERBOSE=0
#
# function usage() {
#     echo "Usage: $0 -l <log_dir> -o <output_dir> [-v]" >&2
#     exit 1
# }
#
# while getopts "l:o:v" opt; do
#   case "${opt}" in
#     l) LOG_DIR="${OPTARG}" ;;
#     o) OUTPUT_DIR="${OPTARG}" ;;
#     v) VERBOSE=1 ;;
#     *) usage ;;
#   esac
# done
#
# if [[ -z "${LOG_DIR}" || -z "${OUTPUT_DIR}" ]]; then
#     echo "Error: Missing required arguments." >&2
#     usage
# fi

# if [[ ! -d "${LOG_DIR}" ]]; then
#     echo "Error: Log directory ${LOG_DIR} does not exist." >&2
#     exit 1
# fi
#
# mkdir -p "${OUTPUT_DIR}"
#
# # Secure temp file creation and cleanup trap
# TEMP_FILE=$(mktemp /tmp/telemetry_proc.XXXXXX)
# trap 'rm -f "${TEMP_FILE}"' EXIT INT TERM
#
# # Safe array population handling spaces in paths
# LOG_FILES=("${LOG_DIR}"/*.log)
#
# if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
#     echo "Warning: No log files found in ${LOG_DIR}" >&2
# fi
#
# TOTAL_ERRORS=0
# PROCESSED_FILES=0
#
# echo "Beginning telemetry processing..." > "${TEMP_FILE}"
#
# for file in "${LOG_FILES[@]}"; do
#     [[ -f "${file}" ]] || continue
#     ((PROCESSED_FILES++))
#     
#     if [[ ${VERBOSE} -eq 1 ]]; then
#         echo "Processing ${file}" >> "${TEMP_FILE}"
#     fi
#     
#     # Process substitution keeps 'while' loop in current shell context (no subshell)
#     while read -r line; do
#         if [[ -n "${line}" ]]; then
#             TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
#             echo "Found error in ${file}: ${line}" >> "${TEMP_FILE}"
#         fi
#     done < <(grep "ERROR" "${file}" || true)
# done
#
# # Atomic report generation
# cat <<REPORT > "${OUTPUT_DIR}/summary.json"
# {
#   "processed_files": ${PROCESSED_FILES},
#   "total_errors": ${TOTAL_ERRORS},
#   "status": "COMPLETED"
# }
# REPORT
#
# exit 0
# ==============================================================================