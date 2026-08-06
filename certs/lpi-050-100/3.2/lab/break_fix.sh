#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 3.2: Creative Commons Licenses (Weight: 5)
# Lab Scenario: Production Asset Licensing Audit & Compliance Repair ("Break & Fix")
#
# Official References:
# - LPI 050-100 Objectives: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# - Creative Commons License Specs: https://creativecommons.org/licenses/
# - SPDX License List (CC identifiers): https://spdx.org/licenses/
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/cc-license-audit-lab"
VERIFIER_BIN="${LAB_DIR}/bin/verify-cc-compliance"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[+] Initializing LPI 050-100 Topic 3.2 Lab Environment...${NC}"

# Clean previous environment if exists
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/content/docs" "${LAB_DIR}/content/media" "${LAB_DIR}/bin"

# ------------------------------------------------------------------------------
# Create the Compliance Engine (Internal Mechanics & Verification Utility)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${VERIFIER_BIN}"
#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="/tmp/cc-license-audit-lab/content"
ERRORS=0

echo "======================================================================"
echo "          CREATIVE COMMONS (CC) COMPLIANCE AUDIT ENGINE               "
echo "======================================================================"
echo "Scanning asset tree: ${LAB_DIR}"
echo ""

check_file() {
    local file="$1"
    local rel_path="${file#$LAB_DIR/}"
    
    if [[ ! -f "$file" ]]; then
        return
    fi

    local spdx=""
    local attribution=""
    local modified=""
    local commercial=""

    spdx=$(grep -i "SPDX-License-Identifier:" "$file" | cut -d':' -f2- | tr -d ' ' || true)
    attribution=$(grep -i "Attribution:" "$file" | cut -d':' -f2- | xargs || true)
    modified=$(grep -i "Is-Modified:" "$file" | cut -d':' -f2- | tr -d ' ' || true)
    commercial=$(grep -i "Target-Use:" "$file" | cut -d':' -f2- | tr -d ' ' || true)

    echo -e "--> Auditing: \033[1m${rel_path}\033[0m"
    echo "    SPDX ID: ${spdx:-NONE}"

    # Rule 1: Valid SPDX syntax check for Creative Commons
    if [[ -n "$spdx" ]]; then
        if [[ "$spdx" == *"ND"* && "$spdx" == *"SA"* ]]; then
            echo -e "    \033[0;31m[FAIL] INVALID CC COMBINATION: 'ND' (NoDerivatives) and 'SA' (ShareAlike) are mutually exclusive.\033[0m"
            ERRORS=$((ERRORS + 1))
            return
        fi

        case "$spdx" in
            CC0-1.0|CC-BY-4.0|CC-BY-SA-4.0|CC-BY-NC-4.0|CC-BY-ND-4.0|CC-BY-NC-SA-4.0|CC-BY-NC-ND-4.0)
                echo -e "    \033[0;32m[OK] Recognized CC SPDX identifier.\033[0m"
                ;;
            *)
                echo -e "    \033[0;31m[FAIL] UNRECOGNIZED SPDX IDENTIFIER: '${spdx}'. Must follow official SPDX CC format (e.g., CC-BY-4.0).\033[0m"
                ERRORS=$((ERRORS + 1))
                return
                ;;
        esac
    else
        echo -e "    \033[0;31m[FAIL] MISSING HEADER: SPDX-License-Identifier tag missing.\033[0m"
        ERRORS=$((ERRORS + 1))
        return
    fi

    # Rule 2: BY (Attribution) Clause Enforcement
    if [[ "$spdx" == CC-BY* ]]; then
        if [[ -z "$attribution" || "$attribution" == "Unknown" || "$attribution" == "N/A" ]]; then
            echo -e "    \033[0;31m[FAIL] VIOLATION OF 'BY' CLAUSE: Creative Commons BY requires explicit creator attribution.\033[0m"
            ERRORS=$((ERRORS + 1))
        else
            echo -e "    \033[0;32m[OK] Attribution condition met: '${attribution}'.\033[0m"
        fi
    fi

    # Rule 3: ND (NoDerivatives) Clause Enforcement
    if [[ "$spdx" == *"ND"* ]]; then
        if [[ "$modified" == "true" || "$modified" == "YES" ]]; then
            echo -e "    \033[0;31m[FAIL] VIOLATION OF 'ND' CLAUSE: Asset has modifications but uses NoDerivatives (ND) license.\033[0m"
            ERRORS=$((ERRORS + 1))
        else
            echo -e "    \033[0;32m[OK] NoDerivatives condition respected (Unmodified asset).\033[0m"
        fi
    fi

    # Rule 4: NC (NonCommercial) Clause Enforcement
    if [[ "$spdx" == *"NC"* ]]; then
        if [[ "$commercial" == "Commercial" || "$commercial" == "enterprise-product" ]]; then
            echo -e "    \033[0;31m[FAIL] VIOLATION OF 'NC' CLAUSE: NonCommercial asset slated for enterprise commercial deployment.\033[0m"
            ERRORS=$((ERRORS + 1))
        else
            echo -e "    \033[0;32m[OK] NonCommercial boundary respected.\033[0m"
        fi
    fi

    # Rule 5: CC0 Public Domain Enforcement
    if [[ "$spdx" == "CC0-1.0" ]]; then
        if [[ -n "$attribution" && "$attribution" != "Public Domain" ]]; then
            echo -e "    \033[0;33m[WARN] CC0 waives copyright worldwide. Requiring restricted attribution contradicts public domain dedication.\033[0m"
        else
            echo -e "    \033[0;32m[OK] CC0 Public Domain Dedication valid.\033[0m"
        fi
    fi

    echo ""
}

