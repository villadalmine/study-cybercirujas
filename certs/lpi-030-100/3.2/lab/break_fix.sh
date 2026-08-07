#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100 v1.0)
# Topic 3.2: CSS Selectors and Style Application (Weight: 7.5)
# Lab Type: Break & Fix Environment Setup & Diagnostic Manual
# Official Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# ==============================================================================
set -euo pipefail

LAB_DIR="/tmp/lpi_030_100_css_selectors_lab"
PORT=8080

echo "======================================================================"
echo " [LPI 030-100] Topic 3.2: CSS Selectors & Style Application Lab Setup"
echo "======================================================================"
echo "Initializing lab workspace at: ${LAB_DIR}"

rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}/css" "${LAB_DIR}/js"

# ------------------------------------------------------------------------------
# Create HTML structure with broken target selectors
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SRE Dashboard - Production Status</title>
    <!-- Cascade Order: External Stylesheets -->
    <link rel="stylesheet" href="css/base.css">
    <link rel="stylesheet" href="css/components.css">
    <style>
        /* Internal Stylesheet Override Test */
        #alert-panel .badge {
            background-color: #6c757d; /* Generic gray fallback */
        }
    </style>
</head>
<body>
    <header id="main-header" class="site-header">
        <nav class="nav-container">
            <div class="nav-wrapper">
                <ul class="nav-list">
                    <li class="nav-item"><a href="#dashboard" class="nav-link active">Dashboard</a></li>
                    <li class="nav-item"><a href="#metrics" class="nav-link">Metrics</a></li>
                    <li class="nav-item"><a href="#alerts" class="nav-link" data-type="critical">Alerts</a></li>
                </ul>
            </div>
        </nav>
    </header>

    <main class="content-body">
        <section id="alert-panel" class="panel">
            <h2>System Health Status</h2>
            <div class="status-grid">
                <div class="card" data-status="active">
                    <h3>API Gateway</h3>
                    <span class="badge status-ok">OPERATIONAL</span>
                    <button class="btn btn-primary" id="btn-refresh">Refresh</button>
                </div>
                <div class="card" data-status="degraded">
                    <h3>Database Cluster</h3>
                    <span class="badge status-warn">DEGRADED</span>
                    <button class="btn btn-secondary">Logs</button>
                </div>
                <div class="card" data-status="critical">
                    <h3>Auth Service</h3>
                    <span class="badge status-error">FAILING</span>
                    <button class="btn btn-danger">Restart</button>
                </div>
            </div>
        </section>

        <section class="table-section">
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Node ID</th>
                        <th>CPU Load</th>
                        <th>Memory</th>
                    </tr>
                </thead>
                <tbody>
                    <tr><td>node-01</td><td>12%</td><td>4.2 GB</td></tr>
                    <tr><td>node-02</td><td>88%</td><td>15.8 GB</td></tr>
                    <tr><td>node-03</td><td>45%</td><td>8.1 GB</td></tr>
                    <tr><td>node-04</td><td>92%</td><td>14.9 GB</td></tr>
                </tbody>
            </table>
        </section>
    </main>
</body>
</html>
EOF

# ------------------------------------------------------------------------------
# Create base.css (Global resets & basic layout)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/css/base.css"
/* Base Styles */
body {
    font-family: Arial, sans-serif;
    background-color: #f4f6f9;
    color: #333333;
    margin: 0;
    padding: 0;
}

.content-body {
    padding: 20px;
}

/* Generic Button Reset */
button {
    cursor: pointer;
    border: none;
    padding: 8px 16px;
    border-radius: 4px;
}
EOF

# ------------------------------------------------------------------------------
# Create components.css (Contains 3 intentional bugs for the student)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/css/components.css"
/* ==========================================================================
   LPI 030-100 LAB BUG 1: Direct Child Combinator Breakage
   Expected: Active nav link should have high visibility background (#0056b3) and white text.
   Bug: The selector assumes direct child structure (nav > ul > li > a)
   but HTML has an intermediate <div class="nav-wrapper"> element.
   ========================================================================== */
header.site-header nav.nav-container > ul.nav-list > li.nav-item > a.nav-link.active {
    background-color: #0056b3;
    color: #ffffff;
    padding: 6px 12px;
    border-radius: 4px;
    font-weight: bold;
}

/* Base Nav link formatting */
.nav-link {
    color: #333;
    text-decoration: none;
}

/* ==========================================================================
   LPI 030-100 LAB BUG 2: Specificity Hierarchy & Internal Style Override
   Expected: Status badges must reflect state colors:
             .status-ok -> #28a745 (Green)
             .status-warn -> #ffc107 (Yellow/Dark Text)
             .status-error -> #dc3545 (Red)
   Bug: In index.html, internal style `#alert-panel .badge` has specificity (0,1,0,1)
        which beats class selectors below with specificity (0,0,1,1).
        Additionally, the attribute selector syntax below has a typo in pseudo-element notation.
   ========================================================================== */
.panel .status-ok {
    background-color: #28a745;
    color: #ffffff;
}

.panel .status-warn {
    background-color: #ffc107;
    color: #212529;
}

