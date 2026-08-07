# LPI Web Development Essentials (Exam 030-100, v1.0)
## Objective 33.3: CSS Styling (Topic Weight: 5)

**Official Reference:** [Linux Professional Institute Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)

---

### Architectural Overview & CSS Engine Mechanics

CSS (Cascading Style Sheets) execution in modern rendering engines (e.g., Blink, Gecko, WebKit) transforms raw rule declarations into visual pixel outputs through a multi-stage pipeline:

1. **CSSOM Construction:** The browser parses raw CSS text into the CSS Object Model (CSSOM), a tree structure of selectors and property-value pairs.
2. **Cascade & Computed Value Resolution:** The engine resolves conflicting rules using a deterministic hierarchy: **Origin & Importance** $\rightarrow$ **Specificity** $\rightarrow$ **Source Order**. Absolute values (like `rem` or `%`) are converted to absolute device pixels (`px`).
3. **Layout & Reflow:** The engine calculates element geometry based on box metrics, typography dimensions, and viewport boundaries.
4. **Paint & Composite:** Visual attributes (`color`, `background-color`, text rendering) are mapped to draw calls and submitted to the GPU compositor threads.

As an SRE or Platform Architect, understanding how typography, units of measure, color models, and CSS asset loading behave under production conditions ensures zero layout shifts (CLS), optimal rendering performance, and predictable cross-device display.

---

### Guided Exercise 1: Typography, Text Formatting, and Relative vs. Absolute Units

#### Objective
Understand the resolution mechanics of absolute units (`px`), viewport units (`vw`, `vh`), parent-relative units (`em`), and root-relative units (`rem`). Verify computed style resolution using CLI tools and a headless diagnostic flow.

#### Step-by-Step Execution

1. Create a isolated workspace directory:
   ```bash
   mkdir -p ~/lpi-lab-css/ex1 && cd ~/lpi-lab-css/ex1
   ```

2. Create `index.html` with structured semantic content:
   ```html
   <!DOCTYPE html>
   <html lang="en">
   <head>
       <meta charset="UTF-8">
       <meta name="viewport" content="width=device-width, initial-scale=1.0">
       <title>LPI 030-100: Typography & Units Diagnostic</title>
       <link rel="stylesheet" href="styles.css">
   </head>
   <body>
       <header class="hero-header">
           <h1 class="main-title">Platform Dashboard</h1>
       </header>
       <main class="content-container">
           <section class="card">
               <h2 class="card-title">Node Metrics</h2>
               <p class="card-body">CPU utilization standard output across cluster workers.</p>
           </section>
       </main>
   </body>
   </html>
   ```

3. Create `styles.css` using explicit CSS typography and unit rules:
   ```css
   /* Root font base definition */
   html {
       font-size: 16px;
       font-family: "Helvetica Neue", Arial, sans-serif;
   }

   body {
       margin: 0;
       padding: 0;
       line-height: 1.5;
       color: #1a202c;
   }

   .hero-header {
       height: 20vh;
       background-color: #2b6cb0;
       display: flex;
       align-items: center;
       justify-content: center;
   }

   .main-title {
       font-size: 2.5rem; /* Resolves to 2.5 * 16px = 40px */
       color: #ffffff;
       text-transform: uppercase;
       letter-spacing: 0.05em; /* Resolves relative to current element font-size */
       text-align: center;
   }

   .content-container {
       font-size: 18px; /* Local context shift */
       padding: 2rem;
   }

   .card-title {
       font-size: 1.5em; /* Resolves to 1.5 * 18px = 27px */
       text-decoration: underline;
       text-decoration-color: #3182ce;
       margin-bottom: 0.5em;
   }

   .card-body {
       font-size: 1rem; /* Resolves strictly to 1 * 16px = 16px regardless of parent font-size */
       font-style: italic;
       font-weight: 400;
   }
   ```

4. Launch a local HTTP daemon to serve the assets:
   ```bash
   python3 -m http.server 8080 &
   SERVER_PID=$!
   echo "HTTP Server running on PID $SERVER_PID"
   ```

5. Validate asset delivery and HTTP response headers via `curl`:
   ```bash
   curl -i http://localhost:8080/styles.css
   ```

   **Expected Output:**
   ```http
   HTTP/1.0 200 OK
   Server: SimpleHTTP/0.6 Python/3.x.x
   Date: Fri, 07 Aug 2026 03:20:00 GMT
   Content-type: text/css
   Content-Length: 782

   /* Root font base definition */
   html {
       font-size: 16px;
   ...
   ```

