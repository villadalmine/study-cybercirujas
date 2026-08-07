# LPI Web Development Essentials (Exam 030-100, v1.0)
## Study Guide & Advanced Practical Labs — Topic 3.4: CSS Box Model and Layout (Weight: 5)

**Target Certification:** LPI Web Development Essentials (Exam 030-100)  
**Topic:** 3.4 CSS Box Model and Layout  
**Weight:** 5  
**Official Reference:** [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)  

---

## Technical Architecture & Internal Mechanics Overview

### 1. The W3C Visual Formatting Model & Box Model Mechanics
The browser's Rendering Engine (e.g., Blink, Gecko) calculates the geometry of every DOM element using the **Visual Formatting Model**. Every rendered element generates zero or more rectangular boxes formatted according to the CSS Box Model.

```
+-------------------------------------------------------+
| MARGIN (Transparent / Parent Background visible)     |
|  +-------------------------------------------------+  |
|  | BORDER (Border Style, Width, Color)             |  |
|  |  +-------------------------------------------+  |  |
|  |  | PADDING (Element Background visible)     |  |  |
|  |  |  +-------------------------------------+  |  |  |
|  |  |  | CONTENT                             |  |  |  |
|  |  |  | (Text, Images, Child Elements)     |  |  |  |
|  |  |  +-------------------------------------+  |  |  |
|  |  +-------------------------------------------+  |  |
|  +-------------------------------------------------+  |
+-------------------------------------------------------+
```

#### Box Sizing Formula Computation
* **`box-sizing: content-box` (Standard Default)**
  $$\text{Rendered Width} = \text{width} + \text{padding-left} + \text{padding-right} + \text{border-left-width} + \text{border-right-width}$$
  $$\text{Rendered Height} = \text{height} + \text{padding-top} + \text{padding-bottom} + \text{border-top-width} + \text{border-bottom-width}$$

* **`box-sizing: border-box` (Modern Production Standard)**
  $$\text{Rendered Width} = \text{width} \quad (\text{includes content, padding, and border})$$
  $$\text{Content Width} = \text{width} - (\text{padding-left} + \text{padding-right} + \text{border-left-width} + \text{border-right-width})$$

---

### 2. Layout Modes, Normal Flow, and Stacking Contexts

| Display Value | Layout Flow Behavior | Margin Collapsing | Width / Height Respect |
| :--- | :--- | :--- | :--- |
| `inline` | Fits within line box, wraps horizontally | Horizontal only (Vertical margins ignored) | Ignored (`auto` based on text content) |
| `block` | Takes 100% parent width, breaks to new line | Vertical margins collapse between adjacent elements | Fully respected |
| `inline-block` | Flows inline horizontally, no line break | Vertical margins **do not** collapse | Fully respected |
| `flex` | Establishes Flex Formatting Context (FFC) | Margins **never** collapse | Driven by `flex-basis`, `flex-grow`, `flex-shrink` |
| `grid` | Establishes Grid Formatting Context (GFC) | Margins **never** collapse | Driven by explicit/implicit grid tracks |

#### Positioning & Stacking Context (`z-index`) Rules
1. **`position: static`** (Default): Positioned according to normal document flow. `top`, `bottom`, `left`, `right`, and `z-index` have no effect.
2. **`position: relative`**: Offset relative to its normal position without removing it from document flow. Creates a local coordinate origin.
3. **`position: absolute`**: Removed from document flow. Positioned relative to its nearest ancestor with a `position` value other than `static` (Containing Block).
4. **`position: fixed`**: Removed from document flow. Positioned relative to the viewport (or transformed parent).
5. **`position: sticky`**: Hybrid of `relative` and `fixed` depending on scroll position relative to nearest scroll container.
6. **Stacking Context Trigger Conditions**: A element creates a new Stacking Context when `z-index` is not `auto` on a positioned element (`relative`/`absolute`/`fixed`/`sticky`), or when CSS properties like `opacity < 1`, `transform`, `filter`, `perspective`, or `isolation: isolate` are applied.

---

