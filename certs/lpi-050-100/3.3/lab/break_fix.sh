#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100 (Open Source Essentials) - Lab Break & Fix Scenario
# Topic 3.3: Other Open Content Licenses (Weight: 2.5)
# Official Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# Additional References:
#   - Creative Commons Licenses: https://creativecommons.org/licenses/
#   - Open Data Commons: https://opendatacommons.org/licenses/
#   - SPDX License List: https://spdx.org/licenses/
#   - GNU Free Documentation License: https://www.gnu.org/licenses/fdl-1.3.html
# ==============================================================================

set -euo pipefail

LAB_DIR="/var/lab/open_content_audit"
CHECKER_BIN="/usr/local/bin/check-content-licenses"

echo "======================================================================"
echo " [LAB SETUP] Initializing Open Content License Compliance Lab..."
echo "======================================================================"

# Create Lab Directory Structure
mkdir -p "${LAB_DIR}/docs"
mkdir -p "${LAB_DIR}/data"

# 1. Create Documentation File with incompatible CC license (CC-BY-NC-4.0 instead of CC-BY-4.0)
cat << 'EOF' > "${LAB_DIR}/docs/architecture.md"
# Platform Architecture Guide

This document describes the cloud-native platform architecture.

---
SPDX-License-Identifier: CC-BY-NC-4.0
License-Type: Open Content
Attribution: Copyright (c) 2026 Platform Engineering Team.
EOF

# 2. Create Dataset Metadata with invalid Open Data Commons License identifier
cat << 'EOF' > "${LAB_DIR}/data/metrics_schema.json"
{
  "dataset_name": "telemetry-metrics-v2",
  "version": "2.4.0",
  "description": "Production cluster performance metrics dataset",
  "license_info": {
    "spdx_id": "ODBL-CUSTOM-DRAFT-2021",
    "type": "Open Data",
    "attribution_required": true,
    "share_alike": true
  }
}
EOF

# 3. Create Root LICENSE File with malformed GFDL declaration
cat << 'EOF' > "${LAB_DIR}/LICENSE.md"
# Project Open Content Licensing

1. Documentation: Covered by Creative Commons Attribution 4.0 International (CC-BY-4.0).
2. Reference Manuals: Covered by GNU Free Documentation License v1.3 without Invariant Sections.
3. Open Data: Covered by Open Data Commons Open Database License v1.0 (ODbL-1.0).

---
SPDX-License-Identifier: GFDL-1.3
EOF

# Create the Compliance Auditor Script
cat << 'EOF' > "${CHECKER_BIN}"
#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="/var/lab/open_content_audit"
ERRORS=0

echo "--- Starting Open Content License Audit ---"
echo "Target Directory: ${LAB_DIR}"
echo ""

# Check 1: Documentation Open Content License Compatibility
DOC_FILE="${LAB_DIR}/docs/architecture.md"
if grep -q "SPDX-License-Identifier: CC-BY-4.0" "${DOC_FILE}" || grep -q "SPDX-License-Identifier: CC-BY-SA-4.0" "${DOC_FILE}"; then
    echo "[PASS] Docs License: Valid commercial-friendly Creative Commons license found."
else
    echo "[FAIL] Docs License: ${DOC_FILE} is using non-compliant or restrictive license."
    echo "       Policy Requirement: Must use 'CC-BY-4.0' or 'CC-BY-SA-4.0'. Found: $(grep 'SPDX-License-Identifier:' "${DOC_FILE}" || echo 'None')"
    ERRORS=$((ERRORS + 1))
fi

# Check 2: Dataset License (Open Data Commons / CC0)
DATA_FILE="${LAB_DIR}/data/metrics_schema.json"
if grep -q '"spdx_id": "ODbL-1.0"' "${DATA_FILE}" || grep -q '"spdx_id": "CC0-1.0"' "${DATA_FILE}" || grep -q '"spdx_id": "PDDL-1.0"' "${DATA_FILE}"; then
    echo "[PASS] Data License: Valid Open Data Commons / CC0 license identifier found."
else
    echo "[FAIL] Data License: ${DATA_FILE} contains invalid SPDX data license identifier."
    echo "       Policy Requirement: Must use valid Open Data Commons identifier ('ODbL-1.0', 'PDDL-1.0') or 'CC0-1.0'."
    ERRORS=$((ERRORS + 1))
fi

# Check 3: GFDL Declaration Standard
LIC_FILE="${LAB_DIR}/LICENSE.md"
if grep -q "SPDX-License-Identifier: GFDL-1.3-no-invariants-only" "${LIC_FILE}" || grep -q "SPDX-License-Identifier: GFDL-1.3-or-later" "${LIC_FILE}"; then
    echo "[PASS] GFDL License: Valid GFDL SPDX license identifier format."
else
    echo "[FAIL] GFDL License: ${LIC_FILE} uses bare 'GFDL-1.3' identifier without standard SPDX variant modifier."
    echo "       Policy Requirement: Must specify standard SPDX identifier 'GFDL-1.3-no-invariants-only' or 'GFDL-1.3-or-later'."
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ "${ERRORS}" -eq 0 ]; then
    echo "======================================================================"
    echo " SUCCESS: All Open Content Licenses pass organization policy audit!"
    echo "======================================================================"
    exit 0
else
    echo "======================================================================"
    echo " AUDIT FAILED: ${ERRORS} license compliance error(s) detected."
    echo "======================================================================"
    exit 1
fi
EOF

chmod +x "${CHECKER_BIN}"

