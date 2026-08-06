#!/bin/bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 2.2: Copyleft Software Licenses (Weight: 7.5)
# Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
#
# BREAK & FIX SCENARIO: Production Copyleft Compliance & Audit Failure
# ==============================================================================
# This script sets up a simulated enterprise release repository and automated
# license compliance checker (/usr/local/bin/audit-copyleft-compliance).
# It intentionally breaks compliance requirements (SPDX headers, LGPL dynamic
# linking rules, and GPL source distribution packaging) and challenges the student
# to resolve them.
# ==============================================================================

set -euo pipefail

# Color definitions for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LAB_DIR="/opt/production-app"
COMPLIANCE_DIR="/var/www/compliance/sources"
AUDIT_BIN="/usr/local/bin/audit-copyleft-compliance"

echo -e "${BLUE}[+] Initializing LPI 050-100 Topic 2.2 Copyleft Compliance Lab...${NC}"

# Clean existing lab setup if re-run
rm -rf "$LAB_DIR" "$COMPLIANCE_DIR" "$AUDIT_BIN"
mkdir -p "$LAB_DIR/src" "$LAB_DIR/bin" "$LAB_DIR/build" "$COMPLIANCE_DIR"

# ------------------------------------------------------------------------------
# STEP 1: Create source files and binaries
# ------------------------------------------------------------------------------

# File 1: Permissive module (MIT)
cat << 'EOF' > "$LAB_DIR/src/utils.c"
/*
 * SPDX-License-Identifier: MIT
 * Utility functions for production application.
 */
#include <stdio.stdio>
void print_version() { printf("App v1.0.0\n"); }
EOF

# File 2: Strong Copyleft module (GPL-3.0-or-later)
cat << 'EOF' > "$LAB_DIR/src/core_engine.c"
/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Core computation engine governed by GNU GPL v3.
 */
#include <stdio.h>
void run_engine() { printf("Running GPL Core Engine\n"); }
EOF

# File 3: Network Copyleft API module (AGPL-3.0-only) - MISSING SPDX HEADER (BREAK 1)
cat << 'EOF' > "$LAB_DIR/src/api_v2.py"
# Production API endpoint handling user requests over HTTP.
# This component interacts with AGPL-licensed microservices.
def handle_request():
    return "200 OK - AGPL Service Active"
EOF

# Build configuration file specifying linking mode for Weak Copyleft (LGPL-3.0-only)
# BREAK 2: LGPL library set to STATIC instead of DYNAMIC linking without source release
cat << 'EOF' > "$LAB_DIR/build/build.conf"
LINK_MODE_LGPL_MATH="STATIC"
TARGET_BINARY="core_engine"
VERSION="1.0.0"
EOF

# Create dummy binary artifact
touch "$LAB_DIR/bin/core_engine"

# ------------------------------------------------------------------------------
# STEP 2: Install Automated Compliance Audit Tool
# ------------------------------------------------------------------------------

cat << 'EOF' > "$AUDIT_BIN"
#!/bin/bash
set -euo pipefail

LAB_DIR="/opt/production-app"
COMPLIANCE_DIR="/var/www/compliance/sources"
BUILD_CONF="$LAB_DIR/build/build.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0

echo "================================================================="
echo "       AUTOMATED COPYLEFT COMPLIANCE AUDIT ENGINE (LPI-050)"
echo "================================================================="

# Check 1: SPDX Headers on Source Files
echo -n "[CHECK 1] Validating SPDX License Identifiers in source files... "
MISSING_SPDX=()
for file in $(find "$LAB_DIR/src" -type f \( -name "*.c" -o -name "*.py" \)); do
    if ! grep -q "SPDX-License-Identifier:" "$file"; then
        MISSING_SPDX+=("$file")
    fi
done

