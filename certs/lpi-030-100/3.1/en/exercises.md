# LPI 030-100 Topic 3.1: CSS Basics — Production-Grade Architecture & Guided Exercises

**Exam Module:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Topic:** Topic 3.1 CSS Basics  
**Exam Weight:** 2.5  

---

## 1. Official References
* **LPI Web Development Essentials Overview:** [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* **W3C CSS Syntax Module Level 3:** [https://www.w3.org/TR/css-syntax-3/](https://www.w3.org/TR/css-syntax-3/)
* **W3C Cascading and Inheritance Level 4:** [https://www.w3.org/TR/css-cascade-4/](https://www.w3.org/TR/css-cascade-4/)
* **MDN Web Docs — CSS Specificity:** [https://developer.mozilla.org/en-US/docs/Web/CSS/Specificity](https://developer.mozilla.org/en-US/docs/Web/CSS/Specificity)

---

## 2. Architectural Overview & Engine Mechanics

### 2.1 Parsing Pipeline: DOM & CSSOM Construction
When a browser engine (e.g., Blink, Gecko) renders a web document, processing follows two parallel streams before composition:

```
HTML Stream ---> HTML Parser ---> Document Object Model (DOM) \
                                                               ===> Render Tree ---> Layout ---> Paint
CSS Stream  ---> CSS Parser  ---> CSS Object Model (CSSOM)   /
```

1. **Tokenization & Tree Construction:** The CSS parser receives raw bytes, decodes them (typically UTF-8), tokenizes input stream into tokens (`IDENT`, `AT-KEYWORD`, `DELIM`, `HASH`, `STRING`, `COLON`, `SEMICOLON`), and builds the **CSS Object Model (CSSOM)**.
2. **Render Tree Attachment:** The browser computes matching rules for each DOM element by evaluating the CSSOM against DOM nodes. Render Tree nodes contain visible visual metrics only (nodes with `display: none` are omitted from the Render Tree, whereas `visibility: hidden` nodes remain).
3. **Critical Rendering Path (CRP) Impact:** External stylesheets (`<link rel="stylesheet">`) are **render-blocking** by default. Until the CSSOM tree is fully constructed, the engine pauses DOM layout and painting to avoid repaint/reflow thrashing (Flash of Unstyled Content - FOUC).

### 2.2 The Cascade Engine Algorithm
Cascading determines the single winning value for a CSS property across multiple competing stylesheet rules. The resolution order occurs in strict sequential priority steps:

1. **Origin and Importance:**
   * Transition declarations (`transition`)
   * User Agent `!important`
   * User `!important`
   * Author `!important`
   * Animation declarations (`@keyframes`)
   * Author normal (`styles.css`, inline styles)
   * User normal (browser extensions/user stylesheets)
   * User Agent normal (default browser style sheets)
2. **Specificity Vector Comparison:** If origins and importance are equal, the rule with the highest specificity score wins.
3. **Order of Appearance:** If specificity vectors are identical, the rule declared **last** in the parsing order wins.

### 2.3 Specificity Calculation Vector `(a, b, c, d)`
Specificity is calculated as a 4-component tuple `(a, b, c, d)` comparing values left-to-right:

$$\text{Specificity} = (a,\, b,\, c,\, d)$$

* **Position $a$ (Inline Styles):** Presence of `style=""` attribute inside HTML elements ($a=1$).
* **Position $b$ (ID Selectors):** Count of `#id` selectors in the compound selector.
* **Position $c$ (Classes, Attributes, Pseudo-classes):** Count of `.class`, `[attr=val]`, and `:hover` / `:first-child` / `:nth-child()`. *(Note: `:not()`, `:is()`, and `:has()` do not add specificity themselves, but their argument selectors do. `:where()` always contributes `(0,0,0,0)`)*.
* **Position $d$ (Elements & Pseudo-elements):** Count of HTML tags (`div`, `p`, `h1`) and pseudo-elements (`::before`, `::after`).
* **Ignored:** Universal selector `*`, combinators (`+`, `>`, `~`, ` `), and inline pseudo-class wrappers like `:where()`.

---

## 3. Hands-on Guided Exercises

### Exercise 1: CSS Integration Strategies, Syntax Integrity, and CLI Linter Diagnostics

#### Scenario
You are deploying a web application assets pipeline. You need to establish valid CSS inclusion methods (Inline, Internal, and External) and validate your CSS syntax against production linting standards using automated CLI tooling.

#### Step 1.1: Create Project Structure
Execute the following commands in your terminal to set up the working workspace:

```bash
mkdir -p ~/lpi-css-lab/css ~/lpi-css-lab/config
cd ~/lpi-css-lab
```

#### Step 1.2: Construct the External Stylesheet
Create `css/styles.css` using your text editor or standard shell commands:

```css
/* css/styles.css - External Production Stylesheet */
@charset "UTF-8";

:root {
  --primary-color: #0d6efd;
  --text-dark: #212529;
}

body {
  margin: 0;
  padding: 0;
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  color: var(--text-dark);
}

.card-container {
  display: flex;
  padding: 1.5rem;
  background-color: #f8f9fa;
}

.card-title {
  color: var(--primary-color);
  font-size: 1.25rem;
  font-weight: 700;
}
```

#### Step 1.3: Construct the HTML Document
Create `index.html` referencing external CSS, an internal `<style>` block, and inline styles:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LPI 030-100 - Topic 3.1 CSS Basics</title>
  <!-- External CSS Inclusion -->
  <link rel="stylesheet" href="css/styles.css">
  
  <!-- Internal CSS Inclusion -->
  <style>
    .internal-banner {
      background-color: #e9ecef;
      border-left: 4px solid #0d6efd;
      padding: 1rem;
      margin: 1rem 0;
    }
  </style>
</head>
<body>

  <header class="internal-banner">
    <h1>Production Dashboard</h1>
  </header>

  <main class="card-container">
    <!-- Inline CSS Inclusion -->
    <article class="card-title" style="text-transform: uppercase; border-bottom: 2px solid #0d6efd;">
      Telemetry Overview
    </article>
  </main>

</body>
</html>
```

#### Step 1.4: Configure Automated StyleLint Validation
Create a minimal `package.json` and Stylelint configuration file to check CSS syntax integrity via CLI:

```bash
cat << 'EOF' > package.json
{
  "name": "lpi-css-lab",
  "version": "1.0.0",
  "private": true,
  "devDependencies": {
    "stylelint": "^16.2.0",
    "stylelint-config-standard": "^36.0.0"
  }
}
EOF

cat << 'EOF' > .stylelintrc.json
{
  "extends": "stylelint-config-standard"
}
EOF
```

#### Step 1.5: Execute Syntax & Style Validation via Node/NPM CLI
Install dependencies and run stylelint on the external CSS file:

```bash
npm install --silent
npx stylelint "css/styles.css"
```

*Expected Output:*
```text
(No output is returned when zero syntax errors or lint violation warnings exist. Return code is 0).
```

Verify exit code:
```bash
echo $?
```
*Expected Output:*
```text
0
```

#### Step 1.6: Validate Resource Loading via Local Web Server
Start a local HTTP server to verify header behavior and CSS loading:

```bash
npx http-server -p 8080 . &
SERVER_PID=$!
sleep 2
curl -I http://localhost:8080/css/styles.css
kill $SERVER_PID
```

*Expected Output:*
```http
HTTP/1.1 200 OK
Content-Type: text/css; charset=UTF-8
Content-Length: 377
...
```

---

### Verification Questions — Block 1

1. **What is the primary architectural drawback of using inline styles (`style="..."`) over external stylesheets (`<link rel="stylesheet">`) in production applications?**
   * A) Inline styles cause syntax parsing failures in strict HTML5 validators.
   * B) Inline styles break separation of concerns, cannot be cached independently by browsers, and duplicate payload across DOM nodes.
   * C) Inline styles cannot override rules defined in external CSS files.
   * D) Inline styles cause the browser to construct the CSSOM synchronously before building the DOM.

2. **Which HTML element and attribute combination correctly imports an external CSS stylesheet while indicating its role to the browser parser?**
   * A) `<script src="css/styles.css" type="text/css"></script>`
   * B) `<style href="css/styles.css" rel="stylesheet"></style>`
   * C) `<link rel="stylesheet" href="css/styles.css">`
   * D) `<import type="stylesheet" file="css/styles.css">`

---

### Exercise 2: Specificity Vector Calculation & Cascade Resolution in Production

#### Scenario
You encounter conflicting style declarations in a legacy CSS codebase. You need to calculate exact Specificity Vectors $(a, b, c, d)$, analyze order-of-appearance resolution, and refactor the rules deterministically without resorting to `!important`.

#### Step 2.1: Analyze the Conflicting Document Structure
Create `specificity-lab.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Specificity & Cascade Laboratory</title>
  <style>
    /* Rule 1 */
    p {
      color: black;
    }

    /* Rule 2 */
    .article-text {
      color: blue;
    }

    /* Rule 3 */
    #main-content p.article-text {
      color: green;
    }

    /* Rule 4 */
    div#main-content .article-text[data-priority="high"] {
      color: orange;
    }

    /* Rule 5 */
    div#main-content p {
      color: purple;
    }
  </style>
</head>
<body>
  <div id="main-content">
    <p id="target-paragraph" class="article-text" data-priority="high">
      Cascade Resolution Test Text
    </p>
  </div>
</body>
</html>
```

#### Step 2.2: Compute Specificity Scores Manually
Calculate the specificity vector $(a, b, c, d)$ for each rule matching `<p id="target-paragraph" class="article-text" data-priority="high">`:

* **Rule 1 (`p`):**
  * $a$ (inline): 0
  * $b$ (IDs): 0
  * $c$ (classes/attrs/pseudo-classes): 0
  * $d$ (elements): 1 (`p`)
  * **Vector:** `(0, 0, 0, 1)`

* **Rule 2 (`.article-text`):**
  * $a$: 0, $b$: 0, $c$: 1 (`.article-text`), $d$: 0
  * **Vector:** `(0, 0, 1, 0)`

* **Rule 3 (`#main-content p.article-text`):**
  * $a$: 0, $b$: 1 (`#main-content`), $c$: 1 (`.article-text`), $d$: 1 (`p`)
  * **Vector:** `(0, 1, 1, 1)`

* **Rule 4 (`div#main-content .article-text[data-priority="high"]`):**
  * $a$: 0, $b$: 1 (`#main-content`), $c$: 2 (`.article-text`, `[data-priority="high"]`), $d$: 1 (`div`)
  * **Vector:** `(0, 1, 2, 1)`

* **Rule 5 (`div#main-content p`):**
  * $a$: 0, $b$: 1 (`#main-content`), $c$: 0, $d$: 2 (`div`, `p`)
  * **Vector:** `(0, 1, 0, 2)`

#### Step 2.3: Determine the Winning Rule
Comparing vectors left to right:
1. $a$ component: All rules have $a = 0$.
2. $b$ component: Rules 3, 4, and 5 have $b = 1$ (higher than Rules 1 and 2 where $b = 0$).
3. $c$ component among remaining candidates (Rules 3, 4, 5):
   * Rule 3: $c = 1$
   * Rule 4: $c = 2$
   * Rule 5: $c = 0$
4. **Rule 4 wins** with `(0, 1, 2, 1)`. The text color rendered on screen will be **orange**.

#### Step 2.4: Validate Specificity Vector Math via Headless Node Execution
Write a quick node script to programmatically inspect selector specificity using an open-source parsing calculation simulation:

```bash
cat << 'EOF' > calculate-specificity.js
// Basic Specificity Calculator AST Simulation for verification
function calculateSpecificity(selector) {
  let a = 0, b = 0, c = 0, d = 0;
  
  // Count IDs
  const idMatches = selector.match(/#[a-zA-Z0-9_-]+/g);
  if (idMatches) b += idMatches.length;

  // Count Classes, Attributes, Pseudo-classes
  const classMatches = selector.match(/\.[a-zA-Z0-9_-]+/g);
  if (classMatches) c += classMatches.length;

  const attrMatches = selector.match(/\[[^\]]+\]/g);
  if (attrMatches) c += attrMatches.length;

  // Remove IDs, classes, attributes to avoid double counting elements
  let cleaned = selector.replace(/#[a-zA-Z0-9_-]+/g, '')
                        .replace(/\.[a-zA-Z0-9_-]+/g, '')
                        .replace(/\[[^\]]+\]/g, '')
                        .replace(/[*+>~]/g, ' ');
  
  const elementMatches = cleaned.trim().split(/\s+/).filter(token => token.length > 0);
  if (elementMatches.length > 0) d += elementMatches.length;

  return `(${a}, ${b}, ${c}, ${d})`;
}

const selectors = [
  "p",
  ".article-text",
  "#main-content p.article-text",
  "div#main-content .article-text[data-priority=\"high\"]",
  "div#main-content p"
];

selectors.forEach(sel => {
  console.log(`${sel.padEnd(55)} => ${calculateSpecificity(sel)}`);
});
EOF

node calculate-specificity.js
```

*Expected Output:*
```text
p                                                       => (0, 0, 0, 1)
.article-text                                           => (0, 0, 1, 0)
#main-content p.article-text                            => (0, 1, 1, 1)
div#main-content .article-text[data-priority="high"]    => (0, 1, 2, 1)
div#main-content p                                      => (0, 1, 0, 2)
```

---

### Verification Questions — Block 2

3. **Given two CSS rules matching the exact same element:**
   * Rule A: `body #wrapper ul.nav-list li a:hover`
   * Rule B: `html body div#wrapper header nav ul li a.active`
   **Which rule has higher specificity?**
   * A) Rule A with score `(0, 1, 2, 3)` beats Rule B with score `(0, 1, 1, 5)`.
   * B) Rule B with score `(0, 1, 1, 5)` beats Rule A because it has more element selectors.
   * C) Both rules tie with equal specificity.
   * D) Rule A with score `(0, 1, 3, 3)` beats Rule B with score `(0, 1, 1, 5)`.

