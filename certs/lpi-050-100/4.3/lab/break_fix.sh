#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 4.3: Compliance and Risk Mitigation (Exam Weight: 7.5)
# Hands-On SRE & Platform Architecture "Break & Fix" Laboratory Script
#
# Official References:
# - LPI Open Source Essentials Overview: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# - SPDX (Software Package Data Exchange) Specification: https://spdx.dev/specifications/
# - Linux Foundation OpenChain Specification (ISO/IEC 5230): https://www.openchainproject.org/
# ==============================================================================

set -euo pipefail

# Style definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

LAB_DIR="/tmp/lpi_compliance_lab"
POLICY_FILE="${LAB_DIR}/config/compliance-policy.json"
APP_DIR="${LAB_DIR}/app"
LOG_DIR="${LAB_DIR}/logs"
AUDIT_LOG="${LOG_DIR}/compliance-audit.log"
SBOM_MANIFEST="${APP_DIR}/sbom.spdx.json"
AUDIT_SCRIPT="${LAB_DIR}/bin/audit-compliance.sh"

echo -e "${CYAN}${BOLD}====================================================================${NC}"
echo -e "${CYAN}${BOLD} LPI 050-100 Topic 4.3: Compliance and Risk Mitigation Lab Setup ${NC}"
echo -e "${CYAN}${BOLD}====================================================================${NC}"

# Check prerequisites
if ! command -v jq &> /dev/null; then
    echo -e "${RED}[!] Error: 'jq' is required for JSON processing in this lab.${NC}"
    echo -e "${YELLOW}Please install jq using your package manager (e.g., 'sudo apt install jq' or 'sudo yum install jq').${NC}"
    exit 1
fi

echo -e "${BLUE}[*] Initializing isolated lab environment in ${LAB_DIR}...${NC}"

# Cleanup any existing lab workspace
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/config" "${LAB_DIR}/app" "${LAB_DIR}/logs" "${LAB_DIR}/bin"

# ------------------------------------------------------------------------------
# STEP 1: Deploy Base Infrastructure & Compliance Enforcement Scripts
# ------------------------------------------------------------------------------

# Create Compliance Policy Configuration
cat << 'EOF' > "${POLICY_FILE}"
{
  "policy_name": "Enterprise Open Source License & Risk Governance Policy",
  "version": "2.1.0",
  "approved_licenses": [
    "MIT",
    "Apache-2.0",
    "BSD-3-Clause"
  ],
  "restricted_licenses": [
    "GPL-2.0-only",
    "GPL-3.0-only"
  ],
  "disallowed_licenses": [
    "AGPL-3.0-only",
    "Proprietary-Unapproved"
  ],
  "enforce_sbom": true,
  "fail_on_high_risk": true
}
EOF

# Create Application Codebase & Dependencies
cat << 'EOF' > "${APP_DIR}/package-manifest.json"
{
  "name": "payment-gateway-service",
  "version": "1.4.0",
  "dependencies": [
    {
      "name": "express-router",
      "version": "4.17.1",
      "license": "MIT"
    },
    {
      "name": "crypto-utils",
      "version": "2.0.1",
      "license": "Apache-2.0"
    },
    {
      "name": "network-telemetry-core",
      "version": "3.1.0",
      "license": "AGPL-3.0-only"
    }
  ]
}
EOF

# Create Malformed/Incomplete SPDX SBOM File
cat << 'EOF' > "${SBOM_MANIFEST}"
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "payment-gateway-service-sbom",
  "documentNamespace": "http://spdx.org/spdxdocs/payment-gateway-service-v1.4.0",
  "creationInfo": {
    "creators": ["Tool: Platform-SRE-Generator-1.0"],
    "created": "2026-08-06T10:00:00Z"
  },
  "packages": [
    {
      "name": "express-router",
      "SPDXID": "SPDXRef-Package-express-router",
      "licenseConcluded": "MIT",
      "downloadLocation": "https://registry.npmjs.org/express-router/-/express-router-4.17.1.tgz"
    },
    {
      "name": "crypto-utils",
      "SPDXID": "SPDXRef-Package-crypto-utils",
      "licenseConcluded": "Apache-2.0",
      "downloadLocation": "https://registry.npmjs.org/crypto-utils/-/crypto-utils-2.0.1.tgz"
    },
    {
      "name": "network-telemetry-core",
      "SPDXID": "SPDXRef-Package-network-telemetry-core",
      "licenseConcluded": "AGPL-3.0-only"
    }
  ]
}
EOF

