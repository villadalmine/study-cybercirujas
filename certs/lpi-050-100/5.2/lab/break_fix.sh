#!/bin/bash
# ==============================================================================
# LPI 050-100: Open Source Essentials - Topic 5.2: Product & Release Management
# Production-Grade Hands-On "Break & Fix" Simulation Lab
# ==============================================================================
# Official Reference Links:
# - LPI 050-100 Overview: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# - Semantic Versioning 2.0.0 (SemVer): https://semver.org/
# - GNU Software Release Standards: https://www.gnu.org/prep/standards/html_node/Releases.html
# - Linux Packaging & Release Best Practices: https://docs.kernel.org/process/submitting-patches.html
# ==============================================================================

set -euo pipefail

LAB_DIR="${HOME}/lpi-050-release-lab"

echo "========================================================================"
echo " [SETUP] Initializing LPI 050-100 Topic 5.2 Release Management Lab..."
echo "========================================================================"

# Check dependency requirements
if ! command -v git &> /dev/null || ! command -v tar &> /dev/null || ! command -v sha256sum &> /dev/null; then
    echo "[!] ERROR: Required utilities (git, tar, sha256sum) are missing."
    echo "    Please install them (e.g., sudo apt-get install -y git tar coreutils)."
    exit 1
fi

# Clean previous lab runs
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/src"

# Navigate to workspace
cd "${LAB_DIR}"

# Initialize local git repository for release tracking
git init -q
git config user.name "Release Engineer"
git config user.email "release@production.local"

# Create application source code
cat << 'EOF' > src/app.sh
#!/bin/bash
VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
echo "Starting Enterprise Core Engine v${VERSION}..."
EOF
chmod +x src/app.sh

# Create initial CHANGELOG.md
cat << 'EOF' > CHANGELOG.md
# Changelog

## [2.1.0] - 2026-08-06
### Added
- Added multi-tenant audit logging module.
- Added metrics endpoint for Prometheus scraping.

### Fixed
- Fixed memory leak in stream worker pool.
EOF

# Create initial VERSION file (Target Release Version)
echo "2.1.0" > VERSION

# Create build & packaging script (CONTAINING BUG 1 & BUG 2)
cat << 'EOF' > release-build.sh
#!/bin/bash
set -e

PROJECT_NAME="enterprise-engine"
VERSION=$(cat VERSION)
DIST_DIR="dist"
TARBALL="${DIST_DIR}/${PROJECT_NAME}-${VERSION}.tar.gz"

echo "==> Building Release Package: ${PROJECT_NAME} v${VERSION}"
mkdir -p "${DIST_DIR}"

# BUG 2: Omits CHANGELOG.md from release tarball, packaging only src directory
tar -czf "${TARBALL}" src/ VERSION

# BUG 3: Generates corrupted/stale SHA256SUMS file due to broken path reference
echo "==> Generating Release Checksum Manifest..."
# Intentionally writing corrupted path inside checksum manifest
echo "0000000000000000000000000000000000000000000000000000000000000000  ${TARBALL}" > "${DIST_DIR}/SHA256SUMS"

echo "==> Release Build Complete: ${TARBALL}"
EOF
chmod +x release-build.sh

# Create verification/audit script (Evaluates release readiness)
cat << 'EOF' > release-audit.sh
#!/bin/bash
set -e

PROJECT_NAME="enterprise-engine"
VERSION=$(cat VERSION 2>/dev/null || echo "")
DIST_DIR="dist"
TARBALL="${DIST_DIR}/${PROJECT_NAME}-${VERSION}.tar.gz"

echo "========================================================================"
echo " [AUDIT] Running Production Release Readiness Audit..."
echo "========================================================================"

# Test 1: SemVer Git Tag Alignment
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "NO_TAG")
EXPECTED_TAG="v${VERSION}"

echo -n "[TEST 1] Checking Git Release Tag consistency (${EXPECTED_TAG})... "
if [ "${LATEST_TAG}" != "${EXPECTED_TAG}" ]; then
    echo "FAILED"
    echo "         ERROR: Git tag '${LATEST_TAG}' does not match VERSION file '${EXPECTED_TAG}'!"
    echo "         Release Management Rule: Git tags MUST match SemVer VERSION file."
    exit 1