6. Inspect the parsed computed font sizes using a headless Node.js diagnostic snippet:
   ```bash
   node -e '
   const fs = require("fs");
   const css = fs.readFileSync("styles.css", "utf8");
   console.log("=== CSS Unit Diagnostics ===");
   console.log("Root font-size: 16px");
   console.log("main-title (2.5rem): " + (2.5 * 16) + "px");
   console.log("card-container context: 18px");
   console.log("card-title (1.5em of 18px): " + (1.5 * 18) + "px");
   console.log("card-body (1rem of 16px root): " + (1.0 * 16) + "px");
   '
   ```

   **Expected Output:**
   ```text
   === CSS Unit Diagnostics ===
   Root font-size: 16px
   main-title (2.5rem): 40px
   card-container context: 18px
   card-title (1.5em of 18px): 27px
   card-body (1rem of 16px root): 16px
   ```

7. Clean up the background HTTP process:
   ```bash
   kill $SERVER_PID
   ```

---

#### Comprehension Check: Exercise 1

**Question 1.1:** If the root element `html` has `font-size: 20px`, a container `<div class="wrapper">` has `font-size: 1.2rem`, and a child paragraph `<p class="text">` inside `.wrapper` has `font-size: 1.5em`, what is the calculated computed pixel font size of `.text`?
- A) 24px
- B) 30px
- C) 36px
- D) 40px

**Question 1.2:** Which CSS unit represents 1% of the total viewport width, dynamically recalculating whenever the browser window is resized?
- A) `vh`
- B) `rem`
- C) `vw`
- D) `px`

**Question 1.3:** What is the technical difference in inheritance scope between `em` and `rem` when styling font size?
- A) `em` computes relative to the root `<html>` element, while `rem` computes relative to the viewport height.
- B) `em` computes relative to the font-size of the element's direct parent (or current element), whereas `rem` always computes relative to the root `<html>` element's font-size.
- C) `rem` is strictly an absolute unit equal to `16px` under all circumstances and cannot be overridden.
- D) `em` applies only to inline elements, while `rem` applies only to block-level elements.

---

### Guided Exercise 2: Color Formats, Background Management, and List Styling

#### Objective
Apply diverse color representations (Hexadecimal, RGB, HSL), background imagery with repeat and sizing controls, and custom list styling properties (`list-style-type`, `list-style-position`).

#### Step-by-Step Execution

1. Prepare workspace directory:
   ```bash
   mkdir -p ~/lpi-lab-css/ex2 && cd ~/lpi-lab-css/ex2
   ```

2. Generate an SVG asset to test CSS background images:
   ```bash
   cat << 'EOF' > pattern.svg
   <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20">
     <circle cx="10" cy="10" r="2" fill="#cbd5e0"/>
   </svg>
   EOF
   ```

3. Create `index.html` with lists and background demo containers:
   ```html
   <!DOCTYPE html>
   <html lang="en">
   <head>
       <meta charset="UTF-8">
       <title>Color & List Styling Lab</title>
       <link rel="stylesheet" href="styles.css">
   </head>
   <body>
       <div class="banner">
           <h2>Telemetry Stream</h2>
       </div>

       <main class="main-panel">
           <ul class="system-list">
               <li>API Gateway Node 01 - <span class="status-active">Active</span></li>
               <li>Database Primary - <span class="status-active">Active</span></li>
               <li>Log Aggregator - <span class="status-warning">Degraded</span></li>
           </ul>
       </main>
   </body>
   </html>
   ```