# Create Compliance Auditor Script
cat << 'EOF' > "${AUDIT_SCRIPT}"
#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="/tmp/lpi_compliance_lab"
POLICY_FILE="${LAB_DIR}/config/compliance-policy.json"
APP_MANIFEST="${LAB_DIR}/app/package-manifest.json"
SBOM_FILE="${LAB_DIR}/app/sbom.spdx.json"
LOG_FILE="${LAB_DIR}/logs/compliance-audit.log"

echo "[AUDIT START] Running Open Source Compliance & Risk Scanner..." > "${LOG_FILE}"

# 1. Audit Log Write Verification
if ! touch "${LOG_FILE}" 2>/dev/null; then
    echo -e "\033[0;31mFATAL: Cannot write to audit log file: ${LOG_FILE}\033[0m" >&2
    exit 2
fi

# 2. Check SBOM Schema & Completeness
if [ ! -f "${SBOM_FILE}" ]; then
    echo "[FAIL] Missing SPDX SBOM manifest: ${SBOM_FILE}" >> "${LOG_FILE}"
    echo -e "\033[0;31mERROR: SPDX SBOM file is missing!\033[0m" >&2
    exit 1
fi

missing_download_locs=$(jq -r '.packages[] | select(.downloadLocation == null or .downloadLocation == "NOASSERTION" and .name != "") | .name' "${SBOM_FILE}")
if [ -n "${missing_download_locs}" ]; then
    echo "[FAIL] SPDX Schema Validation Error: Package '${missing_download_locs}' is missing mandatory 'downloadLocation' metadata." >> "${LOG_FILE}"
    echo -e "\033[0;31mERROR: SPDX SBOM Schema Failure! Package '${missing_download_locs}' missing 'downloadLocation'.\033[0m" >&2
    exit 1
fi

# 3. License Governance Check
approved_list=$(jq -r '.approved_licenses[]' "${POLICY_FILE}")
disallowed_list=$(jq -r '.disallowed_licenses[]' "${POLICY_FILE}")

violating_found=0
while read -r name license; do
    if echo "${disallowed_list}" | grep -q "^${license}$"; then
        echo "[CRITICAL] License Violation Detected: Component '${name}' uses disallowed copyleft/risk license '${license}'." >> "${LOG_FILE}"
        echo -e "\033[0;31mCRITICAL RISK: Component '${name}' uses disallowed license '${license}'!\033[0m" >&2
        violating_found=1
    elif ! echo "${approved_list}" | grep -q "^${license}$"; then
        echo "[WARN] Unclassified/Restricted License: Component '${name}' uses license '${license}'." >> "${LOG_FILE}"
        echo -e "\033[0;33mWARNING: Component '${name}' uses unapproved license '${license}'.\033[0m" >&2
    fi
done < <(jq -r '.dependencies[] | "\(.name) \(.license)"' "${APP_MANIFEST}")

if [ "${violating_found}" -eq 1 ]; then
    echo "[AUDIT FAILED] Compliance Gate: Non-compliant licenses detected." >> "${LOG_FILE}"
    echo -e "\033[0;31mAUDIT FAILED: High-risk open source license compliance violation!\033[0m" >&2
    exit 1
fi

echo "[AUDIT SUCCESS] All dependencies comply with Enterprise Open Source Governance Policy." >> "${LOG_FILE}"
echo -e "\033[0;32mSUCCESS: Open Source Compliance Audit Passed Cleanly.\033[0m"
exit 0
EOF

