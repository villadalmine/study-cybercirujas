# LPI Web Development Essentials (Exam 030-100, v1.0)
## Topic 2.2: HTML Semantics and Document Hierarchy (Weight: 5)

---

### Technical Architecture & Deep Dive: DOM & Accessibility Tree Construction

Modern web rendering engines (e.g., Blink, Gecko) convert raw HTML binary streams into two primary hierarchical structures:
1. **Document Object Model (DOM) Tree**: Represents the structural and programmatic layout of the document.
2. **Accessibility Tree (Accessibility Object Model / AOM)**: Derived directly from the DOM tree, exposing roles, states, and properties to assistive technologies (screen readers like NVDA, VoiceOver, JAWS) and web crawlers (SEO indexers).

```
                 HTML Source Stream
                         │
                         ▼
                  Tokenizer & Parser
                         │
                         ▼
                     DOM Tree
                  ┌────────────┐
                  │   <html>   │
                  └─────┬──────┘
                        │
                ┌───────┴───────┐
                ▼               ▼
             <head>          <body>
                                │
                        ┌───────┴───────┐
                        ▼               ▼
                     <header>        <main>
                        │               │
                     ┌──┴──┐         ┌──┴──┐
                     ▼     ▼         ▼     ▼
                   <h1>  <nav>   <article> <aside>
                         │
                         ▼
                   Accessibility Tree (AOM)
                ┌─────────────────────────┐
                │ Role: banner (<header>) │
                │ Role: navigation (<nav>)│
                │ Role: main (<main>)     │
                │ Role: article (<article>)
                │ Role: complementary     │
                └─────────────────────────┘
```

#### Structural Mechanics & Semantic Elements
- **Document Structure**: `<!DOCTYPE html>` triggers standard standards-mode parsing (preventing quirks mode). `<html>` serves as the root element, with `lang` providing language context for screen reader phonetics and search engine indexing.
- **Landmark Elements**:
  - `<header>`: Maps to `role="banner"` when scoped to `<body>`. Represents global page branding or top-level navigation.
  - `<nav>`: Maps to `role="navigation"`. Used for primary, secondary, or pagination link clusters.
  - `<main>`: Maps to `role="main"`. Must be unique per rendered document view (contains core content).
  - `<article>`: Maps to `role="article"`. Represents self-contained, independently distributable content (e.g., blog post, news story, forum comment).
  - `<section>`: Generic sectioning element. Creates a logical grouping of content, ideally with a heading (`<h1>`-`<h6>`). Maps to `role="region"` only when explicitly given an accessible name (`aria-labelledby` or `aria-label`).
  - `<aside>`: Maps to `role="complementary"`. Holds secondary content related to main context (e.g., sidebars, callout boxes, related articles).
  - `<footer>`: Maps to `role="contentinfo"` when scoped to `<body>`. Contains metadata, copyright, privacy links, and contact info.
  - `<figure>` & `<figcaption>`: Encapsulates media, code listings, or diagrams with an explicit label. Maps to `role="figure"`.
- **Non-Semantic Wrappers**:
  - `<div>`: Generic block-level flow container with no semantic meaning (`role="generic"`).
  - `<span>`: Generic inline flow container with no semantic meaning.

---

### Guided Exercise 1: Constructing a Production-Grade HTML5 Document Hierarchy & Validating Accessibility Landmarks

#### Objective
Build a fully semantic, standards-compliant HTML5 document and inspect its DOM and landmark roles using CLI tools.

#### Environment Setup & Execution Steps

1. Create a project directory and generate `index.html` using a single multi-line `cat` command:

```bash
mkdir -p ~/html-semantics-lab && cd ~/html-semantics-lab

cat << 'EOF' > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Production-ready semantic HTML5 structure demonstration.">
    <title>SRE Incident Portal | Platform Engineering</title>
</head>
<body>
    <header>
        <h1>Platform SRE Observability</h1>
        <nav aria-label="Primary Navigation">
            <ul>
                <li><a href="#dashboard">Dashboard</a></li>
                <li><a href="#incidents">Incidents</a></li>
                <li><a href="#metrics">Metrics</a></li>
            </ul>
        </nav>
    </header>

    <main>
        <article>
            <header>
                <h2>Incident Post-Mortem: INC-84920</h2>
                <p>Published: <time datetime="2026-08-07T00:00:00Z">August 7, 2026</time></p>
            </header>
            <section>
                <h3>Executive Summary</h3>
                <p>Database connection pool exhaustion caused cascading 503 errors in upstream microservices.</p>
            </section>
            <section>
                <h3>Root Cause Analysis</h3>
                <p>A missing index combined with an unthrottled analytics query locked primary DB connection slots.</p>
            </section>
        </article>

        <aside>
            <h2>System Health Status</h2>
            <p>All core API gateways operating within normal latencies (&lt; 45ms p99).</p>
        </aside>
    </main>

    <footer>
        <p>&copy; 2026 Platform Engineering SRE Team. All rights reserved.</p>
    </footer>
</body>
</html>
EOF
```

2. Validate W3C HTML5 compliance using `npx html-validate` or Python-based validation tooling:

```bash
npx --yes html-validate index.html
```

*Expected CLI Output:*
```text
index.html: clean (0 errors, 0 warnings)
```

3. Parse and extract landmark elements using `node` and `jsdom` to verify the DOM tree layout:

```bash
node -e '
const fs = require("fs");
const jsdom = require("jsdom");
const { JSDOM } = jsdom;

const html = fs.readFileSync("index.html", "utf8");
const dom = new JSDOM(html);
const doc = dom.window.document;

console.log("Root Language:", doc.documentElement.lang);
console.log("Document Title:", doc.title);

const landmarks = ["header", "nav", "main", "article", "section", "aside", "footer"];
landmarks.forEach(tag => {
    const elems = doc.querySelectorAll(tag);
    console.log(`Tag <${tag}> count: ${elems.length}`);
});
'
```

*Expected CLI Output:*
```text
Root Language: en
Document Title: SRE Incident Portal | Platform Engineering
Tag <header> count: 2
Tag <nav> count: 1
Tag <main> count: 1
Tag <article> count: 1
Tag <section> count: 2
Tag <aside> count: 1
Tag <footer> count: 1
```

---

#### Verification Questions: Exercise 1

1. In the document generated above, there are two `<header>` tags present. Does having multiple `<header>` elements violate HTML5 semantics or accessibility standards? Explain the contextual scope differences.
2. Why is it vital to include `aria-label="Primary Navigation"` on the `<nav>` element when multiple navigation regions might exist on a enterprise-scale web application?

---

### Guided Exercise 2: Heading Hierarchy, DOM Outline, and Semantic vs. Non-Semantic (`div`/`span`) Structuring

#### Objective
Understand heading levels (`<h1>`-`<h6>`), avoid heading level skipping, and compare a generic `div`-soup layout with a semantic DOM hierarchy for screen reader parsing.

#### Execution Steps

1. Create a script named `validate_outline.js` to inspect heading level continuity and hierarchy:

```bash
cat << 'EOF' > validate_outline.js
const fs = require("fs");
const jsdom = require("jsdom");
const { JSDOM } = jsdom;

function analyzeHeadings(filePath) {
    const html = fs.readFileSync(filePath, "utf8");
    const dom = new JSDOM(html);
    const doc = dom.window.document;
    const headings = Array.from(doc.querySelectorAll("h1, h2, h3, h4, h5, h6"));

    console.log(`=== Heading Audit for ${filePath} ===`);
    let lastLevel = 0;
    let issues = 0;

    headings.forEach((h, index) => {
        const currentLevel = parseInt(h.tagName.substring(1), 10);
        const text = h.textContent.trim();
        let status = "OK";

        if (index === 0 && currentLevel !== 1) {
            status = "WARNING: Document does not start with h1";
            issues++;
        } else if (currentLevel > lastLevel + 1 && lastLevel !== 0) {
            status = `ERROR: Skipped heading level from h${lastLevel} to h${currentLevel}`;
            issues++;
        }

        console.log(`[${h.tagName}] ${text} -> ${status}`);
        lastLevel = currentLevel;
    });

    console.log(`Total Issues Detected: ${issues}\n`);
}

analyzeHeadings("index.html");
EOF

node validate_outline.js
```

*Expected CLI Output:*
```text
=== Heading Audit for index.html ===
[H1] Platform SRE Observability -> OK
[H2] Incident Post-Mortem: INC-84920 -> OK
[H3] Executive Summary -> OK
[H3] Root Cause Analysis -> OK
[H2] System Health Status -> OK
Total Issues Detected: 0
```

