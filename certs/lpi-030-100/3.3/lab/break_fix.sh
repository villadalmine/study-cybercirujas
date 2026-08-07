#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, Version 1.0)
# Topic 3.3: CSS Styling (Weight: 5)
# Production Break & Fix Laboratory Script
#
# Official Reference Documentation:
# - LPI Web Development Essentials: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# - W3C CSS Cascade and Inheritance Level 4: https://www.w3.org/TR/css-cascade-4/
# - W3C CSS Box Model Module Level 3: https://www.w3.org/TR/css-box-3/
# - W3C CSS Syntax Module Level 3 (Parsing Rules): https://www.w3.org/TR/css-syntax-3/
# - MDN CSS Specificity Mechanics: https://developer.mozilla.org/en-US/docs/Web/CSS/Specificity
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_030_3_css_lab"
PORT=8888
PID_FILE="${LAB_DIR}/server.pid"

# Colors for terminal display
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[INFO] Initializing LPI 030-100 Topic 3.3 (CSS Styling) Break & Fix Lab...${NC}"

# Cleanup existing environment if present
if [ -f "$PID_FILE" ]; then
    echo -e "${YELLOW}[CLEANUP] Stopping existing lab web server...${NC}"
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
fi
rm -rf "$LAB_DIR"
mkdir -p "${LAB_DIR}/css"

# ------------------------------------------------------------------------------
# STEP 1: Generate Baseline Standard Files
# ------------------------------------------------------------------------------
echo -e "${BLUE}[SETUP] Generating standard web application files...${NC}"

cat << 'EOF' > "${LAB_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Production System Dashboard - SRE Portal</title>
    <link rel="stylesheet" href="css/main.css">
</head>
<body>
    <header id="main-header" class="site-header">
        <h1>Enterprise Platform Status</h1>
        <nav id="app-nav" class="navigation">
            <a href="#overview" class="nav-item active">Overview</a>
            <a href="#metrics" class="nav-item">Metrics</a>
            <a href="#logs" class="nav-item">Logs</a>
        </nav>
    </header>

    <main id="app-container" class="dashboard-wrapper">
        <section class="card alert-card">
            <h2>Critical Incident Feed</h2>
            <p>System status is nominal. All edge clusters operational.</p>
        </section>
        <section class="card metrics-card">
            <h2>Cluster Telemetry</h2>
            <div class="grid-container">
                <div class="grid-item">CPU Usage: 42%</div>
                <div class="grid-item">RAM Usage: 68%</div>
            </div>
        </section>
    </main>
</body>
</html>
EOF

# Standard css/main.css
cat << 'EOF' > "${LAB_DIR}/css/main.css"
@import url("layout.css");
@import url("theme.css");

/* Base Reset & Core Styles */
* {
    margin: 0;
    padding: 0;
}

body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background-color: #0f172a;
    color: #f8fafc;
}
EOF

# Standard css/layout.css
cat << 'EOF' > "${LAB_DIR}/css/layout.css"
/* Layout Definitions */
.dashboard-wrapper {
    width: 100%;
    padding: 40px;
    border: 4px solid #334155;
    box-sizing: border-box;
}

.grid-container {
    display: flex;
    flex-direction: row;
    gap: 20px;
}

.grid-item {
    flex: 1;
    background: #1e293b;
    padding: 15px;
    border-radius: 6px;
}
EOF

# Standard css/theme.css
cat << 'EOF' > "${LAB_DIR}/css/theme.css"
/* Theme & Component Specificity Rules */
.nav-item {
    color: #94a3b8;
    text-decoration: none;
    padding: 8px 16px;
}

.nav-item.active {
    color: #38bdf8;
    border-bottom: 2px solid #38bdf8;
    font-weight: bold;
}

.card {
    background-color: #1e293b;
    border-radius: 8px;
    margin-bottom: 20px;
    padding: 20px;
}
EOF

# ------------------------------------------------------------------------------
# STEP 2: Introduce Controlled Production Breakages
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[BREAKING] Injecting CSS architecture defects into production stylesheets...${NC}"

# DEFECT 1: Incorrect relative path in @import inside main.css causing 404 on layout.css
cat << 'EOF' > "${LAB_DIR}/css/main.css"
@import url("styles/layout.css");
@import url("theme.css");