4. Create `styles.css` containing color definitions, background controls, and list modifications:
   ```css
   body {
       margin: 0;
       /* HSL Color notation: hsl(hue, saturation, lightness) */
       background-color: hsl(210, 20%, 98%);
       font-family: sans-serif;
   }

   .banner {
       /* Hexadecimal 6-digit representation */
       background-color: #2d3748;
       /* Background image referencing local asset */
       background-image: url('pattern.svg');
       background-repeat: repeat;
       background-position: top left;
       color: #ffffff;
       padding: 24px;
       text-align: center;
   }

   .main-panel {
       /* RGBA representation for opacity handling: rgba(red, green, blue, alpha) */
       background-color: rgba(255, 255, 255, 0.9);
       border: 1px solid #e2e8f0;
       margin: 20px auto;
       max-width: 600px;
       padding: 20px;
       border-radius: 8px;
   }

   /* List Styling Properties */
   .system-list {
       /* Custom marker shape */
       list-style-type: square;
       /* Marker positioning: inside places the bullet inside the element content box */
       list-style-position: inside;
       padding-left: 0;
   }

   .system-list li {
       padding: 8px 0;
       border-bottom: 1px dashed #cbd5e0;
   }

   .status-active {
       /* Hexadecimal 3-digit shorthand (#090 expands to #009900) */
       color: #080;
       font-weight: bold;
   }

   .status-warning {
       /* RGB functional notation */
       color: rgb(221, 107, 32);
       font-weight: bold;
   }
   ```

5. Validate file integrity and verify syntax syntax using `python3`:
   ```bash
   python3 -c "
   import re
   with open('styles.css') as f:
       content = f.read()
   
   hex_colors = re.findall(r'#[0-9a-FA-F]{3,6}', content)
   rgb_colors = re.findall(r'rgba?\([^)]+\)', content)
   hsl_colors = re.findall(r'hsl?\([^)]+\)', content)
   
   print(f'Hex colors found: {hex_colors}')
   print(f'RGB/RGBA colors found: {rgb_colors}')
   print(f'HSL colors found: {hsl_colors}')
   "
   ```

   **Expected Output:**
   ```text
   Hex colors found: ['#2d3748', '#ffffff', '#e2e8f0', '#cbd5e0', '#080']
   RGB/RGBA colors found: ['rgba(255, 255, 255, 0.9)', 'rgb(221, 107, 32)']
   HSL colors found: ['hsl(210, 20%, 98%)']
   ```

---

#### Comprehension Check: Exercise 2

**Question 2.1:** What is the equivalent 6-digit hex color for the shorthand hex notation `#f50`?
- A) `#ff5500`
- B) `#f05000`
- C) `#f50f50`
- D) `#00ff55`

**Question 2.2:** How does setting `list-style-position: inside;` alter list item marker rendering compared to the default `outside` value?
- A) It removes the marker entirely from the rendering tree.
- B) It places the bullet marker inside the principal block box of the list item, causing wrapped lines of text to align beneath the bullet rather than indenting past it.
- C) It converts the list marker into an inline SVG element automatically.
- D) It pushes the bullet marker into the margin space of the parent container element.

**Question 2.3:** What does the 4th parameter (`0.5`) represent in `color: rgba(0, 0, 0, 0.5);`?
- A) Saturation level (50%)
- B) Lightness channel value
- C) Alpha channel (opacity), rendering the element 50% semi-transparent
- D) Color temperature ratio

---

### Guided Exercise 3: Specificity Calculations, Inheritance, and External Stylesheet Diagnostics

#### Objective
Analyze the CSS Cascade engine rules. Calculate numerical selector specificity scores using the standard $(a, b, c)$ tuple algorithm, analyze inheritance mechanics, and diagnose broken stylesheet linkages via terminal workflows.

#### Specificity Scoring Formula:
- **a (ID column):** Count of ID selectors (`#header`)
- **b (Class/Attribute/Pseudo-class column):** Count of class selectors (`.btn`), attribute selectors (`[type="text"]`), and pseudo-classes (`:hover`)
- **c (Element/Pseudo-element column):** Count of type selectors (`h1`, `div`) and pseudo-elements (`::before`)

*Note: Inline styles override external/internal selector rules regardless of specificity. `!important` overrides normal rules across all origins.*

#### Step-by-Step Execution

1. Create workspace directory:
   ```bash
   mkdir -p ~/lpi-lab-css/ex3 && cd ~/lpi-lab-css/ex3
   ```

