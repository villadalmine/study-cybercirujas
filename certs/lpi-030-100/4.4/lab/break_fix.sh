#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100 v1.0)
# Topic 4.4: JavaScript Manipulation of Website Content and Styling (Weight: 5)
# Break & Fix Practical Production-Level Lab Environment Script
#
# Official Reference URL:
# https://www.lpi.org/our-certifications/web-development-essentials-overview/
# ==============================================================================

set -euo pipefail

LAB_DIR="${HOME}/lpi_lab_topic_4_4"

echo "[+] Initializing LPI 030-100 Topic 4.4 Break & Fix Lab Environment..."
echo "[+] Creating target directory at: ${LAB_DIR}"
mkdir -p "${LAB_DIR}"

# ------------------------------------------------------------------------------
# 1. Create index.html (Baseline DOM Structure)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Production System Health Dashboard</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <header>
        <h1>Infrastructure Monitoring Dashboard</h1>
        <button id="theme-toggle-btn">Toggle Dark Mode</button>
    </header>

    <main>
        <section id="controls">
            <button id="update-status-btn">Update Cluster Status</button>
            <button id="highlight-cards-btn">Highlight Master Node</button>
        </section>

        <section id="dashboard">
            <div class="status-card" data-node="node-01">
                <h2>Node 01 (Master)</h2>
                <div class="status-content">Status: Initializing</div>
            </div>
            <div class="status-card" data-node="node-02">
                <h2>Node 02 (Worker)</h2>
                <div class="status-content">Status: Initializing</div>
            </div>
            <div class="status-card" data-node="node-03">
                <h2>Node 03 (Worker)</h2>
                <div class="status-content">Status: Initializing</div>
            </div>
        </section>
    </main>

    <script src="app.js"></script>
</body>
</html>
EOF

# ------------------------------------------------------------------------------
# 2. Create styles.css (CSS Base Tokens & Classes)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/styles.css"
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background-color: #f4f6f8;
    color: #1f2937;
    margin: 0;
    padding: 24px;
    transition: background-color 0.3s ease, color 0.3s ease;
}

body.dark-mode {
    background-color: #111827;
    color: #f9fafb;
}

header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 2px solid #e5e7eb;
    padding-bottom: 16px;
}

body.dark-mode header {
    border-color: #374151;
}

button {
    padding: 10px 18px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    border: none;
    border-radius: 6px;
    background-color: #2563eb;
    color: #ffffff;
    margin-right: 12px;
}

button:hover {
    background-color: #1d4ed8;
}

#dashboard {
    display: flex;
    gap: 20px;
    margin-top: 24px;
}

.status-card {
    background: #ffffff;
    border: 1px solid #d1d5db;
    border-radius: 8px;
    padding: 16px;
    width: 220px;
    transition: transform 0.2s, background-color 0.3s, border-color 0.3s;
}

body.dark-mode .status-card {
    background: #1f2937;
    border-color: #374151;
}

.badge-active {
    color: #059669;
    font-weight: 700;
}
EOF

# ------------------------------------------------------------------------------
# 3. Create app.js (Injected with Common Real-World DOM Manipulation Bugs)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/app.js"
// Broken JavaScript Implementation - LPI 030-100 Topic 4.4 Lab

document.addEventListener('DOMContentLoaded', () => {

    // BUG 1: Misunderstanding DOM Selector APIs
    // getElementById expects ONLY the element ID name (string), not CSS syntax selector ('#').
    // This query evaluates to null and causes an exception when adding event listeners.
    const themeBtn = document.getElementById('#theme-toggle-btn');
    
    themeBtn.addEventListener('click', () => {
        document.body.classList.toggle('dark-mode');
    });

    // BUG 2 & BUG 3: NodeList Property Access & Text Node Escaping Errors
    const updateBtn = document.getElementById('update-status-btn');
    
    updateBtn.addEventListener('click', () => {
        const cards = document.querySelectorAll('.status-card');
        
        // BUG 2: querySelectorAll returns a NodeList collection, NOT a single Element.
        // Direct property mutation on NodeList (cards.style) fails silently or throws TypeError.
        cards.style.backgroundColor = '#ecfdf5';
        
        // BUG 3: Inappropriate property choice for HTML element insertion.
        // textContent escapes raw strings, rendering literal HTML tags as text.
        const statusElements = document.querySelectorAll('.status-content');
        statusElements.forEach((el) => {
            el.textContent = '<span class="badge-active">Status: Operational</span>';
        });
    });

    // BUG 4: Invalid JavaScript Syntax for Inline Style Modification
    const highlightBtn = document.getElementById('highlight-cards-btn');
    highlightBtn.addEventListener('click', () => {
        const firstCard = document.querySelector('.status-card');
        // BUG 4: CSS properties with hyphens cannot be accessed using unquoted dot notation.
        // In JS object syntax, `style.border-color` is parsed as subtraction (style.border MINUS color).
        firstCard.style.border-color = '#059669';
    });
});
EOF

