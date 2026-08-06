#!/bin/bash
# ==============================================================================
# LPI Open Source Essentials (050-100) - Topic 5.3: Community Management
# Production SRE Hands-on Break & Fix Lab Environment
#
# Official Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# Additional References:
#   - Developer Certificate of Origin (DCO): https://developercertificate.org/
#   - Contributor Covenant Code of Conduct: https://www.contributor-covenant.org/
#
# ARCHITECT & SRE TECHNICAL CONTEXT:
# In open-source platform engineering, community governance is enforced via
# automated compliance gates. Key artifacts include CODE_OF_CONDUCT.md, 
# CONTRIBUTING.md, LICENSE, and automated DCO (Signed-off-by) checks. 
# Trade-offs:
#   - DCO vs. CLA: DCO provides lightweight per-commit legal attestation via Git
#     without requiring complex corporate/individual signing pipelines (CLA).
#   - Automated Hooks vs. CI Gates: Client-side hooks (.git/hooks/) provide fast
#     feedback but can be bypassed; server-side CI gates provide hard enforcement.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi-050-community-lab"
REPO_DIR="${LAB_DIR}/oss-project"

echo "======================================================================"
echo "[LPI 050-100 Topic 5.3] Initializing Open Source Governance Lab Setup..."
echo "======================================================================"

# Clean up previous runs safely
rm -rf "${LAB_DIR}"
mkdir -p "${REPO_DIR}/.git/hooks"
mkdir -p "${REPO_DIR}/scripts"

cd "${REPO_DIR}"

# 1. Initialize standard Git repository
git init --quiet "${REPO_DIR}"

# 2. Create basic repository governance templates
cat << 'EOF' > "${REPO_DIR}/README.md"
# Enterprise Open Source Platform Engine
Welcome to our project. Please review CONTRIBUTING.md and CODE_OF_CONDUCT.md before submitting PRs.
EOF

cat << 'EOF' > "${REPO_DIR}/LICENSE"
Apache License, Version 2.0
http://www.apache.org/licenses/LICENSE-2.0
EOF

cat << 'EOF' > "${REPO_DIR}/CODE_OF_CONDUCT.md"
# Contributor Covenant Code of Conduct
## Our Pledge
We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone.
EOF

cat << 'EOF' > "${REPO_DIR}/CONTRIBUTING.md"
# Contributing Guidelines
Thank you for contributing to our platform project!
EOF

# 3. Create Automated Community Governance Validator Script
cat << 'EOF' > "${REPO_DIR}/scripts/validate-governance.sh"
#!/bin/bash
# Open Source Governance & DCO Verification Tool

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[+] Auditing Open Source Community Governance Compliance..."

ERRORS=0

# Check required community governance documents
# INJECTED BUG 1: Broken hardcoded absolute path pointing outside repo root
COC_FILE="/var/tmp/global_coc.md"
CONTRIBUTING_FILE="${REPO_ROOT}/CONTRIBUTING.md"
LICENSE_FILE="${REPO_ROOT}/LICENSE"

if [[ ! -f "${COC_FILE}" ]]; then
    echo "[ERROR] Mandatory Code of Conduct document missing at: ${COC_FILE}"
    ERRORS=$((ERRORS + 1))
fi

if [[ ! -f "${CONTRIBUTING_FILE}" ]]; then
    echo "[ERROR] Contributing guidelines missing at: ${CONTRIBUTING_FILE}"
    ERRORS=$((ERRORS + 1))
else
    # Verify required governance sections exist in CONTRIBUTING.md
    if ! grep -q "Developer Certificate of Origin" "${CONTRIBUTING_FILE}"; then
        echo "[ERROR] CONTRIBUTING.md is missing required section: 'Developer Certificate of Origin'"
        ERRORS=$((ERRORS + 1))
    fi
fi

if [[ ! -f "${LICENSE_FILE}" ]]; then
    echo "[ERROR] Open source license file missing at: ${LICENSE_FILE}"
    ERRORS=$((ERRORS + 1))
fi

# Check Git Commit DCO Signature Rule
# INJECTED BUG 2: Overly restrictive regex enforcing internal corporate domain instead of open standard
DCO_REGEX="^Signed-off-by: [A-Za-z ]+ <[a-z0-9._%+-]+@internal-corp\.com>$"

LATEST_COMMIT_MSG="$(git log -1 --pretty=%B 2>/dev/null || echo '')"
if [[ -n "${LATEST_COMMIT_MSG}" ]]; then
    if ! echo "${LATEST_COMMIT_MSG}" | grep -Eq "${DCO_REGEX}"; then
        echo "[ERROR] Commit fails Developer Certificate of Origin (DCO) validation!"
        echo "        Received message line does not match required format."
        ERRORS=$((ERRORS + 1))
    fi
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo "[-] Community Governance Audit FAILED with ${ERRORS} error(s)."
    exit 1
else
    echo "[SUCCESS] Community Governance Audit PASSED!"
    exit 0
fi
EOF

chmod +x "${REPO_DIR}/scripts/validate-governance.sh"

