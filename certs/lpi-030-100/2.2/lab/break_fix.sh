#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, Version 1.0)
# Topic 2.2: HTML Semantics and Document Hierarchy (Weight: 5)
# ------------------------------------------------------------------------------
# Official References:
# - LPI Certification Overview: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# - W3C HTML5 Semantics Spec: https://www.w3.org/TR/html52/dom.html#sec-semantics
# - WHATWG HTML Living Standard (Document Structure & Headings): https://html.spec.whatwg.org/multipage/sections.html
# - W3C Accessibility Landmarks (ARIA/HTML5): https://www.w3.org/WAI/ARIA/apg/patterns/landmarks/
# ==============================================================================
# PRODUCTION ENVIRONMENT BREAK-AND-FIX SCENARIO
# Target: Automated Accessibility & DOM Hierarchy CI/CD Pipeline
# ==============================================================================

set -euo pipefail

LAB_DIR="/opt/lpi-lab-topic2.2"

echo "=============================================================================="
echo " [+] Initializing SRE Break-and-Fix Environment for LPI 030-100 Topic 2.2"
echo "=============================================================================="
echo " Creating lab workspace at: ${LAB_DIR}"

mkdir -p "${LAB_DIR}"

# ------------------------------------------------------------------------------
# 1. Create the BROKEN HTML Document (Severe Semantic Anti-patterns & Invalid Outline)
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/index.html"
<html>
<head>
    <title>Enterprise Cloud Infrastructure Dashboard</title>
</head>
<body>
    <div id="top-bar">
        <div class="logo">CloudOps Portal</div>
        <div class="navigation">
            <a href="/clusters">Clusters</a> | 
            <a href="/metrics">Metrics</a> | 
            <a href="/alerts">Alerts</a>
        </div>
    </div>

    <div class="main-body">
        <h1>Cloud Cluster Health Summary</h1>
        <p>Current operational status for global Kubernetes regions.</p>

        <h4>Active Incident Overview</h4>
        <p>Region us-east-1 is experiencing degraded API latency.</p>
        <p>Incident logged on: 2026-08-07 01:15 UTC</p>

        <div class="content-box">
            <h3>Infrastructure Node Topology</h3>
            <p>Node <b>k8s-worker-01</b> status is <i>Ready</i>.</p>
            <img src="topology.png" alt="Node Diagram">
        </div>
    </div>

    <div id="footer">
        <p>&copy; 2026 CloudOps Platform Team. All rights reserved.</p>
    </div>
</body>
</html>
EOF

# ------------------------------------------------------------------------------
# 2. Create the Python DOM Semantic & Outline Validator Tool
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/validate.py"
import sys
import re
from html.parser import HTMLParser