chmod +x "${AUDIT_SCRIPT}"

# ------------------------------------------------------------------------------
# STEP 2: Introduce Controlled Failures ("Break" Phase)
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[*] Injecting intentional compliance governance failures and permissions breakages...${NC}"

# Break 1: Restrict write access to log directory (Simulate privilege / container filesystem permission drift)
chmod 555 "${LOG_DIR}"

echo -e "${GREEN}[+] Lab setup complete!${NC}\n"

# ------------------------------------------------------------------------------
# STEP 3: Student Instructions & Problem Statement
# ------------------------------------------------------------------------------
echo -e "${BOLD}${CYAN}====================================================================${NC}"
echo -e "${BOLD}${CYAN}                    STUDENT INSTRUCTIONS & SYMPTOMS                 ${NC}"
echo -e "${BOLD}${CYAN}====================================================================${NC}"
echo -e "${BOLD}SCENARIO:${NC}"
echo -e "You are the Lead Platform SRE responsible for Open Source Governance and CI/CD Security Gates."
echo -e "Your automated compliance verification runner script at:"
echo -e "  ${BOLD}${AUDIT_SCRIPT}${NC}"
echo -e "is currently failing in your production integration pipeline.\n"

echo -e "${BOLD}OBSERVED SYMPTOMS:${NC}"
echo -e "1. Running the audit script directly results in execution errors."
echo -e "2. Non-compliant open source components (strong copyleft / AGPL licenses) have slipped into the manifest."
echo -e "3. The Software Bill of Materials (SBOM) compliant with SPDX standards fails schema validation."
echo -e "4. Log auditing directory access is misconfigured.\n"

echo -e "${BOLD}YOUR OBJECTIVE:${NC}"
echo -e "Diagnose and resolve all issues until running ${BOLD}${AUDIT_SCRIPT}${NC} returns exit code ${GREEN}0${NC} and prints:"
echo -e "  ${GREEN}SUCCESS: Open Source Compliance Audit Passed Cleanly.${NC}\n"

echo -e "${YELLOW}To test your progress at any time, execute:${NC}"
echo -e "  ${BOLD}/tmp/lpi_compliance_lab/bin/audit-compliance.sh${NC}\n"

exit 0