.panel .status-error {
    background-color: #dc3545;
    color: #ffffff;
}

.badge {
    padding: 4px 8px;
    border-radius: 3px;
    font-size: 0.85rem;
}

/* ==========================================================================
   LPI 030-100 LAB BUG 3: Pseudo-class Syntax & Alternate Row Styling
   Expected: Alternating table rows in <tbody> should have background #e9ecef.
   Bug: Wrong pseudo-class selection syntax and wrong element targeting.
   ========================================================================== */
.data-table tbody tr:nth-child(even) {
    background-color: #ffffff;
}

/* Attempting to style even rows using invalid syntax */
.data-table tbody tr:nth-child = 2n + 1 {
    background-color: #e9ecef;
}

/* Attribute selector bug: attribute match missing quotes and wrong matching operator */
.card[data-status*=critical] {
    border-left: 5px solid #dc3545;
}
EOF

# ------------------------------------------------------------------------------
# Create simple Node verification script to test CSS rules headlessly
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/js/verify.js"
const fs = require('fs');
const path = require('path');

const cssPath = path.join(__dirname, '../css/components.css');
const htmlPath = path.join(__dirname, '../index.html');

const cssContent = fs.readFileSync(cssPath, 'utf8');
const htmlContent = fs.readFileSync(htmlPath, 'utf8');

let errors = [];

// Rule 1 Check: Child combinator fix
if (cssContent.includes('nav.nav-container > ul.nav-list')) {
    errors.push("[BUG 1 UNRESOLVED] Direct child combinator '>' still expects 'ul' directly inside 'nav', but '.nav-wrapper' exists.");
}

// Rule 2 Check: Specificity resolution
if (htmlContent.includes('#alert-panel .badge') && !cssContent.includes('#alert-panel .badge') && !cssContent.includes('!important')) {
    errors.push("[BUG 2 UNRESOLVED] Internal style `#alert-panel .badge` in index.html is still overriding component badge colors due to ID specificity (0,1,0,1).");
}

// Rule 3 Check: Pseudo-class nth-child syntax
if (cssContent.includes(':nth-child = 2n + 1') || cssContent.includes(':nth-child(even) {\n    background-color: #ffffff;')) {
    errors.push("[BUG 3 UNRESOLVED] Table zebra striping `:nth-child` pseudo-class syntax is invalid or inverted.");
}

if (errors.length === 0) {
    console.log("=====================================================");
    console.log(" SUCCESS: All CSS Selector & Specificity issues fixed!");
    console.log("=====================================================");
    process.exit(0);
} else {
    console.log("=====================================================");
    console.log(" VERIFICATION FAILED - Review the following issues:");
    console.log("=====================================================");
    errors.forEach(e => console.log(" - " + e));
    process.exit(1);
}
EOF

# ------------------------------------------------------------------------------
# Display Diagnostic Manual & Problem Statement
# ------------------------------------------------------------------------------
cat << EOF

======================================================================
 STUDENT DIAGNOSTIC MANUAL - LPI 030-100 TOPIC 3.2
======================================================================

LAB ENVIRONMENT CREATED AT: ${LAB_DIR}

