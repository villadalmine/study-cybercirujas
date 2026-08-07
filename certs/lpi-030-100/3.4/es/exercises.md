# LPI Web Development Essentials (Exam 030-100, v1.0)
## Guía de Estudio y Laboratorios Prácticos Avanzados — Tema 3.4: CSS Box Model y Layout (Peso: 5)

**Certificación Objetivo:** LPI Web Development Essentials (Exam 030-100)  
**Tema:** 3.4 CSS Box Model y Layout  
**Peso:** 5  
**Referencia Oficial:** [LPI Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)  

---

## Visión General de Arquitectura Técnica y Mecánica Interna

### 1. El W3C Visual Formatting Model y Mecánica del Box Model
El motor de renderizado (Rendering Engine) del navegador (por ejemplo, Blink, Gecko) calcula la geometría de cada elemento del DOM utilizando el **Visual Formatting Model**. Cada elemento renderizado genera cero o más cajas rectangulares formateadas de acuerdo con el CSS Box Model.

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

#### Cálculo de la Fórmula de Box Sizing
* **`box-sizing: content-box` (Predeterminado Estándar)**
  $$\text{Rendered Width} = \text{width} + \text{padding-left} + \text{padding-right} + \text{border-left-width} + \text{border-right-width}$$
  $$\text{Rendered Height} = \text{height} + \text{padding-top} + \text{padding-bottom} + \text{border-top-width} + \text{border-bottom-width}$$

* **`box-sizing: border-box` (Estándar de Producción Moderno)**
  $$\text{Rendered Width} = \text{width} \quad (\text{includes content, padding, and border})$$
  $$\text{Content Width} = \text{width} - (\text{padding-left} + \text{padding-right} + \text{border-left-width} + \text{border-right-width})$$

---

### 2. Modos de Layout, Normal Flow y Stacking Contexts

| Valor de Display | Comportamiento de Layout Flow | Margin Collapsing | Respeto de Width / Height |
| :--- | :--- | :--- | :--- |
| `inline` | Se ajusta dentro de la line box, se envuelve horizontalmente | Solo horizontal (se ignoran márgenes verticales) | Ignorado (`auto` basado en contenido de texto) |
| `block` | Toma el 100% del ancho del padre, hace salto a nueva línea | Los márgenes verticales colapsan entre elementos adyacentes | Totalmente respetado |
| `inline-block` | Fluye en línea horizontalmente, sin salto de línea | Los márgenes verticales **no** colapsan | Totalmente respetado |
| `flex` | Establece un Flex Formatting Context (FFC) | Los márgenes **nunca** colapsan | Determinado por `flex-basis`, `flex-grow`, `flex-shrink` |
| `grid` | Establece un Grid Formatting Context (GFC) | Los márgenes **nunca** colapsan | Determinado por tracks explícitos/implícitos del grid |

#### Reglas de Posicionamiento y Stacking Context (`z-index`)
1. **`position: static`** (Predeterminado): Posicionado según el normal document flow. `top`, `bottom`, `left`, `right` y `z-index` no tienen efecto.
2. **`position: relative`**: Desplazado en relación con su posición normal sin eliminarlo del document flow. Crea un origen de coordenadas local.
3. **`position: absolute`**: Eliminado del document flow. Posicionado en relación con su ancestro más cercano con un valor de `position` distinto de `static` (Containing Block).
4. **`position: fixed`**: Eliminado del document flow. Posicionado en relación con el viewport (o padre transformado).
5. **`position: sticky`**: Híbrido de `relative` y `fixed` dependiendo de la posición de desplazamiento (scroll) en relación con el contenedor de scroll más cercano.
6. **Condiciones de Activación de Stacking Context**: Un elemento crea un nuevo Stacking Context cuando `z-index` no es `auto` en un elemento posicionado (`relative`/`absolute`/`fixed`/`sticky`), o cuando se aplican propiedades CSS como `opacity < 1`, `transform`, `filter`, `perspective` o `isolation: isolate`.

---

## Laboratorios Prácticos Guiados

