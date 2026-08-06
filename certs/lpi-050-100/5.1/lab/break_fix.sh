#!/usr/bin/env bash
# ==============================================================================
# SRE / DevOps Lab: Break & Fix Scenario
# Certification: LPI 050-100 (Open Source Essentials / DevOps Tools Engineer)
# Topic 5.1: Software Development Models (Agile, Waterfall, CI/CD, Git Workflows)
# Official Reference:
#   - https://www.lpi.org/our-certifications/open-source-essentials-overview/
# ==============================================================================

set -euo pipefail

LAB_DIR="${HOME}/sre_lab_software_dev_models"

color_info="\033[1;34m"
color_success="\033[1;32m"
color_warn="\033[1;33m"
color_err="\033[1;31m"
color_reset="\033[0m"

echo -e "${color_info}[+] Setting up SRE Break & Fix Lab for Topic 5.1: Software Development Models...${color_reset}"

# Clean up previous runs
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}"
cd "${LAB_DIR}"

# ------------------------------------------------------------------------------
# 1. BASE SYSTEM SETUP (Simulating Agile Trunk-Based Development Repository)
# ------------------------------------------------------------------------------
git init -q
git config user.name "SRE Lab Engineer"
git config user.email "lab@sre.internal"
git config initial.defaultBranch main

mkdir -p .ci src

# Create application code
cat << 'EOF' > src/app.py
import sys

def main():
    print("Application version 1.2.0 active.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
EOF

# Create automated CI validation gate script
cat << 'EOF' > .ci/validate_workflow.sh
#!/usr/bin/env bash
# Automated Shift-Left CI Gate: Enforces Agile Branching & Conventional Commit Standards
set -e

CONFIG_FILE=".ci/workflow.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[CRITICAL ERROR] Missing CI workflow configuration file: $CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"

# 1. Validate Branch Naming Model (e.g., main, feature/name, bugfix/name)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
echo "[CI Check] Validating Branch Name: '${CURRENT_BRANCH}'..."

if [[ ! "${CURRENT_BRANCH}" =~ ${ALLOWED_BRANCH_REGEX} ]]; then
    echo "[CI FAIL] Branch '${CURRENT_BRANCH}' violates Agile Workflow branching model!" >&2
    echo "          Expected Regex Pattern: ${ALLOWED_BRANCH_REGEX}" >&2
    exit 2
fi

# 2. Validate Conventional Commit Message Format
LAST_COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null || echo "")
echo "[CI Check] Validating Last Commit Message: '${LAST_COMMIT_MSG}'..."

if ! echo "${LAST_COMMIT_MSG}" | grep -Eq "${CONVENTIONAL_COMMIT_REGEX}"; then
    echo "[CI FAIL] Commit message does not conform to Conventional Commits standard!" >&2
    echo "          Format required: feat(scope): message | fix(scope): message | chore(scope): message" >&2
    exit 3
fi

# 3. Check Semantic Versioning string presence
VERSION=$(grep -oP 'version \K[0-9]+\.[0-9]+\.[0-9]+' src/app.py || true)
if [[ -z "${VERSION}" ]]; then
    echo "[CI FAIL] Semantic version string (X.Y.Z) missing in src/app.py!" >&2
    exit 4
fi

echo "[CI PASS] Agile CI/CD workflow checks succeeded for version ${VERSION} on branch ${CURRENT_BRANCH}."
exit 0
EOF

chmod +x .ci/validate_workflow.sh

# Commit initial state
git add .
git commit -m "chore(init): setup repository for sprint 1" -q

# Set up Git pre-commit hook to trigger shift-left automated tests
cat << 'EOF' > .git/hooks/pre-commit
#!/usr/bin/env bash
./.ci/validate_workflow.sh
EOF

# ------------------------------------------------------------------------------
# 2. CONTROLLED BREAKAGE INJECTION
# ------------------------------------------------------------------------------

# Breakage A: Corrupt CI configuration regex patterns (Unclosed parentheses & invalid commit regex)
cat << 'EOF' > .ci/workflow.env
# CI/CD Workflow Environment Variables
ALLOWED_BRANCH_REGEX="^(main|feature\/[a-z0-9-]+|bugfix\/[a-z0-9-]+$"
CONVENTIONAL_COMMIT_REGEX="^(feat|fix|chore)(\([a-z0-9-]+\))?!: .+$"
EOF

# Breakage B: Revoke execution rights from Git hook (Bypasses shift-left automated testing)
chmod -x .git/hooks/pre-commit

# Breakage C: Create non-compliant branch and commit bypassing safety checks
git checkout -b "feature-user-auth" -q 2>/dev/null || git checkout -b "feature-user-auth" -q

cat << 'EOF' >> src/app.py

def authenticate_user():
    return True
EOF

git add src/app.py
git commit --no-verify -m "added authentication feature" -q