SYMPTOMS OBSERVED:
1. Navigation Menu:
   - The active navigation item ('Dashboard') is not highlighted with the 
     blue background (#0056b3) and white text. It appears as plain text.
   - Root Cause: Selector combinator mismatch between CSS declaration and DOM tree structure.

2. System Status Badges:
   - All badges (OPERATIONAL, DEGRADED, FAILING) display with a generic grey 
     background (#6c757d) instead of their designated state colors (green, yellow, red).
   - Root Cause: Specificity hierarchy collision. Internal `<style>` tag in 
     `index.html` uses an ID selector (#alert-panel .badge) which overrides 
     class selectors (.panel .status-ok) regardless of stylesheet order.

3. Table Zebra Striping & Critical Card Borders:
   - Table rows are not alternating colors correctly (`:nth-child` syntax error).
   - The card with `data-status="critical"` does not render the red left border.
   - Root Cause: Malformed pseudo-class expression and malformed attribute selector syntax.

STUDENT OBJECTIVE:
Fix `index.html` and `css/components.css` so that all styling rules correctly match 
target elements, satisfy specificity rules, and pass the verification suite.

HOW TO TEST YOUR FIXES:
  cd ${LAB_DIR}
  node js/verify.js

OR launch a local HTTP server to inspect visually:
  python3 -m http.server ${PORT} --directory ${LAB_DIR}
  (Navigate to http://localhost:${PORT} in browser)

======================================================================
EOF

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL EXPLANATION (STUDENT REFERENCE)
# ==============================================================================
#
# TECHNICAL BACKGROUND (LPI 030-100 Topic 3.2 Objectives):
#
# 1. CSS Selector Types & Combinators:
#    - Type / Element selector: target by HTML tag (e.g., `body`, `table`) -> Weight: (0,0,0,1)
#    - Class selector: target by `.class-name` -> Weight: (0,0,1,0)
#    - ID selector: target by `#id-name` -> Weight: (0,1,0,0)
#    - Attribute selector: target by `[attr="value"]`, `[attr*="value"]` -> Weight: (0,0,1,0)
#    - Pseudo-class: target state `:hover`, `:focus`, `:nth-child(n)` -> Weight: (0,0,1,0)
#    - Pseudo-element: target sub-part `::before`, `::after` -> Weight: (0,0,0,1)
#
#    Combinators:
#    - Descendant (space): matches any descendant element regardless of depth.
#    - Child (`>`): matches ONLY direct children of the parent element.
#    - Adjacent Sibling (`+`): matches element immediately following target sibling.
#    - General Sibling (`~`): matches all elements following target sibling.
#
# 2. Specificity Calculation Rule: (Inline, ID, Class/Attr/Pseudo, Element)
#    - Inline styles: (1, 0, 0, 0)
#    - ID selectors: (0, 1, 0, 0)
#    - Class, Attribute, Pseudo-class: (0, 0, 1, 0)
#    - Element, Pseudo-element: (0, 0, 0, 1)
#    - Universal (`*`), combinators (`+`, `>`, `~`, ` `) have 0 specificity weight.
#    - Equal specificity? The LAST declared rule in cascade order wins.
#
# ------------------------------------------------------------------------------
# FIX 1: Resolving Child Combinator Mismatch in css/components.css
# ------------------------------------------------------------------------------
# Problematic CSS:
#   header.site-header nav.nav-container > ul.nav-list > li.nav-item > a.nav-link.active
# DOM Structure:
#   header > nav.nav-container > div.nav-wrapper > ul.nav-list
# Fix Option A (Use Descendant Combinator):
#   header.site-header nav.nav-container ul.nav-list > li.nav-item > a.nav-link.active
# Fix Option B (Include wrapper in chain):
#   header.site-header nav.nav-container > .nav-wrapper > ul.nav-list > li.nav-item > a.nav-link.active
#
# Command to execute fix via CLI:
# sed -i 's/nav.nav-container > ul.nav-list/nav.nav-container .nav-wrapper > ul.nav-list/g' /tmp/lpi_030_100_css_selectors_lab/css/components.css
#
# ------------------------------------------------------------------------------
# FIX 2: Resolving Specificity Hierarchy Collision
# ------------------------------------------------------------------------------
# Problematic Internal Style in index.html:
#   #alert-panel .badge { background-color: #6c757d; }  <-- Specificity: (0,1,1,0)
# Class rules in css/components.css:
#   .panel .status-ok { background-color: #28a745; }   <-- Specificity: (0,0,2,0)
# Because (0,1,1,0) > (0,0,2,0), the internal ID selector always overrides external rules!
#
# Solution:
# 1. Remove internal `<style>` block from `index.html` OR match ID specificity in `components.css`:
#    `#alert-panel .status-ok { background-color: #28a745; }`
# 2. Refactor `index.html` to eliminate aggressive ID specificity overrides:
#
# Command to execute fix via CLI:
# sed -i '/#alert-panel \.badge/,+2d' /tmp/lpi_030_100_css_selectors_lab/index.html
#
# ------------------------------------------------------------------------------
# FIX 3: Correcting Pseudo-class Syntax & Attribute Selectors
# ------------------------------------------------------------------------------
# Problematic CSS:
#   .data-table tbody tr:nth-child = 2n + 1 { background-color: #e9ecef; }
#   .card[data-status*=critical] { border-left: 5px solid #dc3545; }
#
# Corrected CSS:
#   .data-table tbody tr:nth-child(odd) { background-color: #e9ecef; }
#   .data-table tbody tr:nth-child(even) { background-color: #ffffff; }
#   .card[data-status="critical"] { border-left: 5px solid #dc3545; }
#
# Command to execute fix via CLI:
# cat << 'EOFFIX' > /tmp/lpi_030_100_css_selectors_lab/css/components.css
# /* Corrected components.css */
# header.site-header nav.nav-container .nav-wrapper > ul.nav-list > li.nav-item > a.nav-link.active {
#     background-color: #0056b3;
#     color: #ffffff;
#     padding: 6px 12px;
#     border-radius: 4px;
#     font-weight: bold;
# }
#
# .nav-link {
#     color: #333;
#     text-decoration: none;
# }
#
# #alert-panel .badge.status-ok, .panel .status-ok {
#     background-color: #28a745;
#     color: #ffffff;
# }
#
# #alert-panel .badge.status-warn, .panel .status-warn {
#     background-color: #ffc107;
#     color: #212529;
# }
#
# #alert-panel .badge.status-error, .panel .status-error {
#     background-color: #dc3545;
#     color: #ffffff;
# }
#
# .badge {
#     padding: 4px 8px;
#     border-radius: 3px;
#     font-size: 0.85rem;
# }
#
# .data-table tbody tr:nth-child(odd) {
#     background-color: #e9ecef;
# }

# .data-table tbody tr:nth-child(even) {
#     background-color: #ffffff;
# }
#
# .card[data-status="critical"] {
#     border-left: 5px solid #dc3545;
# }
# EOFFIX
# ==============================================================================