### Requisitos Previos y Configuración del Servidor de Prueba

Ejecute un servidor HTTP local usando Node.js/Python o `npx` para servir archivos de prueba sin problemas de CORS:

```bash
# Prepare working directory
mkdir -p ~/lpi-css-lab && cd ~/lpi-css-lab

# Start a lightweight local static server on port 8080
npx serve -l 8080 .
```

Salida esperada:
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

### Laboratorio Guiado 1: Diagnóstico del Tamaño del Box Model y Margin Collapsing Vertical

#### Paso 1: Crear la Estructura de Prueba HTML (`lab1.html`)
Cree `~/lpi-css-lab/lab1.html` con dos configuraciones de caja idénticas que operen bajo diferentes reglas de `box-sizing`, seguidas de elementos de bloque verticales adyacentes para demostrar la mecánica de colapso de margen (margin collapse).

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

#### Paso 2: Abrir la Consola del Navegador y Ejecutar la Verificación de Estilos Computados del Layout
Abra Google Chrome o Mozilla Firefox, navegue a `http://localhost:8080/lab1.html`, presione `F12` (DevTools) y ejecute los siguientes comandos de JavaScript en la pestaña **Console**:

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

#### Salida Esperada de la Consola de DevTools:
```text
┌───┬──────────────────────┬───────────────┬───────────────────────┬────────────────────────┬───────────────┐
│   │ id                   │ widthProperty │ renderedBoundingWidth │ renderedBoundingHeight │ boxSizing     │
├───┼──────────────────────┼───────────────┼───────────────────────┼────────────────────────┼───────────────┤
│ 0 │ 'content-box-target' │ '200px'       │ 260                   │ 160                    │ 'content-box' │
│ 1 │ 'border-box-target'  │ '200px'       │ 200                   │ 100                    │ 'border-box'  │
└───┴──────────────────────┴───────────────┴───────────────────────┴────────────────────────┴───────────────┘
```

#### Paso 3: Verificar la Distancia de Margin Collapsing mediante la Consola
Ejecute en la consola del navegador:

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

#### Salida Esperada:
```text
Normal Flow Margin Distance: 30px (Expected: 30px due to collapse max(30, 20))
Flex Context Margin Distance: 50px (Expected: 50px due to non-collapse 30 + 20)
```

---

#### Preguntas de Comprensión — Laboratorio 1

1. **Pregunta 1.1:** Un elemento tiene `box-sizing: content-box`, `width: 300px`, `padding: 15px 25px`, `border: 5px solid red` y `margin: 20px`. ¿Cuál es el ancho físico renderizado exacto ocupado por este elemento en la pantalla (excluyendo el margen) y cuál es el espacio total del layout horizontal requerido (incluyendo el margen)?
2. **Pregunta 1.2:** El Elemento A (`margin-bottom: 40px`) está directamente encima del Elemento B (`margin-top: 25px`) en el normal flow. El Elemento B tiene un párrafo interno con `margin-top: 50px` que se extiende más allá del borde superior del Elemento B. ¿Cuál será la separación vertical entre el Elemento A y el Elemento B bajo las reglas estándar de colapso de margen (margin collapsing) de CSS?
3. **Pregunta 1.3:** ¿Qué declaración CSS debe agregarse a un elemento contenedor para evitar que los márgenes verticales de sus elementos de bloque hijos colapsen con los márgenes superior/inferior del contenedor sin agregar bordes o rellenos (paddings) visibles?

---

### Laboratorio Guiado 2: Tipos de Posicionamiento, Containing Blocks y Stacking Contexts

#### Paso 1: Crear la Estructura de Prueba HTML (`lab2.html`)
Cree `~/lpi-css-lab/lab2.html` para analizar el posicionamiento relativo, absoluto, fijo y sticky junto con la aislamiento de Stacking Context de raíz vs anidado.

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

#### Paso 2: Validar Desplazamientos de Containing Block a través de la Consola de DevTools
Navegue a `http://localhost:8080/lab2.html` y ejecute:

```javascript
const child = document.getElementById('absolute-node');
const parent = child.offsetParent;

console.log(`Child ID: ${child.id}`);
console.log(`Containing Block Element: <${parent.tagName.toLowerCase()} class="${parent.className}">`);
console.log(`Offset Left relative to Containing Block: ${child.offsetLeft}px`);
console.log(`Offset Top relative to Containing Block: ${child.offsetTop}px`);
```

#### Salida Esperada:
```text
Child ID: absolute-node
Containing Block Element: <div class="relative-parent">
Offset Left relative to Containing Block: 246px
Offset Top relative to Containing Block: 138px
```

#### Paso 3: Inspeccionar la Jerarquía Visual de Stacking
En la consola del navegador, ejecute verificaciones de puntos de elementos para determinar qué elemento se renderiza arriba cuando ocurre una superposición en la coordenada `(X: 50, Y: 230)`:

```javascript
// Test pixel intersection point where child-1 (z-index 9999) overlaps with parent-2/child-2 area
const topElement = document.elementFromPoint(60, 230);
console.log(`Element visually rendered at (60, 230):`, topElement.id || topElement.className);
```

#### Salida Esperada:
```text
Element visually rendered at (60, 230): child-2
```
*Conclusión Clave:* Aunque `child-1` tiene `z-index: 9999`, está atrapado dentro de `parent-1` (`z-index: 1`). Dado que `parent-2` tiene `z-index: 2`, `parent-2` y todos sus hijos se renderizan **por encima** de `parent-1` y todos sus hijos.

---

#### Preguntas de Comprensión — Laboratorio 2

1. **Pregunta 2.1:** Un elemento tiene `position: absolute; top: 0; left: 0;`. Si ninguno de sus elementos ancestros tiene `position` establecido explícitamente, ¿a qué bloque se ancla la posición del elemento?
2. **Pregunta 2.2:** ¿Por qué `Child 1` (con `z-index: 9999`) apareció *detrás* de `Child 2` (con `z-index: 1`) en el Laboratorio 2? ¿Qué concepto controla este comportamiento?
3. **Pregunta 2.3:** ¿Qué sucede con un elemento estilizado con `position: sticky; top: 20px;` si su contenedor padre inmediato tiene una altura igual a la del propio elemento sticky?

---

### Laboratorio Guiado 3: Dinámica de Flexbox, Alineación de Ejes y Cálculos de Longitud Flexible

#### Paso 1: Crear la Estructura de Prueba HTML (`lab3.html`)
Cree `~/lpi-css-lab/lab3.html` para calcular los algoritmos de tamaño de flex items (`flex-grow`, `flex-shrink`, `flex-basis`).

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

#### Paso 2: Análisis Matemático y Verificación en Consola
Abra `http://localhost:8080/lab3.html` en su navegador.

##### Teoría de Cálculo de Tamaño:
* Ancho Total del Contenedor = `800px`
* Suma de `flex-basis` = `100px + 100px + 200px = 400px`
* Espacio Libre Restante = `800px - 400px = 400px`
* Factores Totales de `flex-grow` = `1 + 3 + 0 = 4`
* Valor por Unidad de Grow = `400px / 4 = 100px`
* **Anchos Finales Computados:**
  * Caja 1: $100\text{px} + (1 \times 100\text{px}) = \mathbf{200\text{px}}$
  * Caja 2: $100\text{px} + (3 \times 100\text{px}) = \mathbf{400\text{px}}$
  * Caja 3: $200\text{px} + (0 \times 100\text{px}) = \mathbf{200\text{px}}$

Ejecute en la Consola para verificar que el cálculo en tiempo de ejecución coincide con la teoría:

```javascript
['flex-box-1', 'flex-box-2', 'flex-box-3'].forEach(id => {
  const el = document.getElementById(id);
  console.log(`${id} rendered width: ${el.getBoundingClientRect().width}px`);
});
```

#### Salida Esperada:
```text
flex-box-1 rendered width: 200px
flex-box-2 rendered width: 400px
flex-box-3 rendered width: 200px
```

---

