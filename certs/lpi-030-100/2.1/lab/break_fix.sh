#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, Version 1.0)
# Topic 2.1: HTML Document Anatomy (Weight: 5)
# Production-Grade Break & Fix Lab Script
#
# Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_lab_html_anatomy"
TARGET_FILE="${LAB_DIR}/index.html"
VERIFY_SCRIPT="${LAB_DIR}/verify.sh"

echo "[+] Initializing LPI 030-100 Topic 2.1 Lab Environment..."
mkdir -p "${LAB_DIR}"

# ------------------------------------------------------------------------------
# STEP 1: Inject Controlled Failure State (Broken HTML Document Anatomy)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${TARGET_FILE}"
<html>
  <title>Production System Telemetry Dashboard</title>
  <meta name="viewport" content="width=device, scale=1">
  <body>
    <h1>Cluster Telemetry Status</h1>
    <p>Operational Metrics: Latency 12ms | Throughput 45k rps | Error Rate 0.001%</p>
    <p>Region nodes: États-Unis (us-east), América do Sul (sa-east), España (eu-south).</p>
  </body>
EOF

# ------------------------------------------------------------------------------
# STEP 2: Generate Automated Verification Test Suite
# ------------------------------------------------------------------------------
cat << 'EOF' > "${VERIFY_SCRIPT}"
#!/usr/bin/env bash
set -euo pipefail

TARGET="/tmp/lpi_lab_html_anatomy/index.html"
ERRORS=0

echo "======================================================================"
echo " Running Automated Compliance Check for HTML Document Anatomy..."
echo "======================================================================"

if [ ! -f "$TARGET" ]; then
  echo "[FAIL] Target file $TARGET does not exist."
  exit 1
fi

# Check 1: DOCTYPE declaration on line 1
FIRST_LINE=$(head -n 1 "$TARGET" | tr -d '\r')
if echo "$FIRST_LINE" | grep -iq '^<!DOCTYPE html>'; then
  echo "[PASS] Valid HTML5 <!DOCTYPE html> declaration present on line 1."
else
  echo "[FAIL] Missing <!DOCTYPE html> on line 1. Browsers will trigger legacy Quirks Mode."
  ERRORS=$((ERRORS + 1))
fi