# ==============================================================================
#                        STEP-BY-STEP SOLUTION GUIDE
#                       (LPI 050-100 Topic 4.3 Reference)
# ==============================================================================
#
# TECHNICAL BACKGROUND & ARCHITECTURAL MECHANICS:
# Topic 4.3 (Compliance and Risk Mitigation) requires understanding how open source
# licenses affect software distribution, corporate liability, intellectual property,
# and technical risk.
#
# Key Concepts:
# 1. Permissive vs. Copyleft Licenses:
#    - Permissive (MIT, Apache-2.0, BSD): Allow reuse with minimal restrictions.
#    - Strong Copyleft / Viral (GPL-2.0, GPL-3.0, AGPL-3.0): Require derivative works or
#      network-accessible services to open-source their entire codebase under the same license.
# 2. Software Bill of Materials (SBOM):
#    - Standardized machine-readable inventory of software components (e.g., SPDX, CycloneDX).
#    - ISO/IEC 5230 (OpenChain) compliance mandates tracking origin, license, and download links.
# 3. Risk Mitigation:
#    - Automated policy gates in SRE/DevSecOps pipelines prevent legal infringement
#      and supply chain security vulnerabilities prior to production artifact deployment.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP DIAGNOSIS AND FIX PROCEDURES:
# ------------------------------------------------------------------------------
#
# DIAGNOSTIC STEP 1: Execute the audit script to observe initial failure.
# Command:
#   /tmp/lpi_compliance_lab/bin/audit-compliance.sh
# Expected Output:
#   /tmp/lpi_compliance_lab/bin/audit-compliance.sh: line 14: /tmp/lpi_compliance_lab/logs/compliance-audit.log: Permission denied
#   FATAL: Cannot write to audit log file: /tmp/lpi_compliance_lab/logs/compliance-audit.log
#
# REMEDIATION STEP 1: Fix permissions on the logs directory.
# Command:
#   chmod 755 /tmp/lpi_compliance_lab/logs
#
# ------------------------------------------------------------------------------
# DIAGNOSTIC STEP 2: Re-run the audit script to identify schema and license issues.
# Command:
#   /tmp/lpi_compliance_lab/bin/audit-compliance.sh
# Expected Output:
#   ERROR: SPDX SBOM Schema Failure! Package 'network-telemetry-core' missing 'downloadLocation'.
#
# REMEDIATION STEP 2: Inspect and fix the SPDX SBOM JSON file.
# Inspection Command:
#   jq '.packages[] | {name, licenseConcluded, downloadLocation}' /tmp/lpi_compliance_lab/app/sbom.spdx.json
#
# Fix: Update `/tmp/lpi_compliance_lab/app/sbom.spdx.json` to include a valid `downloadLocation` for `network-telemetry-core`.
# Command:
#   jq '.packages |= map(if .name == "network-telemetry-core" then . + {"downloadLocation": "https://registry.npmjs.org/network-telemetry-core/-/network-telemetry-core-3.1.0.tgz"} else . end)' \
#     /tmp/lpi_compliance_lab/app/sbom.spdx.json > /tmp/lpi_compliance_lab/app/sbom.spdx.json.tmp \
#     && mv /tmp/lpi_compliance_lab/app/sbom.spdx.json.tmp /tmp/lpi_compliance_lab/app/sbom.spdx.json
#
# ------------------------------------------------------------------------------
# DIAGNOSTIC STEP 3: Re-run the audit script to evaluate open source license risk.
# Command:
#   /tmp/lpi_compliance_lab/bin/audit-compliance.sh
# Expected Output:
#   CRITICAL RISK: Component 'network-telemetry-core' uses disallowed license 'AGPL-3.0-only'!
#   AUDIT FAILED: High-risk open source license compliance violation!
#
# REMEDIATION STEP 3: Replace or remediate the non-compliant AGPL-3.0 component.
# SRE / Architecture decision: In compliance governance, AGPL-3.0 imposes severe copyleft risk for backend services.
# Replace the component in `/tmp/lpi_compliance_lab/app/package-manifest.json` with an approved permissive component (e.g. `opentelemetry-core` with `Apache-2.0`).
#
# Fix Command:
#   jq '.dependencies |= map(if .name == "network-telemetry-core" then {"name": "opentelemetry-core", "version": "3.1.0", "license": "Apache-2.0"} else . end)' \
#     /tmp/lpi_compliance_lab/app/package-manifest.json > /tmp/lpi_compliance_lab/app/package-manifest.json.tmp \
#     && mv /tmp/lpi_compliance_lab/app/package-manifest.json.tmp /tmp/lpi_compliance_lab/app/package-manifest.json
#
# Also update the SPDX SBOM file package name to match the updated dependency:
#   jq '.packages |= map(if .name == "network-telemetry-core" then {"name": "opentelemetry-core", "SPDXID": "SPDXRef-Package-opentelemetry-core", "licenseConcluded": "Apache-2.0", "downloadLocation": "https://registry.npmjs.org/opentelemetry-core/-/opentelemetry-core-3.1.0.tgz"} else . end)' \
#     /tmp/lpi_compliance_lab/app/sbom.spdx.json > /tmp/lpi_compliance_lab/app/sbom.spdx.json.tmp \
#     && mv /tmp/lpi_compliance_lab/app/sbom.spdx.json.tmp /tmp/lpi_compliance_lab/app/sbom.spdx.json
#
# ------------------------------------------------------------------------------
# VERIFICATION:
# Run the audit script one final time:
#   /tmp/lpi_compliance_lab/bin/audit-compliance.sh
# Expected Output:
#   SUCCESS: Open Source Compliance Audit Passed Cleanly.
# Check exit code:
#   echo $?
# Expected Output:
#   0
# ==============================================================================