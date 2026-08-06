#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 2.1: Concepts of Open Source Software Licenses (Weight: 7.5)
# Production Break & Fix Lab Environment
#
# References:
# - Official Exam Specs: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# - Open Source Initiative (OSI) Licenses: https://opensource.org/licenses
# - SPDX License List: https://spdx.org/licenses/
# - GNU License Compatibility FAQ: https://www.gnu.org/licenses/gpl-faq.html
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/license_compliance_lab"
AUDIT_SCRIPT="${LAB_DIR}/audit_licenses.sh"

echo "======================================================================"
echo " LPI 050-100 Topic 2.1: Open Source Software Licenses - Lab Setup"
echo "======================================================================"
echo "[+] Initializing lab environment at ${LAB_DIR}..."

# Clean up previous lab state if exists
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/src" "${LAB_DIR}/vendor" "${LAB_DIR}/docs"

# ------------------------------------------------------------------------------
# Create Project Files and Deliberate Compliance Violations
# ------------------------------------------------------------------------------

# 1. Main Project Metadata (Permissive License Goal: Apache-2.0)
cat << 'EOF' > "${LAB_DIR}/PROJECT_POLICY.json"
{
  "projectName": "Enterprise Data Router",
  "targetLicense": "Apache-2.0",
  "allowedLicenses": [
    "MIT",
    "Apache-2.0",
    "BSD-3-Clause",
    "ISC"
  ],
  "prohibitedLicenseTypes": [
    "Strong Copyleft",
    "Non-OSI Approved",
    "Proprietary EULA"
  ]
}
EOF

# 2. Source Code Header Check Violation (Invalid SPDX Identifier)
cat << 'EOF' > "${LAB_DIR}/src/main.py"
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Enterprise Corp.
def main():
    print("Starting Enterprise Data Router...")
EOF

cat << 'EOF' > "${LAB_DIR}/src/router.py"
# SPDX-License-Identifier: Invalid-Custom-License-1.0
# Copyright (c) 2026 Enterprise Corp.
class Router:
    pass
EOF

cat << 'EOF' > "${LAB_DIR}/src/telemetry.py"
# Missing SPDX header entirely
class Telemetry:
    pass
EOF

# 3. Third-Party Vendor Dependencies with License Violations
# Vendor Module A: Permissive (MIT) - OK
mkdir -p "${LAB_DIR}/vendor/lib-json-parser"
cat << 'EOF' > "${LAB_DIR}/vendor/lib-json-parser/LICENSE"
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy...
EOF
cat << 'EOF' > "${LAB_DIR}/vendor/lib-json-parser/package.json"
{
  "name": "lib-json-parser",
  "spdx": "MIT",
  "type": "Permissive"
}
EOF

# Vendor Module B: Strong Copyleft (GPL-3.0-only) included in Permissive Project - VIOLATION
mkdir -p "${LAB_DIR}/vendor/lib-gpl-crypto"
cat << 'EOF' > "${LAB_DIR}/vendor/lib-gpl-crypto/LICENSE"
GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007
Everyone is permitted to copy and distribute verbatim copies...
EOF
cat << 'EOF' > "${LAB_DIR}/vendor/lib-gpl-crypto/package.json"
{
  "name": "lib-gpl-crypto",
  "spdx": "GPL-3.0-only",
  "type": "Strong Copyleft"
}
EOF

# Vendor Module C: Non-OSI Source Available (SSPL-1.0) - VIOLATION (Not Open Source according to OSI)
mkdir -p "${LAB_DIR}/vendor/lib-cloud-db"
cat << 'EOF' > "${LAB_DIR}/vendor/lib-cloud-db/LICENSE"
SERVER SIDE PUBLIC LICENSE
Version 1, October 16, 2018...
EOF
cat << 'EOF' > "${LAB_DIR}/vendor/lib-cloud-db/package.json"
{
  "name": "lib-cloud-db",
  "spdx": "SSPL-1.0",
  "type": "Non-OSI Approved"
}
EOF

# 4. Create the CI/CD Automated License Compliance Auditor Script
cat << 'EOF' > "${AUDIT_SCRIPT}"
#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="/tmp/license_compliance_lab"
ERRORS=0

echo "[*] Running Open Source License & Compliance Audit..."

# Check 1: Verify SPDX Header Validity in Source Files
echo "--> Step 1: Auditing source code SPDX headers..."
VALID_SPDX_IDS=("Apache-2.0" "MIT" "BSD-3-Clause")

