#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (030-100) - Topic 2.4: HTML Forms (Weight: 5)
# Production SRE & Web Architecture "Break & Fix" Hands-On Laboratory
# Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# ==============================================================================
#
# PURPOSE:
# This script creates a controlled broken environment containing typical production
# HTML form defects (security flaws, missing data payloads, file upload failures,
# and broken UI accessibility). It guides the student through diagnosis, symptoms,
# and verification.
#
# ==============================================================================

set -euo pipefail

LAB_DIR="${HOME}/lpi_forms_lab"
WWW_DIR="${LAB_DIR}/public"

echo "========================================================================"
echo "  Deploying LPI 030-100 Topic 2.4 (HTML Forms) Break & Fix Environment  "
echo "========================================================================"

mkdir -p "${WWW_DIR}"

# ------------------------------------------------------------------------------
# 1. Inject Broken HTML Forms Application
# ------------------------------------------------------------------------------
cat << 'EOF' > "${WWW_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Production Identity & Profile Portal</title>
</head>
<body>
    <h1>User Authentication & Profile Management</h1>

    <!-- FORM 1: User Login & Registration (BROKEN) -->
    <section>
        <h2>Account Login</h2>
        <!-- BUG 1: HTTP GET method used for credential submission -->
        <form action="/api/v1/auth" method="GET">
            <div>
                <!-- BUG 2: Label 'for' attribute does not match input 'id' -->
                <label for="user-email-input">Email Address:</label>
                <!-- BUG 3: Missing 'name' attribute - input data will not be transmitted -->
                <input type="email" id="email-field" placeholder="user@example.com" required>
            </div>

            <div>
                <label for="password-field">Password:</label>
                <!-- BUG 4: Missing 'name' attribute and incorrect input type -->
                <input type="text" id="password-field" placeholder="Enter password" required>
            </div>

            <div>
                <!-- BUG 5: button type="button" prevents form submission trigger -->
                <button type="button">Sign In</button>
            </div>
        </form>
    </section>

    <hr>

    <!-- FORM 2: Avatar Image Upload (BROKEN) -->
    <section>
        <h2>Upload Profile Avatar</h2>
        <!-- BUG 6: Missing enctype="multipart/form-data" for file transmission -->
        <form action="/api/v1/avatar" method="POST">
            <div>
                <label for="avatar-file">Select Image File (PNG/JPEG):</label>
                <input type="file" id="avatar-file" name="avatar_image" accept="image/png, image/jpeg">
            </div>

            <div>
                <!-- BUG 7: Incorrect button type resets inputs instead of submitting form -->
                <input type="reset" value="Upload Avatar">
            </div>
        </form>
    </section>
</body>
</html>
EOF

# ------------------------------------------------------------------------------
# 2. Display Lab Diagnostics & Instructions
# ------------------------------------------------------------------------------
cat << EOF

[+] Lab environment successfully deployed at: ${WWW_DIR}
[+] Target file: ${WWW_DIR}/index.html

--------------------------------------------------------------------------------
LAB SCENARIO & DIAGNOSTIC SYMPTOMS (INCIDENT INC-8402):
--------------------------------------------------------------------------------
You are an SRE on-call resolving incident INC-8402 on the Production Portal:

1. Credential Leakage & Request Payload Failure:
   - Submitting login credentials leaks plain-text passwords into browser URL history.
   - Backend APIs receive empty HTTP request bodies (missing key/value pairs).
2. UI Accessibility Failure:
   - Clicking the "Email Address" label text fails to shift focus to the input box.
3. Form Submission Inoperability:
   - Clicking "Sign In" does nothing; the browser triggers no HTTP submit action.
4. Binary File Upload Corruption:
   - Profile picture uploads fail at backend parsing; server receives empty text payload
     instead of multi-part binary file streams.
5. Wrong Control Action:
   - Clicking "Upload Avatar" clears form inputs instead of transmitting file data.

--------------------------------------------------------------------------------
STUDENT OBJECTIVES:
--------------------------------------------------------------------------------
Analyze and refactor '${WWW_DIR}/index.html' to comply with HTML5 standards:

1. Fix HTTP Method: Use method="POST" for sensitive credentials.
2. Fix Input Names: Add explicit 'name' attributes ('email', 'password') for HTTP transmission.
3. Fix Label Association: Bind <label for="..."> correctly to <input id="...">.
4. Fix Input Types: Change password field to type="password" for visual masking.
5. Fix Button Semantics: Set login button to type="submit".
6. Fix Encoding Type: Add enctype="multipart/form-data" to the avatar upload form.
7. Fix Submit Control: Replace the reset control in Form 2 with a valid type="submit".

--------------------------------------------------------------------------------
VERIFICATION COMMAND:
--------------------------------------------------------------------------------
To test your fixes, run the automated verification script:
  bash ${LAB_DIR}/verify.sh

EOF

# ------------------------------------------------------------------------------
# 3. Create Verification Script
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/verify.sh"
#!/usr/bin/env bash
set -euo pipefail

TARGET="${HOME}/lpi_forms_lab/public/index.html"
ERRORS=0

echo "Running W3C / SRE Compliance Checks on ${TARGET}..."
echo "--------------------------------------------------------"

# Check 1: Method POST on auth form
if grep -qE '<form[^>]*action="/api/v1/auth"[^>]*method="POST"' "${TARGET}" || grep -qE '<form[^>]*method="POST"[^>]*action="/api/v1/auth"' "${TARGET}"; then
    echo "[PASS] Form 1 uses HTTP POST method."
else
    echo "[FAIL] Form 1 must use method=\"POST\"."
    ERRORS=$((ERRORS + 1))
fi

# Check 2: Label for email matches input id
if grep -q '<label for="email-field">' "${TARGET}" && grep -q '<input[^>]*id="email-field"' "${TARGET}"; then
    echo "[PASS] Email label 'for' correctly matches input 'id'."
else
    echo "[FAIL] Email label 'for' attribute must match input id ('email-field')."
    ERRORS=$((ERRORS + 1))
fi

# Check 3: Email input has name="email"
if grep -qE '<input[^>]*id="email-field"[^>]*name="email"' "${TARGET}" || grep -qE '<input[^>]*name="email"[^>]*id="email-field"' "${TARGET}"; then
    echo "[PASS] Email input defines name=\"email\"."
else
    echo "[FAIL] Email input is missing name=\"email\" attribute."
    ERRORS=$((ERRORS + 1))
fi

# Check 4: Password input has type="password" and name="password"
if grep -qE '<input[^>]*type="password"' "${TARGET}" && grep -qE '<input[^>]*name="password"' "${TARGET}"; then
    echo "[PASS] Password field uses type=\"password\" and defines name=\"password\"."
else
    echo "[FAIL] Password field must use type=\"password\" and name=\"password\"."
    ERRORS=$((ERRORS + 1))
fi

# Check 5: Form 1 submit button
if grep -qE '<button[^>]*type="submit"' "${TARGET}"; then
    echo "[PASS] Login button uses type=\"submit\"."
else
    echo "[FAIL] Login button must use type=\"submit\" to trigger form submission."
    ERRORS=$((ERRORS + 1))
fi

# Check 6: Avatar form enctype
if grep -qE '<form[^>]*enctype="multipart/form-data"' "${TARGET}"; then
    echo "[PASS] Avatar form includes enctype=\"multipart/form-data\"."
else
    echo "[FAIL] Avatar upload form missing enctype=\"multipart/form-data\"."
    ERRORS=$((ERRORS + 1))
fi

# Check 7: Avatar form submit input
if grep -qE '<input[^>]*type="submit"' "${TARGET}"; then
    echo "[PASS] Avatar form contains submit control."
else
    echo "[FAIL] Avatar form must use a submit control (type=\"submit\"), not type=\"reset\"."
    ERRORS=$((ERRORS + 1))
fi

echo "--------------------------------------------------------"
if [ "${ERRORS}" -eq 0 ]; then
    echo "SUCCESS: All HTML Form requirements satisfied! High availability restored."
    exit 0
else
    echo "FAILED: ${ERRORS} issue(s) remain unresolved."
    exit 1
fi
EOF

chmod +x "${LAB_DIR}/verify.sh"


# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL REFERENCE (COMMENTED)
# ==============================================================================
#
# STEP 1: Deep Technical Analysis of HTML Form Mechanics
# ------------------------------------------------------------------------------
# 1. HTTP Methods (GET vs POST):
#    - method="GET": Encodes form payload directly into the URI query string
#      (?key=value). Never use GET for sensitive payload (passwords, tokens) or
#      state-changing requests. GET payloads are limited in length, stored in
#      access logs, and cached by proxies.
#    - method="POST": Sends form payload inside the HTTP request body. Mandatory
#      for authentication, mutations, and transmitting sensitive data.
#
# 2. Key Payload Transmission ('name' vs 'id'):
#    - 'id': Specifies a unique client-side element ID (used for CSS styling,
#      JavaScript DOM selection, and <label for="..."> binding). DOES NOT send
#      data to the web server.
#    - 'name': Defines the property key transmitted in HTTP form submissions
#      (e.g., email=user@domain.com). If 'name' is missing, the browser completely
#      omits the field from the request payload.
#
# 3. Label Accessibility (<label for="...">):
#    - The 'for' attribute of a <label> must match the exact 'id' attribute of
#      the targeted <input>. This provides screen-reader accessibility and enables
#      users to click label text to focus/toggle inputs.
#
# 4. Encoding Types (enctype):
#    - application/x-www-form-urlencoded (Default): Converts characters to URL
#      encoding. Cannot transport raw binary byte arrays.
#    - multipart/form-data: Splitting request bodies into MIME boundary sections.
#      MANDATORY whenever an HTML form includes <input type="file">.
#
# 5. Form Submission Triggers:
#    - <button type="button">: Rendered as a generic clickable button; does NOT
#      trigger default form submission.
#    - <button type="submit"> or <input type="submit">: Triggers native HTML form
#      validation and transmits the HTTP request payload to the 'action' endpoint.
#    - <input type="reset">: Resets all controls in the parent form to initial values.
#
# ------------------------------------------------------------------------------
# STEP 2: Full Solution Code ('${HOME}/lpi_forms_lab/public/index.html')
# ------------------------------------------------------------------------------
# Replace the contents of public/index.html with the following corrected HTML:
#
# <!DOCTYPE html>
# <html lang="en">
# <head>
#     <meta charset="UTF-8">
#     <meta name="viewport" content="width=device-width, initial-scale=1.0">
#     <title>Production Identity & Profile Portal</title>
# </head>
# <body>
#     <h1>User Authentication & Profile Management</h1>
#
#     <!-- FORM 1: User Login & Registration (FIXED) -->
#     <section>
#         <h2>Account Login</h2>
#         <form action="/api/v1/auth" method="POST">
#             <div>
#                 <label for="email-field">Email Address:</label>
#                 <input type="email" id="email-field" name="email" placeholder="user@example.com" required>
#             </div>
#
#             <div>
#                 <label for="password-field">Password:</label>
#                 <input type="password" id="password-field" name="password" placeholder="Enter password" required>
#             </div>
#
#             <div>
#                 <button type="submit">Sign In</button>
#             </div>
#         </form>
#     </section>
#
#     <hr>
#
#     <!-- FORM 2: Avatar Image Upload (FIXED) -->
#     <section>
#         <h2>Upload Profile Avatar</h2>
#         <form action="/api/v1/avatar" method="POST" enctype="multipart/form-data">
#             <div>
#                 <label for="avatar-file">Select Image File (PNG/JPEG):</label>
#                 <input type="file" id="avatar-file" name="avatar_image" accept="image/png, image/jpeg">
#             </div>
#
#             <div>
#                 <input type="submit" value="Upload Avatar">
#             </div>
#         </form>
#     </section>
# </body>
# </html>
#
# ------------------------------------------------------------------------------
# STEP 3: Execution & Verification
# ------------------------------------------------------------------------------
# Run:
#   $ bash ~/lpi_forms_lab/verify.sh
# Expected Output:
#   [PASS] Form 1 uses HTTP POST method.
#   [PASS] Email label 'for' correctly matches input 'id'.
#   [PASS] Email input defines name="email".
#   [PASS] Password field uses type="password" and defines name="password".
#   [PASS] Login button uses type="submit".
#   [PASS] Avatar form includes enctype="multipart/form-data".
#   [PASS] Avatar form contains submit control.
#   SUCCESS: All HTML Form requirements satisfied! High availability restored.