#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, v1.0)
# Topic 3.1: CSS Basics (Weight: 2.5)
# Official Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
#
# Scenario: Break & Fix - CSS Linkage, Syntax Parsing, and Specificity Failures
# Author: Senior SRE & Platform Architecture Instructor
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi-030-100-topic-3.1-lab"
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_CYAN="\033[36m"

echo -e "${COLOR_CYAN}======================================================================${COLOR_RESET}"
echo -e "${COLOR_CYAN}  LPI 030-100 Topic 3.1: CSS Basics - Break & Fix Laboratory Setup    ${COLOR_RESET}"
echo -e "${COLOR_CYAN}======================================================================${COLOR_RESET}"

# 1. Clean and initialize lab workspace safely
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/css"

# 2. Inject intentional failure state into index.html
cat << 'EOF' > "${LAB_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Production Monitoring Console</title>
    <!-- INJECTED BUG #1: Incorrect rel attribute and invalid stylesheet path -->
    <link rel="style" href="css/style.css">
</head>
<body>
    <header id="hero-banner">
        <h1>Production Kubernetes Cluster Status</h1>
        <p class="subtitle">Region: us-east-1 | Environment: Production</p>
    </header>

    <main id="content">
        <section class="card">
            <h2>Node Pool Telemetry</h2>
            <!-- INJECTED BUG #3: Specificity conflict between #content p and .highlight -->
            <p class="highlight">CRITICAL: 2 nodes reporting High Memory Pressure (p99 > 94%).</p>
        </section>

        <!-- INJECTED BUG #2: Button styling blocked by unclosed CSS rule block above -->
        <button class="btn-primary">Drain Faulty Nodes</button>
    </main>
</body>
</html>
EOF

# 3. Inject intentional failure state into css/styles.css
cat << 'EOF' > "${LAB_DIR}/css/styles.css"
/* CSS Basics Production Stylesheet */

body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background-color: #f4f6f9;
    color: #1a1a1a;
    margin: 0;
    padding: 24px;
}

/* INJECTED BUG #2a: Unclosed declaration block - missing closing brace '}' */
#hero-banner {
    background-color: #0b2545;
    color: #ffffff;
    padding: 28px;
    border-radius: 6px;

.btn-primary {
    background-color: #137547;
    color: #ffffff;
    padding: 12px 24px;
    border: none;
    border-radius: 4px;
    font-weight: bold;
    cursor: pointer;
}

/* INJECTED BUG #2b: Invalid property name for text color */
.subtitle {
    font-colour: #8da9c4;
    font-size: 1rem;
}

/* INJECTED BUG #3: Higher specificity ID selector (#content p) overrides class (.highlight) */
#content p {
    color: #4a4a4a;
    font-size: 1rem;
    line-height: 1.5;
}

.highlight {
    color: #d90429;
    font-weight: bold;
}
EOF

echo -e "\n${COLOR_GREEN}[+] Lab directory initialized at: ${LAB_DIR}${COLOR_RESET}"
echo -e "${COLOR_YELLOW}[!] Controlled failures injected into index.html and css/styles.css${COLOR_RESET}\n"

# 4. Display Scenario Overview, Symptoms, and Student Objectives
cat << EOF
----------------------------------------------------------------------
INCIDENT REPORT & TROUBLESHOOTING GUIDE
----------------------------------------------------------------------
Target Directory: ${LAB_DIR}
Files Included  : index.html, css/styles.css

[SYMPTOMS REPORTED BY USERS]
1. The web page displays completely unstyled plain HTML in the browser.
2. The browser network tab or cURL returns 404 / fails to load external CSS.
3. After resolving the linking issue, the primary action button (.btn-primary)
   still renders with default browser system button styling instead of green.
4. The subtitle text (.subtitle) fails to adopt the configured light blue text color.
5. The alert message (.highlight) remains dark gray (#4a4a4a) instead of rendering
   in urgent alert red (#d90429).

[STUDENT OBJECTIVES]
Analyze and fix all CSS Basics bugs in index.html and css/styles.css:
  1. Fix the external stylesheet declaration in 'index.html'.
  2. Fix CSS syntax errors in 'css/styles.css' (unclosed block & invalid property name).
  3. Resolve the selector specificity conflict so '.highlight' successfully applies
     the red color to the paragraph inside #content (DO NOT use !important).

[DIAGNOSTIC & VERIFICATION COMMANDS]
Run a local test server to inspect:
  cd ${LAB_DIR} && python3 -m http.server 8080

Validate document response with cURL:
  curl -sI http://localhost:8080/css/styles.css
  curl -s http://localhost:8080/index.html | grep link

----------------------------------------------------------------------
EOF

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION (Keep commented out for reference)
# ==============================================================================
#
# STEP 1: Fix External Stylesheet Link in index.html
# ------------------------------------------------------------------------------
# Line 9 of `index.html` contains two errors:
#   <link rel="style" href="css/style.css">
#
# Causes:
#   - The `rel` attribute must be set to `stylesheet` (browsers ignore `rel="style"`).
#   - The `href` attribute references `style.css` (singular), but the file on disk is `styles.css` (plural).
#
# Fix in `index.html`:
#   <link rel="stylesheet" href="css/styles.css">
#
#
# STEP 2: Fix Syntax Parsing Errors in css/styles.css
# ------------------------------------------------------------------------------
# Inspect lines 12-28 of `css/styles.css`:
#
# Causes:
#   - `#hero-banner` lacks a closing curly brace `}`. In CSS syntax rules, any rule
#     following an unclosed block is swallowed as an invalid nested declaration,
#     causing `.btn-primary` to be completely ignored by the CSS parser.
#   - `.subtitle` uses `font-colour: #8da9c4;`. In standard CSS, `font-colour` is an
#     invalid property name; text color must be set using the `color` property.
#
# Fix in `css/styles.css`:
#   #hero-banner {
#       background-color: #0b2545;
#       color: #ffffff;
#       padding: 28px;
#       border-radius: 6px;
#   }
#
#   .subtitle {
#       color: #8da9c4;
#       font-size: 1rem;
#   }
#
#
# STEP 3: Resolve Specificity Conflict in css/styles.css
# ------------------------------------------------------------------------------
# Inspect lines 34-42 of `css/styles.css`:
#   #content p { color: #4a4a4a; font-size: 1rem; line-height: 1.5; }
#   .highlight { color: #d90429; font-weight: bold; }
#
# Specificity Breakdown:
#   - Selector `#content p`  -> (1, 0, 1) [1 ID, 0 Classes, 1 Element]
#   - Selector `.highlight` -> (0, 1, 0) [0 IDs, 1 Class, 0 Elements]
#
# Since (1, 0, 1) > (0, 1, 0), the ID combinator rule `#content p` wins the cascade,
# preventing `.highlight` from setting the red text color.
#
# Fix (Increase `.highlight` specificity without using !important):
# Change `.highlight` to `#content p.highlight` -> Specificity (1, 1, 1):
#
#   #content p.highlight {
#       color: #d90429;
#       font-weight: bold;
#   }
#
#
# STEP 4: Production Runtime Verification
# ------------------------------------------------------------------------------
# 1. Start HTTP server:
#    cd /tmp/lpi-030-100-topic-3.1-lab && python3 -m http.server 8080
# 2. Access http://localhost:8080:
#    - Header background is dark navy (#0b2545) with light blue subtitle text (#8da9c4).
#    - 'Drain Faulty Nodes' button displays styled green (#137547) with white bold text.
#    - Telemetry alert text renders in bold red (#d90429).