/* Base Reset & Core Styles */
* {
    margin: 0;
    padding: 0;
}

body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background-color: #0f172a;
    color: #f8fafc;
}
EOF

# DEFECT 2 & 3: Syntax parsing failure (unclosed comment dropping layout rules)
# AND Box Model Overflow defect (width 100% with padding without border-box)
cat << 'EOF' > "${LAB_DIR}/css/layout.css"
/* Layout Definitions
   Broken Comment Block: Missing closing delimiter breaks stylesheet parser
.dashboard-wrapper {
    width: 100%;
    padding: 40px;
    border: 4px solid #334155;
    /* Missing box-sizing: border-box causes horizontal viewport overflow */
    box-sizing: content-box;
}

.grid-container {
    display: flex;
    flex-direction: row;
    gap: 20px;
}

.grid-item {
    flex: 1;
    background: #1e293b;
    padding: 15px;
    border-radius: 6px;
}
EOF

# DEFECT 4: Specificity Collision breaking .nav-item.active styling
cat << 'EOF' >> "${LAB_DIR}/css/theme.css"

/* High-specificity override breaking state styling */
#main-header #app-nav a {
    color: #94a3b8 !important;
    border-bottom: none;
}
EOF

# ------------------------------------------------------------------------------
# STEP 3: Launch Local Lab Web Server
# ------------------------------------------------------------------------------
echo -e "${BLUE}[SYSTEM] Launching background HTTP service on port ${PORT}...${NC}"
python3 -m http.server "$PORT" --directory "$LAB_DIR" > /dev/null 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"
sleep 1

# Verify server operation
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo -e "${RED}[ERROR] Failed to start HTTP server on port ${PORT}.${NC}"
    exit 1
fi

# ------------------------------------------------------------------------------
# STEP 4: Present Problem Briefing to Student
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}==============================================================================${NC}"
echo -e "${GREEN}             LPI 030-100 (Topic 3.3: CSS Styling) LAB LOADED                  ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo -e "Lab URL: ${YELLOW}http://localhost:${PORT}/index.html${NC}"
echo -e "Lab Path: ${YELLOW}${LAB_DIR}${NC}\n"

cat << 'EOF'
[SRE SCENARIO BRIEFING]
You are responding to a UI deployment incident on the SRE Monitoring Portal.
Following a front-end refactoring release, the dashboard interface suffers from four
critical CSS rendering issues in production:

1. RESOURCE LOADING FAILURE:
   The main layout stylesheet is returning a HTTP 404 error when fetched by clients.

2. CSS SYNTAX PARSER DROP:
   The browser parser drops key layout blocks, causing `.dashboard-wrapper` and grid
   flex layout rules to fail silently.

3. BOX MODEL CALCULATED OVERFLOW:
   Even when layout rules apply, `.dashboard-wrapper` causes horizontal scrollbar
   overflow on standard viewport widths because element width exceeds 100%.

4. SPECIFICITY OVERRIDE COLLISION:
   The navigation active state (`.nav-item.active`) visual indicators (highlight color
   and active bottom border) are overridden and failing to render due to selector
   specificity precedence misuse.

[EXPECTED SYMPTOMS & DIAGNOSTICS TO PERFORM]
Run the following commands to observe and diagnose the defects:

  1. Test HTTP Resource Loading for Cascaded Imports:
     $ curl -sI http://localhost:8888/css/styles/layout.css
     (Expected: HTTP/1.0 404 Not Found)

  2. Verify Valid Stylesheet Resource Path:
     $ curl -sI http://localhost:8888/css/layout.css
     (Expected: HTTP/1.0 200 OK)

  3. Inspect Syntax Block Violations in `css/layout.css`:
     Notice the unclosed comment block `/* Layout Definitions ...` which causes
     conforming CSS parsers (per W3C CSS Syntax Level 3) to consume subsequent token
     stream until EOF or closing delimiter, ignoring rules.

  4. Analyze Box Model Sizing Calculation:
     Calculated width = width (100%) + padding-left (40px) + padding-right (40px)
                        + border-left (4px) + border-right (4px)
                      = 100% + 88px  (Triggers viewport horizontal overflow)
     Target box-sizing model: `border-box` (Calculated total width = 100%).

  5. Analyze CSS Specificity Calculation:
     Current active state selector: `.nav-item.active` -> Specificity (0, 0, 2, 0)
     Colliding rule: `#main-header #app-nav a` -> Specificity (0, 2, 0, 1) + `!important`
     Because (0, 2, 0, 1) + !important > (0, 0, 2, 0), the active color styling is blocked.