class HTMLSemanticValidator(HTMLParser):
    def __init__(self):
        super().__init__()
        self.doctype_found = False
        self.meta_charset_found = False
        self.tags_seen = []
        self.headings = []
        self.tag_stack = []
        self.errors = []
        self.figures = []

    def handle_decl(self, decl):
        if decl.lower().strip() == 'html':
            self.doctype_found = True

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        self.tags_seen.append(tag)
        self.tag_stack.append(tag)
        attr_dict = dict(attrs)

        if tag == 'meta':
            if 'charset' in attr_dict or attr_dict.get('http-equiv', '').lower() == 'content-type':
                self.meta_charset_found = True

        if re.match(r'^h[1-6]$', tag):
            level = int(tag[1])
            self.headings.append((tag, level))

        if tag == 'figure':
            self.figures.append({'has_figcaption': False})

        if tag == 'figcaption':
            if self.figures:
                self.figures[-1]['has_figcaption'] = True
            else:
                self.errors.append("DOM Structure Error: <figcaption> found outside of a parent <figure> container.")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in self.tag_stack:
            self.tag_stack.remove(tag)

    def validate(self, content):
        self.feed(content)

        # Rule 1: Standard HTML5 DOCTYPE
        if not self.doctype_found:
            self.errors.append("[CRITICAL] Missing HTML5 DOCTYPE declaration (<!DOCTYPE html>). Quirks Mode activated.")

        # Rule 2: Meta Charset Declaration
        if not self.meta_charset_found:
            self.errors.append("[HIGH] Missing <meta charset=\"UTF-8\"> inside <head> for explicit character encoding.")

        # Rule 3: HTML5 Landmark Structural Elements
        required_landmarks = ['header', 'nav', 'main', 'footer']
        missing_landmarks = [lm for lm in required_landmarks if lm not in self.tags_seen]
        if missing_landmarks:
            self.errors.append(f"[HIGH] Missing structural HTML5 landmarks: {', '.join('<' + lm + '>' for lm in missing_landmarks)}. Document relies on generic <div> elements.")

        # Rule 4: Structural Sectioning
        sectioning_elements = ['article', 'section', 'aside']
        if not any(se in self.tags_seen for se in sectioning_elements):
            self.errors.append("[MEDIUM] Missing HTML5 sectioning elements (<article>, <section>, or <aside>). DOM hierarchy lacks semantic grouping.")

        # Rule 5: Heading Hierarchy & Document Outline
        if self.headings:
            first_tag, first_level = self.headings[0]
            if first_level != 1:
                self.errors.append(f"[HIGH] Document heading hierarchy must start with <h1>, but starts with <{first_tag}>.")

            for i in range(1, len(self.headings)):
                prev_tag, prev_level = self.headings[i-1]
                curr_tag, curr_level = self.headings[i]
                if curr_level > prev_level + 1:
                    self.errors.append(f"[HIGH] Invalid Heading Hierarchy: <{prev_tag}> followed by <{curr_tag}>. Skipping heading levels breaks document outline for screen readers (WCAG 2.1 1.3.1).")

        # Rule 6: Text Semantics vs Visual Formatting
        if 'b' in self.tags_seen or 'i' in self.tags_seen:
            self.errors.append("[MEDIUM] Non-semantic text formatting tags present (<b> or <i>). Replace with semantic <strong> (importance) or <em> (stress emphasis).")

        # Rule 7: Media Semantics & Figure Packaging
        if 'img' in self.tags_seen and 'figure' not in self.tags_seen:
            self.errors.append("[MEDIUM] Standalone image found without semantic wrapper (<figure> and <figcaption>).")

        for fig in self.figures:
            if not fig['has_figcaption']:
                self.errors.append("[HIGH] <figure> element missing child <figcaption> element.")

        # Rule 8: Machine-Readable Time Semantics
        if not any(tag == 'time' for tag in self.tags_seen):
            self.errors.append("[LOW] Temporal data present without machine-readable <time datetime=\"...\"> element.")

        return self.errors

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 validate.py <path_to_html>")
        sys.argv.append('/opt/lpi-lab-topic2.2/index.html')

    filepath = sys.argv[1]
    with open(filepath, 'r', encoding='utf-8') as f:
        html_content = f.read()

    validator = HTMLSemanticValidator()
    validation_errors = validator.validate(html_content)

    print("\n----------------------------------------------------------------------")
    print(" LPI 030-100 Topic 2.2 -- HTML Semantic & DOM Hierarchy Audit Report")
    print(" Target File: " + filepath)
    print("----------------------------------------------------------------------")

    if not validation_errors:
        print("\n[SUCCESS] 0 Violations Found. The HTML document complies with HTML5 Semantic Standards, WCAG 2.1 AA Landmarks, and Document Hierarchy rules!\n")
        sys.exit(0)
    else:
        print(f"\n[FAIL] Detected {len(validation_errors)} Semantic & Document Hierarchy Violations:\n")
        for idx, err in enumerate(validation_errors, 1):
            print(f" {idx}. {err}")
        print("\nPipeline Result: BUILD FAILED\n")
        sys.exit(1)
EOF

# ------------------------------------------------------------------------------
# 3. Create Execution Helper Script for the Student
# ------------------------------------------------------------------------------
cat << 'EOF' > "${LAB_DIR}/validate.sh"
#!/usr/bin/env bash
python3 /opt/lpi-lab-topic2.2/validate.py /opt/lpi-lab-topic2.2/index.html
EOF