4. **If Rule X has a specificity of `(0, 0, 2, 1)` and is declared on line 10 of `styles.css`, while Rule Y has a specificity of `(0, 0, 2, 1)` and is declared on line 45 of `styles.css`, which value will the browser engine apply?**
   * A) Rule X because earlier rules take precedence in DOM loading order.
   * B) Rule Y because when specificity is equal, order of appearance determines precedence (the last defined rule wins).
   * C) Neither; equal specificity generates a parse warning and styles are ignored.
   * D) The browser randomly chooses based on CSSOM tree traversal sequence.

---

### Exercise 3: Property Inheritance, Initial/Unset Keyword Mechanics, and DevTools Inspection

#### Scenario
Not all CSS properties inherit down the DOM tree automatically. You must configure inherited vs non-inherited properties, control cascade boundaries using explicit CSS keywords (`inherit`, `initial`, `unset`), and verify computed styling results.

#### Step 3.1: Create Inheritance Test Environment
Create `inheritance-lab.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Property Inheritance & Explicit Keyword Diagnostics</title>
  <style>
    /* Parent container establishing base properties */
    .parent-box {
      color: #0b5ed7;                  /* Inherited property */
      font-family: monospace;          /* Inherited property */
      border: 2px solid #212529;       /* Non-inherited property */
      padding: 20px;                   /* Non-inherited property */
      margin: 10px;                    /* Non-inherited property */
    }

    /* Child 1: Standard natural inheritance */
    .child-default {
      background-color: #e9ecef;
    }

    /* Child 2: Forcing non-inherited property to inherit */
    .child-forced-inherit {
      border: inherit;
      padding: inherit;
    }

    /* Child 3: Resetting inherited property to CSS Spec Initial value */
    .child-initial-reset {
      color: initial; /* Resets to browser default initial (typically black/canvas text) */
    }

    /* Child 4: Unset keyword behavior test */
    .child-unset {
      color: unset;  /* Acts as 'inherit' for inherited properties like color */
      border: unset; /* Acts as 'initial' (none) for non-inherited properties */
    }
  </style>
</head>
<body>

  <div class="parent-box">
    Parent Element Text (Monospace, Blue Text, Solid Dark Border)
    
    <div class="child-default">
      Child 1 (Default): Inherits color and font-family; does NOT inherit border/padding.
    </div>

    <div class="child-forced-inherit">
      Child 2 (Forced Inherit): Explicitly inherits parent's border and padding.
    </div>

    <div class="child-initial-reset">
      Child 3 (Initial Reset): Resets color property to initial value.
    </div>

    <div class="child-unset">
      Child 4 (Unset): Color unsets to inherit (blue), border unsets to initial (none).
    </div>
  </div>

</body>
</html>
```