2. Create a non-semantic counter-example `bad_practice.html` and run the audit against it:

```bash
cat << 'EOF' > bad_practice.html
<!DOCTYPE html>
<html>
<head><title>Bad Practice</title></head>
<body>
    <div class="header">
        <div class="title">System Dashboard</div>
    </div>
    <div class="content">
        <h4>System Metrics</h4>
        <p>CPU Utilization: 84%</p>
        <h6>Network I/O</h6>
        <p>Inbound: 1.2Gbps</p>
    </div>
</body>
</html>
EOF

node -e '
const { analyzeHeadings } = require("./validate_outline.js");
' || node -e '
const fs = require("fs");
const jsdom = require("jsdom");
const { JSDOM } = jsdom;
const html = fs.readFileSync("bad_practice.html", "utf8");
const dom = new JSDOM(html);
const doc = dom.window.document;
const headings = Array.from(doc.querySelectorAll("h1, h2, h3, h4, h5, h6"));
headings.forEach(h => console.log(h.tagName, ":", h.textContent));
'
```

*Expected CLI Output:*
```text
H4 : System Metrics
H6 : Network I/O
```

---

#### Verification Questions: Exercise 2

1. What is the impact on screen reader users (e.g., rotor navigation) when heading levels skip from `<h4>` directly to `<h6>` without an intervening `<h5>`?
2. A developer uses `<div class="button" onclick="submitForm()">Submit</div>` instead of `<button type="submit">Submit</button>`. What native HTML capabilities and accessibility features are lost by using `<div>`?

---

### Guided Exercise 3: Encapsulating Media with `<figure>` / `<figcaption>` & Sectioning Algorithms

#### Objective
Implement semantic media representation with `<figure>` and `<figcaption>`, use proper semantic text formatting elements (`<time>`, `<code>`, `<mark>`), and verify their semantic binding.

#### Execution Steps

1. Update `index.html` to include a code block and architectural diagram encapsulated within `<figure>` tags:

```bash
cat << 'EOF' > complex_semantic.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Kubernetes Cluster Metrics</title>
</head>
<body>
    <main>
        <article>
            <h1>Kubernetes Node Lifecycle Audit</h1>

            <section>
                <h2>Pod Eviction Analysis</h2>
                <p>When memory limits are reached, the <mark>kubelet</mark> initiates pod eviction.</p>

                <figure>
                    <pre><code>
kubectl get pods --all-namespaces \
  --field-selector=status.phase=Failed
                    </code></pre>
                    <figcaption>Listing 1.1: CLI command to locate failed and evicted pods across all namespaces.</figcaption>
                </figure>

                <figure>
                    <img src="cluster-architecture.svg" alt="Diagram showing API Server, Etcd, and Worker Node communication paths.">
                    <figcaption>Figure 1.2: High-level Kubernetes control plane architecture overview.</figcaption>
                </figure>
            </section>
        </article>
    </main>
</body>
</html>
EOF
```

2. Execute a Node.js verification script to validate that `<figcaption>` is correctly associated with its parent `<figure>`:

```bash
node -e '
const fs = require("fs");
const jsdom = require("jsdom");
const { JSDOM } = jsdom;

const html = fs.readFileSync("complex_semantic.html", "utf8");
const dom = new JSDOM(html);
const doc = dom.window.document;

const figures = doc.querySelectorAll("figure");
console.log(`Total <figure> elements found: ${figures.length}`);

figures.forEach((fig, index) => {
    const caption = fig.querySelector("figcaption");
    const hasImg = fig.querySelector("img") !== null;
    const hasCode = fig.querySelector("code") !== null;

    console.log(`Figure #${index + 1}:`);
    console.log(`  Contains Image: ${hasImg}`);
    console.log(`  Contains Code: ${hasCode}`);
    console.log(`  Caption Text: "${caption ? caption.textContent.trim() : "MISSING"}"`);
});
'
```

*Expected CLI Output:*
```text
Total <figure> elements found: 2
Figure #1:
  Contains Image: false
  Contains Code: true
  Caption Text: "Listing 1.1: CLI command to locate failed and evicted pods across all namespaces."
Figure #2:
  Contains Image: true
  Contains Code: false
  Caption Text: "Figure 1.2: High-level Kubernetes control plane architecture overview."