#### Preguntas de Comprensión — Laboratorio 3

1. **Pregunta 3.1:** En un contenedor flex con `flex-direction: column`, ¿qué propiedad controla el posicionamiento **horizontal** de los flex items a lo largo del eje secundario (cross axis)?
2. **Pregunta 3.2:** ¿Cuál es la sintaxis abreviada (shorthand) equivalente para definir `flex-grow: 0`, `flex-shrink: 1` y `flex-basis: auto` en un flex item?
3. **Pregunta 3.3:** Un contenedor flex tiene un ancho de `500px`. Contiene dos elementos: Elemento A (`flex-basis: 300px`, `flex-shrink: 1`) y Elemento B (`flex-basis: 300px`, `flex-shrink: 3`). ¿Cuál será el ancho renderizado final del Elemento A y del Elemento B después de aplicar el encogimiento (shrinkage)?

---

### Laboratorio Guiado 4: Arquitectura de CSS Grid, Tracks Explícitos/Implícitos y Áreas Nombradas

#### Paso 1: Crear la Estructura de Prueba HTML (`lab4.html`)
Cree `~/lpi-css-lab/lab4.html` para configurar un layout de dashboard de producción utilizando áreas de CSS Grid, funciones de track (`fr`, `repeat`, `minmax`) y propiedades de gap.

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

#### Paso 2: Inspeccionar los Cálculos de Grid Tracks mediante las DevTools del Navegador
Navegue a `http://localhost:8080/lab4.html`. Ejecute el siguiente script en la consola de DevTools para inspeccionar los parámetros computados de las tracks de CSS Grid:

```javascript
const gridEl = document.getElementById('main-grid');
const computed = window.getComputedStyle(gridEl);

console.log("Computed Grid Columns:", computed.getPropertyValue('grid-template-columns'));
console.log("Computed Grid Rows:", computed.getPropertyValue('grid-template-rows'));
console.log("Computed Grid Areas:", computed.getPropertyValue('grid-template-areas'));
```

#### Salida Esperada de la Consola:
```text
Computed Grid Columns: 200px 332.5px 332.5px
Computed Grid Rows: 60px 370px 40px
Computed Grid Areas: "header header header" "sidebar content content" "footer footer footer"
```

---

#### Preguntas de Comprensión — Laboratorio 4

1. **Pregunta 4.1:** ¿Cuál es la diferencia entre `grid-template-columns: repeat(auto-fill, minmax(150px, 1fr))` y `grid-template-columns: repeat(auto-fit, minmax(150px, 1fr))` cuando el ancho del contenedor es lo suficientemente grande como para dar cabida a columnas vacías adicionales?
2. **Pregunta 4.2:** Dada la propiedad `grid-column: 2 / span 3;`, ¿dónde empieza y termina el elemento grid en términos de números de líneas de grid (grid lines)?
3. **Pregunta 4.3:** ¿La propiedad `gap` (o `grid-gap`) de CSS coloca espaciamiento *fuera* de los bordes del límite exterior del contenedor grid?

---

<details>
<summary><b>Haz clic para expandir: Respuestas y Explicaciones Técnicas Detalladas</b></summary>

### Respuestas del Laboratorio 1

* **Respuesta 1.1:**  
  * Ancho Renderizado (excluyendo el margen) = $300\text{px (width)} + 50\text{px (padding izquierdo+derecho)} + 10\text{px (borde izquierdo+derecho)} = \mathbf{360\text{px}}$.  
  * Espacio Horizontal Total (incluyendo el margen) = $360\text{px} + 40\text{px (margen izquierdo+derecho)} = \mathbf{400\text{px}}$.

* **Respuesta 1.2:**  
  * La separación vertical entre el Elemento A y el Elemento B será de **$50\text{px}$**.  
  * *Mecanismo:* Bajo las reglas de colapso de margen vertical (vertical margin collapsing), cuando elementos de bloque adyacentes colisionan, sus márgenes colapsan en un único margen igual al máximo de los márgenes individuales ($\max(40, 25, 50) = 50\text{px}$).

