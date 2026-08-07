#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, Version 1.0)
# Topic 3.4: CSS Box Model and Layout (Weight: 5)
# SRE & Platform Architecture Production Practice Lab: "Break & Fix"
#
# Official Reference Documentation:
# - LPI Exam Overview & Objectives: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# - MDN CSS Box Model: https://developer.mozilla.org/en-US/docs/Learn/CSS/Building_blocks/The_box_model
# - MDN CSS box-sizing Property: https://developer.mozilla.org/en-US/docs/Web/CSS/box-sizing
# - W3C CSS Box Model Module Level 3: https://www.w3.org/TR/css-box-3/
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_css_box_model_lab"

echo "[+] Initializing LPI 030-100 Topic 3.4 Production Lab Environment..."
echo "[+] Target Directory: ${LAB_DIR}"

rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}"

# Create HTML entrypoint
cat << 'EOF' > "${LAB_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SRE Telemetry Dashboard - Box Model Lab</title>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header class="header">
    <h1>Cluster Telemetry Dashboard</h1>
  </header>
  <main class="dashboard-container">
    <div class="card-grid">
      <section class="card" id="card-cpu">
        <h2>CPU Utilization</h2>
        <p class="metric">42%</p>
      </section>
      <section class="card" id="card-mem">
        <h2>Memory Usage</h2>
        <p class="metric">78%</p>
      </section>
      <section class="card" id="card-disk">
        <h2>Disk Throughput</h2>
        <p class="metric">120 MB/s</p>
      </section>
    </div>
  </main>
</body>
</html>
EOF

# Create broken CSS file demonstrating the content-box calculation bug
cat << 'EOF' > "${LAB_DIR}/styles.css"
/* BROKEN CSS CONFIGURATION - TOPIC 3.4 BOX MODEL BUG */

/* Reset & Basic Styling */
body {
  margin: 0;
  font-family: system-ui, -apple-system, sans-serif;
  background-color: #0f172a;
  color: #f8fafc;
}

.header {
  background-color: #1e293b;
  padding: 16px 24px;
  border-bottom: 2px solid #334155;
}

/* Fixed container width designed for exactly 3 columns side-by-side */
.dashboard-container {
  width: 1200px;
  margin: 40px auto;
  background-color: #1e293b;
  padding: 24px;
}

/* Flexbox container intended to display 3 cards in one horizontal row */
.card-grid {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  gap: 0px;
}

/* 
 * BROKEN BOX MODEL MECHANICS:
 * The initial browser default for 'box-sizing' is 'content-box'.
 * Intended layout width per card: 400px (1200px container / 3 cards = 400px per card).
 *
 * Under 'content-box':
 *   Rendered Width = width + padding-left + padding-right + border-left-width + border-right-width
 *   Rendered Width = 400px + 20px + 20px + 2px + 2px = 444px per card.
 *
 * Total Row Width for 3 Cards = 444px * 3 = 1332px.
 * Since 1332px > 1200px (container width), flex-wrap forces the 3rd card to drop to line 2.
 */
.card {
  width: 400px;
  padding: 20px;
  border: 2px solid #3b82f6;
  background-color: #0f172a;
  border-radius: 8px;
}

.card h2 {
  margin-top: 0;
  color: #94a3b8;
  font-size: 1.1rem;
}

.card .metric {
  font-size: 2rem;
  font-weight: bold;
  color: #38bdf8;
}
EOF

# Create programmatic validation script
cat << 'EOF' > "${LAB_DIR}/check_solution.sh"
#!/usr/bin/env bash
set -euo pipefail

CSS_FILE="/tmp/lpi_css_box_model_lab/styles.css"

echo "[*] Validating solution against CSS Box Model objectives..."

if [ ! -f "$CSS_FILE" ]; then
  echo "[FAIL] File $CSS_FILE not found!"
  exit 1
fi

# Check if box-sizing: border-box is present in the CSS stylesheet
HAS_BORDER_BOX=$(grep -E "box-sizing:\s*border-box" "$CSS_FILE" || true)

if [ -z "$HAS_BORDER_BOX" ]; then
  echo "[FAIL] 'box-sizing: border-box' is missing in $CSS_FILE!"
  echo "       Default content-box calculation causes padding (40px) and borders (4px)"
  echo "       to be added outside the 400px width, resulting in 444px total width per card."
  echo "       This overflows the 1200px container (444px * 3 = 1332px > 1200px)."
  exit 1
fi

echo "[SUCCESS] Box Model fix verified! 'box-sizing: border-box' is configured."
echo "[SUCCESS] Each card rendered width (content + padding + border) now equals 400px."
echo "[SUCCESS] Total width for 3 cards = 400px * 3 = 1200px. All cards fit in 1 row!"
EOF

