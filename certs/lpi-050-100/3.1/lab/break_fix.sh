#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 3.1: Concepts of Open Content Licenses (Weight: 5)
# Break & Fix Production Simulation Laboratory
# Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# ==============================================================================
#
# DESCRIPTION:
# This lab simulates a production static site generator and documentation 
# compliance audit pipeline. The organization publishes open educational content,
# documentation, and media assets using standard Open Content licenses 
# (Creative Commons family, GFDL, CC0).
#
# The automated compliance validator script enforces license compatibility,
# mandatory attribution metadata, and copyleft/derivative restrictions before 
# deploying artifacts to the public CDN.
#
# SCENARIO & BROKEN STATE:
# An automated documentation build pipeline is failing during the license audit step.
# A contributor pushed new content modules with invalid Creative Commons combinations
# and missing mandatory attribution metadata according to Open Content specifications.
#
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/open_content_lab"
BUILD_LOG="${LAB_DIR}/build.log"

echo "======================================================================"
echo " Setting up LPI 050-100 Topic 3.1 Laboratory: Open Content Licensing"
echo "======================================================================"

# Clean up previous runs cleanly
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/docs/modules" "${LAB_DIR}/bin"

# Create license database specification
cat << 'EOF' > "${LAB_DIR}/docs/manifest.json"
{
  "project": "Cloud Native Architecture Guide",
  "default_license": "CC-BY-SA-4.0",
  "modules": [
    {
      "id": "mod-01-intro",
      "file": "modules/01_introduction.md",
      "license": "CC-BY-4.0",
      "attribution": {
        "author": "Cloud Native Foundation",
        "title": "Introduction to Microservices",
        "url": "https://example.org/intro"
      }
    },
    {
      "id": "mod-02-storage",
      "file": "modules/02_storage_architecture.md",
      "license": "CC-BY-SA-4.0",
      "attribution": {
        "author": "Storage Working Group",
        "title": "Distributed Storage Basics",
        "url": "https://example.org/storage"
      }
    },
    {
      "id": "mod-03-security",
      "file": "modules/03_security_hardening.md",
      "license": "CC-BY-NC-ND-4.0",
      "attribution": {
        "author": "SecOps Team",
        "title": "Hardening Guide",
        "url": "https://example.org/security"
      }
    },
    {
      "id": "mod-04-public-domain-assets",
      "file": "modules/04_public_assets.md",
      "license": "CC0-1.0",
      "attribution": {
        "author": "Community Contributors",
        "title": "Public Domain Cheatsheet",
        "url": "https://example.org/assets"
      }
    }
  ]
}
EOF

# Create module files
cat << 'EOF' > "${LAB_DIR}/docs/modules/01_introduction.md"
---
title: Introduction to Cloud Native Architecture
license: CC-BY-4.0
author: Cloud Native Foundation
---
# Introduction to Cloud Native Architecture
This module introduces core concepts of cloud-native computing.
EOF

cat << 'EOF' > "${LAB_DIR}/docs/modules/02_storage_architecture.md"
---
title: Distributed Storage Architecture
license: CC-BY-SA-4.0
author: Storage Working Group
---
# Distributed Storage Architecture
Derived from CC-BY-SA upstream sources. Must remain under ShareAlike terms.
EOF

# BROKEN MODULE 1: Incompatible license mix (CC-BY-NC-ND vs Commercial & Adaptation Pipeline)
cat << 'EOF' > "${LAB_DIR}/docs/modules/03_security_hardening.md"
---
title: Security Hardening & Compliance
license: CC-BY-NC-ND-4.0
author: SecOps Team
---
# Security Hardening & Compliance
This document contains security rules.
Notice: Pipeline rules require commercial re-use and derivative adaptations.
EOF

# BROKEN MODULE 2: Missing mandatory CC-BY attribution metadata in document body
cat << 'EOF' > "${LAB_DIR}/docs/modules/04_public_assets.md"
---
title: Reference Diagrams & Assets
license: CC-BY-4.0
---
# Public Domain Cheatsheet
This document uses CC-BY-4.0 content but lacks explicit attribution details!
EOF

# Create validation engine
cat << 'EOF' > "${LAB_DIR}/bin/audit_licensing.py"
#!/usr/bin/env python3
import json
import sys
import os
import re

