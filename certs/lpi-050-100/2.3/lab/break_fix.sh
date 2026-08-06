#!/bin/bash
# ==============================================================================
# LPI 050-100 Open Source Essentials - Topic 2.3: Permissive Software Licenses
# BREAK & FIX LAB: Open Source Software License Compliance Audit & Attribution Engine
# ==============================================================================
# Author: Principal Platform Architect & Senior SRE Instructor
# Target Certification: LPI Open Source Essentials (Exam 050-100)
# Topic: 2.3 Permissive Software Licenses (Weight: 7.5)
# Official References:
# - https://www.lpi.org/our-certifications/open-source-essentials-overview/
# - https://opensource.org/licenses/MIT
# - https://opensource.org/licenses/BSD-3-Clause
# - https://www.apache.org/licenses/LICENSE-2.0
# - https://www.gnu.org/licenses/license-list.html
# ==============================================================================

set -euo pipefail

LAB_DIR="/opt/compliance-lab/microservice-api"
AUDIT_SCRIPT="/usr/local/bin/check-license-compliance.sh"

echo "[+] Initializing LPI 050-100 Topic 2.3 (Permissive Software Licenses) Lab Environment..."

# 1. Clean and setup lab directory structure
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/vendor/fast-hash"
mkdir -p "${LAB_DIR}/vendor/crypto-utils"
mkdir -p "${LAB_DIR}/vendor/http-core"
mkdir -p "${LAB_DIR}/vendor/json-parser"

# 2. Populate vendor libraries with source files and initial states
# MIT Component
cat << 'EOF' > "${LAB_DIR}/vendor/fast-hash/LICENSE"
MIT License

Copyright (c) 2026 FastHash Open Source Project Authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

# BSD 3-Clause Component
cat << 'EOF' > "${LAB_DIR}/vendor/crypto-utils/LICENSE"
BSD 3-Clause License

Copyright (c) 2026 CryptoUtils Technologies Inc.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED.
EOF

# Apache 2.0 Component
cat << 'EOF' > "${LAB_DIR}/vendor/http-core/LICENSE"
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION
EOF

cat << 'EOF' > "${LAB_DIR}/vendor/http-core/NOTICE.template"
HTTP Core Networking Engine
Copyright 2026 Apache Software Foundation Enterprise Projects