export -f check_file
export LAB_DIR
export ERRORS

find "${LAB_DIR}" -type f \( -name "*.md" -o -name "*.txt" -o -name "*.meta" \) | while read -r f; do
    check_file "$f"
done

echo "======================================================================"
if [[ $ERRORS -eq 0 ]]; then
    echo -e "\033[0;32mAUDIT SUCCESSFUL: All Creative Commons assets comply with CNCF & LPI standards.\033[0m"
    exit 0
else
    echo -e "\033[0;31mAUDIT FAILED: Detected ${ERRORS} Creative Commons licensing compliance error(s).\033[0m"
    exit 1
fi
EOF

chmod +x "${VERIFIER_BIN}"

# ------------------------------------------------------------------------------
# Break Phase: Inject Licensing Errors & Real-world Misconfigurations
# ------------------------------------------------------------------------------

# Valid file for reference
cat << 'EOF' > "${LAB_DIR}/content/docs/README.md"
<!--
SPDX-License-Identifier: CC-BY-4.0
Attribution: Open Source Infrastructure Team
Is-Modified: false
Target-Use: Public-Docs
-->
# Project Documentation Gateway
This documentation is licensed under Creative Commons Attribution 4.0 International.
EOF

# VIOLATION 1: Contradictory License Combination (ND + SA combined)
cat << 'EOF' > "${LAB_DIR}/content/docs/ARCHITECTURE_OVERVIEW.md"
<!--
SPDX-License-Identifier: CC-BY-NC-ND-SA-4.0
Attribution: SRE Architecture Guild
Is-Modified: false
Target-Use: Internal-Knowledgebase
-->
# System Architecture Diagram & Topology
Internal architecture map for platform components.
EOF

# VIOLATION 2: CC BY Clause Violation (Missing required Attribution)
cat << 'EOF' > "${LAB_DIR}/content/docs/OPERATIONAL_RUNBOOK.md"
<!--
SPDX-License-Identifier: CC-BY-4.0
Attribution: N/A
Is-Modified: true
Target-Use: DevOps-Operations
-->
# Emergency Failover Runbook
Step-by-step procedures for regional failover.
EOF

# VIOLATION 3: CC ND Clause Violation (Modified content under NoDerivatives)
cat << 'EOF' > "${LAB_DIR}/content/media/INFRASTRUCTURE_DIAGRAM.meta"
SPDX-License-Identifier: CC-BY-ND-4.0
Attribution: Original Cloud Vector Art (Modified by Platform Team)
Is-Modified: YES
Target-Use: Web-Portal
EOF

# VIOLATION 4: CC NC Clause Violation (NonCommercial asset packaged for Commercial enterprise release)
cat << 'EOF' > "${LAB_DIR}/content/docs/ENTERPRISE_INTEGRATION_GUIDE.md"
<!--
SPDX-License-Identifier: CC-BY-NC-4.0
Attribution: Third-Party Community Contributor
Is-Modified: false
Target-Use: enterprise-product
-->
# Enterprise Integration Modules
SaaS integration documentation bundled into commercial enterprise subscription binaries.
EOF

echo -e "${GREEN}[+] Lab setup complete. Initializing diagnostic scenario...${NC}"
echo ""

# ------------------------------------------------------------------------------
# Student Instructions & Diagnostic Briefing
# ------------------------------------------------------------------------------
cat << 'EOF'
================================================================================
  LPI 050-100 TOPIC 3.2: CREATIVE COMMONS LICENSES - ACCELERATED SRE LAB
================================================================================

SCENARIO BRIEFING:
You are an SRE Platform Architect conducting a pre-publication legal & technical
compliance audit on software documentation, infrastructure diagrams, and media
assets before releasing them in a CNCF-compliant open-source distribution repository.

The CI/CD pipeline runs an automated Creative Commons scanner (`verify-cc-compliance`).
Currently, the pipeline is failing with multiple legal and structural license errors.

YOUR OBJECTIVE:
1. Execute the diagnostic verification script:
   /tmp/cc-license-audit-lab/bin/verify-cc-compliance

2. Identify and fix all Creative Commons licensing violations in `/tmp/cc-license-audit-lab/content/`:
   - Understand the 4 core CC condition building blocks:
     * BY (Attribution): Requires credit to original creator.
     * SA (ShareAlike): Derivatives must be released under identical/compatible license.
     * NC (NonCommercial): Cannot be used for commercial advantage or monetary compensation.
     * ND (NoDerivatives): Work can be copied/distributed, but CANNOT be remixed or modified.
   - Understand CC0 (Public Domain Dedication): Complete waiver of copyright.
   - Detect invalid CC combinations (e.g., ND and SA cannot exist together).