chmod +x "${LAB_DIR}/check_solution.sh"

cat << 'EOF'

================================================================================
  LPI 030-100 TOPIC 3.4 - LAB ENVIRONMENT READY
================================================================================

Lab Directory: /tmp/lpi_css_box_model_lab

[SCENARIO OVERVIEW]
You are managing an SRE monitoring dashboard frontend where 3 telemetry metrics 
cards are rendered inside a fixed 1200px parent container (`.dashboard-container`). 
The design system mandates that all 3 cards fit side-by-side in a single row.

[OBSERVED SYMPTOMS]
1. The 3rd card ("Disk Throughput") wraps to a second row below the first two.
2. The flexbox container width is strictly fixed at 1200px.
3. Each `.card` element is configured with:
     width: 400px
     padding: 20px (left + right = 40px)
     border: 2px solid #3b82f6 (left + right = 4px)
4. Under default CSS box calculation (`content-box`), total element width is:
     400px (content) + 40px (padding) + 4px (border) = 444px
5. Total width of 3 cards: 444px * 3 = 1332px > 1200px, triggering unwanted flex wrapping.

[STUDENT OBJECTIVES]
1. Navigate to `/tmp/lpi_css_box_model_lab/`.
2. Inspect `styles.css` to diagnose the Box Model sizing behavior.
3. Modify `styles.css` using modern CSS Box Model best practices (`box-sizing: border-box`)
   so that element padding and borders are calculated INSIDE the 400px width.
4. Execute `./check_solution.sh` to verify your fix.

================================================================================
EOF


# ==============================================================================
# STEP-BY-STEP SOLUTION AND DIAGNOSTIC GUIDE (INSTRUCTOR / PRACTICE REFERENCE)
# ==============================================================================
#
# DIAGNOSTIC COMMANDS & ANALYSIS:
# -------------------------------
# 1. Inspect box-sizing declarations in stylesheet:
#    grep -i "box-sizing" /tmp/lpi_css_box_model_lab/styles.css
#    Result: (empty) -> Indicates browser default 'content-box' is active.
#
# 2. Inspect element dimensions math:
#    - Container width: 1200px
#    - Requested card width: 400px (3 * 400 = 1200px)
#    - Padding: 20px left + 20px right = 40px
#    - Border: 2px left + 2px right = 4px
#    - Computed content-box width = 400 + 40 + 4 = 444px
#    - Overflow calculation: 444px * 3 = 1332px (132px beyond container limit).
#
# UNDERLYING ARCHITECTURE & CSS MECHANICS:
# ----------------------------------------
# According to W3C CSS Box Model Specification (Module Level 3):
#
# 1. `box-sizing: content-box` (Default Spec Behavior):
#    - `width` property configures ONLY the inner Content area width.
#    - Total Element Width = width + padding-left + padding-right + border-left + border-right
#    - Forces developers to manually recalculate content width whenever padding or border changes.
#
# 2. `box-sizing: border-box` (Modern Production Standard):
#    - `width` property configures the ENTIRE Outer Box (Content + Padding + Border).
#    - Inner Content Width = width - (padding-left + padding-right + border-left + border-right)
#    - For this lab: 400px - (40px + 4px) = 356px inner content width.
#    - Total rendered element width remains exactly 400px, ensuring 3 * 400px = 1200px.
#
# STEP-BY-STEP SOLUTION FIX:
# --------------------------
# Method A: Universal CSS Reset (Industry Best Practice)
# Add the universal selector box-sizing reset at the top of styles.css:
#
# *,
# *::before,
# *::after {
#   box-sizing: border-box;
# }
#
# Method B: Targeted Class Override
# Add `box-sizing: border-box;` directly inside the `.card` rule:
#
# .card {
#   box-sizing: border-box;
#   width: 400px;
#   padding: 20px;
#   border: 2px solid #3b82f6;
#   background-color: #0f172a;
#   border-radius: 8px;
# }
#
# VERIFICATION EXECUTION:
# -----------------------
# Run: /tmp/lpi_css_box_model_lab/check_solution.sh
# Expected Terminal Output:
#   [*] Validating solution against CSS Box Model objectives...
#   [SUCCESS] Box Model fix verified! 'box-sizing: border-box' is configured.
#   [SUCCESS] Each card rendered width (content + padding + border) now equals 400px.
#   [SUCCESS] Total width for 3 cards = 400px * 3 = 1200px. All cards fit in 1 row!
# ==============================================================================