## Guided Practical Labs

### Prerequisites & Test Server Setup

Run a local HTTP server using Node.js/Python or `npx` to serve test files without CORS issues:

```bash
# Prepare working directory
mkdir -p ~/lpi-css-lab && cd ~/lpi-css-lab

# Start a lightweight local static server on port 8080
npx serve -l 8080 .
```

Expected output:
```text
┌─────────────────────────────────────────┐
│                                         │
│   Serving!                              │
│                                         │
│   - Local:    http://localhost:8080     │
│   - Network:  http://192.168.1.50:8080  │
│                                         │
└─────────────────────────────────────────┘
```

---

### Guided Lab 1: Box Model Sizing & Vertical Margin Collapsing Diagnostics

#### Step 1: Create the HTML Test Rig (`lab1.html`)
Create `~/lpi-css-lab/lab1.html` with two identical box configurations operating under different `box-sizing` rules, followed by adjacent vertical block elements to demonstrate margin collapse mechanics.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>LPI 030-100 Lab 1 - Box Model & Margin Collapsing</title>
  <style>
    /* CSS Reset */
    * {
      margin: 0;
      padding: 0;
    }

    body {
      font-family: monospace;
      padding: 20px;
      background-color: #121212;
      color: #e0e0e0;
    }

    .container {
      margin-bottom: 40px;
      background-color: #1e1e1e;
      padding: 10px;
      border: 1px dashed #555;
    }

    /* Box Model Sizing Comparison */
    .box-content {
      box-sizing: content-box;
      width: 200px;
      height: 100px;
      padding: 20px;
      border: 10px solid #00e676;
      margin: 15px;
      background-color: #263238;
    }

    .box-border {
      box-sizing: border-box;
      width: 200px;
      height: 100px;
      padding: 20px;
      border: 10px solid #00b0ff;
      margin: 15px;
      background-color: #263238;
    }

    /* Vertical Margin Collapsing Mechanics */
    .block-top {
      height: 60px;
      margin-bottom: 30px;
      background-color: #ff5252;
    }

    .block-bottom {
      height: 60px;
      margin-top: 20px;
      background-color: #ff4081;
    }

    .flex-wrapper {
      display: flex;
      flex-direction: column;
      background-color: #37474f;
    }

    .flex-item-top {
      height: 60px;
      margin-bottom: 30px;
      background-color: #ab47bc;
    }

    .flex-item-bottom {
      height: 60px;
      margin-top: 20px;
      background-color: #7e57c2;
    }
  </style>
</head>
<body>
  <h2>1. Box Sizing Breakdown</h2>
  <div class="container">
    <div id="content-box-target" class="box-content">Content-Box Target</div>
    <div id="border-box-target" class="box-border">Border-Box Target</div>
  </div>

  <h2>2. Vertical Margin Collapse vs Non-Collapse</h2>
  <div class="container">
    <h3>Normal Flow Blocks (Margins Collapse)</h3>
    <div class="block-top" id="normal-top">Top Block (mb: 30px)</div>
    <div class="block-bottom" id="normal-bottom">Bottom Block (mt: 20px)</div>
  </div>

  <div class="container">
    <h3>Flex Formatting Context (No Collapse)</h3>
    <div class="flex-wrapper">
      <div class="flex-item-top" id="flex-top">Flex Item Top (mb: 30px)</div>
      <div class="flex-item-bottom" id="flex-bottom">Flex Item Bottom (mt: 20px)</div>
    </div>
  </div>
</body>
</html>
```

#### Step 2: Open Browser Console & Run Layout Computed Style Verification
Open Google Chrome or Mozilla Firefox, navigate to `http://localhost:8080/lab1.html`, press `F12` (DevTools), and execute the following JavaScript commands in the **Console** tab:

```javascript
// Function to measure physical rendered layout dimensions
function measureElement(id) {
  const el = document.getElementById(id);
  const rect = el.getBoundingClientRect();
  const computed = window.getComputedStyle(el);
  
  return {
    id: id,
    widthProperty: computed.width,
    renderedBoundingWidth: rect.width,
    renderedBoundingHeight: rect.height,
    boxSizing: computed.boxSizing
  };
}

console.table([
  measureElement('content-box-target'),
  measureElement('border-box-target')
]);
```