# ------------------------------------------------------------------------------
# 3. STUDENT LAB PRESENTATION
# ------------------------------------------------------------------------------
echo -e "${color_success}[+] Lab setup complete! Target directory: ${LAB_DIR}${color_reset}"
echo ""
echo -e "${color_warn}======================================================================${color_reset}"
echo -e "${color_warn} SRE BREAK & FIX: Topic 5.1 - Software Development Models             ${color_reset}"
echo -e "${color_warn}======================================================================${color_reset}"
echo ""
echo -e "${color_info}PROBLEM DESCRIPTION / SYMPTOMS:${color_reset}"
echo "An engineering team migrating from Waterfall to an Agile CI/CD model reports"
echo "that automated delivery pipelines are broken and commit gates are silently failing."
echo ""
echo "Observed issues:"
echo "1. Running direct CI validation './.ci/validate_workflow.sh' fails with Bash regex syntax errors."
echo "2. Local Git pre-commit hooks fail to execute automatically during developer commits."
echo "3. The repository branch naming ('feature-user-auth') and commit history violate"
echo "   Agile Trunk-Based Development and Conventional Commit standards."
echo ""
echo -e "${color_info}STUDENT OBJECTIVES:${color_reset}"
echo "1. Fix '.ci/workflow.env' to restore valid Regex patterns for Agile branch model"
echo "   compliance (e.g. 'feature/user-auth') and conventional commits ('feat(scope): msg')."
echo "2. Restore executable permissions to '.git/hooks/pre-commit' to enforce Shift-Left testing."
echo "3. Correct the local Git branch name to 'feature/user-auth' and amend the last commit"
echo "   message to follow Conventional Commits standard ('feat(auth): add authentication feature')."
echo "4. Verify that running './.ci/validate_workflow.sh' succeeds with exit code 0."
echo ""
echo -e "${color_warn}Begin troubleshooting by executing:${color_reset}"
echo "  cd ${LAB_DIR}"
echo "  ./.ci/validate_workflow.sh"
echo ""

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & ARCHITECTURAL GUIDE (FOR INSTRUCTORS/STUDENTS)
# ==============================================================================
#
# STEP 1: Reproduce and Diagnose the CI Script Failure
# -----------------------------------------------------
# Run the validation script:
#   $ cd ~/sre_lab_software_dev_models
#   $ ./.ci/validate_workflow.sh
#
# Diagnostic Output:
#   ./.ci/validate_workflow.sh: line 19: [[: ... syntax error in conditional expression
#
# Cause:
# Inspecting `.ci/workflow.env` reveals `ALLOWED_BRANCH_REGEX` has an unclosed parenthesis:
#   ALLOWED_BRANCH_REGEX="^(main|feature\/[a-z0-9-]+|bugfix\/[a-z0-9-]+$"
#
# Also, `CONVENTIONAL_COMMIT_REGEX` requires a `!` character after scope, which is invalid:
#   CONVENTIONAL_COMMIT_REGEX="^(feat|fix|chore)(\([a-z0-9-]+\))?!: .+$"
#
# STEP 2: Fix the CI Environment Configuration
# --------------------------------------------
# Edit `.ci/workflow.env` and replace its contents with valid POSIX EERE/Bash regex:
#
# cat << 'EOF' > .ci/workflow.env
# ALLOWED_BRANCH_REGEX="^(main|feature/[a-z0-9-]+|bugfix/[a-z0-9-]+)$"
# CONVENTIONAL_COMMIT_REGEX="^(feat|fix|chore)(\([a-z0-9-]+\))?: .+$"
# EOF
#
# STEP 3: Restore Pre-Commit Hook Executability (Shift-Left Automation)
# ----------------------------------------------------------------------
# Verify git hook permissions:
#   $ ls -la .git/hooks/pre-commit
#   -rw-r--r-- 1 user user ... .git/hooks/pre-commit
#
# Grant execution permissions so Git triggers the hook automatically before commit creation:
#   $ chmod +x .git/hooks/pre-commit
#
# STEP 4: Fix Agile Branching Model & Commit History Non-Compliance
# ------------------------------------------------------------------
# A. Rename the non-compliant branch 'feature-user-auth' to standard 'feature/user-auth':
#   $ git branch -m feature/user-auth
#
# B. Amend non-compliant commit message ("added authentication feature") to conventional format:
#   $ git commit --amend -m "feat(auth): add user authentication feature"
#
# STEP 5: Verification & Validation
# ---------------------------------
# Re-run the automated CI gate check:
#   $ ./.ci/validate_workflow.sh
#
# Expected Output:
#   [CI Check] Validating Branch Name: 'feature/user-auth'...
#   [CI Check] Validating Last Commit Message: 'feat(auth): add user authentication feature'...
#   [CI PASS] Agile CI/CD workflow checks succeeded for version 1.2.0 on branch feature/user-auth.
#   $ echo $?
#   0
#
# ==============================================================================
# PRINCIPAL ARCHITECT NOTES: SOFTWARE DEVELOPMENT MODELS (LPI 050-100 TOPIC 5.1)
# ==============================================================================
# 1. Waterfall vs. Agile Paradigm Shift:
#    - Waterfall: Sequential stages (Requirements -> Design -> Code -> Test -> Deploy).
#      High release risk, large batch sizes, slow feedback loops.
#    - Agile: Iterative, incremental development cycles (Sprints). Focuses on continuous
#      feedback, small pull requests, and automated validation.
#
# 2. Continuous Integration & Continuous Delivery (CI/CD):
#    - CI requires developers to integrate code into shared repository main branch frequently.
#    - Shift-Left Testing moves validation (linters, branch checks, unit tests) to local
#      developer environments using Git pre-commit hooks before remote push.
#
# 3. Branching Strategies:
#    - Trunk-Based Development: Short-lived feature branches (`feature/*`) merged quickly
#      into `main` with feature flags. Minimizes merge friction.
#    - GitFlow: Complex branching model with `develop`, `release`, `hotfix`, and `master`
#      branches. Often adds integration overhead compared to modern DevOps practices.
# ==============================================================================