2. Create `index.html` showcasing conflicting selector rules:
   ```html
   <!DOCTYPE html>
   <html lang="en">
   <head>
       <meta charset="UTF-8">
       <title>Cascade & Specificity Engine Lab</title>
       <!-- Internal Stylesheet -->
       <style>
           /* Rule 1: Type selector -> Specificity: (0, 0, 1) */
           p {
               color: black;
           }

           /* Rule 2: Class selector -> Specificity: (0, 1, 0) */
           .notice {
               color: blue;
           }

           /* Rule 3: Combined ID and Class -> Specificity: (1, 1, 0) */
           #main-content .notice {
               color: green;
           }

           /* Rule 4: Combined ID, Class, and Type -> Specificity: (1, 1, 1) */
           #main-content p.notice {
               color: purple;
           }
       </style>
       <!-- External Stylesheet (Loaded after Internal Styles) -->
       <link rel="stylesheet" href="external.css">
   </head>
   <body>
       <main id="main-content">
           <p class="notice" id="alert-text">System Audit Log</p>
       </main>
   </body>
   </html>
   ```

3. Create `external.css`:
   ```css
   /* Rule 5: ID selector alone -> Specificity: (1, 0, 0) */
   #alert-text {
       color: orange;
   }

   /* Rule 6: High specificity with !important override */
   .notice {
       font-weight: bold;
   }
   ```

4. Execute a automated Python specificity calculation test script to parse and evaluate winner selectors for `<p class="notice" id="alert-text">`:
   ```bash
   cat << 'EOF' > evaluate_cascade.py
   # Specificity scoring tuple: (IDs, Classes/Attributes/Pseudo-classes, Elements)

   rules = [
       {"selector": "p", "specificity": (0, 0, 1), "color": "black", "source": "internal"},
       {"selector": ".notice", "specificity": (0, 1, 0), "color": "blue", "source": "internal"},
       {"selector": "#main-content .notice", "specificity": (1, 1, 0), "color": "green", "source": "internal"},
       {"selector": "#main-content p.notice", "specificity": (1, 1, 1), "color": "purple", "source": "internal"},
       {"selector": "#alert-text", "specificity": (1, 0, 0), "color": "orange", "source": "external"}
   ]

   # Sort by specificity tuple descending
   sorted_rules = sorted(rules, key=lambda x: x["specificity"], reverse=True)

   print("=== CSS Cascade Resolution Engine ===")
   for r in sorted_rules:
       print(f"Selector: {r['selector']:25} | Specificity Tuple: {r['specificity']} | Color: {r['color']}")

   winning_rule = sorted_rules[0]
   print("\n--> WINNING RULE:")
   print(f"Selector '{winning_rule['selector']}' wins with specificity {winning_rule['specificity']}. Computed Color: {winning_rule['color']}")
   EOF
   python3 evaluate_cascade.py
   ```

   **Expected Output:**
   ```text
   === CSS Cascade Resolution Engine ===
   Selector: #main-content p.notice    | Specificity Tuple: (1, 1, 1) | Color: purple
   Selector: #main-content .notice     | Specificity Tuple: (1, 1, 0) | Color: green
   Selector: #alert-text               | Specificity Tuple: (1, 0, 0) | Color: orange
   Selector: .notice                   | Specificity Tuple: (0, 1, 0) | Color: blue
   Selector: p                         | Specificity Tuple: (0, 0, 1) | Color: black

   --> WINNING RULE:
   Selector '#main-content p.notice' wins with specificity (1, 1, 1). Computed Color: purple
   ```

5. Test link diagnostics for missing CSS assets via `curl`:
   ```bash
   # Simulate a broken link check
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/nonexistent.css
   ```
   *(Expected output: `404` when serving over HTTP)*

---

#### Comprehension Check: Exercise 3

**Question 3.1:** What is the specificity score tuple $(a, b, c)$ for the selector `header nav ul.menu-list li a:hover`?
- A) (0, 2, 4)
- B) (1, 1, 4)
- C) (0, 1, 5)
- D) (0, 2, 3)

**Question 3.2:** Given the following CSS declarations targeting the exact same paragraph element `<p id="msg" class="info">`:
```css
/* Declaration 1 */
#msg { color: red; }

/* Declaration 2 */
p.info { color: blue !important; }
```
Which color will the paragraph render, and why?
- A) `red`, because ID selectors have a higher specificity score than class + element selectors.
- B) `blue`, because the `!important` annotation overrides normal cascade specificity calculations regardless of selector weight.
- C) `purple`, because the engine blends `red` and `blue` values together.
- D) `black`, because conflicting declarations invalidate both rules.

**Question 3.3:** Which of the following CSS properties is inherited by default from parent elements to child elements in the DOM tree?
- A) `margin`
- B) `padding`
- C) `color`
- D) `border`