chmod +x "${LAB_DIR}/validate.sh"

# ------------------------------------------------------------------------------
# 4. Display Scenario Overview and Diagnostic Instructions to Student
# ------------------------------------------------------------------------------
cat << 'EOF'

==============================================================================
 [!] BREAK-AND-FIX SCENARIO INSTANTIATED
==============================================================================
 Target File: /opt/lpi-lab-topic2.2/index.html
 Validator:   /opt/lpi-lab-topic2.2/validate.sh

 SYMPTOMS OBSERVED IN PRODUCTION:
 --------------------------------
 Your team's automated web deployment pipeline has rejected the release of the
 CloudOps Monitoring Portal. The CI/CD stage 'accessibility-dom-audit' failed
 due to strict compliance checks against LPI 030-100 Topic 2.2 requirements.

 Screen readers (NVDA/JAWS), search engine crawlers, and HTML5 parsers cannot
 build an Accessibility Tree (a11y tree) or Document Outline from the artifact.

 YOUR GOAL:
 ----------
 1. Execute the validation suite:
    $ /opt/lpi-lab-topic2.2/validate.sh

 2. Inspect the failure log and edit '/opt/lpi-lab-topic2.2/index.html'.

 3. Refactor 'index.html' into a syntactically valid, production-grade HTML5
    document adhering to standard document structure and semantic rules:
    - Include proper standard HTML5 Document Type Declaration and Metadata.
    - Replace generic <div> soup with HTML5 structural landmarks (<header>, <nav>,
      <main>, <footer>).
    - Establish valid structural sectioning using <section>, <article>, and/or <aside>.
    - Fix the broken Heading Hierarchy outline (h1 -> h2 -> h3, without skipping levels).
    - Replace non-semantic formatting (<b>, <i>) with semantic emphasis (<strong>, <em>).
    - Wrap media items in <figure> with explicit <figcaption>.
    - Use machine-readable <time datetime="..."> tags for dates/timestamps.

 4. Re-run '/opt/lpi-lab-topic2.2/index.html' validation until you receive:
    "[SUCCESS] 0 Violations Found."

==============================================================================
EOF