for src_file in "${LAB_DIR}"/src/*.py; do
    fname=$(basename "${src_file}")
    if ! grep -q "SPDX-License-Identifier:" "${src_file}"; then
        echo "  [FAIL] Missing SPDX header in ${fname}"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    spdx_id=$(grep "SPDX-License-Identifier:" "${src_file}" | awk '{print $NF}')
    is_valid=0
    for valid in "${VALID_SPDX_IDS[@]}"; do
        if [[ "${spdx_id}" == "${valid}" ]]; then
            is_valid=1
            break
        fi
    done

    if [[ ${is_valid} -eq 0 ]]; then
        echo "  [FAIL] Invalid or unapproved SPDX identifier '${spdx_id}' in ${fname}"
        ERRORS=$((ERRORS + 1))
    else
        echo "  [PASS] Valid SPDX identifier '${spdx_id}' in ${fname}"
    fi
done

# Check 2: Audit Vendor Dependencies for License Compatibility & OSI Compliance
echo "--> Step 2: Auditing vendored package licenses against project policy..."
ALLOWED_LICENSES=("MIT" "Apache-2.0" "BSD-3-Clause" "ISC")

for pkg_json in "${LAB_DIR}"/vendor/*/package.json; do
    pkg_name=$(grep '"name"' "${pkg_json}" | cut -d'"' -f4)
    pkg_spdx=$(grep '"spdx"' "${pkg_json}" | cut -d'"' -f4)
    pkg_type=$(grep '"type"' "${pkg_json}" | cut -d'"' -f4)

    # Check OSI approval
    if [[ "${pkg_type}" == "Non-OSI Approved" ]]; then
        echo "  [FAIL] Dependency '${pkg_name}' uses '${pkg_spdx}' which is NOT OSI-approved open source."
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Check Copyleft vs Permissive Compatibility for Apache-2.0 target
    if [[ "${pkg_type}" == "Strong Copyleft" ]]; then
        echo "  [FAIL] Incompatible license! Dependency '${pkg_name}' is Strong Copyleft (${pkg_spdx}). Linking GPL code forces the entire project to be GPL (Copyleft Reciprocity Violation for Apache-2.0 target)."
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Check against allowed list
    is_allowed=0
    for allowed in "${ALLOWED_LICENSES[@]}"; do
        if [[ "${pkg_spdx}" == "${allowed}" ]]; then
            is_allowed=1
            break
        fi
    done

    if [[ ${is_allowed} -eq 1 ]]; then
        echo "  [PASS] Dependency '${pkg_name}' (${pkg_spdx}) is compliant."
    else
        echo "  [FAIL] Dependency '${pkg_name}' uses unapproved license '${pkg_spdx}'."
        ERRORS=$((ERRORS + 1))
    fi
done

echo "----------------------------------------------------------------------"
if [[ ${ERRORS} -gt 0 ]]; then
    echo "[!] LICENSE AUDIT FAILED with ${ERRORS} violation(s)."
    exit 1
else
    echo "[SUCCESS] ALL LICENSE COMPLIANCE CHECKS PASSED!"
    exit 0
fi
EOF

chmod +x "${AUDIT_SCRIPT}"

# ------------------------------------------------------------------------------
# Display Problem Statement & Student Instructions
# ------------------------------------------------------------------------------
echo ""
echo "======================================================================"
echo " SYMPTOM DESCRIPTION & TASK OBJECTIVE"
echo "======================================================================"
echo "You are an SRE / Platform Architect auditing software license compliance"
echo "for a commercial project ('Enterprise Data Router') targeting an Apache-2.0 license."
echo ""
echo "The CI pipeline run failed when executing '${AUDIT_SCRIPT}'."
echo ""
echo "YOUR OBJECTIVES:"
echo "1. Run '${AUDIT_SCRIPT}' and analyze the failure output."
echo "2. Fix all SPDX header violations in '${LAB_DIR}/src/':"
echo "   - Ensure all python source files contain a valid standard SPDX identifier matching Apache-2.0."
echo "3. Resolve License Compatibility & OSI Open Source Definition violations in '${LAB_DIR}/vendor/':"
echo "   - Understand why 'GPL-3.0-only' (Strong Copyleft) cannot be linked into a Permissive (Apache-2.0) project without copyleft reciprocity."
echo "   - Replace or update the non-compliant dependencies with compliant alternatives (e.g. LGPL/MIT/Apache-2.0 compatible modules)."
echo "   - Understand why 'SSPL-1.0' fails the OSI Open Source Definition (OSD) requirement."
echo "4. Re-run '${AUDIT_SCRIPT}' until it outputs: [SUCCESS] ALL LICENSE COMPLIANCE CHECKS PASSED!"
echo "======================================================================"
echo ""

# Execute audit to present immediate failure state to student
"${AUDIT_SCRIPT}" || true

