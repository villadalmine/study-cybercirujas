# LPI Web Development Essentials (Exam 030-100, v1.0)
## Topic 3.2: CSS Selectors and Style Application (Weight: 7.5)

### Official References & Specifications
* [LPI Web Development Essentials Objective 033.2](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* [W3C CSS Selectors Level 4 Specification](https://www.w3.org/TR/selectors-4/)
* [W3C CSS Cascading and Inheritance Level 4](https://www.w3.org/TR/css-cascade-4/)
* [MDN Web Docs: CSS Specificity](https://developer.mozilla.org/en-US/docs/Web/CSS/Specificity)

---

### Architectural & Internal Engine Mechanics

#### 1. CSSOM Construction & Right-to-Left Selector Matching
During browser rendering, the Layout Engine (e.g., Blink, Gecko) parses CSS rules into the **CSS Object Model (CSSOM)**. When evaluating DOM nodes against CSS rules, browser engine selector matchers evaluate compound selectors **from right to left** (key selector first).
* **Key Selector**: The rightmost selector part (e.g., in `div.nav-wrapper ul > li.active a`, `a` is the key selector).
* **Execution Flow**: The engine filters candidates based on `a`, then traverses parent/ancestor chains upward. This minimizes DOM subtree traversals. Using overly generic key selectors (e.g., `*` or `div`) across deep DOMs increases evaluation overhead during style recalculation passes (Recalculate Style phase).

#### 2. Specificity Vector Matrix
CSS Specificity is calculated as a 3-component vector `(a, b, c)` (often conceptualized as `(ID, Class/Attribute/Pseudo-class, Element/Pseudo-element)`):
* **Component `a` (ID Selectors)**: Matches by `#id` attribute (e.g., `#header`). Value = `1,0,0`.
* **Component `b` (Class, Attribute, Pseudo-class Selectors)**: Includes `.class`, `[attr=val]`, `:hover`, `:nth-child()`, `:first-child`. Value = `0,1,0`.
* **Component `c` (Type Selectors & Pseudo-elements)**: Includes `div`, `h1`, `p`, `::before`, `::after`. Value = `0,0,1`.
* **Inline Styles**: Applied directly via `style=""` attributes in HTML, overriding stylesheet rules regardless of specificity (conceptually slot `1,0,0,0`).
* **Universal Selector (`*`) & Combinators (`>`, `+`, `~`, ` `)**: Add `(0,0,0)` specificity.
* **Functional Pseudo-classes**:
  * `:not()`, `:is()`, `:has()` take the specificity of their most specific argument inside the argument list.
  * `:where()` forces specificity to `(0,0,0)` regardless of its argument content.

#### 3. The CSS Cascade Algorithm
When multiple conflicting rules match a single DOM node, the cascade resolves property values according to the following order of precedence (highest to lowest):
1. **Origin & Importance**: `User Agent !important` > `User !important` > `Author !important` > `Author Normal` > `User Normal` > `User Agent Normal`.
2. **Context**: Transition / Animation overrides.
3. **Specificity**: Higher `(a, b, c)` vector wins.
4. **Order of Appearance**: Last declared rule in source order wins if specificity vectors are equal.

#### 4. Property Inheritance Mechanics
Properties are categorized as **inherited** (e.g., `color`, `font-family`, `line-height`, `visibility`) or **non-inherited** (e.g., `margin`, `padding`, `border`, `background`, `display`).
* Explicit control keywords:
  * `inherit`: Forces a property to take the computed value of its parent node.
  * `initial`: Resets property to the CSS specification's default value.
  * `unset`: Acts as `inherit` if property is inherited naturally, otherwise acts as `initial`.
  * `revert`: Rolls back the cascaded value to the user agent or user origin stylesheet defaults.

---

### Hands-On Guided Exercises

#### Exercise 1: Structural Selectors, Combinators, and CSSOM Evaluation

In this exercise, you will create a production status dashboard HTML structure and test exact target selection using descendant, direct child, adjacent sibling, and general sibling combinators.

##### Step 1.1: Create the HTML Workbench
Run the following shell command in your workspace directory to generate `dashboard.html`:

```bash
cat << 'EOF' > dashboard.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Production Monitoring Dashboard</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <header id="main-header" class="site-header">
        <h1 class="title">Cluster Health Overview</h1>
    </header>
    <main id="app-content">
        <section class="metric-card alert-critical" id="nodes-card">
            <h2 class="card-title">Node Group Alpha</h2>
            <p class="status-text">Status: Degraded</p>

            <div class="node-list">
                <div class="node-item primary">node-01 (Master)</div>
                <div class="node-item standby">node-02 (Worker)</div>
                <div class="node-item standby">node-03 (Worker)</div>
            </div>
            
            <span class="footnote">Telemetry interval: 500ms</span>
            <p class="description">Requires immediate failover inspection.</p>
        </section>
    </main>
</body>
</html>
EOF
```

##### Step 1.2: Construct the Style Sheet
Create `styles.css` using the following snippet:

```bash
cat << 'EOF' > styles.css
/* Rule 1: Universal reset */
* {
    box-sizing: border-box;
}

/* Rule 2: Descendant combinator */
main div {
    font-family: monospace;
}

/* Rule 3: Child combinator */
section.metric-card > p {
    color: #b91c1c;
}

/* Rule 4: Adjacent Sibling combinator */
div.node-item.primary + div.node-item {
    border-left: 4px solid #f59e0b;
}

/* Rule 5: General Sibling combinator */
div.node-item.primary ~ div.node-item {
    background-color: #fef3c7;
}

/* Rule 6: Attribute presence selector */
[class*="alert-"] {
    padding: 1rem;
    border: 1px solid #dc2626;
}
EOF
```

##### Step 1.3: Diagnose Matching Elements using Node.js DOM Parser CLI
To programmatically inspect CSS selector matches as evaluated by browser engines in CI/CD automated linting pipelines, execute the following script:

```bash
node -e '
const fs = require("fs");
const { JSDOM } = require("jsdom");

const html = fs.readFileSync("dashboard.html", "utf-8");
const dom = new JSDOM(html);
const doc = dom.window.document;

function query(selector) {
    const nodes = doc.querySelectorAll(selector);
    console.log(`Selector: "${selector}" -> Matched (${nodes.length}):`);
    nodes.forEach(n => console.log(`  - <${n.tagName.toLowerCase()} class="${n.className}" id="${n.id}"> Text: "${n.textContent.trim().split("\n")[0]}"`));
}

query("section.metric-card > p");
query("div.node-item.primary + div.node-item");
query("div.node-item.primary ~ div.node-item");
'
```

##### Expected Output:
```text
Selector: "section.metric-card > p" -> Matched (2):
  - <p class="status-text" id=""> Text: "Status: Degraded"
  - <p class="description" id=""> Text: "Requires immediate failover inspection."
Selector: "div.node-item.primary + div.node-item" -> Matched (1):
  - <div class="node-item standby" id=""> Text: "node-02 (Worker)"
Selector: "div.node-item.primary ~ div.node-item" -> Matched (2):
  - <div class="node-item standby" id=""> Text: "node-02 (Worker)"
  - <div class="node-item standby" id=""> Text: "node-03 (Worker)"
```

---

##### Verification Questions — Exercise 1

1. **Question 1.1**: Why does `section.metric-card > p` match both `<p class="status-text">` and `<p class="description">`, but **not** any `<p>` tag that might be located inside `<div class="node-list">`? Explain the explicit distinction between the descendant (` `) and direct child (`>`) combinators.
2. **Question 1.2**: If the markup is altered so `<span class="badge">Active</span>` is placed directly between `node-01` and `node-02`, what is the exact effect on `div.node-item.primary + div.node-item` versus `div.node-item.primary ~ div.node-item`?

---

#### Exercise 2: Pseudo-Classes, State Management, and Structural Querying

In this exercise, you will apply pseudo-classes for state tracking (`:focus`, `:disabled`, `:checked`) and structural position matching (`:first-child`, `:last-of-type`, `:nth-child(even)`).

##### Step 2.1: Append Form & Component Controls to HTML
Update `dashboard.html` by adding an interactive node control panel:

```bash
cat << 'EOF' > dashboard.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Interactive Infrastructure Control</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <ul id="server-list">
        <li class="server-node">Server 01 - Online</li>
        <li class="server-node">Server 02 - Offline</li>
        <li class="server-node">Server 03 - Online</li>
        <li class="server-node">Server 04 - Maintenance</li>
        <li class="server-node">Server 05 - Online</li>
    </ul>

    <form id="control-panel">
        <input type="text" id="node-name" name="nodeName" placeholder="Enter node ID..." required>
        <button type="submit" class="btn btn-primary" disabled>Deploy Pod</button>
        <button type="reset" class="btn btn-secondary">Reset Form</button>
    </form>
</body>
</html>
EOF
```

##### Step 2.2: Add Pseudo-Class Rules to Stylesheet
Append the following pseudo-class selectors to `styles.css`:

```bash
cat << 'EOF' >> styles.css

/* Structural Pseudo-classes */
#server-list > li:nth-child(odd) {
    background-color: #f3f4f6;
}

#server-list > li:first-child {
    font-weight: bold;
    border-top: 2px solid #1d4ed8;
}

#server-list > li:last-of-type {
    border-bottom: 2px solid #1d4ed8;
}

/* User Action & Form State Pseudo-classes */
input[type="text"]:focus {
    outline: 2px solid #2563eb;
    background-color: #eff6ff;
}

button:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}

/* Logical Combination Selectors */
:is(#server-list, #control-panel) {
    margin: 1.5rem 0;
    padding: 1rem;
}

:not(.btn-primary) {
    text-transform: lowercase;
}
EOF
```

##### Step 2.3: Execute CLI Audit for Pseudo-Class Selector Matching
Validate structural selector targeting using `jsdom` CLI script:

```bash
node -e '
const fs = require("fs");
const { JSDOM } = require("jsdom");

const html = fs.readFileSync("dashboard.html", "utf-8");
const dom = new JSDOM(html);
const doc = dom.window.document;

console.log("Odd items matched:");
doc.querySelectorAll("#server-list > li:nth-child(odd)")
   .forEach(el => console.log(" - " + el.textContent));

console.log("\nDisabled button matched:");
doc.querySelectorAll("button:disabled")
   .forEach(el => console.log(" - " + el.outerHTML));
'
```

##### Expected Output:
```text
Odd items matched:
 - Server 01 - Online
 - Server 03 - Online
 - Server 05 - Online

Disabled button matched:
 - <button type="submit" class="btn btn-primary" disabled="">Deploy Pod</button>
```

---

##### Verification Questions — Exercise 2

1. **Question 2.1**: What is the difference between `:nth-child(2)` and `:nth-of-type(2)` when matching nodes inside a parent element containing a mixed sequence of `<h1>`, `<p>`, `<div>`, and `<p>` tags?
2. **Question 2.2**: Calculate the specificity vector `(a, b, c)` of `:is(#server-list, #control-panel) button:disabled` vs `:where(#server-list, #control-panel) button:disabled`. Which rule overrides the other?

---

#### Exercise 3: Specificity Matrix, Cascade Resolution, and Inheritance Profiling

In this exercise, you will resolve style collision scenarios, analyze the impact of `!important`, inspect inherited versus non-inherited styles, and use CLI linting tools to audit selector specificity.

##### Step 3.1: Create Specificity Collision File
Create `cascade_test.html` and `cascade.css`:

```bash
cat << 'EOF' > cascade_test.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Specificity and Cascade Resolution</title>
    <link rel="stylesheet" href="cascade.css">
</head>
<body>
    <div id="wrapper" class="container">
        <ul class="nav-list" id="main-nav">
            <li class="nav-item active" id="home-item">
                <a href="#" class="nav-link" style="color: purple;">Dashboard Home</a>
            </li>
        </ul>
    </div>
</body>
</html>
EOF
```

Create `cascade.css`:

```bash
cat << 'EOF' > cascade.css
/* Rule A: Specificity (0, 0, 1) */
a {
    color: black;
    font-size: 14px;
    border: 1px solid black;
}

/* Rule B: Specificity (0, 1, 1) */
ul.nav-list a {
    color: blue;
}

/* Rule C: Specificity (0, 2, 1) */
.container .nav-item .nav-link {
    color: green;
}

/* Rule D: Specificity (1, 1, 1) */
#main-nav .nav-item a {
    color: orange;
}

/* Rule E: Specificity (2, 0, 1) */
#wrapper #home-item a {
    color: red;
}

/* Rule F: Important declaration */
.nav-link {
    color: yellow !important;
}
EOF
```

##### Step 3.2: Inspect Computed Styles via Node.js CLI Pipeline
Execute a headless computation of element style resolution to trace the winning specificity rule:

```bash
node -e '
const fs = require("fs");
const { JSDOM } = require("jsdom");

const html = fs.readFileSync("cascade_test.html", "utf-8");
const css = fs.readFileSync("cascade.css", "utf-8");

const dom = new JSDOM(html, { runScripts: "dangerously" });
const { document, window } = dom;

const styleEl = document.createElement("style");
styleEl.textContent = css;
document.head.appendChild(styleEl);

const anchor = document.querySelector("a.nav-link");
const computed = window.getComputedStyle(anchor);

console.log("Resolved color property:", computed.color);
console.log("Resolved border property:", computed.border);
'
```

##### Expected Output:
```text
Resolved color property: yellow
Resolved border property: 1px solid black
```

##### Step 3.3: Specificity Vector Calculation Audit Table
Analyze the computed vectors for each rule declared in `cascade.css`:

| Rule ID | Selector Target | Component `a` (IDs) | Component `b` (Classes/Attrs) | Component `c` (Elements) | Total Vector `(a,b,c)` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Rule A** | `a` | 0 | 0 | 1 | `(0, 0, 1)` |
| **Rule B** | `ul.nav-list a` | 0 | 1 | 2 | `(0, 1, 2)` |
| **Rule C** | `.container .nav-item .nav-link` | 0 | 3 | 0 | `(0, 3, 0)` |
| **Rule D** | `#main-nav .nav-item a` | 1 | 1 | 1 | `(1, 1, 1)` |
| **Rule E** | `#wrapper #home-item a` | 2 | 0 | 1 | `(2, 0, 1)` |
| **Rule F** | `.nav-link` (`!important`) | 0 | 1 | 0 | `(0, 1, 0)` + `!important` |
| **Inline** | `style="color: purple;"` | N/A | N/A | N/A | Inline Origin |

---

##### Verification Questions — Exercise 3

1. **Question 3.1**: If the `!important` flag is removed from Rule F (`.nav-link { color: yellow; }`), which rule dictates the final computed color of the `<a>` tag: the inline style `style="color: purple;"` or Rule E (`#wrapper #home-item a`)? Why?
2. **Question 3.2**: Explain why the `border` property declared in Rule A applies to the `<a>` tag, but is **not** inherited by any child element placed inside the `<a>` tag, whereas `font-size` is inherited by child elements unless explicitly overridden.

---

### Solutions and Technical Explanations

<details>
<summary><strong>Click to expand solutions for Exercise 1</strong></summary>

#### Solution 1.1
* **Direct Child Combinator (`>`)**: Selects elements that are direct immediate children of the specified parent element in the DOM tree hierarchy. `section.metric-card > p` requires that `<p>` be directly attached under `<section class="metric-card">`.
* **Descendant Combinator (` ` space)**: Traverses down any number of DOM nesting levels. If the selector had been `section.metric-card p`, it would match both direct children `<p>` elements and any `<p>` elements nested deeper inside child elements (such as `<div class="node-list">`).

#### Solution 1.2
* **Adjacent Sibling Combinator (`+`)**: Matches an element only if it **immediately follows** the former element at the same DOM hierarchical level. If `<span class="badge">` is inserted between `node-01` and `node-02`, `div.node-item.primary + div.node-item` will match **0 elements**, because the element immediately following `node-01` is a `<span>`, not a `div.node-item`.
* **General Sibling Combinator (`~`)**: Matches all elements following the former element at the same DOM level, regardless of intermediate non-matching elements. `div.node-item.primary ~ div.node-item` will still match both `node-02` and `node-03`.

</details>

<details>
<summary><strong>Click to expand solutions for Exercise 2</strong></summary>

#### Solution 2.1
* **`:nth-child(n)`**: Evaluates position relative to **all sibling elements** inside the parent, regardless of tag name. If the second child of a parent is an `<h1>`, `p:nth-child(2)` will fail to match if the element at index 2 is not a `<p>`.
* **`:nth-of-type(n)`**: Filters the sibling list to include **only elements of the matching element type (tag name)** before applying index counting. `p:nth-of-type(2)` matches the second `<p>` tag under the parent container, ignoring any non-`<p>` siblings.

#### Solution 2.2
* **Specificity of `:is(#server-list, #control-panel) button:disabled`**:
  * `:is()` takes the specificity of its **most specific selector argument**.
  * `#server-list` and `#control-panel` each have specificity `(1, 0, 0)`.
  * `button` adds `(0, 0, 1)`.
  * `:disabled` adds `(0, 1, 0)`.
  * **Total Specificity**: `(1, 0, 0) + (0, 0, 1) + (0, 1, 0) = (1, 1, 1)`.

* **Specificity of `:where(#server-list, #control-panel) button:disabled`**:
  * `:where()` always contributes `(0, 0, 0)` specificity, replacing its argument specificity with zero.
  * `button` adds `(0, 0, 1)`.
  * `:disabled` adds `(0, 1, 0)`.
  * **Total Specificity**: `(0, 0, 0) + (0, 0, 1) + (0, 1, 0) = (0, 1, 1)`.

* **Resolution**: The `:is()` rule wins over the `:where()` rule because `(1, 1, 1)` strictly overrides `(0, 1, 1)`.

</details>

<details>
<summary><strong>Click to expand solutions for Exercise 3</strong></summary>

#### Solution 3.1
* If `!important` is removed from Rule F, the **inline style** `style="color: purple;"` wins.
* **Cascade Precedence Engine Order**:
  1. Author `!important` declarations override normal author styles and inline styles.
  2. Inline styles specified via the HTML `style` attribute override normal stylesheet declarations regardless of selector specificity (inline styles override `(2, 0, 1)` of Rule E).
  3. Author stylesheet normal declarations are evaluated by specificity vector `(a, b, c)`.
  4. Order of appearance resolves ties.
* Thus, removing `!important` drops Rule F back down to `(0, 1, 0)` author normal status, allowing the inline style origin to prevail.

#### Solution 3.2
* **Inherited Properties**: Properties related to typography and text presentation (`font-size`, `font-family`, `color`, `line-height`) automatically propagate down the DOM tree to child elements via inheritance mechanics, unless the child has explicit rules overriding them.
* **Non-inherited Properties**: Properties governing box model, layout geometry, borders, and backgrounds (`border`, `margin`, `padding`, `display`, `width`, `height`) apply strictly to the matched element node and do **not** automatically pass to child nodes, preventing accidental visual breakage of child layout boxes.

</details>