fi
echo "PASSED"

# Test 2: Release Artifact Existence
echo -n "[TEST 2] Verifying release bundle tarball existence... "
if [ ! -f "${TARBALL}" ]; then
    echo "FAILED"
    echo "         ERROR: ${TARBALL} not found. Run ./release-build.sh first."
    exit 2
fi
echo "PASSED"

# Test 3: Release Tarball Content Integrity (Must contain CHANGELOG.md, VERSION, src)
echo -n "[TEST 3] Checking Release Tarball contents for mandatory files... "
TAR_CONTENTS=$(tar -tzf "${TARBALL}")
if ! echo "${TAR_CONTENTS}" | grep -q "CHANGELOG.md"; then
    echo "FAILED"
    echo "         ERROR: Mandatory file 'CHANGELOG.md' missing from ${TARBALL}!"
    echo "         Release Packaging Rule: Tarballs must include CHANGELOG, LICENSE, and VERSION."
    exit 3
fi
echo "PASSED"

# Test 4: Cryptographic Integrity Verification (SHA256SUMS match)
echo -n "[TEST 4] Verifying SHA256 cryptographic checksum manifest... "
cd "${DIST_DIR}"
if ! sha256sum -c SHA256SUMS --status 2>/dev/null; then
    echo "FAILED"
    echo "         ERROR: Checksum verification failed for SHA256SUMS!"
    echo "         Release Integrity Rule: Digest manifest MUST match actual build artifacts."
    exit 4
fi
cd ..
echo "PASSED"

echo "------------------------------------------------------------------------"
echo " [SUCCESS] RELEASE AUDIT PASSED! Software is ready for production distribution."
echo "------------------------------------------------------------------------"
EOF
chmod +x release-audit.sh

# Commit files to git repository
git add .
git commit -m "feat(core): prepare release candidate 2.1.0" -q

# BUG 1: Create mismatched/incorrect legacy tag v2.0.9 instead of v2.1.0
git tag -a "v2.0.9" -m "Release v2.0.9"

# Execute initial broken build to establish dirty state
./release-build.sh > /dev/null 2>&1 || true

echo ""
echo "========================================================================"
echo "          PRODUCT MANAGEMENT & RELEASE MANAGEMENT (LPI 050-100)"
echo "            ADVANCED PRODUCTION TROUBLESHOOTING SIMULATION"
echo "========================================================================"
echo " ARCHITECTURAL BACKGROUND & INTERNAL MECHANICS:"
echo " ----------------------------------------------------------------------"
echo " In open-source and modern SRE release engineering, a Release Lifecycle"
echo " governs how software transitions from code to production artifacts:"
echo "   1. Semantic Versioning (SemVer 2.0.0): MAJOR.MINOR.PATCH"
echo "      - MAJOR: Incompatible API changes."
echo "      - MINOR: Backward-compatible functionality additions."
echo "      - PATCH: Backward-compatible bug fixes."
echo "   2. Release Tagging: Git annotations (git tag -a vX.Y.Z) create immutable"
echo "      pointers to release commits, aligning repo history with binaries."
echo "   3. Release Packaging & Tarballs: Distribution archives must be self-"
echo "      contained, carrying code, VERSION, and CHANGELOG.md."
echo "   4. Cryptographic Provenance: Artifacts are validated via SHA256 sum"
echo "      manifests (sha256sum) to detect distribution corruption or tampering."
echo ""
echo " TRADE-OFF ANALYSIS:"
echo "   - Time-based Releases vs. Feature-based Releases: Time-based releases"
echo "     (e.g., Ubuntu 6-month cycle) improve predictability but risk shipping"
echo "     incomplete features. Feature-based releases ensure completeness but"
echo "     cause release date slippage."
echo "   - Automated CI/CD Pipelines vs. Manual Gatekeeping: Automated tag-driven"
echo "     release builds eliminate human error but require strict manifest audit"
echo "     gates before publishing tarballs to public registries."
echo ""
echo " SYMPTOM OBSERVED BY THE STUDENT:"
echo " ----------------------------------------------------------------------"
echo " You are the Release Lead. Running the automated audit script:"
echo "   $ cd ~/lpi-050-release-lab"
echo "   $ ./release-audit.sh"
echo " Results in audit failure across version tagging, packaging, and checksums!"
echo ""
echo " YOUR MISSION:"
echo " ----------------------------------------------------------------------"
echo " Fix the release pipeline so that running './release-audit.sh' passes 100%."
echo ""
echo " Expected Output when Fixed:"
echo "   [TEST 1] Checking Git Release Tag consistency (v2.1.0)... PASSED"
echo "   [TEST 2] Verifying release bundle tarball existence... PASSED"
echo "   [TEST 3] Checking Release Tarball contents for mandatory files... PASSED"
echo "   [TEST 4] Verifying SHA256 cryptographic checksum manifest... PASSED"
echo "   [SUCCESS] RELEASE AUDIT PASSED! Software is ready for production distribution."
echo ""
echo " Workspace Location: ${LAB_DIR}"
echo "========================================================================"
echo ""