# ==============================================================================
# DETAILED STEP-BY-STEP SOLUTION AND TECHNICAL ARCHITECTURAL EXPLANATION
# ==============================================================================
# (The content below is intentionally commented out for self-guided student practice)
#
# TECHNICAL BACKGROUND & ARCHITECTURAL MECHANICS:
# -----------------------------------------------
# 1. Document Structure & Rendering Modes:
#    - Without `<!DOCTYPE html>`, browsers enter "Quirks Mode", emulating legacy
#      bugs from Navigation/IE4 era. Standard HTML5 mode requires `<!DOCTYPE html>`
#      as the very first line of the document.
#    - `<meta charset="UTF-8">` prevents character encoding vulnerability attacks
#      (e.g., UTF-7 XSS exploits) and ensures deterministic DOM tokenization.
#
# 2. HTML5 Semantic Landmarks vs `<div>` Soup:
#    - `<header>`: Represents introductory content or navigational links for a section/page.
#    - `<nav>`: Explicitly signals major navigation blocks to assistive technologies.
#    - `<main>`: Represents the dominant, non-repeating content of the `<body>`.
#      Only ONE unhidden `<main>` element can exist per document.
#    - `<footer>`: Contains copyright information, author data, or related links.
#    - Trade-offs: `<div>` has zero semantic meaning. It forces screen reader users
#      to linearly parse thousands of nodes instead of jumping via ARIA landmark hotkeys.
#
# 3. Document Outline & Heading Hierarchy (WCAG 2.1 Success Criterion 1.3.1):
#    - The HTML Document Outline relies on logical heading progression (`<h1>` to `<h6>`).
#    - Skipping heading levels (e.g., `<h1>` directly to `<h4>`) breaks the semantic tree,
#      misleading search engine crawlers regarding section weight and causing screen
#      readers to misinterpret child container boundaries.
#
# 4. Text & Media Semantics:
#    - `<b>` and `<i>` are purely typographic/visual.
#    - `<strong>` signals semantic importance/urgency; `<em>` signals stress emphasis.
#    - `<figure>` packages self-contained media (diagrams, photos, code snippets).
#    - `<figcaption>` provides an explicit accessibility caption bound directly to the figure.
#    - `<time datetime="YYYY-MM-DDThh:mm:ssZ">` translates human text into machine-parsable
#      ISO timestamps for search engines and calendar agents.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP REPAIR PROCEDURES:
# ------------------------------------------------------------------------------
# Step 1: Execute the validator script to view the initial failure report.
#   $ /opt/lpi-lab-topic2.2/validate.sh
#
# Expected output:
#   [FAIL] Detected 8 Semantic & Document Hierarchy Violations:
#    1. [CRITICAL] Missing HTML5 DOCTYPE declaration (<!DOCTYPE html>).
#    2. [HIGH] Missing <meta charset="UTF-8"> inside <head>...
#    3. [HIGH] Missing structural HTML5 landmarks: <header>, <nav>, <main>, <footer>...
#    4. [MEDIUM] Missing HTML5 sectioning elements (<article>, <section>, or <aside>)...
#    5. [HIGH] Invalid Heading Hierarchy: <h1> followed by <h4>...
#    6. [MEDIUM] Non-semantic text formatting tags present (<b> or <i>)...
#    7. [MEDIUM] Standalone image found without semantic wrapper...
#    8. [LOW] Temporal data present without machine-readable <time> element...
#
# Step 2: Open '/opt/lpi-lab-topic2.2/index.html' in your preferred editor:
#   $ nano /opt/lpi-lab-topic2.2/index.html
#
# Step 3: Replace the entire contents of index.html with the syntactically valid solution:
#
# ------------------------------------------------------------------------------
# FULLY SYNTACTICALLY VALID RESOLVED MANIFEST:
# ------------------------------------------------------------------------------
# <!DOCTYPE html>
# <html lang="en">
# <head>
#     <meta charset="UTF-8">
#     <meta name="viewport" content="width=device-width, initial-scale=1.0">
#     <title>Enterprise Cloud Infrastructure Dashboard</title>
# </head>
# <body>
#     <header>
#         <div class="logo">CloudOps Portal</div>
#         <nav aria-label="Main Navigation">
#             <a href="/clusters">Clusters</a> | 
#             <a href="/metrics">Metrics</a> | 
#             <a href="/alerts">Alerts</a>
#         </nav>
#     </header>
# 
#     <main>
#         <header>
#             <h1>Cloud Cluster Health Summary</h1>
#             <p>Current operational status for global Kubernetes regions.</p>
#         </header>
# 
#         <section>
#             <h2>Active Incident Overview</h2>
#             <p>Region us-east-1 is experiencing degraded API latency.</p>
#             <p>Incident logged on: <time datetime="2026-08-07T01:15:00Z">2026-08-07 01:15 UTC</time></p>
#         </section>
# 
#         <article>
#             <h2>Infrastructure Node Topology</h2>
#             <p>Node <strong>k8s-worker-01</strong> status is <em>Ready</em>.</p>
#             <figure>
#                 <img src="topology.png" alt="Kubernetes Node Connectivity Diagram">
#                 <figcaption>Figure 1.1: Active Worker Node Topology and Mesh State.</figcaption>
#             </figure>
#         </article>
#     </main>
# 
#     <footer>
#         <p>&copy; 2026 CloudOps Platform Team. All rights reserved.</p>
#     </footer>
# </body>
# </html>
# ------------------------------------------------------------------------------
#
# Step 4: Re-run the validation script to verify resolution:
#   $ /opt/lpi-lab-topic2.2/validate.sh
#
# Expected output:
#   ----------------------------------------------------------------------
#    LPI 030-100 Topic 2.2 -- HTML Semantic & DOM Hierarchy Audit Report
#    Target File: /opt/lpi-lab-topic2.2/index.html
#   ----------------------------------------------------------------------
#   
#   [SUCCESS] 0 Violations Found. The HTML document complies with HTML5 Semantic Standards, WCAG 2.1 AA Landmarks, and Document Hierarchy rules!
# ==============================================================================