3. Re-run `/tmp/cc-license-audit-lab/bin/verify-cc-compliance` until the audit returns 0 errors.

EXPECTED INITIAL SYMPTOMS:
- `ARCHITECTURE_OVERVIEW.md`: Fails due to invalid SPDX combination `CC-BY-NC-ND-SA-4.0`.
- `OPERATIONAL_RUNBOOK.md`: Fails due to missing attribution (`Attribution: N/A`) under `CC-BY-4.0`.
- `INFRASTRUCTURE_DIAGRAM.meta`: Fails because `Is-Modified: YES` violates `CC-BY-ND-4.0`.
- `ENTERPRISE_INTEGRATION_GUIDE.md`: Fails because `Target-Use: enterprise-product` violates `CC-BY-NC-4.0`.

DIAGNOSTIC COMMANDS TO USE:
- Audit script:
  $ /tmp/cc-license-audit-lab/bin/verify-cc-compliance
- Inspect headers:
  $ grep -Hn "SPDX-License-Identifier" /tmp/cc-license-audit-lab/content/docs/* /tmp/cc-license-audit-lab/content/media/*
- Edit metadata headers via text editor or standard Linux utilities (`sed`, `vim`, `nano`).

================================================================================
EOF

# ==============================================================================
# STEP-BY-STEP SOLUTION (KEEP COMMENTED OUT FOR STUDENT EXERCISES)
# ==============================================================================
#
# STEP 1: Execute the audit engine to identify failing files.
#   $ /tmp/cc-license-audit-lab/bin/verify-cc-compliance
#
# STEP 2: Understand the underlying Creative Commons mechanics for each error:
#
# Error 1: ARCHITECTURE_OVERVIEW.md
#   Problem: License set to 'CC-BY-NC-ND-SA-4.0'.
#   Mechanism: Creative Commons licenses combine modular conditions (BY, NC, ND, SA).
#   However, NoDerivatives (ND) prohibits distributing modified versions, while
#   ShareAlike (SA) requires modified versions to be licensed identically. Thus,
#   ND and SA are logically mutually exclusive and cannot be combined.
#   Fix: Convert to a valid license such as CC-BY-NC-SA-4.0 or CC-BY-NC-ND-4.0.
#   Command:
#     sed -i 's/CC-BY-NC-ND-SA-4.0/CC-BY-NC-SA-4.0/g' /tmp/cc-license-audit-lab/content/docs/ARCHITECTURE_OVERVIEW.md
#
# Error 2: OPERATIONAL_RUNBOOK.md
#   Problem: SPDX is 'CC-BY-4.0' but Attribution is set to 'N/A'.
#   Mechanism: The 'BY' clause explicitly obligates any user/distributor to provide
#   attribution to the original author. Stating N/A breaks the core legal requirement.
#   Fix: Provide explicit creator attribution.
#   Command:
#     sed -i 's/Attribution: N\/A/Attribution: SRE Operations Team/g' /tmp/cc-license-audit-lab/content/docs/OPERATIONAL_RUNBOOK.md
#
# Error 3: INFRASTRUCTURE_DIAGRAM.meta
#   Problem: SPDX is 'CC-BY-ND-4.0' but metadata shows 'Is-Modified: YES'.
#   Mechanism: The 'ND' (NoDerivatives) condition allows sharing existing copies,
#   but explicitly forbids distributing altered, transformed, or built-upon versions.
#   Fix: Since the diagram was modified, the license must be changed to CC-BY-4.0
#        (or CC-BY-SA-4.0), removing the ND restriction.
#   Command:
#     sed -i 's/CC-BY-ND-4.0/CC-BY-4.0/g' /tmp/cc-license-audit-lab/content/media/INFRASTRUCTURE_DIAGRAM.meta
#
# Error 4: ENTERPRISE_INTEGRATION_GUIDE.md
#   Problem: SPDX is 'CC-BY-NC-4.0' but Target-Use is set to 'enterprise-product'.
#   Mechanism: The 'NC' (NonCommercial) clause restricts usage to non-monetary,
#   non-commercial purposes. Bundling NC-licensed documentation into a paid
#   commercial product violates the license terms.
#   Fix: Re-license the enterprise documentation under a commercial-friendly CC license
#        like CC-BY-4.0 (with author consent) or adjust target use for non-commercial distribution.
#   Command:
#     sed -i 's/CC-BY-NC-4.0/CC-BY-4.0/g' /tmp/cc-license-audit-lab/content/docs/ENTERPRISE_INTEGRATION_GUIDE.md
#
# STEP 3: Verify the fix.
#   $ /tmp/cc-license-audit-lab/bin/verify-cc-compliance
#   Expected output: "AUDIT SUCCESSFUL: All Creative Commons assets comply with CNCF & LPI standards."
# ==============================================================================