if [ ${#MISSING_SPDX[@]} -eq 0 ]; then
    echo -e "${GREEN}PASSED${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo -e "  ${YELLOW}Reason:${NC} The following files lack valid SPDX license headers:"
    for f in "${MISSING_SPDX[@]}"; do
        echo "    - $f"
    done
    ERRORS=$((ERRORS + 1))
fi

# Check 2: GPL-3.0 / AGPL-3.0 Source Code Distribution Requirement
echo -n "[CHECK 2] Verifying Source Release packages for Strong Copyleft components... "
GPL_TARBALL="$COMPLIANCE_DIR/core_engine-1.0.0.tar.gz"
if [ -f "$GPL_TARBALL" ]; then
    echo -e "${GREEN}PASSED${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo -e "  ${YELLOW}Reason:${NC} Missing mandatory source distribution archive: $GPL_TARBALL"
    echo -e "          GPLv3 / AGPLv3 mandates offering full source code when binaries are distributed."
    ERRORS=$((ERRORS + 1))
fi

# Check 3: LGPL-3.0 Relinking / Dynamic Linking Requirement (Weak Copyleft)
echo -n "[CHECK 3] Auditing Weak Copyleft (LGPL) library linking mechanism... "
LINK_MODE=$(grep "^LINK_MODE_LGPL_MATH=" "$BUILD_CONF" | cut -d'=' -f2 | tr -d '"')
if [ "$LINK_MODE" = "DYNAMIC" ]; then
    echo -e "${GREEN}PASSED${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo -e "  ${YELLOW}Reason:${NC} LGPL-3.0 library 'libmath' is configured for static linking ($LINK_MODE)."
    echo -e "          Weak Copyleft (LGPL) permits proprietary/closed integration ONLY if dynamically"
    echo -e "          linked or if object files are provided to allow user relinking."
    ERRORS=$((ERRORS + 1))
fi

echo "================================================================="
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}AUDIT SUCCESSFUL:${NC} All Copyleft compliance gates passed."
    exit 0
else
    echo -e "${RED}AUDIT FAILED:${NC} $ERRORS compliance violation(s) detected."
    exit 1
fi
EOF

chmod +x "$AUDIT_BIN"

# ------------------------------------------------------------------------------
# STEP 3: Display Scenario Information & Instructions
# ------------------------------------------------------------------------------

cat << EOF

===============================================================================
  LPI 050-100 (Open Source Essentials) - LAB BREAK & FIX
  Topic 2.2: Copyleft Software Licenses
===============================================================================

SITUATION:
You are an SRE / Platform Architect ensuring open source license compliance in
a continuous integration pipeline. The automated compliance auditor tool:
  $AUDIT_BIN
is reporting multiple compliance failures on the release candidate located at:
  $LAB_DIR

OBSERVED SYMPTOMS:
Running '$AUDIT_BIN' produces 3 compliance blockages.

YOUR TASK:
Analyze the copyleft licensing requirements for Strong Copyleft (GPLv3/AGPLv3),
Weak Copyleft (LGPLv3), and SPDX standardization, then fix the codebase and
configuration so that '$AUDIT_BIN' passes clean (exit status 0).

RESOURCES / REFERENCES:
- LPI 050-100 Topic 2.2: https://www.lpi.org/our-certifications/open-source-essentials-overview/
- SPDX License List: https://spdx.org/licenses/
- GNU Licenses (GPL, LGPL, AGPL): https://www.gnu.org/licenses/

===============================================================================
EOF

# Execute initial audit to display symptoms to the student
set +e
$AUDIT_BIN
set -e

echo ""
echo -e "${YELLOW}The lab environment is now live. Fix the 3 issues and re-run: audit-copyleft-compliance${NC}"
echo ""

# ==============================================================================
# STEP-BY-STEP SOLUTION (STUDENT REFERENCE)
# ==============================================================================
: '
--------------------------------------------------------------------------------
SOLUTION PASO A PASO / STEP-BY-STEP SOLUTION
--------------------------------------------------------------------------------

Issue 1: Missing SPDX Header on AGPL Source File
------------------------------------------------
Symptom:
  [CHECK 1] Validating SPDX License Identifiers in source files... FAILED
  Reason: The following files lack valid SPDX license headers: /opt/production-app/src/api_v2.py

Explanation:
  Copyleft governance requires clear identification of source licenses. SPDX
  (Software Package Data Exchange) standardized short identifiers like
  "AGPL-3.0-only" or "AGPL-3.0-or-later" provide unambiguous license metadata.

Fix:
  Edit /opt/production-app/src/api_v2.py and insert the correct SPDX header at line 1:

  # SPDX-License-Identifier: AGPL-3.0-or-later

Command:
  sed -i '1i # SPDX-License-Identifier: AGPL-3.0-or-later' /opt/production-app/src/api_v2.py


Issue 2: Missing Source Code Package for Strong Copyleft (GPLv3) Binary
------------------------------------------------------------------------
Symptom:
  [CHECK 2] Verifying Source Release packages for Strong Copyleft components... FAILED
  Reason: Missing mandatory source distribution archive: /var/www/compliance/sources/core_engine-1.0.0.tar.gz

Explanation:
  Strong Copyleft licenses (such as GPLv2, GPLv3, and AGPLv3) require that anyone
  receiving a binary distribution of the software must also be provided with access
  to the complete corresponding source code.

Fix:
  Create the required source release tarball containing the application sources.

Commands:
  tar -czvf /var/www/compliance/sources/core_engine-1.0.0.tar.gz -C /opt/production-app/src .


Issue 3: Incorrect Linking Mode for Weak Copyleft (LGPLv3) Component
----------------------------------------------------------------------
Symptom:
  [CHECK 3] Auditing Weak Copyleft (LGPL) library linking mechanism... FAILED
  Reason: LGPL-3.0 library 'libmath' is configured for static linking (STATIC).

Explanation:
  Weak Copyleft licenses (such as the GNU Lesser General Public License - LGPL)
  allow integration with non-copyleft or proprietary code without forcing the
  entire work to become copyleft, PROVIDED that the LGPL library is dynamically
  linked (so users can replace/upgrade the library) or relocatable object files
  are provided for relinking. Static linking without providing relinkable objects
  violates the LGPL copyleft boundary.

Fix:
  Update /opt/production-app/build/build.conf to change LINK_MODE_LGPL_MATH from "STATIC" to "DYNAMIC".

Command:
  sed -i 's/LINK_MODE_LGPL_MATH="STATIC"/LINK_MODE_LGPL_MATH="DYNAMIC"/' /opt/production-app/build/build.conf


Verification:
-------------
Run the compliance auditor:
  audit-copyleft-compliance

Expected Output:
  =================================================================
         AUTOMATED COPYLEFT COMPLIANCE AUDIT ENGINE (LPI-050)
  =================================================================
  [CHECK 1] Validating SPDX License Identifiers in source files... PASSED
  [CHECK 2] Verifying Source Release packages for Strong Copyleft components... PASSED
  [CHECK 3] Auditing Weak Copyleft (LGPL) library linking mechanism... PASSED
  =================================================================
  AUDIT SUCCESSFUL: All Copyleft compliance gates passed.
--------------------------------------------------------------------------------
'