# ==============================================================================
# STEP-BY-STEP SOLUTION (DO NOT READ UNTIL YOU ATTEMPT TO FIX IT YOURSELF)
# ==============================================================================
#
# DIAGNOSTIC COMMANDS TO IDENTIFY THE ROOT CAUSES:
# ------------------------------------------------------------------------------
# 1. Inspect version alignment between git tag and VERSION file:
#    $ cd ~/lpi-050-release-lab
#    $ cat VERSION
#    # Output: 2.1.0
#    $ git describe --tags --abbrev=0
#    # Output: v2.0.9   <-- DRIFT DETECTED (Git tag does not match VERSION file)
#
# 2. Inspect the broken release audit execution:
#    $ ./release-audit.sh
#    # Fails at Test 1 due to mismatched Git tag.
#
# 3. Inspect release build packaging in `release-build.sh`:
#    $ cat release-build.sh
#    # Notice line: tar -czf "${TARBALL}" src/ VERSION
#    # CHANGELOG.md is excluded from the release tarball.
#    # Notice line: echo "00000000..." > "${DIST_DIR}/SHA256SUMS"
#    # The SHA256 manifest is hardcoded with dummy invalid zeroes.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP FIX INSTRUCTIONS:
# ------------------------------------------------------------------------------
#
# Step 1: Fix Git Tagging (SemVer Alignment)
# Delete the erroneous tag and tag the HEAD commit with the correct version v2.1.0:
#    $ git tag -d v2.0.9
#    $ git tag -a "v2.1.0" -m "Release v2.1.0"
#
# Step 2: Fix `release-build.sh` script logic
# Edit `release-build.sh` to include CHANGELOG.md and compute valid sha256 checksums:
#
# Replace `release-build.sh` with the corrected code:
#    $ cat << 'EOF' > release-build.sh
# #!/bin/bash
# set -e
# 
# PROJECT_NAME="enterprise-engine"
# VERSION=$(cat VERSION)
# DIST_DIR="dist"
# TARBALL_NAME="${PROJECT_NAME}-${VERSION}.tar.gz"
# TARBALL="${DIST_DIR}/${TARBALL_NAME}"
# 
# echo "==> Building Release Package: ${PROJECT_NAME} v${VERSION}"
# mkdir -p "${DIST_DIR}"
# 
# # Fix: Include CHANGELOG.md in release archive
# tar -czf "${TARBALL}" src/ VERSION CHANGELOG.md
# 
# echo "==> Generating Release Checksum Manifest..."
# # Fix: Calculate actual SHA256 checksum using relative file paths
# cd "${DIST_DIR}"
# sha256sum "${TARBALL_NAME}" > SHA256SUMS
# cd ..
# 
# echo "==> Release Build Complete: ${TARBALL}"
# EOF
#    $ chmod +x release-build.sh
#
# Step 3: Re-run Build and Audit
#    $ ./release-build.sh
#    $ ./release-audit.sh
#
# Verify Output:
#    [TEST 1] Checking Git Release Tag consistency (v2.1.0)... PASSED
#    [TEST 2] Verifying release bundle tarball existence... PASSED
#    [TEST 3] Checking Release Tarball contents for mandatory files... PASSED
#    [TEST 4] Verifying SHA256 cryptographic checksum manifest... PASSED
#    [SUCCESS] RELEASE AUDIT PASSED! Software is ready for production distribution.
# ==============================================================================