#### Step 3.2: Programmatic Verification of Computed Values
Create a Node script using `jsdom` (or standard DOM engine emulation) to inspect final computed styles across inherited boundaries:

```bash
cat << 'EOF' > verify-computed.js
const fs = require('fs');
const { JSDOM } = require('jsdom');

const htmlContent = fs.readFileSync('inheritance-lab.html', 'utf-8');
const dom = new JSDOM(htmlContent, { runScripts: "dangerously" });
const window = dom.window;
const document = window.document;

// Helper to log element computed properties
function inspectElement(selector) {
  const el = document.querySelector(selector);
  const style = window.getComputedStyle(el);
  return {
    color: style.getPropertyValue('color'),
    fontFamily: style.getPropertyValue('font-family'),
    borderTopStyle: style.getPropertyValue('border-top-style'),
    paddingTop: style.getPropertyValue('padding-top')
  };
}

console.log("=== COMPUTED STYLE DIAGNOSTIC LOG ===");
console.log("Parent Box:           ", inspectElement('.parent-box'));
console.log("Child 1 (Default):    ", inspectElement('.child-default'));
console.log("Child 2 (Forced):     ", inspectElement('.child-forced-inherit'));
EOF

npm install jsdom --silent
node verify-computed.js
```

*Expected Output:*
```text
=== COMPUTED STYLE DIAGNOSTIC LOG ===
Parent Box:            { color: 'rgb(11, 94, 215)', fontFamily: 'monospace', borderTopStyle: 'solid', paddingTop: '20px' }
Child 1 (Default):     { color: 'rgb(11, 94, 215)', fontFamily: 'monospace', borderTopStyle: 'none', paddingTop: '0px' }
Child 2 (Forced):      { color: 'rgb(11, 94, 215)', fontFamily: 'monospace', borderTopStyle: 'solid', paddingTop: '20px' }
```