This product includes software developed at
The Apache Software Foundation (http://www.apache.org/).
EOF

# ISC Component
cat << 'EOF' > "${LAB_DIR}/vendor/json-parser/LICENSE"
ISC License

Copyright (c) 2026 OpenSource JSON Parser Group

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES.
EOF

# 3. Create the automated audit engine script
cat << 'EOF' > "${AUDIT_SCRIPT}"
#!/bin/bash
set -euo pipefail

LAB_DIR="/opt/compliance-lab/microservice-api"
ERRORS=0

echo "=========================================================================="
echo "    OPEN SOURCE COMPLIANCE AUDIT ENGINE (LPI 050-100 Topic 2.3)"
echo "=========================================================================="
echo "Target Workspace: ${LAB_DIR}"
echo ""

# Check 1: MIT License Attribution Check
echo -n "[AUDIT] Component 'fast-hash' (MIT License): Retains Copyright & Permission Clause... "
if grep -qi "Copyright" "${LAB_DIR}/vendor/fast-hash/LICENSE" && grep -q "Permission is hereby granted" "${LAB_DIR}/vendor/fast-hash/LICENSE"; then
    echo "[PASS]"
else
    echo "[FAIL]"
    echo "  -> CRITICAL VIOLATION: MIT License requires preserving both the copyright notice"
    echo "     and the explicit permission notice."
    ERRORS=$((ERRORS + 1))
fi

# Check 2: BSD 3-Clause Non-Endorsement Clause Check
echo -n "[AUDIT] Component 'crypto-utils' (BSD 3-Clause): Retains Non-Endorsement Clause... "
if grep -qi "neither the name of the copyright holder nor the names of its" "${LAB_DIR}/vendor/crypto-utils/LICENSE"; then
    echo "[PASS]"
else
    echo "[FAIL]"
    echo "  -> CRITICAL VIOLATION: BSD 3-Clause license modified to remove clause 3 (non-endorsement)."
    echo "     Removing clause 3 alters the license type to BSD 2-Clause, violating copyright retention terms."
    ERRORS=$((ERRORS + 1))
fi

# Check 3: Apache 2.0 NOTICE File Requirement (Section 4d)
echo -n "[AUDIT] Component 'http-core' (Apache 2.0): Section 4(d) NOTICE file compliance... "
if [ ! -f "${LAB_DIR}/vendor/http-core/NOTICE" ]; then
    echo "[FAIL]"
    echo "  -> CRITICAL VIOLATION: Apache License 2.0 Section 4(d) requires preserving"
    echo "     and redistributing the NOTICE file alongside the software."
    ERRORS=$((ERRORS + 1))
elif ! grep -qi "Copyright" "${LAB_DIR}/vendor/http-core/NOTICE"; then
    echo "[FAIL]"
    echo "  -> CRITICAL VIOLATION: NOTICE file present but missing attribution statements."
    ERRORS=$((ERRORS + 1))
else
    echo "[PASS]"
fi

# Check 4: ISC License Check
echo -n "[AUDIT] Component 'json-parser' (ISC License): Retains Copyright & Permission... "
if grep -qi "Copyright" "${LAB_DIR}/vendor/json-parser/LICENSE" && grep -q "Permission to use, copy, modify" "${LAB_DIR}/vendor/json-parser/LICENSE"; then
    echo "[PASS]"
else
    echo "[FAIL]"
    echo "  -> CRITICAL VIOLATION: ISC License missing copyright notice."
    ERRORS=$((ERRORS + 1))
fi

echo "=========================================================================="
if [ ${ERRORS} -eq 0 ]; then
    echo "RESULT: ALL PERMISSIVE LICENSE COMPLIANCE AUDITS PASSED [EXIT 0]"
    exit 0
else
    echo "RESULT: COMPLIANCE AUDIT FAILED WITH ${ERRORS} VIOLATION(S) [EXIT 1]"
    exit 1
fi
EOF
chmod +x "${AUDIT_SCRIPT}"

# 4. INTRODUCE BREAKAGE (Controlled breakdown simulating developer compliance oversights)
# Violation A: Remove Copyright notice line from MIT component
sed -i '/Copyright (c)/d' "${LAB_DIR}/vendor/fast-hash/LICENSE"

# Violation B: Strip Non-Endorsement Clause from BSD 3-Clause component
sed -i '/Neither the name of the copyright holder/,+2d' "${LAB_DIR}/vendor/crypto-utils/LICENSE"

# Violation C: Remove required NOTICE file from Apache 2.0 component
rm -f "${LAB_DIR}/vendor/http-core/NOTICE"

# 5. Output student diagnostic banner
cat << 'EOF'

===============================================================================
             SRE / COMPLIANCE AUDITOR LAB: BREAK & FIX SCENARIO
===============================================================================
CERTIFICATION: LPI 050-100 Open Source Essentials
TOPIC:         2.3 Permissive Software Licenses (MIT, BSD, Apache 2.0, ISC)
WEIGHT:        7.5

Symptom:
  The CI/CD software bill of materials (SBOM) and license compliance engine
  failed during automated build verification of `/opt/compliance-lab/microservice-api`.

Goal:
  1. Execute the compliance audit tool:
     $ /usr/local/bin/check-license-compliance.sh

  2. Diagnose the output failures based on permissive software licensing mechanics:
     - MIT License: Must retain copyright notice and permission notice.
     - BSD 3-Clause: Must retain copyright, list of conditions, and non-endorsement clause.
     - Apache 2.0: Must preserve LICENSE and comply with Section 4(d) NOTICE file retention.

  3. Fix all licensing metadata violations under `/opt/compliance-lab/microservice-api/vendor/`
     so that `/usr/local/bin/check-license-compliance.sh` exits cleanly with status 0.

Official Reference URLs:
  - https://www.lpi.org/our-certifications/open-source-essentials-overview/
  - https://opensource.org/licenses/MIT
  - https://opensource.org/licenses/BSD-3-Clause
  - https://www.apache.org/licenses/LICENSE-2.0
===============================================================================
EOF

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (COMMENTED OUT)
# ==============================================================================
#
# ------------------------------------------------------------------------------
# PERMISSIVE LICENSES TECHNICAL MECHANICS & TRADE-OFFS (LPI 050-100 Topic 2.3)
# ------------------------------------------------------------------------------
# Permissive software licenses (also known as BSD-style or academic licenses)
# grant broad freedoms to inspect, modify, combine, and redistribute software
# under virtually any license model (including proprietary closed-source).
#
# Unlike Copyleft / Strong Copyleft licenses (e.g., GNU GPL v2/v3, AGPL), permissive
# licenses DO NOT contain reciprocity clauses (they do not force derivative works
# to be published under the same open source license).
#
# Key Permissive License Categories & Specific Requirements:
#
# 1. MIT License:
#    - Simplest and most widely used permissive license.
#    - Requirement: Copyright notice and permission notice MUST be retained in all
#      copies or substantial portions of the software.
#    - Trade-off: Maximum freedom, minimal legal protection beyond liability disclaimers.
#
# 2. BSD Licenses (Berkeley Software Distribution):
#    - BSD 2-Clause ("Simplified" or "FreeBSD" License):
#      Requires (1) source code retains copyright notice, (2) binary redistributions
#      reproduce copyright notice in documentation.
#    - BSD 3-Clause ("New" or "Modified" License):
#      Adds Clause 3 (Non-endorsement clause): Explicitly forbids using the name of
#      the project, copyright holder, or contributors to promote derived products
#      without prior written authorization.
#    - BSD 4-Clause ("Original"): Includes an legacy advertising clause requiring
#      acknowledgment in all advertising materials (now deprecated/discouraged).
#
# 3. Apache License 2.0:
#    - Enterprise-grade permissive license designed for modern software engineering.
#    - Express Patent Grant (Section 3): Grants explicit patent licenses from contributors
#      to users, with automated patent retaliation clauses.
#    - Section 4(d) NOTICE File: If the original work includes a "NOTICE" text file,
#      redistributors MUST retain and distribute a readable copy of attribution notices
#      contained within the NOTICE file.
#
# 4. ISC License (Internet Systems Consortium):
#    - Functionally equivalent to MIT or BSD 2-Clause, simplified wording.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP DIAGNOSTIC AND REMEDIATION COMMANDS
# ------------------------------------------------------------------------------
#
# Step 1: Execute the audit tool to view exact compliance errors
# Command:
#   $ /usr/local/bin/check-license-compliance.sh
#
# Expected Error Output:
#   ==========================================================================
#       OPEN SOURCE COMPLIANCE AUDIT ENGINE (LPI 050-100 Topic 2.3)
#   ==========================================================================
#   Target Workspace: /opt/compliance-lab/microservice-api
#   
#   [AUDIT] Component 'fast-hash' (MIT License): Retains Copyright & Permission Clause... [FAIL]
#     -> CRITICAL VIOLATION: MIT License requires preserving both the copyright notice
#        and the explicit permission notice.
#   [AUDIT] Component 'crypto-utils' (BSD 3-Clause): Retains Non-Endorsement Clause... [FAIL]
#     -> CRITICAL VIOLATION: BSD 3-Clause license modified to remove clause 3 (non-endorsement).
#        Removing clause 3 alters the license type to BSD 2-Clause, violating copyright retention terms.
#   [AUDIT] Component 'http-core' (Apache 2.0): Section 4(d) NOTICE file compliance... [FAIL]
#     -> CRITICAL VIOLATION: Apache License 2.0 Section 4(d) requires preserving
#        and redistributing the NOTICE file alongside the software.
#   [AUDIT] Component 'json-parser' (ISC License): Retains Copyright & Permission... [PASS]
#   ==========================================================================
#   RESULT: COMPLIANCE AUDIT FAILED WITH 3 VIOLATION(S) [EXIT 1]
#
# ------------------------------------------------------------------------------
# Step 2: Fix Violation 1 - MIT Copyright Notice Restoration
# Command:
#   $ cat << 'EOF_MIT' > /opt/compliance-lab/microservice-api/vendor/fast-hash/LICENSE
# MIT License
# 
# Copyright (c) 2026 FastHash Open Source Project Authors
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# EOF_MIT
#
# ------------------------------------------------------------------------------
# Step 3: Fix Violation 2 - BSD 3-Clause Non-Endorsement Clause Restoration
# Command:
#   $ cat << 'EOF_BSD' > /opt/compliance-lab/microservice-api/vendor/crypto-utils/LICENSE
# BSD 3-Clause License
# 
# Copyright (c) 2026 CryptoUtils Technologies Inc.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
# 
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
# 
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED.
# EOF_BSD
#
# ------------------------------------------------------------------------------
# Step 4: Fix Violation 3 - Apache 2.0 Section 4(d) NOTICE File Restoration
# Command:
#   $ cp /opt/compliance-lab/microservice-api/vendor/http-core/NOTICE.template \
#        /opt/compliance-lab/microservice-api/vendor/http-core/NOTICE
#
# ------------------------------------------------------------------------------
# Step 5: Verification - Re-run the compliance audit engine
# Command:
#   $ /usr/local/bin/check-license-compliance.sh
#
# Expected Verification Output:
#   ==========================================================================
#       OPEN SOURCE COMPLIANCE AUDIT ENGINE (LPI 050-100 Topic 2.3)
#   ==========================================================================
#   Target Workspace: /opt/compliance-lab/microservice-api
#   
#   [AUDIT] Component 'fast-hash' (MIT License): Retains Copyright & Permission Clause... [PASS]
#   [AUDIT] Component 'crypto-utils' (BSD 3-Clause): Retains Non-Endorsement Clause... [PASS]
#   [AUDIT] Component 'http-core' (Apache 2.0): Section 4(d) NOTICE file compliance... [PASS]
#   [AUDIT] Component 'json-parser' (ISC License): Retains Copyright & Permission... [PASS]
#   ==========================================================================
#   RESULT: ALL PERMISSIVE LICENSE COMPLIANCE AUDITS PASSED [EXIT 0]
# ==============================================================================