# 4. Create Git commit-msg hook for local client-side DCO verification
cat << 'EOF' > "${REPO_DIR}/.git/hooks/commit-msg"
#!/bin/bash
COMMIT_MSG_FILE="$1"
if ! grep -q "^Signed-off-by: " "${COMMIT_MSG_FILE}"; then
    echo "[ERROR] Commit rejected: Missing DCO signature ('Signed-off-by: First Last <email>')."
    echo "        Use 'git commit -s' to automatically append Developer Certificate of Origin."
    exit 1
fi
EOF

# INJECTED BUG 3: Remove executable permissions from Git hook script
chmod 644 "${REPO_DIR}/.git/hooks/commit-msg"

# 5. Create initial un-signed commit to stage lab failure state
git config user.name "Student Developer"
git config user.email "student@example.org"
git add .
git commit -m "Initial community scaffolding" --no-gpg-sign >/dev/null 2>&1 || true

echo ""
echo "======================================================================"
echo "                         LAB BREAKAGE COMPLETE                         "
echo "======================================================================"
echo " SCENARIO OVERVIEW:"
echo " You are the Platform Architect auditing an open-source project located at:"
echo " ${REPO_DIR}"
echo ""
echo " OBSERVED SYMPTOMS:"
echo " 1. Running compliance check yields failure errors:"
echo "    $ ${REPO_DIR}/scripts/validate-governance.sh"
echo "    - Claims CODE_OF_CONDUCT.md is missing at /var/tmp/global_coc.md."
echo "    - Reports CONTRIBUTING.md is missing DCO governance declarations."
echo "    - Rejects valid open-source commits signed with open standard DCOs."
echo " 2. Contributors notice that local Git commits allow unsigned commits without"
echo "    triggering local git hook checks."
echo ""
echo " CHALLENGE OBJECTIVES:"
echo " 1. Fix '${REPO_DIR}/scripts/validate-governance.sh':"
echo "    - Point CODE_OF_CONDUCT.md path to inspect local repository root."
echo "    - Update DCO regex pattern to accept any valid RFC 5322 email format"
echo "      (e.g., Signed-off-by: Name <name@domain.tld>)."
echo " 2. Fix CONTRIBUTING.md:"
echo "    - Add missing 'Developer Certificate of Origin' section explaining DCO requirements."
echo " 3. Fix Git Hook Execution:"
echo "    - Make '.git/hooks/commit-msg' executable so Git invokes client-side enforcement."
echo " 4. Remediate & Verify:"
echo "    - Amend the latest Git commit using 'git commit --amend -s'."
echo "    - Re-run '${REPO_DIR}/scripts/validate-governance.sh' and confirm [SUCCESS]."
echo "======================================================================"

# ==============================================================================
# STEP-BY-STEP SOLUTION (STUDENT REFERENCE & AUTO-VERIFICATION)
# ==============================================================================
#
# Step 1: Navigate to repository workspace
#   $ cd /tmp/lpi-050-community-lab/oss-project
#
# Step 2: Inspect initial failure outputs
#   $ ./scripts/validate-governance.sh
#   Expected failure output:
#   [ERROR] Mandatory Code of Conduct document missing at: /var/tmp/global_coc.md
#   [ERROR] CONTRIBUTING.md is missing required section: 'Developer Certificate of Origin'
#   [ERROR] Commit fails Developer Certificate of Origin (DCO) validation!
#
# Step 3: Fix path reference and DCO Regex in scripts/validate-governance.sh
#   Edit scripts/validate-governance.sh:
#     - Change line 16:
#       COC_FILE="/var/tmp/global_coc.md"
#       to:
#       COC_FILE="${REPO_ROOT}/CODE_OF_CONDUCT.md"
#
#     - Change line 38:
#       DCO_REGEX="^Signed-off-by: [A-Za-z ]+ <[a-z0-9._%+-]+@internal-corp\.com>$"
#       to:
#       DCO_REGEX="^Signed-off-by: [A-Za-z ]+ <[a-z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}>$"
#
# Step 4: Add required DCO governance documentation to CONTRIBUTING.md
#   $ cat << 'EOF' >> CONTRIBUTING.md
#
# ## Developer Certificate of Origin
# By contributing to this project, you certify under the Developer Certificate of Origin (DCO)
# that your contributions are original and licensed under the open source Apache 2.0 license.
# All commits must include a `Signed-off-by:` line (run `git commit -s`).
# EOF
#
# Step 5: Restore executable permissions for the Git commit-msg hook
#   $ chmod +x .git/hooks/commit-msg
#
# Step 6: Stage fixes and re-sign the Git commit with DCO attestation
#   $ git add CONTRIBUTING.md scripts/validate-governance.sh
#   $ git commit --amend -s --no-edit
#
# Step 7: Verify final compliance gate execution
#   $ ./scripts/validate-governance.sh
#   Expected output:
#   [+] Auditing Open Source Community Governance Compliance...
#   [SUCCESS] Community Governance Audit PASSED!
# ==============================================================================