* **Respuesta 1.3:**  
  * Agregar **`overflow: auto`** (o `overflow: hidden`, `display: flow-root`) al elemento contenedor.  
  * *Mecanismo:* La creación de un nuevo Block Formatting Context (BFC) evita que los márgenes de los hijos se escapen o colapsen fuera de los límites del padre.

---

### Respuestas del Laboratorio 2

* **Respuesta 2.1:**  
  * Se ancla al **Initial Containing Block**, que corresponde a las dimensiones del **Viewport** del navegador (contexto del elemento `<html>`).

* **Respuesta 2.2:**  
  * Controlado por la **Jerarquía de Stacking Context**.  
  * `Child 1` pertenece a `Parent 1` (`z-index: 1`), mientras que `Child 2` pertenece a `Parent 2` (`z-index: 2`). Debido a que `Parent 2` forma un stacking context con un índice de apilamiento mayor que `Parent 1`, todos los hijos de `Parent 2` se renderizan delante de `Parent 1` y todo su subárbol, independientemente de qué tan alto esté establecido el `z-index` local de `Child 1`.

* **Respuesta 2.3:**  
  * El elemento **no se pegará (stick)** y se comportará como `position: relative`.  
  * *Mecanismo:* Un elemento sticky solo puede moverse dentro de los límites de la caja de su contenedor padre. Si la altura del contenedor es igual a la altura del elemento sticky, hay cero espacio de desplazamiento (scroll) restante dentro del contenedor para que el elemento se pegue a lo largo del recorrido.

---

### Respuestas del Laboratorio 3

* **Respuesta 3.1:**  
  * **`align-items`** (o **`align-self`** en elementos individuales).  
  * *Mecanismo:* Cuando `flex-direction` está configurado en `column`, el eje principal (main axis) se vuelve vertical (controlado por `justify-content`), y el eje secundario (cross axis) se vuelve horizontal (controlado por `align-items`).

* **Respuesta 3.2:**  
  * **`flex: initial;`** (o `flex: 0 1 auto;`).

* **Respuesta 3.3:**  
  * Ancho final del Elemento A = **$275\text{px}$**, Ancho final del Elemento B = **$225\text{px}$**.  
  * *Deducción Matemática:*  
    * Suma total del basis = $300\text{px} + 300\text{px} = 600\text{px}$.  
    * Espacio excedente a encoger = $600\text{px} - 500\text{px} = 100\text{px}$.  
    * Ponderación total de shrink = $(300 \times 1) + (300 \times 3) = 300 + 900 = 1200$.  
    * Proporción de shrink del Elemento A = $(300 \times 1) / 1200 = 300 / 1200 = 0.25$.  
    * Reducción del Elemento A = $100\text{px} \times 0.25 = 25\text{px} \implies 300\text{px} - 25\text{px} = \mathbf{275\text{px}}$.  
    * Proporción de shrink del Elemento B = $(300 \times 3) / 1200 = 900 / 1200 = 0.75$.  
    * Reducción del Elemento B = $100\text{px} \times 0.75 = 75\text{px} \implies 300\text{px} - 75\text{px} = \mathbf{225\text{px}}$.

---

### Respuestas del Laboratorio 4

* **Respuesta 4.1:**  
  * `auto-fill` crea tracks vacíos si hay espacio extra disponible, manteniendo las columnas de tracks aunque estén vacías.  
  * `auto-fit` colapsa cualquier track vacío a `0px` y estira los elementos grid no vacíos restantes para consumir el espacio sobrante del contenedor.

* **Respuesta 4.2:**  
  * Empieza en **Grid Line 2** y termina en **Grid Line 5** (abarcando a lo largo de 3 columnas de track).

* **Respuesta 4.3:**  
  * **No.** `gap` (y `row-gap`/`column-gap`) solo crea separaciones (gutters) *entre* tracks grid adyacentes. Nunca agrega espaciamiento entre los tracks exteriores y el borde del límite del contenedor (use `padding` en el contenedor grid para el espaciamiento exterior).

</details>