---

### Verification Questions — Block 3

5. **Which group consists exclusively of naturally INHERITED CSS properties?**
   * A) `margin`, `padding`, `border`, `background-color`
   * B) `color`, `font-family`, `line-height`, `text-align`
   * C) `width`, `height`, `display`, `position`
   * D) `top`, `flex-direction`, `opacity`, `overflow`

6. **What is the exact functional distinction between `initial` and `inherit` CSS keywords when applied to an element property?**
   * A) `initial` copies the value from the direct HTML parent element, while `inherit` resets the value to `#000000`.
   * B) `initial` resets the property to the value defined in the W3C spec default for that property, whereas `inherit` explicitly forces the property to take the computed value of its parent node.
   * C) `initial` forces the property to use the external CSS file definition, while `inherit` forces internal `<style>` rules.
   * D) There is no functional difference; both keywords behave identically in modern browsers.

---

## 4. Solutions & Answers

<details>
<summary><strong>Click to expand solutions for verification questions</strong></summary>

### Question 1
* **Correct Answer:** **B**
* **Detailed Explanation:** Inline styles duplicate CSS declarations inside individual HTML elements, violating the architectural principle of separation of concerns (HTML for structure, CSS for presentation). Because inline styles are embedded directly inside the HTML markup stream, browsers cannot cache them as separate static assets HTTP responses (unlike `.css` files served with long-lived `Cache-Control` headers). Furthermore, inline styles require manually editing every HTML element to make global style adjustments.
* **Why others are incorrect:** 
  * A is wrong because inline CSS is valid syntax in HTML5 when placed within the `style` attribute.
  * C is wrong because inline styles have a specificity vector position of $a=1$, which allows them to override normal external CSS selectors.
  * D is wrong because inline styles do not alter the sequence of DOM/CSSOM parser execution order.