#### Expected DevTools Console Output:
```text
┌───┬──────────────────────┬───────────────┬───────────────────────┬────────────────────────┬───────────────┐
│   │ id                   │ widthProperty │ renderedBoundingWidth │ renderedBoundingHeight │ boxSizing     │
├───┼──────────────────────┼───────────────┼───────────────────────┼────────────────────────┼───────────────┤
│ 0 │ 'content-box-target' │ '200px'       │ 260                   │ 160                    │ 'content-box' │
│ 1 │ 'border-box-target'  │ '200px'       │ 200                   │ 100                    │ 'border-box'  │
└───┴──────────────────────┴───────────────┴───────────────────────┴────────────────────────┴───────────────┘
```

#### Step 3: Verify Margin Collapsing Distance via Console
Execute in the browser console:

```javascript
const normalTop = document.getElementById('normal-top').getBoundingClientRect();
const normalBottom = document.getElementById('normal-bottom').getBoundingClientRect();
const normalDistance = normalBottom.top - normalTop.bottom;

const flexTop = document.getElementById('flex-top').getBoundingClientRect();
const flexBottom = document.getElementById('flex-bottom').getBoundingClientRect();
const flexDistance = flexBottom.top - flexTop.top - flexTop.height;

console.log(`Normal Flow Margin Distance: ${normalDistance}px (Expected: 30px due to collapse max(30, 20))`);
console.log(`Flex Context Margin Distance: ${flexDistance}px (Expected: 50px due to non-collapse 30 + 20)`);
```

#### Expected Output:
```text
Normal Flow Margin Distance: 30px (Expected: 30px due to collapse max(30, 20))
Flex Context Margin Distance: 50px (Expected: 50px due to non-collapse 30 + 20)
```

---

#### Comprehension Questions — Lab 1

1. **Question 1.1:** An element has `box-sizing: content-box`, `width: 300px`, `padding: 15px 25px`, `border: 5px solid red`, and `margin: 20px`. What is the exact physical rendered width occupied by this element on the screen (excluding margin), and what is the total horizontal layout space required (including margin)?
2. **Question 1.2:** Element A (`margin-bottom: 40px`) is directly above Element B (`margin-top: 25px`) in normal flow. Element B has an inner paragraph with `margin-top: 50px` that extends beyond Element B's top border. What will be the vertical gap between Element A and Element B under standard CSS margin collapsing rules?
3. **Question 1.3:** What CSS declaration must be added to a container element to prevent its child block elements' vertical margins from collapsing with the container's top/bottom margins without adding visible borders or paddings?

---

### Guided Lab 2: Positioning Types, Containing Blocks, and Stacking Contexts

#### Step 1: Create the HTML Test Rig (`lab2.html`)
Create `~/lpi-css-lab/lab2.html` to analyze relative, absolute, fixed, and sticky positioning along with root vs nested stacking context isolation.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>LPI 030-100 Lab 2 - Positioning & Stacking Context</title>
  <style>
    body {
      font-family: sans-serif;
      margin: 0;
      height: 2000px; /* Force scrollbar for fixed/sticky tests */
      background-color: #f4f4f9;
    }

    .section {
      padding: 20px;
      margin: 20px;
      background: #ffffff;
      border: 1px solid #ccc;
    }

    /* Containing Block Test */
    .relative-parent {
      position: relative;
      width: 400px;
      height: 200px;
      background: #e3f2fd;
      border: 2px solid #2196f3;
      margin-top: 20px;
    }

    .absolute-child {
      position: absolute;
      bottom: 10px;
      right: 10px;
      width: 150px;
      height: 50px;
      background: #ff9800;
      color: white;
      text-align: center;
      line-height: 50px;
    }

    /* Sticky Test */
    .sticky-header {
      position: sticky;
      top: 0;
      background: #4caf50;
      color: white;
      padding: 15px;
      font-weight: bold;
      z-index: 10;
    }

    /* Stacking Context Isolation Test */
    .stack-parent-1 {
      position: relative;
      z-index: 1; /* Creates Stacking Context 1 */
      background: #e1bee7;
      width: 250px;
      height: 150px;
      margin-bottom: -50px; /* Overlap with Parent 2 */
    }

    .stack-child-1 {
      position: absolute;
      top: 20px;
      left: 20px;
      z-index: 9999; /* High z-index inside Stacking Context 1 */
      background: #9c27b0;
      color: white;
      padding: 10px;
    }

    .stack-parent-2 {
      position: relative;
      z-index: 2; /* Creates Stacking Context 2 (Higher than Parent 1) */
      background: #c8e6c9;
      width: 250px;
      height: 150px;
    }

    .stack-child-2 {
      position: absolute;
      top: 20px;
      left: 40px;
      z-index: 1; /* Low z-index inside Stacking Context 2 */
      background: #2e7d32;
      color: white;
      padding: 10px;
    }
  </style>