# ------------------------------------------------------------------------------
# 4. Display Scenario, Symptoms, and Lab Instructions to Student
# ------------------------------------------------------------------------------
cat << 'INSTRUCTIONS'

================================================================================
          LPI 030-100 (v1.0) TOPIC 4.4 BREAK & FIX CHALLENGE ENVIRONMENT
================================================================================

CERTIFICATION MODULE:
Topic 4.4: JavaScript Manipulation of Website Content and Styling (Weight: 5)
Official Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/

SCENARIO:
You are an SRE maintaining a web-based status monitoring portal. A recent feature
commit broke all dynamic interactive content and theme manipulation routines in `app.js`.

EXPECTED BEHAVIOR:
1. Clicking "Toggle Dark Mode" should toggle the `.dark-mode` class on the `<body>` element.
2. Clicking "Update Cluster Status" should iterate over all `.status-card` elements, 
   set their background color to `#ecfdf5`, and update `.status-content` elements with 
   styled HTML badges reading "Status: Operational".
3. Clicking "Highlight Master Node" should apply a green border (`#059669`) to the first card.

CURRENT SYMPTOMS:
- Page load / Script execution failure: Browser Console reports syntax errors or runtime exceptions.
- Clicking "Toggle Dark Mode" throws: `Uncaught TypeError: Cannot read properties of null (reading 'addEventListener')`.
- Clicking "Update Cluster Status" throws: `Uncaught TypeError: Cannot set properties of undefined (setting 'backgroundColor')`.
- HTML tags appear literally as text strings instead of rendering rich badge UI elements.

YOUR GOAL:
Inspect and refactor `${HOME}/lpi_lab_topic_4_4/app.js` using proper JavaScript DOM APIs:
- Correct DOM selector method parameters (`document.getElementById` vs `document.querySelector`).
- Properly iterate over `NodeList` collections returned by `querySelectorAll`.
- Use correct property bindings for HTML content parsing (`innerHTML` vs `textContent`).
- Apply inline styles using valid JavaScript camelCase property names or API methods.

TO START THE LOCAL WEB SERVER FOR TESTING:
  cd ~/lpi_lab_topic_4_4
  python3 -m http.server 8080

Then access http://localhost:8080 in your web browser and open Developer Tools (F12 -> Console).
================================================================================