# Check 2: html element with lang attribute
if grep -iq '<html[^>]*lang=["'\''][a-zA-Z-]\+["'\'']' "$TARGET"; then
  echo "[PASS] Root <html> tag specifies a valid language attribute."
else
  echo "[FAIL] Root <html> tag is missing a valid lang attribute (e.g. <html lang=\"en\">)."
  ERRORS=$((ERRORS + 1))
fi

# Check 3: Explicit head section tag structure
if grep -iq '<head>' "$TARGET" && grep -iq '</head>' "$TARGET"; then
  echo "[PASS] Explicit <head> and </head> structure tags present."
else
  echo "[FAIL] Missing explicit <head> container tags."
  ERRORS=$((ERRORS + 1))
fi

# Check 4: Character encoding meta tag inside head
if grep -iq '<meta[^>]*charset=["'\'']\(utf-8\|UTF-8\)["'\'']' "$TARGET"; then
  echo "[PASS] Explicit UTF-8 metadata encoding tag (<meta charset=\"UTF-8\">) found."
else
  echo "[FAIL] Missing or invalid UTF-8 character encoding meta tag."
  ERRORS=$((ERRORS + 1))
fi

# Check 5: Viewport meta tag syntax
if grep -iq '<meta[^>]*name=["'\'']viewport["'\''][^>]*content=["'\''][^"']*width=device-width' "$TARGET" && \
   grep -iq '<meta[^>]*name=["'\'']viewport["'\''][^>]*content=["'\''][^"']*initial-scale=1' "$TARGET"; then
  echo "[PASS] Responsive Viewport meta tag correctly configured."
else
  echo "[FAIL] Viewport meta tag missing or invalid (must contain 'width=device-width, initial-scale=1.0')."
  ERRORS=$((ERRORS + 1))
fi

# Check 6: Element nesting & positioning (<title> must be inside <head>)
HEAD_START=$(grep -n -i '<head' "$TARGET" | cut -d: -f1 | head -n1 || echo 0)
HEAD_END=$(grep -n -i '</head>' "$TARGET" | cut -d: -f1 | head -n1 || echo 0)
TITLE_POS=$(grep -n -i '<title' "$TARGET" | cut -d: -f1 | head -n1 || echo 0)

if [ "$HEAD_START" -ne 0 ] && [ "$HEAD_END" -ne 0 ] && [ "$TITLE_POS" -gt "$HEAD_START" ] && [ "$TITLE_POS" -lt "$HEAD_END" ]; then
  echo "[PASS] <title> element is correctly nested inside <head>."
else
  echo "[FAIL] <title> element is missing or positioned outside the <head> block."
  ERRORS=$((ERRORS + 1))
fi

# Check 7: Closing root tags
if grep -iq '</body>' "$TARGET" && grep -iq '</html>' "$TARGET"; then
  echo "[PASS] Closing </body> and </html> tags are present."
else
  echo "[FAIL] Document is missing closing </body> or </html> tags."
  ERRORS=$((ERRORS + 1))
fi

echo "----------------------------------------------------------------------"
if [ "$ERRORS" -eq 0 ]; then
  echo "[SUCCESS] HTML Document Anatomy meets all LPI 030-100 Topic 2.1 requirements!"
  exit 0
else
  echo "[TOTAL FAILS] Found $ERRORS compliance failure(s). Update $TARGET and re-run."
  exit 1
fi
EOF

chmod +x "${VERIFY_SCRIPT}"

# ------------------------------------------------------------------------------
# STEP 3: Display Lab Scenario and Diagnostic Guidance
# ------------------------------------------------------------------------------
cat << EOF

==============================================================================
  LPI 030-100 (v1.0) Topic 2.1: HTML Document Anatomy (Weight 5)
  SRE BREAK & FIX SCENARIO
==============================================================================
Target File: ${TARGET_FILE}

[SYMPTOMS REPORTED IN PRODUCTION / EDGE PROXIES]
1. Rendering Engine Fallback: Browsers render the telemetry dashboard in
   "Quirks Mode" instead of Standards Mode, causing unexpected CSS grid box-model calculation drift.
2. Responsive Layout Failure: Mobile client monitors report horizontal overflow
   and unscaled text viewports.
3. Character Set Corruption: Non-ASCII characters (e.g., États-Unis, América,
   España) render with byte-corruption glitches (Mojibake artifacts) under default HTTP fallback headers.
4. DOM Parsing Warnings: Headless browsers and SRE automated test runners throw
   structural DOM hierarchy errors.

[YOUR TASK]
Refactor ${TARGET_FILE} to strictly conform to standard HTML5 Document Anatomy:
- Add a valid, case-insensitive HTML5 Document Type Declaration (<!DOCTYPE html>) on line 1.
- Open the root <html> element with an appropriate language attribute (e.g., lang="en").
- Construct an explicit <head> metadata block containing:
    * Character encoding definition (<meta charset="UTF-8">)
    * Mobile viewport setup (<meta name="viewport" content="width=device-width, initial-scale=1.0">)
    * Document title (<title>...)
- Encapsulate page body content inside proper <body>...</body> tags.
- Ensure all open structural tags (<html>, <head>, <body>) are properly closed in correct hierarchy.

[DIAGNOSTIC & VERIFICATION COMMANDS]
Run the validation script to test your changes:
  $ ${VERIFY_SCRIPT}

View current document state:
  $ cat ${TARGET_FILE}

==============================================================================
EOF

# ==============================================================================
# SOLUTION STEP-BY-STEP (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# Step 1: Navigate to the lab directory:
#   cd /tmp/lpi_lab_html_anatomy
#
# Step 2: Inspect current file state:
#   cat index.html
#
# Step 3: Edit index.html using an editor (e.g., nano or vim):
#   nano index.html
#
# Step 4: Replace content with valid HTML5 Document Anatomy:
#
# <!DOCTYPE html>
# <html lang="en">
#   <head>
#     <meta charset="UTF-8">
#     <meta name="viewport" content="width=device-width, initial-scale=1.0">
#     <title>Production System Telemetry Dashboard</title>
#   </head>
#   <body>
#     <h1>Cluster Telemetry Status</h1>
#     <p>Operational Metrics: Latency 12ms | Throughput 45k rps | Error Rate 0.001%</p>
#     <p>Region nodes: États-Unis (us-east), América do Sul (sa-east), España (eu-south).</p>
#   </body>
# </html>
#
# Step 5: Execute verification script to confirm zero failure output:
#   ./verify.sh
#
# Expected CLI Output on Success:
#   ======================================================================
#    Running Automated Compliance Check for HTML Document Anatomy...
#   ======================================================================
#   [PASS] Valid HTML5 <!DOCTYPE html> declaration present on line 1.
#   [PASS] Root <html> tag specifies a valid language attribute.
#   [PASS] Explicit <head> and </head> structure tags present.
#   [PASS] Explicit UTF-8 metadata encoding tag (<meta charset="UTF-8">) found.
#   [PASS] Responsive Viewport meta tag correctly configured.
#   [PASS] <title> element is correctly nested inside <head>.
#   [PASS] Closing </body> and </html> tags are present.
#   ----------------------------------------------------------------------
#   [SUCCESS] HTML Document Anatomy meets all LPI 030-100 Topic 2.1 requirements!
# ==============================================================================