echo ""
echo "======================================================================"
echo " LAB ENVIRONMENT READY: OPEN CONTENT LICENSES (LPI 050-100 Topic 3.3)"
echo "======================================================================"
echo ""
echo "SRE / ARCHITECT CONTEXT:"
echo "Open content licensing governs non-software assets such as documentation,"
echo "datasets, infrastructure blueprints, and multimedia assets. Key open content"
echo "license families include Creative Commons (CC), Open Data Commons (ODC), and"
echo "the GNU Free Documentation License (GFDL)."
echo ""
echo "PROBLEM STATEMENT / SYMPTOMS:"
echo "The CI/CD open content auditor '/usr/local/bin/check-content-licenses'"
echo "is currently FAILING for the repository located at /var/lab/open_content_audit."
echo ""
echo "YOUR OBJECTIVE:"
echo "1. Run the checker script: /usr/local/bin/check-content-licenses"
echo "2. Analyze the failure outputs regarding Open Content Licenses."
echo "3. Modify the metadata and license headers in:"
echo "   - /var/lab/open_content_audit/docs/architecture.md"
echo "   - /var/lab/open_content_audit/data/metrics_schema.json"
echo "   - /var/lab/open_content_audit/LICENSE.md"
echo "   so they comply with valid SPDX identifiers for Open Content & Open Data:"
echo "     * Docs: CC-BY-4.0 (Creative Commons Attribution 4.0)"
echo "     * Data: ODbL-1.0 (Open Data Commons Open Database License v1.0)"
echo "     * GFDL: GFDL-1.3-no-invariants-only (GNU Free Documentation License v1.3)"
echo "4. Re-run /usr/local/bin/check-content-licenses until it returns SUCCESS (exit status 0)."
echo ""
echo "Reference URLs:"
echo " - LPI 050-100 Overview: https://www.lpi.org/our-certifications/open-source-essentials-overview/"
echo " - Creative Commons: https://creativecommons.org/licenses/"
echo " - Open Data Commons: https://opendatacommons.org/licenses/"
echo " - SPDX License List: https://spdx.org/licenses/"
echo "======================================================================"

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION (DO NOT UNCOMMENT WHEN RUNNING LAB SETUP)
# ==============================================================================
#
# STEP 1: Execute the auditor script to observe failure output and diagnostic logs.
# Command:
#   /usr/local/bin/check-content-licenses
#
# Expected Output:
#   --- Starting Open Content License Audit ---
#   Target Directory: /var/lab/open_content_audit
#
#   [FAIL] Docs License: /var/lab/open_content_audit/docs/architecture.md is using non-compliant or restrictive license.
#          Policy Requirement: Must use 'CC-BY-4.0' or 'CC-BY-SA-4.0'. Found: SPDX-License-Identifier: CC-BY-NC-4.0
#   [FAIL] Data License: /var/lab/open_content_audit/data/metrics_schema.json contains invalid SPDX data license identifier.
#          Policy Requirement: Must use valid Open Data Commons identifier ('ODbL-1.0', 'PDDL-1.0') or 'CC0-1.0'.
#   [FAIL] GFDL License: /var/lab/open_content_audit/LICENSE.md uses bare 'GFDL-1.3' identifier without standard SPDX variant modifier.
#          Policy Requirement: Must specify standard SPDX identifier 'GFDL-1.3-no-invariants-only' or 'GFDL-1.3-or-later'.
#
#   ======================================================================
#    AUDIT FAILED: 3 license compliance error(s) detected.
#   ======================================================================
#
# STEP 2: Fix the Documentation License header in docs/architecture.md
# Replace 'CC-BY-NC-4.0' (Non-Commercial, which restricts commercial redistribution)
# with the standard open content license 'CC-BY-4.0'.
#
# Command:
#   sed -i 's/SPDX-License-Identifier: CC-BY-NC-4.0/SPDX-License-Identifier: CC-BY-4.0/' /var/lab/open_content_audit/docs/architecture.md
#
# Verification:
#   grep "SPDX-License-Identifier" /var/lab/open_content_audit/docs/architecture.md
#   Output: SPDX-License-Identifier: CC-BY-4.0
#
# STEP 3: Fix the Dataset License in data/metrics_schema.json
# Replace the invalid identifier 'ODBL-CUSTOM-DRAFT-2021' with the canonical
# SPDX identifier for Open Data Commons Open Database License 'ODbL-1.0'.
#
# Command:
#   sed -i 's/"spdx_id": "ODBL-CUSTOM-DRAFT-2021"/"spdx_id": "ODbL-1.0"/' /var/lab/open_content_audit/data/metrics_schema.json
#
# Verification:
#   grep "spdx_id" /var/lab/open_content_audit/data/metrics_schema.json
#   Output: "spdx_id": "ODbL-1.0",
#
# STEP 4: Fix the GFDL License Identifier in LICENSE.md
# Replace bare 'GFDL-1.3' with standard SPDX identifier 'GFDL-1.3-no-invariants-only'.
#
# Command:
#   sed -i 's/SPDX-License-Identifier: GFDL-1.3/SPDX-License-Identifier: GFDL-1.3-no-invariants-only/' /var/lab/open_content_audit/LICENSE.md
#
# Verification:
#   grep "SPDX-License-Identifier" /var/lab/open_content_audit/LICENSE.md
#   Output: SPDX-License-Identifier: GFDL-1.3-no-invariants-only
#
# STEP 5: Re-run the auditor script to verify clean compliance pass.
# Command:
#   /usr/local/bin/check-content-licenses
#
# Expected Output:
#   --- Starting Open Content License Audit ---
#   Target Directory: /var/lab/open_content_audit
#
#   [PASS] Docs License: Valid commercial-friendly Creative Commons license found.
#   [PASS] Data License: Valid Open Data Commons / CC0 license identifier found.
#   [PASS] GFDL License: Valid GFDL SPDX license identifier format.
#
#   ======================================================================
#    SUCCESS: All Open Content Licenses pass organization policy audit!
#   ======================================================================
# Exit Code: 0