LAB_DIR = "/tmp/open_content_lab"
MANIFEST_PATH = os.path.join(LAB_DIR, "docs/manifest.json")

VALID_OPEN_CONTENT_LICENSES = [
    "CC0-1.0",
    "CC-BY-4.0",
    "CC-BY-SA-4.0",
    "FAL-1.3",
    "GFDL-1.3"
]

RESTRICTED_NON_FREE_CONTENT_LICENSES = [
    "CC-BY-NC-4.0",
    "CC-BY-ND-4.0",
    "CC-BY-NC-SA-4.0",
    "CC-BY-NC-ND-4.0"
]

def audit():
    print("[+] Starting Open Content License Compliance Audit...")
    if not os.path.exists(MANIFEST_PATH):
        print(f"[FATAL] Manifest file missing: {MANIFEST_PATH}")
        sys.exit(1)

    with open(MANIFEST_PATH, "r") as f:
        manifest = json.load(f)

    errors = 0
    warnings = 0

    for mod in manifest.get("modules", []):
        mod_id = mod.get("id")
        lic = mod.get("license")
        file_path = os.path.join(LAB_DIR, "docs", mod.get("file"))

        print(f"\n[*] Auditing Module [{mod_id}] ({file_path})...")

        # Rule 1: Check Open Content Definition Compliance
        if lic in RESTRICTED_NON_FREE_CONTENT_LICENSES:
            print(f"  [ERROR] License '{lic}' violates Open Content / Free Cultural Works guidelines!")
            print("          NonCommercial (NC) and NoDerivatives (ND) clauses restrict commercial use and adaptations.")
            print("          Allowed Open Content licenses: CC0-1.0, CC-BY-4.0, CC-BY-SA-4.0, FAL-1.3, GFDL-1.3.")
            errors += 1
        elif lic not in VALID_OPEN_CONTENT_LICENSES:
            print(f"  [ERROR] Unknown or unapproved license: '{lic}'")
            errors += 1
        else:
            print(f"  [OK] License '{lic}' meets Open Content standard criteria.")

        # Rule 2: Verify Attribution (BY requirement)
        if lic.startswith("CC-BY"):
            attr = mod.get("attribution", {})
            author = attr.get("author")
            title = attr.get("title")

            if not author or not title:
                print(f"  [ERROR] License '{lic}' requires mandatory 'BY' (Attribution) metadata (author and title missing in manifest).")
                errors += 1

            # Check markdown header attribution
            if os.path.exists(file_path):
                with open(file_path, "r") as mf:
                    content = mf.read()
                    if "author:" not in content.lower():
                        print(f"  [ERROR] File '{mod.get('file')}' is missing frontmatter 'author' field for CC-BY compliance.")
                        errors += 1

        # Rule 3: ShareAlike (SA) copyleft enforcement
        if lic == "CC-BY-SA-4.0":
            print("  [INFO] Copyleft clause active (ShareAlike). Any derivatives must inherit CC-BY-SA-4.0.")

    print("\n" + "="*50)
    if errors > 0:
        print(f"[FAIL] Audit failed with {errors} error(s). Build aborted.")
        sys.exit(1)
    else:
        print("[SUCCESS] All modules compliant with Open Content Licensing standards!")
        sys.exit(0)

if __name__ == "__main__":
    audit()
EOF

chmod +x "${LAB_DIR}/bin/audit_licensing.py"

# Simulate execution of broken lab
"${LAB_DIR}/bin/audit_licensing.py" > "${BUILD_LOG}" 2>&1 || true

cat << EOF

======================================================================
  LPI 050-100 LAB INSTRUCTIONS - TOPIC 3.1: OPEN CONTENT LICENSES
======================================================================

Symptom Report:
--------------
The continuous delivery pipeline for open content documentation failed.
Review the build log at: ${BUILD_LOG}

Task Objectives:
---------------
1. Analyze the core principles of Open Content & Free Cultural Works licenses:
   - Creative Commons Attribution (CC BY)
   - Creative Commons ShareAlike (CC BY-SA)
   - Creative Commons NonCommercial (CC BY-NC)
   - Creative Commons NoDerivatives (CC BY-ND)
   - CC0 (Public Domain Dedication)
   - GNU Free Documentation License (GFDL) / Free Art License (FAL)