# ==============================================================================
# STEP-BY-STEP SOLUTION & EXPLANATION (STUDENT REFERENCE)
# ==============================================================================
#
# BACKGROUND & THEORETICAL CONCEPTS (LPI 050-100 Topic 2.1):
#
# 1. Permissive Licenses (MIT, Apache-2.0, BSD):
#    - Allow royalty-free use, modification, and redistribution.
#    - Do NOT require derivative works or combined projects to release source code under the same license.
#    - Apache-2.0 includes explicit patent grant clauses.
#
# 2. Copyleft Licenses (GPL, AGPL, LGPL):
#    - Strong Copyleft (GPLv2, GPLv3, AGPLv3): Requires any derivative work or combined application to be licensed entirely under the GPL/AGPL when distributed.
#      You CANNOT embed GPL code inside a proprietary or purely Apache-2.0 licensed software product without relicensing the combined work under GPL.
#    - Weak Copyleft (LGPL, MPL): Applies copyleft only to modifications of the library itself. Linking dynamically to an LGPL library from a permissive/proprietary program is permitted.
#
# 3. Open Source Definition (OSD) & Non-OSI Licenses (e.g., SSPL, BSL):
#    - Managed by the Open Source Initiative (OSI).
#    - Requires no discrimination against fields of endeavor, no restrictions on commercial use, and free redistribution.
#    - Licenses like SSPL (Server Side Public License) restrict commercial cloud hosting, violating OSD Clause 6 (No Discrimination Against Fields of Endeavor). Thus, SSPL is NOT Open Source.
#
# 4. SPDX Identifiers:
#    - Standardized short strings (e.g. `SPDX-License-Identifier: Apache-2.0`) defined by the Linux Foundation to simplify machine-readable license scanning in file headers.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP COMMANDS TO FIX THE LAB:
# ------------------------------------------------------------------------------
#
# Step 1: Fix invalid/missing SPDX headers in source code
# --------------------------------------------------------
# File 1: /tmp/license_compliance_lab/src/router.py
# Fix the typo in SPDX identifier from 'Invalid-Custom-License-1.0' to 'Apache-2.0'
#
# Command:
# sed -i 's/SPDX-License-Identifier: Invalid-Custom-License-1.0/SPDX-License-Identifier: Apache-2.0/' /tmp/license_compliance_lab/src/router.py
#
# File 2: /tmp/license_compliance_lab/src/telemetry.py
# Add missing SPDX header at the top of the file:
#
# Command:
# sed -i '1i # SPDX-License-Identifier: Apache-2.0\n# Copyright (c) 2026 Enterprise Corp.' /tmp/license_compliance_lab/src/telemetry.py
#
# Step 2: Fix vendor dependency violations
# ----------------------------------------
# Issue A: 'lib-gpl-crypto' uses GPL-3.0-only (Strong Copyleft).
# Solution: Replace with a permissively licensed crypto module, e.g., 'lib-mit-crypto' using MIT license.
#
# Commands:
# rm -rf /tmp/license_compliance_lab/vendor/lib-gpl-crypto
# mkdir -p /tmp/license_compliance_lab/vendor/lib-mit-crypto
# cat << 'SOL' > /tmp/license_compliance_lab/vendor/lib-mit-crypto/package.json
# {
#   "name": "lib-mit-crypto",
#   "spdx": "MIT",
#   "type": "Permissive"
# }
# SOL
# cat << 'SOL' > /tmp/license_compliance_lab/vendor/lib-mit-crypto/LICENSE
# MIT License
# SOL
#
# Issue B: 'lib-cloud-db' uses SSPL-1.0 (Non-OSI Approved Source-Available License).
# Solution: Replace with an OSI-approved Apache-2.0 database client module, e.g., 'lib-open-db'.
#
# Commands:
# rm -rf /tmp/license_compliance_lab/vendor/lib-cloud-db
# mkdir -p /tmp/license_compliance_lab/vendor/lib-open-db
# cat << 'SOL' > /tmp/license_compliance_lab/vendor/lib-open-db/package.json
# {
#   "name": "lib-open-db",
#   "spdx": "Apache-2.0",
#   "type": "Permissive"
# }
# SOL
# cat << 'SOL' > /tmp/license_compliance_lab/vendor/lib-open-db/LICENSE
# Apache License Version 2.0
# SOL
#
# Step 3: Verify the Fix
# ----------------------
# Run:
# /tmp/license_compliance_lab/audit_licenses.sh
#
# Expected output:
# --> Step 1: Auditing source code SPDX headers...
#   [PASS] Valid SPDX identifier 'Apache-2.0' in main.py
#   [PASS] Valid SPDX identifier 'Apache-2.0' in router.py
#   [PASS] Valid SPDX identifier 'Apache-2.0' in telemetry.py
# --> Step 2: Auditing vendored package licenses against project policy...
#   [PASS] Dependency 'lib-json-parser' (MIT) is compliant.
#   [PASS] Dependency 'lib-mit-crypto' (MIT) is compliant.
#   [PASS] Dependency 'lib-open-db' (Apache-2.0) is compliant.
# ----------------------------------------------------------------------
# [SUCCESS] ALL LICENSE COMPLIANCE CHECKS PASSED!
# ==============================================================================