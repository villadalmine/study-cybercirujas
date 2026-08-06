#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100 v1.0)
# Topic 2.3: HTML References and Embedded Resources (Weight: 5)
# Production Break & Fix Lab Script
# ==============================================================================
# Official Reference Sources:
# - LPI 030-100 Overview: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# - W3C HTML5 URL Resolution Spec: https://html.spec.whatwg.org/multipage/urls-and-fetching.html
# - MDN HTML Embedded Resources: https://developer.mozilla.org/en-US/docs/Learn/Getting_started_with_the_web/Dealing_with_files
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_lab_2_3"
PORT=8080

echo "======================================================================"
echo " [LAB INITIALIZATION] LPI 030-100 Topic 2.3: HTML References & Assets "
echo "======================================================================"

# Clean up previous runs
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/webroot/portal/assets/css"
mkdir -p "${LAB_DIR}/webroot/portal/assets/js"
mkdir -p "${LAB_DIR}/webroot/portal/assets/images"

# Create valid asset files in correct subpath structure
cat << 'EOF' > "${LAB_DIR}/webroot/portal/assets/css/theme.css"
/* Production Theme CSS */
body { font-family: sans-serif; background-color: #0f172a; color: #f8fafc; margin: 0; padding: 2rem; }
.card { border: 1px solid #334155; padding: 1.5rem; border-radius: 8px; background-color: #1e293b; }
.status-ok { color: #4ade80; font-weight: bold; }
EOF

cat << 'EOF' > "${LAB_DIR}/webroot/portal/assets/js/runtime.js"
console.log("[PRODUCTION LOG] Runtime script loaded successfully.");
document.addEventListener("DOMContentLoaded", () => {
    const statusEl = document.getElementById("js-status");
    if (statusEl) {
        statusEl.innerText = "Active & Executing";
        statusEl.className = "status-ok";
    }
});
EOF

# Base64 encoded 1x1 PNG image asset
cat << 'EOF' > "${LAB_DIR}/webroot/portal/assets/images/logo.png.b64"
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
EOF
base64 -d "${LAB_DIR}/webroot/portal/assets/images/logo.png.b64" > "${LAB_DIR}/webroot/portal/assets/images/logo.png"
rm -f "${LAB_DIR}/webroot/portal/assets/images/logo.png.b64"

# Inject BROKEN index.html with multi-vector reference defects
cat << 'EOF' > "${LAB_DIR}/webroot/portal/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Production System Dashboard</title>
    <!-- BROKEN REFERENCE 1: Root-relative path fails when application is deployed under subpath /portal/ -->
    <link rel="stylesheet" href="/assets/css/theme.css">
</head>
<body>
    <div class="card">
        <!-- BROKEN REFERENCE 2: Path traversal pointing outside directory tree & missing accessibility alt tag -->
        <img src="../../images/logo.png" title="Company Logo" width="100" height="100">
        
        <h1>SRE Control Center</h1>
        <p>JavaScript Engine Status: <span id="js-status">Failed to Load</span></p>

        <!-- BROKEN REFERENCE 3: Misspelled src attribute ('scr') and wrong script extension ('.jss') -->
        <script scr="assets/js/runtime.jss"></script>

        <!-- BROKEN REFERENCE 4: Scheme-less external link resolves to local relative URL instead of external site -->
        <p>Documentation: <a href="www.lpi.org/our-certifications/web-development-essentials-overview/" target="_blank">LPI Web Development Essentials Overview</a></p>
    </div>
</body>
</html>
EOF

# Stop existing Python HTTP servers running on target port
pkill -f "python3 -m http.server ${PORT}" 2>/dev/null || true

# Launch background HTTP server serving from webroot root directory
(cd "${LAB_DIR}/webroot" && python3 -m http.server "${PORT}" --bind 127.0.0.1 > "${LAB_DIR}/server.log" 2>&1 &)

sleep 1

# Generate automated verification script for student self-testing
cat << 'EOF' > "${LAB_DIR}/verify.sh"
#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="/tmp/lpi_lab_2_3"
INDEX_HTML="${LAB_DIR}/webroot/portal/index.html"
ERRORS=0

echo "[VERIFICATION] Validating HTML References and Embedded Resources..."

# Test 1: Validate CSS link tag path resolution
CSS_HREF=$(grep -oP '(?<=<link rel="stylesheet" href=")[^"]+' "${INDEX_HTML}" || true)
if [ "${CSS_HREF}" = "assets/css/theme.css" ] || [ "${CSS_HREF}" = "./assets/css/theme.css" ]; then
    echo "  [PASS] CSS href path correctly references document-relative path 'assets/css/theme.css'"
else
    echo "  [FAIL] CSS href is '${CSS_HREF}'. Expected document-relative 'assets/css/theme.css' or './assets/css/theme.css'"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: Validate Image tag src path and mandatory alt attribute
IMG_SRC=$(grep -oP '(?<=<img src=")[^"]+' "${INDEX_HTML}" || true)
HAS_ALT=$(grep -E '<img [^>]*alt="[^"]+"' "${INDEX_HTML}" || true)

if [ "${IMG_SRC}" = "assets/images/logo.png" ] || [ "${IMG_SRC}" = "./assets/images/logo.png" ]; then
    echo "  [PASS] Image src correctly references 'assets/images/logo.png'"
else
    echo "  [FAIL] Image src is '${IMG_SRC}'. Expected 'assets/images/logo.png'"
    ERRORS=$((ERRORS + 1))
fi

if [ -n "${HAS_ALT}" ]; then
    echo "  [PASS] Image element contains required 'alt' accessibility attribute"
else
    echo "  [FAIL] Image element is missing mandatory 'alt' attribute"
    ERRORS=$((ERRORS + 1))
fi

# Test 3: Validate Script tag attribute syntax and script file extension
SCRIPT_TAG=$(grep -E '<script [^>]*src="assets/js/runtime.js"[^>]*>' "${INDEX_HTML}" || true)
if [ -n "${SCRIPT_TAG}" ]; then
    echo "  [PASS] Script tag uses valid 'src' attribute pointing to 'assets/js/runtime.js'"
else
    echo "  [FAIL] Script tag missing or contains attribute/extension syntax errors"
    ERRORS=$((ERRORS + 1))
fi

# Test 4: Validate Hyperlink href URI scheme for external domain
ANCHOR_HREF=$(grep -oP '(?<=<a href=")[^"]+' "${INDEX_HTML}" || true)
if [[ "${ANCHOR_HREF}" =~ ^https://www\.lpi\.org/ ]]; then
    echo "  [PASS] Anchor href uses absolute HTTPS scheme (https://www.lpi.org/...)"
else
    echo "  [FAIL] External anchor href '${ANCHOR_HREF}' lacks absolute URI scheme (e.g., https://)"
    ERRORS=$((ERRORS + 1))
fi

# Test 5: End-to-End HTTP status code verification via local HTTP server
echo "[VERIFICATION] Performing HTTP fetch tests against http://127.0.0.1:8080/portal/..."
HTTP_INDEX_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/portal/index.html")
HTTP_CSS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/portal/assets/css/theme.css")
HTTP_JS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/portal/assets/js/runtime.js")
HTTP_IMG_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/portal/assets/images/logo.png")

if [ "${HTTP_INDEX_CODE}" -eq 200 ] && [ "${HTTP_CSS_CODE}" -eq 200 ] && [ "${HTTP_JS_CODE}" -eq 200 ] && [ "${HTTP_IMG_CODE}" -eq 200 ]; then
    echo "  [PASS] HTTP Server returns 200 OK for index document and all embedded assets."
else
    echo "  [FAIL] Resource fetch status - Index: ${HTTP_INDEX_CODE}, CSS: ${HTTP_CSS_CODE}, JS: ${HTTP_JS_CODE}, IMG: ${HTTP_IMG_CODE}"
    ERRORS=$((ERRORS + 1))
fi

if [ "${ERRORS}" -eq 0 ]; then
    echo "======================================================================"
    echo " RESULT: SUCCESS - All HTML references and embedded resources fixed! "
    echo "======================================================================"
    exit 0
else
    echo "======================================================================"
    echo " RESULT: FAILED - Found ${ERRORS} reference error(s). Keep debugging! "
    echo "======================================================================"
    exit 1
fi
EOF

chmod +x "${LAB_DIR}/verify.sh"

cat << EOF

[LAB LOADED SUCCESSFULLY]

Scenario Context:
You are an SRE on-call for a production control portal deployed under a URL subpath ('/portal/').
Following a deployment pipeline execution, users report that the application frontend is completely
unstyled, images return broken 404 graphics, interactive JS elements are non-functional, and clicking
the external documentation link redirects to a local 404 route on your web server.

Target HTML File:
  ${LAB_DIR}/webroot/portal/index.html

Live HTTP Endpoint:
  http://127.0.0.1:${PORT}/portal/index.html

Observed Symptoms:
  1. Browser / Curl displays unstyled plain text HTML.
  2. Browser Developer Tools show 404 Not Found for CSS:
     GET http://127.0.0.1:${PORT}/assets/css/theme.css
  3. Image 'logo.png' returns 404 due to path traversal escaping web root bounds.
  4. JavaScript engine remains inactive due to typo in script tag attribute ('scr') and 
     invalid script extension ('.jss').
  5. Clicking the external LPI documentation link attempts relative navigation to 
     http://127.0.0.1:${PORT}/portal/www.lpi.org/... instead of opening https://www.lpi.org/
  6. Accessibility compliance linters fail due to missing 'alt' text on the <img> element.

Diagnostic CLI Commands:
  1. View target HTML code:
     cat ${LAB_DIR}/webroot/portal/index.html
  2. Inspect asset fetching via curl:
     curl -I http://127.0.0.1:${PORT}/portal/assets/css/theme.css
     curl -I http://127.0.0.1:${PORT}/assets/css/theme.css
  3. Run initial automated verification:
     ${LAB_DIR}/verify.sh

Your Objective:
Edit '${LAB_DIR}/webroot/portal/index.html' to correct all broken HTML resource references,
attribute names, extensions, and URI schemes.

When finished, execute:
  ${LAB_DIR}/verify.sh

EOF

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION & TECHNICAL DEEP DIVE (FOR INSTRUCTORS/STUDENTS)
# ==============================================================================
#
# TECHNICAL MECHANICS & ARCHITECTURAL TRADE-OFFS:
#
# 1. URL Path Resolution Mechanics (W3C WHATWG HTML Specification):
#    Browsers resolve every relative URL against a Document Base URL.
#    - Absolute URLs ('https://example.com/assets/file.ext'):
#      Bypasses base URL. Useful for external cross-origin CDN assets.
#      Trade-off: Hardcodes domain; breaks in offline, staging, or multi-tenant deployments.
#
#    - Root-Relative URLs ('/assets/css/theme.css'):
#      Starts with '/'. Resolves directly against Origin (Scheme + Host + Port).
#      If server path is http://127.0.0.1:8080/portal/index.html, '/assets/css/theme.css'
#      resolves to http://127.0.0.1:8080/assets/css/theme.css. When hosted under subpath '/portal/',
#      this causes an HTTP 404 error because the asset path lacks '/portal'.
#
#    - Document-Relative URLs ('assets/css/theme.css' or './assets/css/theme.css'):
#      Does NOT start with '/'. Resolves relative to current directory path ('/portal/').
#      Resolves to http://127.0.0.1:8080/portal/assets/css/theme.css (Correct).
#
# 2. HTML Tag Attributes & Semantics:
#    - <link rel="stylesheet" href="...">:
#      Defines relationship between document and external CSS resource via 'href' attribute.
#    - <script src="...">:
#      Embeds client-side executable code. Mandatory attribute is 'src'. Typo 'scr' is ignored
#      by browser HTML parsers, leaving script unexecuted.
#    - <img src="..." alt="...">:
#      Embeds raster/vector graphics. The 'alt' attribute provides alternative text for visually
#      impaired screen readers (WCAG compliance) and renders when image fetch fails.
#    - <a href="...">:
#      Defines hyperlink target. Omitting scheme prefix ('https://') causes browser to interpret
#      string as document-relative path, appending it to current window location URL.
#
# ------------------------------------------------------------------------------
# MANUAL STEP-BY-STEP FIX:
# ------------------------------------------------------------------------------
#
# Step 1: Open index.html in an editor:
#   nano /tmp/lpi_lab_2_3/webroot/portal/index.html
#
# Step 2: Repair Reference 1 (Root-relative to Document-relative CSS path):
#   Change: <link rel="stylesheet" href="/assets/css/theme.css">
#   To:     <link rel="stylesheet" href="assets/css/theme.css">
#
# Step 3: Repair Reference 2 (Image path traversal & add missing 'alt' attribute):
#   Change: <img src="../../images/logo.png" title="Company Logo" width="100" height="100">
#   To:     <img src="assets/images/logo.png" alt="Company Logo" title="Company Logo" width="100" height="100">
#
# Step 4: Repair Reference 3 (Script tag attribute typo 'scr' -> 'src' & '.jss' -> '.js'):
#   Change: <script scr="assets/js/runtime.jss"></script>
#   To:     <script src="assets/js/runtime.js"></script>
#
# Step 5: Repair Reference 4 (Add missing explicit scheme 'https://' to anchor href):
#   Change: <a href="www.lpi.org/our-certifications/web-development-essentials-overview/" target="_blank">
#   To:     <a href="https://www.lpi.org/our-certifications/web-development-essentials-overview/" target="_blank">
#
# ------------------------------------------------------------------------------
# AUTOMATED SED ONE-LINER SOLUTION:
# ------------------------------------------------------------------------------
# Run the following shell snippet to repair the file automatically and run verification:
#
# cat << 'EOF_FIX' > /tmp/lpi_lab_2_3/apply_fix.sh
# #!/usr/bin/env bash
# TARGET="/tmp/lpi_lab_2_3/webroot/portal/index.html"
# sed -i 's|href="/assets/css/theme.css"|href="assets/css/theme.css"|g' "$TARGET"
# sed -i 's|src="../../images/logo.png" title="Company Logo"|src="assets/images/logo.png" alt="Company Logo" title="Company Logo"|g' "$TARGET"
# sed -i 's|scr="assets/js/runtime.jss"|src="assets/js/runtime.js"|g' "$TARGET"
# sed -i 's|href="www.lpi.org|href="https://www.lpi.org|g' "$TARGET"
# echo "[FIX APPLIED] Executing verification test..."
# /tmp/lpi_lab_2_3/verify.sh
# EOF_FIX
# chmod +x /tmp/lpi_lab_2_3/apply_fix.sh
# /tmp/lpi_lab_2_3/apply_fix.sh
# ==============================================================================