[OBJECTIVES TO FIX THE INCIDENT]
- Fix `css/main.css` `@import` statement to correctly reference `layout.css`.
- Fix syntax error in `css/layout.css` by closing the block comment (`*/`).
- Configure proper Box Model reset or sizing rule `box-sizing: border-box;` on `.dashboard-wrapper`.
- Refactor `css/theme.css` to eliminate the `!important` flag and high-specificity selector collision,
  allowing `.nav-item.active` (specificity 0,0,2,0) to determine active state styles cleanly.

==============================================================================
EOF

exit 0

# ==============================================================================
#                      STEP-BY-STEP SOLUTION (COMMENTED)
# ==============================================================================
# To resolve all defects introduced in this lab, perform the following edits:
#
# ------------------------------------------------------------------------------
# STEP 1: Fix @import relative path in `css/main.css`
# ------------------------------------------------------------------------------
# Problem: `@import url("styles/layout.css");` looks for `/css/styles/layout.css` (404).
# Solution: Update `css/main.css` to import `layout.css` from the same directory (`css/`).
#
# Edit `css/main.css`:
# ```css
# @import url("layout.css");
# @import url("theme.css");
#
# * {
#     margin: 0;
#     padding: 0;
# }

# body {
#     font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
#     background-color: #0f172a;
#     color: #f8fafc;
# }
# ```
#
# ------------------------------------------------------------------------------
# STEP 2: Fix Syntax Error and Box Model Sizing in `css/layout.css`
# ------------------------------------------------------------------------------
# Problem 1: Unclosed comment `/* Layout Definitions` eats `.dashboard-wrapper` rule.
# Problem 2: `box-sizing: content-box` with `width: 100%` and `padding: 40px` causes overflow.
#
# Edit `css/layout.css`:
# ```css
# /* Layout Definitions */
# .dashboard-wrapper {
#     width: 100%;
#     padding: 40px;
#     border: 4px solid #334155;
#     box-sizing: border-box; /* Ensures width includes padding and border */
# }

# .grid-container {
#     display: flex;
#     flex-direction: row;
#     gap: 20px;
# }

# .grid-item {
#     flex: 1;
#     background: #1e293b;
#     padding: 15px;
#     border-radius: 6px;
# }
# ```
#
# ------------------------------------------------------------------------------
# STEP 3: Resolve Specificity and Cascade Conflict in `css/theme.css`
# ------------------------------------------------------------------------------
# Problem: `#main-header #app-nav a` uses high specificity (0,2,0,1) with `!important`,
# overriding `.nav-item.active` (0,0,2,0).
#
# Edit `css/theme.css`:
# Remove or refactor `#main-header #app-nav a` so it does not force `!important` over state classes.
#
# ```css
# .nav-item {
#     color: #94a3b8;
#     text-decoration: none;
#     padding: 8px 16px;
# }

# .nav-item.active {
#     color: #38bdf8;
#     border-bottom: 2px solid #38bdf8;
#     font-weight: bold;
# }

# .card {
#     background-color: #1e293b;
#     border-radius: 8px;
#     margin-bottom: 20px;
#     padding: 20px;
# }
# ```
#
# ------------------------------------------------------------------------------
# STEP 4: Verification Commands
# ------------------------------------------------------------------------------
# Run curl to verify all imports return HTTP 200:
# $ curl -sI http://localhost:8888/css/layout.css
# $ curl -sI http://localhost:8888/css/theme.css
# $ curl -s http://localhost:8888/index.html | head -n 20
#
# Reload http://localhost:8888/index.html in a web browser or headlessly inspect stylesheet
# rules to confirm layout alignment and active navigation highlight styling.
# ==============================================================================