</head>
<body>

  <div class="sticky-header" id="sticky-node">Sticky Header (Sticks to top: 0)</div>

  <div class="section">
    <h2>Containing Block Resolution</h2>
    <div class="relative-parent">
      Relative Parent (`position: relative`)
      <div class="absolute-child" id="absolute-node">Absolute Child</div>
    </div>
  </div>

  <div class="section">
    <h2>Stacking Context Isolation Trap</h2>
    <div class="stack-parent-1" id="parent-1">
      Parent 1 (z-index: 1)
      <div class="stack-child-1" id="child-1">Child 1 (z-index: 9999)</div>
    </div>
    <div class="stack-parent-2" id="parent-2">
      Parent 2 (z-index: 2)
      <div class="stack-child-2" id="child-2">Child 2 (z-index: 1)</div>
    </div>
  </div>

</body>
</html>
```

#### Step 2: Validate Containing Block Offsets via DevTools Console
Navigate to `http://localhost:8080/lab2.html` and execute:

```javascript
const child = document.getElementById('absolute-node');
const parent = child.offsetParent;

console.log(`Child ID: ${child.id}`);
console.log(`Containing Block Element: <${parent.tagName.toLowerCase()} class="${parent.className}">`);
console.log(`Offset Left relative to Containing Block: ${child.offsetLeft}px`);
console.log(`Offset Top relative to Containing Block: ${child.offsetTop}px`);
```

#### Expected Output:
```text
Child ID: absolute-node
Containing Block Element: <div class="relative-parent">
Offset Left relative to Containing Block: 246px
Offset Top relative to Containing Block: 138px
```

#### Step 3: Inspect Visual Stacking Hierarchy
In the browser console, execute element point checks to determine which element renders on top when overlapping occurs at coordinate `(X: 50, Y: 230)`:

```javascript
// Test pixel intersection point where child-1 (z-index 9999) overlaps with parent-2/child-2 area
const topElement = document.elementFromPoint(60, 230);
console.log(`Element visually rendered at (60, 230):`, topElement.id || topElement.className);
```

#### Expected Output:
```text
Element visually rendered at (60, 230): child-2
```
*Key Takeaway:* Even though `child-1` has `z-index: 9999`, it is trapped within `parent-1` (`z-index: 1`). Because `parent-2` has `z-index: 2`, `parent-2` and all of its children render **above** `parent-1` and all of its children.

---

#### Comprehension Questions — Lab 2

1. **Question 2.1:** An element has `position: absolute; top: 0; left: 0;`. If none of its ancestor elements have `position` explicitly set, to what block is the element's position anchored?
2. **Question 2.2:** Why did `Child 1` (with `z-index: 9999`) appear *behind* `Child 2` (with `z-index: 1`) in Lab 2? What concept controls this behavior?
3. **Question 2.3:** What happens to an element styled with `position: sticky; top: 20px;` if its immediate parent container has a height equal to the sticky element itself?