INSTRUCTIONS

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION & TECHNICAL ANALYSIS (FOR INSTRUCTORS / VERIFICATION)
# ==============================================================================
#
# ------------------------------------------------------------------------------
# ROOT CAUSE ANALYSIS & TECHNICAL EXPLANATIONS:
# ------------------------------------------------------------------------------
#
# 1. Selector Parameter Mismatch (`getElementById`):
#    - `document.getElementById('id-name')` takes a raw string ID value WITHOUT a `#` prefix.
#    - `document.querySelector('#id-name')` takes a full CSS selector string WITH a `#` prefix.
#    - Passing `'#theme-toggle-btn'` into `getElementById` returns `null`, causing `null.addEventListener()`
#      to throw a runtime `TypeError`.
#
# 2. NodeList Mutation Fallacy:
#    - `document.querySelectorAll()` returns a static `NodeList` array-like collection.
#    - Individual CSS style properties exist on `Element.style`, NOT on the `NodeList` container.
#    - The collection must be iterated using `.forEach(element => element.style.property = value)`.
#
# 3. Text Escaping vs HTML Parsing (`textContent` vs `innerHTML`):
#    - `textContent` sets or returns the textual content of a node and its descendants. It treats
#      input strings strictly as text and automatically escapes HTML entities (`<` becomes `&lt;`).
#    - `innerHTML` parses the string input as HTML markup, rendering embedded elements (e.g. `<span>`).
#
# 4. CSS Property Naming Conventions in JavaScript DOM Style Objects:
#    - Hyphenated CSS property names (e.g., `border-color`) are invalid identifiers in JavaScript dot notation.
#    - JavaScript maps CSS property names to camelCase properties on the `CSSStyleDeclaration` object:
#      `element.style.borderColor = '#059669'`.
#    - Alternatively, standard string-based property access can be used:
#      `element.style.setProperty('border-color', '#059669')`.
#
# ------------------------------------------------------------------------------
# FULLY SYNTACTICALLY VALID RESOLUTION (`app.js`):
# ------------------------------------------------------------------------------
#
# document.addEventListener('DOMContentLoaded', () => {
#
#     // FIX 1: Remove '#' from getElementById argument
#     const themeBtn = document.getElementById('theme-toggle-btn');
#     
#     if (themeBtn) {
#         themeBtn.addEventListener('click', () => {
#             document.body.classList.toggle('dark-mode');
#         });
#     }
#
#     // FIX 2 & FIX 3: Iterate over NodeList and use innerHTML for markup
#     const updateBtn = document.getElementById('update-status-btn');
#     
#     if (updateBtn) {
#         updateBtn.addEventListener('click', () => {
#             const cards = document.querySelectorAll('.status-card');
#             
#             // Correctly iterate over NodeList
#             cards.forEach((card) => {
#                 card.style.backgroundColor = '#ecfdf5';
#             });
#             
#             const statusElements = document.querySelectorAll('.status-content');
#             statusElements.forEach((el) => {
#                 // Use innerHTML to parse span element correctly
#                 el.innerHTML = '<span class="badge-active">Status: Operational</span>';
#             });
#         });
#     }
#
#     // FIX 4: Use camelCase property naming syntax for JS style access
#     const highlightBtn = document.getElementById('highlight-cards-btn');
#     if (highlightBtn) {
#         highlightBtn.addEventListener('click', () => {
#             const firstCard = document.querySelector('.status-card');
#             if (firstCard) {
#                 firstCard.style.borderColor = '#059669';
#                 firstCard.style.borderWidth = '2px';
#                 firstCard.style.borderStyle = 'solid';
#             }
#         });
#     }
# });
#
# ------------------------------------------------------------------------------
# AUTOMATED LAB FIX COMMAND (ONE-LINER FOR TESTING):
# ------------------------------------------------------------------------------
# cat << 'SOLUTION_EOF' > "${HOME}/lpi_lab_topic_4_4/app.js"
# document.addEventListener('DOMContentLoaded', () => {
#     const themeBtn = document.getElementById('theme-toggle-btn');
#     themeBtn.addEventListener('click', () => {
#         document.body.classList.toggle('dark-mode');
#     });
#
#     const updateBtn = document.getElementById('update-status-btn');
#     updateBtn.addEventListener('click', () => {
#         const cards = document.querySelectorAll('.status-card');
#         cards.forEach((card) => {
#             card.style.backgroundColor = '#ecfdf5';
#         });
#         
#         const statusElements = document.querySelectorAll('.status-content');
#         statusElements.forEach((el) => {
#             el.innerHTML = '<span class="badge-active">Status: Operational</span>';
#         });
#     });
#
#     const highlightBtn = document.getElementById('highlight-cards-btn');
#     highlightBtn.addEventListener('click', () => {
#         const firstCard = document.querySelector('.status-card');
#         if (firstCard) {
#             firstCard.style.borderColor = '#059669';
#             firstCard.style.borderWidth = '2px';
#             firstCard.style.borderStyle = 'solid';
#         }
#     });
# });
# SOLUTION_EOF
# ==============================================================================