---

### Question 2
* **Correct Answer:** **C**
* **Detailed Explanation:** The standard, syntactically valid method to include an external stylesheet in HTML5 is via the void tag `<link>` placed within the document `<head>`. It requires two main attributes: `rel="stylesheet"` (which defines the relationship between the HTML document and the linked resource) and `href="path/to/file.css"` (which specifies the URL location of the CSS file).
* **Why others are incorrect:** 
  * A incorrectly uses `<script>` (reserved for JavaScript execution).
  * B incorrectly uses `<style>` with an `href` attribute (the `<style>` tag is used exclusively for block-internal CSS declarations, not external file references).
  * D uses `<import>`, which is not a valid HTML element.

---

### Question 3
* **Correct Answer:** **A**
* **Detailed Explanation:** Let's calculate the specificity vector $(a, b, c, d)$ for both rules:
  * **Rule A (`body #wrapper ul.nav-list li a:hover`):**
    * $a$ (inline): `0`
    * $b$ (IDs): `1` (`#wrapper`)
    * $c$ (classes, attributes, pseudo-classes): `2` (`.nav-list`, `:hover`)
    * $d$ (elements): `4` (`body`, `ul`, `li`, `a`)
    * **Vector A:** `(0, 1, 2, 4)`
  * **Rule B (`html body div#wrapper header nav ul li a.active`):**
    * $a$ (inline): `0`
    * $b$ (IDs): `1` (`#wrapper`)
    * $c$ (classes, attributes, pseudo-classes): `1` (`.active`)
    * $d$ (elements): `7` (`html`, `body`, `div`, `header`, `nav`, `ul`, `li`, `a`)
    * **Vector B:** `(0, 1, 1, 7)`

  Comparing left to right: $a$ ties at `0`, $b$ ties at `1`. At position $c$, Rule A has `2` while Rule B has `1`. Because `2 > 1`, Rule A wins regardless of how many element selectors Rule B has in position $d$.