2. Identify why module 03 ('mod-03-security') and module 04 ('mod-04-public-domain-assets')
   fail compliance checks against Open Content standards.

3. Fix the manifest file at '${LAB_DIR}/docs/manifest.json' and markdown files under
   '${LAB_DIR}/docs/modules/' so that:
   a) Module 03 uses a true Open Content / Free Cultural Works compliant license
      (e.g., CC-BY-SA-4.0 or CC-BY-4.0) instead of restricted NC/ND terms.
   b) Module 04 fulfills all CC-BY attribution metadata requirements both in
      '${LAB_DIR}/docs/manifest.json' and in '${LAB_DIR}/docs/modules/04_public_assets.md'.

Verification Command:
--------------------
Run the audit engine again:
   ${LAB_DIR}/bin/audit_licensing.py

When all licensing rules, attribution requirements, and copyleft/ShareAlike criteria
are correctly configured, the command will exit with status 0 and output:
"[SUCCESS] All modules compliant with Open Content Licensing standards!"

======================================================================
EOF

# ==============================================================================
# SOLUTION AND STEP-BY-STEP DIAGNOSTIC GUIDE (COMMENTED OUT BELOW)
# ==============================================================================
#
# STEP 1: UNDERSTAND THE THEORY (LPI 050-100 TOPIC 3.1 CONCEPTS)
# ------------------------------------------------------------------------------
# Open Content / Free Cultural Works Definition:
# - Open Content licenses grant permissions to copy, modify, and redistribute content.
# - CC0, CC BY, and CC BY-SA are recognized as true Open Content / Free Cultural Works licenses.
# - NonCommercial (NC) restricts commercial usage, rendering content NON-FREE under standard
#   Open Content / Open Source definitions.
# - NoDerivatives (ND) prohibits modifications/adaptations, violating the freedom to adapt.
# - CC BY requires Attribution (author, title, source URL).
# - CC BY-SA enforces Copyleft (ShareAlike): modified versions must be released under CC BY-SA.
#
# STEP 2: INSPECT THE ERROR LOG
# ------------------------------------------------------------------------------
# View log details:
#   cat /tmp/open_content_lab/build.log
#
# Errors found:
# 1. 'mod-03-security': Uses 'CC-BY-NC-ND-4.0'. NC and ND violate Open Content rules.
# 2. 'mod-04-public-domain-assets': Uses 'CC-BY-4.0' in manifest but missing
#    author frontmatter in markdown file '04_public_assets.md'.
#
# STEP 3: FIX MODULE 03 LICENSING TERMS
# ------------------------------------------------------------------------------
# Edit /tmp/open_content_lab/docs/manifest.json:
# Update 'mod-03-security' license from "CC-BY-NC-ND-4.0" to "CC-BY-SA-4.0".
#
# Example command using jq / sed or text editor:
#   sed -i 's/"CC-BY-NC-ND-4.0"/"CC-BY-SA-4.0"/g' /tmp/open_content_lab/docs/manifest.json
#
# STEP 4: FIX MODULE 04 ATTRIBUTION METADATA
# ------------------------------------------------------------------------------
# 1) Ensure /tmp/open_content_lab/docs/manifest.json has full attribution for mod-04:
#    "attribution": {
#      "author": "Community Contributors",
#      "title": "Public Domain Cheatsheet",
#      "url": "https://example.org/assets"
#    }
#
# 2) Edit /tmp/open_content_lab/docs/modules/04_public_assets.md to include 'author' metadata:
#
# cat << 'EOF' > /tmp/open_content_lab/docs/modules/04_public_assets.md
# ---
# title: Reference Diagrams & Assets
# license: CC-BY-4.0
# author: Community Contributors
# ---
# # Public Domain Cheatsheet
# Explicitly attributed to Community Contributors under CC-BY-4.0.
# EOF
#
# STEP 5: RE-RUN VERIFICATION AUDIT
# ------------------------------------------------------------------------------
#   /tmp/open_content_lab/bin/audit_licensing.py
#
# Expected output:
#   [SUCCESS] All modules compliant with Open Content Licensing standards!
# ==============================================================================