```

---

#### Verification Questions: Exercise 3

1. Can a `<figure>` element contain content other than graphics/images (e.g., code snippets, data tables, quotes)? What is the primary semantic rule governing `<figure>`?
2. Where inside a `<figure>` container can `<figcaption>` be legally positioned according to W3C HTML5 specifications?

---

<details>
<summary>Answers and Detailed Rationales</summary>

### Exercise 1 Answers

1. **Multiple `<header>` elements validity**:
   - **Answer**: Yes, having multiple `<header>` tags is **fully valid** in HTML5.
   - **Technical Rationale**: The semantic scope of `<header>` depends on its parent container:
     - When a child of `<body>`, `<header>` represents the global page header (implicitly `role="banner"`).
     - When inside sectioning elements such as `<article>` or `<section>`, `<header>` represents the header specific to that section/article. In this context, it does *not* map to `role="banner"`, avoiding conflicting top-level landmarks.

2. **Importance of `aria-label` on `<nav>`**:
   - **Answer**: It distinguishes multiple navigation landmarks for assistive technology users.
   - **Technical Rationale**: When a page contains multiple `<nav>` elements (e.g., main header navigation, sidebar table of contents, footer legal links), screen readers list all `role="navigation"` landmarks in a screen reader rotor menu. Without `aria-label` or `aria-labelledby`, screen readers announce each simply as "navigation", creating ambiguity. Labeling them ("Primary Navigation", "Footer Navigation") allows immediate identification.

---

### Exercise 2 Answers

1. **Impact of skipping heading levels (`<h4>` to `<h6>`)**:
   - **Answer**: It breaks logical document hierarchy, confuses screen reader navigation, and degrades accessibility compliance (WCAG 2.1 SC 1.3.1 Info and Relationships).
   - **Technical Rationale**: Screen reader users frequently navigate documents by jumping between heading levels (e.g., pressing `H` or number keys `1`-`6` in NVDA/JAWS). Skipping from `h4` to `h6` causes users to suspect content is missing or that they missed an `h5` parent section.

2. **Loss of features by using `<div class="button">` instead of `<button>`**:
   - **Answer**: Native keyboard focusability, default keyboard triggers, forms integration, accessibility tree roles, and state management are lost.
   - **Technical Rationale**:
     - **Keyboard Focus**: `<button>` is natively included in the sequential focus navigation order (`tabindex="0"`). A `<div>` is not focusable by default.
     - **Keyboard Event Handling**: `<button>` triggers `click` handlers on both `Enter` and `Space` key presses natively. A `<div>` requires custom `keydown`/`keyup` JavaScript handlers.
     - **Accessibility Tree**: `<button>` exposes `role="button"` to AOM automatically. A `<div>` exposes `role="generic"`, hiding its interactive purpose from screen readers unless explicitly patched with `role="button"` and `tabindex="0"`.

---

### Exercise 3 Answers

1. **Permissible content inside `<figure>`**:
   - **Answer**: Yes, `<figure>` can encapsulate code examples, math equations, audio clips, SVG diagrams, data tables, or block quotes.
   - **Technical Rationale**: The specification defines `<figure>` as self-contained content, optionally with a caption, that is referenced as a single unit from the main flow. The key requirement is that removing the `<figure>` to an appendix or another location does not affect the logical flow of the surrounding main text.

2. **Allowed position of `<figcaption>`**:
   - **Answer**: `<figcaption>` must be placed as either the **first child** or the **last child** inside the `<figure>` element.
   - **Technical Rationale**: W3C HTML specification prohibits placing `<figcaption>` in the middle of other child nodes within `<figure>`. It serves as either a header caption (first element) or a footer caption (last element) of the figure block.

</details>

---

### Official Reference Sources
- LPI Web Development Essentials Certification Overview: https://www.lpi.org/our-certifications/web-development-essentials-overview/
- HTML Living Standard - Document structures & Semantics: https://html.spec.whatwg.org/multipage/dom.html#elements-in-the-dom
- HTML Living Standard - Sections and Landmarks: https://html.spec.whatwg.org/multipage/sections.html
- W3C ARIA Authoring Practices Guide (Landmark Roles): https://www.w3.org/WAI/ARIA/apg/patterns/landmarks/