---

### Guided Lab 3: Flexbox Dynamics, Axis Alignment, and Flexible Length Calculations

#### Step 1: Create the HTML Test Rig (`lab3.html`)
Create `~/lpi-css-lab/lab3.html` to compute flex item sizing algorithms (`flex-grow`, `flex-shrink`, `flex-basis`).

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>LPI 030-100 Lab 3 - Flexbox Layout Engine</title>
  <style>
    body {
      font-family: monospace;
      background: #1a1a1a;
      color: #fff;
      padding: 20px;
    }

    .flex-container {
      display: flex;
      width: 800px;
      height: 120px;
      background: #333;
      border: 2px solid #555;
      margin-bottom: 30px;
    }

    /* Lab 3A: Flex Grow Distribution */
    .grow-1 {
      flex-grow: 1;
      flex-basis: 100px;
      background: #e53935;
    }

    .grow-2 {
      flex-grow: 3;
      flex-basis: 100px;
      background: #43a047;
    }

    .grow-3 {
      flex-grow: 0;
      flex-basis: 200px;
      background: #1e88e5;
    }

    /* Lab 3B: Alignment Properties */
    .align-container {
      display: flex;
      flex-direction: row;
      justify-content: space-between;
      align-items: center;
      width: 800px;
      height: 150px;
      background: #263238;
    }

    .item {
      width: 100px;
      height: 60px;
      background: #ffb300;
      color: #000;
      text-align: center;
      line-height: 60px;
      font-weight: bold;
    }

    .item-custom-align {
      align-self: flex-end;
      background: #00bcd4;
    }
  </style>
</head>
<body>
  <h2>Flexbox Sizing Math (`width: 800px`)</h2>
  <div class="flex-container">
    <div id="flex-box-1" class="grow-1">Box 1 (basis: 100, grow: 1)</div>
    <div id="flex-box-2" class="grow-2">Box 2 (basis: 100, grow: 3)</div>
    <div id="flex-box-3" class="grow-3">Box 3 (basis: 200, grow: 0)</div>
  </div>

  <h2>Axis Alignment Diagnostics</h2>
  <div class="align-container">
    <div class="item">Item A</div>
    <div class="item item-custom-align" id="custom-align-node">Item B (self: end)</div>
    <div class="item">Item C</div>
  </div>
</body>
</html>
```

#### Step 2: Mathematical Analysis & Console Verification
Open `http://localhost:8080/lab3.html` in your browser.

##### Sizing Calculation Theory:
* Container Total Width = `800px`
* Sum of `flex-basis` = `100px + 100px + 200px = 400px`
* Remaining Free Space = `800px - 400px = 400px`
* Total `flex-grow` factors = `1 + 3 + 0 = 4`
* Value per Grow Unit = `400px / 4 = 100px`
* **Computed Final Widths:**
  * Box 1: $100\text{px} + (1 \times 100\text{px}) = \mathbf{200\text{px}}$
  * Box 2: $100\text{px} + (3 \times 100\text{px}) = \mathbf{400\text{px}}$
  * Box 3: $200\text{px} + (0 \times 100\text{px}) = \mathbf{200\text{px}}$

Execute in Console to verify runtime math matching theory:

```javascript
['flex-box-1', 'flex-box-2', 'flex-box-3'].forEach(id => {
  const el = document.getElementById(id);
  console.log(`${id} rendered width: ${el.getBoundingClientRect().width}px`);
});
```

#### Expected Output:
```text
flex-box-1 rendered width: 200px
flex-box-2 rendered width: 400px
flex-box-3 rendered width: 200px
```

---

#### Comprehension Questions — Lab 3

1. **Question 3.1:** In a flex container with `flex-direction: column`, which property controls the **horizontal** positioning of flex items across the cross axis?
2. **Question 3.2:** What is the shorthand syntax equivalent for setting `flex-grow: 0`, `flex-shrink: 1`, and `flex-basis: auto` on a flex item?
3. **Question 3.3:** A flex container has a width of `500px`. It contains two items: Item A (`flex-basis: 300px`, `flex-shrink: 1`) and Item B (`flex-basis: 300px`, `flex-shrink: 3`). What will be the final rendered width of Item A and Item B after shrinkage is applied?