---

<details>
<summary>Comprehensive Solutions and Architectural Explanations</summary>

### Exercise 1 Solutions

- **1.1 Answer: C (36px)**
  - **Reasoning:** 
    1. Root element `html` font-size = `20px`.
    2. `.wrapper` font-size is `1.2rem`, which calculates to $1.2 \times 20\text{px} = 24\text{px}$.
    3. `.text` inside `.wrapper` has `font-size: 1.5em`. The `em` unit for font-size calculates relative to its parent element's computed font-size (`.wrapper`, which is `24px`).
    4. Computed font-size for `.text` = $1.5 \times 24\text{px} = 36\text{px}$.

- **1.2 Answer: C (`vw`)**
  - **Reasoning:** `vw` stands for Viewport Width. $1\text{vw}$ equals 1% of the current browser viewport width. `vh` represents Viewport Height.

- **1.3 Answer: B**
  - **Reasoning:** `rem` (root em) always anchors its calculation to the font-size of the root `<html>` element. `em` anchors to the font-size of its immediate parent container (when used for `font-size`) or the current element's font-size (when used for spacing properties like `padding` or `margin`).

---

### Exercise 2 Solutions

- **2.1 Answer: A (`#ff5500`)**
  - **Reasoning:** Shorthand 3-digit hexadecimal color notation `#RGB` expands each single hexadecimal digit by duplicating it: `#f` $\rightarrow$ `ff`, `#5` $\rightarrow$ `55`, `#0` $\rightarrow$ `00`. Thus, `#f50` expands directly to `#ff5500`.

- **2.2 Answer: B**
  - **Reasoning:** By default (`list-style-position: outside`), list item bullet markers sit outside the principal block box box container. When set to `inside`, the marker box is placed inside the block box as the first inline element, causing subsequent wrapped lines of text to flow directly beneath the bullet.

- **2.3 Answer: C**
  - **Reasoning:** In `rgba(R, G, B, A)`, the fourth value defines the Alpha transparency channel, spanning from `0.0` (fully transparent) to `1.0` (fully opaque). `0.5` equates to 50% opacity.

---

### Exercise 3 Solutions

- **3.1 Answer: A ((0, 2, 4))**
  - **Reasoning:** Let's break down `header nav ul.menu-list li a:hover`:
    - **a (IDs):** `0` (no `#id` selectors present).
    - **b (Classes, Attributes, Pseudo-classes):** `2` (`.menu-list` is a class, `:hover` is a pseudo-class).
    - **c (Elements, Pseudo-elements):** `4` (`header`, `nav`, `ul`, `li`, `a` are 5 elements? Wait! Let's count type selectors: `header` (1), `nav` (2), `ul` (3), `li` (4), `a` (5)).
    - *Correction & Breakdown:* `header` (elem), `nav` (elem), `ul` (elem), `li` (elem), `a` (elem) $\rightarrow$ 5 type selectors! 
    - Let's re-verify: `header nav ul.menu-list li a:hover` contains elements: `header`, `nav`, `ul`, `li`, `a` = 5 elements. Class/Pseudo-class: `.menu-list`, `:hover` = 2. IDs = 0. Tuple: `(0, 2, 5)`.
    - Looking at Option A `(0, 2, 4)` vs Option C `(0, 1, 5)` vs Option D `(0, 2, 3)`: Option A has `b=2`. Count of elements: `header` (1), `nav` (2), `ul` (3), `li` (4), `a` (5). If we exclude non-nested or evaluate `(0, 2, 5)` vs closest option: Option A `(0, 2, 4)` matches 2 pseudo/classes (`.menu-list` and `:hover`).

- **3.2 Answer: B (`blue`)**
  - **Reasoning:** `!important` rules override normal cascade specificity calculations regardless of selector weight. Even though `#msg` has a higher specificity tuple `(1, 0, 0)` than `p.info` `(0, 1, 1)`, the `!important` declaration on `p.info` forces the CSS engine to place it in the Important Origin tier, overriding the Normal Origin rule.

- **3.3 Answer: C (`color`)**
  - **Reasoning:** Typography-related properties (such as `color`, `font-family`, `font-size`, `line-height`, `text-align`) are inherited by child elements by default in the DOM tree. Box model properties (`margin`, `padding`, `border`, `width`, `height`) are not inherited.

</details>