---

### Question 4
* **Correct Answer:** **B**
* **Detailed Explanation:** The CSS Cascade evaluation algorithm processes matching rules in a strict order:
  1. Origin and Importance
  2. Specificity
  3. Order of Appearance

  When two selectors matching the same element yield identical Specificity Vectors (in this case, both are `(0, 0, 2, 1)`), the tie is broken by the **Order of Appearance**. The rule defined later in the parsed style stream (line 45) overrides the rule defined earlier (line 10).

---

### Question 5
* **Correct Answer:** **B**
* **Detailed Explanation:** Textual and typographic CSS properties—such as `color`, `font-family`, `font-size`, `font-weight`, `line-height`, `text-align`, `letter-spacing`, and `visibility`—naturally inherit from parent DOM elements down to their children by default according to the CSS specification. Layout, box model, sizing, and positioning properties (`margin`, `padding`, `border`, `background-color`, `width`, `height`, `display`, `position`, `flex`, `grid`) are non-inherited.

---

### Question 6
* **Correct Answer:** **B**
* **Detailed Explanation:** 
  * `initial`: Sets the property value to the explicit default value defined in the W3C CSS specification for that specific property (e.g., `color` defaults to `black` or implementation-defined canvas text, `display` defaults to `inline`, `border-style` defaults to `none`).
  * `inherit`: Explicitly instructs the CSS engine to traverse up to the element's parent in the DOM tree and copy its computed value for that property, overriding default non-inheritance behaviors.

</details>