---

### Guided Lab 4: CSS Grid Architecture, Explicit/Implicit Tracks, and Named Areas

#### Step 1: Create the HTML Test Rig (`lab4.html`)
Create `~/lpi-css-lab/lab4.html` to configure a production dashboard layout using CSS Grid areas, track functions (`fr`, `repeat`, `minmax`), and gap properties.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>LPI 030-100 Lab 4 - CSS Grid System</title>
  <style>
    body {
      font-family: sans-serif;
      margin: 0;
      background: #0f172a;
      color: #f8fafc;
      padding: 20px;
    }

    /* Grid Dashboard Layout */
    .grid-dashboard {
      display: grid;
      width: 100%;
      max-width: 900px;
      height: 500px;
      gap: 15px;
      grid-template-columns: 200px 1fr 1fr;
      grid-template-rows: 60px 1fr 40px;
      grid-template-areas:
        "header  header  header"
        "sidebar content content"
        "footer  footer  footer";
      background: #1e293b;
      padding: 15px;
      border-radius: 8px;
    }

    .grid-header {
      grid-area: header;
      background: #3b82f6;
      display: flex;
      align-items: center;
      padding: 0 15px;
      font-weight: bold;
    }

    .grid-sidebar {
      grid-area: sidebar;
      background: #334155;
      padding: 15px;
    }

    .grid-content {
      grid-area: content;
      background: #475569;
      padding: 15px;
      /* Sub-grid using responsive minmax columns */
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 10px;
      align-content: start;
    }

    .card {
      background: #0ea5e9;
      height: 80px;
      border-radius: 4px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: bold;
    }

    .grid-footer {
      grid-area: footer;
      background: #1e293b;
      border-top: 1px solid #475569;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 0.85rem;
      color: #94a3b8;
    }
  </style>
</head>
<body>

  <h2>Production Dashboard Grid</h2>
  <div class="grid-dashboard" id="main-grid">
    <header class="grid-header">Header (grid-area: header)</header>
    <aside class="grid-sidebar">Sidebar (200px)</aside>
    <main class="grid-content" id="card-container">
      <div class="card">Card 1</div>
      <div class="card">Card 2</div>
      <div class="card">Card 3</div>
    </main>
    <footer class="grid-footer">Footer (grid-area: footer)</footer>
  </div>

</body>
</html>
```

#### Step 2: Inspect Grid Track Computations via Browser DevTools
Navigate to `http://localhost:8080/lab4.html`. Execute the following script in the DevTools console to inspect computed CSS Grid track parameters:

```javascript
const gridEl = document.getElementById('main-grid');
const computed = window.getComputedStyle(gridEl);

console.log("Computed Grid Columns:", computed.getPropertyValue('grid-template-columns'));
console.log("Computed Grid Rows:", computed.getPropertyValue('grid-template-rows'));
console.log("Computed Grid Areas:", computed.getPropertyValue('grid-template-areas'));
```

#### Expected Console Output:
```text
Computed Grid Columns: 200px 332.5px 332.5px
Computed Grid Rows: 60px 370px 40px
Computed Grid Areas: "header header header" "sidebar content content" "footer footer footer"
```

---

#### Comprehension Questions — Lab 4

1. **Question 4.1:** What is the difference between `grid-template-columns: repeat(auto-fill, minmax(150px, 1fr))` and `grid-template-columns: repeat(auto-fit, minmax(150px, 1fr))` when the container width is large enough to fit extra empty columns?
2. **Question 4.2:** Given the property `grid-column: 2 / span 3;`, where does the grid item start and end in terms of grid line numbers?
3. **Question 4.3:** Does the CSS `gap` (or `grid-gap`) property place spacing *outside* the outer boundary edges of the grid container?

---

<details>
<summary><b>Click to Expand: Answers and Deep Technical Explanations</b></summary>

### Lab 1 Answers

* **1.1 Answer:**  
  * Rendered Width (excluding margin) = $300\text{px (width)} + 50\text{px (left+right padding)} + 10\text{px (left+right border)} = \mathbf{360\text{px}}$.  
  * Total Horizontal Space (including margin) = $360\text{px} + 40\text{px (left+right margin)} = \mathbf{400\text{px}}$.

* **1.2 Answer:**  
  * The vertical gap between Element A and Element B will be **$50\text{px}$**.  
  * *Mechanism:* Under vertical margin collapsing rules, when adjacent block elements collide, their margins collapse into a single margin equal to the maximum of the individual margins ($\max(40, 25, 50) = 50\text{px}$).

* **1.3 Answer:**  
  * Add **`overflow: auto`** (or `overflow: hidden`, `display: flow-root`) to the container element.  
  * *Mechanism:* Creating a new Block Formatting Context (BFC) prevents child margins from escaping or collapsing outside the parent's boundaries.

---

### Lab 2 Answers

* **2.1 Answer:**  
  * It anchors to the **Initial Containing Block**, which corresponds to the dimensions of the browser **Viewport** (`<html>` element context).

* **2.2 Answer:**  
  * Controlled by **Stacking Context Hierarchy**.  
  * `Child 1` belongs to `Parent 1` (`z-index: 1`), while `Child 2` belongs to `Parent 2` (`z-index: 2`). Because `Parent 2` forms a stacking context with a higher stacking index than `Parent 1`, all children of `Parent 2` render in front of `Parent 1` and its entire sub-tree, regardless of how high `Child 1`'s local `z-index` is set.

* **2.3 Answer:**  
  * The element will **not stick** and will behave like `position: relative`.  
  * *Mechanism:* A sticky element can only move within the boundaries of its parent container box. If the container height equals the sticky element's height, there is zero remaining scroll space inside the container for the element to stick across.

---

### Lab 3 Answers

* **3.1 Answer:**  
  * **`align-items`** (or **`align-self`** on individual items).  
  * *Mechanism:* When `flex-direction` is set to `column`, the main axis becomes vertical (controlled by `justify-content`), and the cross axis becomes horizontal (controlled by `align-items`).

* **3.2 Answer:**  
  * **`flex: initial;`** (or `flex: 0 1 auto;`).

* **3.3 Answer:**  
  * Item A final width = **$275\text{px}$**, Item B final width = **$225\text{px}$**.  
  * *Mathematical Derivation:*  
    * Total basis sum = $300\text{px} + 300\text{px} = 600\text{px}$.  
    * Overflow space to shrink = $600\text{px} - 500\text{px} = 100\text{px}$.  
    * Total shrink weighting = $(300 \times 1) + (300 \times 3) = 300 + 900 = 1200$.  
    * Item A shrink ratio = $(300 \times 1) / 1200 = 300 / 1200 = 0.25$.  
    * Item A reduction = $100\text{px} \times 0.25 = 25\text{px} \implies 300\text{px} - 25\text{px} = \mathbf{275\text{px}}$.  
    * Item B shrink ratio = $(300 \times 3) / 1200 = 900 / 1200 = 0.75$.  
    * Item B reduction = $100\text{px} \times 0.75 = 75\text{px} \implies 300\text{px} - 75\text{px} = \mathbf{225\text{px}}$.

---

### Lab 4 Answers

* **4.1 Answer:**  
  * `auto-fill` creates empty tracks if there is extra room available, maintaining track columns even if empty.  
  * `auto-fit` collapses any empty tracks down to `0px` and stretches the remaining non-empty grid items to consume the leftover container space.

* **4.2 Answer:**  
  * Starts at **Grid Line 2** and ends at **Grid Line 5** (spanning across 3 track columns).

* **4.3 Answer:**  
  * **No.** `gap` (and `row-gap`/`column-gap`) only creates gutters *between* adjacent grid tracks. It never adds spacing between outer tracks and the container boundary edge (use `padding` on the grid container for outer spacing).

</details>