# LPI Web Development Essentials (Exam 030-100, v1.0)
## Topic 3.2: CSS Selectors and Style Application (Weight: 7.5)

### Referencias oficiales y especificaciones
* [LPI Web Development Essentials Objective 033.2](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* [W3C CSS Selectors Level 4 Specification](https://www.w3.org/TR/selectors-4/)
* [W3C CSS Cascading and Inheritance Level 4](https://www.w3.org/TR/css-cascade-4/)
* [MDN Web Docs: CSS Specificity](https://developer.mozilla.org/en-US/docs/Web/CSS/Specificity)

---

### Mecánica de arquitectura y motor interno

#### 1. Construcción de CSSOM y coincidencia de selectores de derecha a izquierda (Right-to-Left Selector Matching)
Durante el renderizado del navegador, el Layout Engine (por ejemplo, Blink, Gecko) analiza las reglas CSS en el **CSS Object Model (CSSOM)**. Al evaluar los nodos DOM frente a las reglas CSS, los evaluadores de selectores del motor del navegador analizan los selectores compuestos **de derecha a izquierda** (el key selector primero).
* **Key Selector**: La parte más a la derecha del selector (por ejemplo, en `div.nav-wrapper ul > li.active a`, `a` es el key selector).
* **Flujo de ejecución**: El motor filtra los candidatos basándose en `a`, luego recorre hacia arriba las cadenas de padres/ancestros. Esto minimiza el recorrido por los subárboles del DOM. Utilizar key selectors demasiado genéricos (por ejemplo, `*` o `div`) en DOMs profundos aumenta la sobrecarga de evaluación durante las pasadas de recalculación de estilos (fase de Recalculate Style).

#### 2. Matriz del vector de especificidad (Specificity Vector Matrix)
La especificidad CSS se calcula como un vector de 3 componentes `(a, b, c)` (a menudo conceptualizado como `(ID, Class/Attribute/Pseudo-class, Element/Pseudo-element)`):
* **Componente `a` (Selectores ID)**: Coincide por el atributo `#id` (por ejemplo, `#header`). Valor = `1,0,0`.
* **Componente `b` (Selectores de clase, atributo y pseudoclase)**: Incluye `.class`, `[attr=val]`, `:hover`, `:nth-child()`, `:first-child`. Valor = `0,1,0`.
* **Componente `c` (Selectores de tipo y pseudoelementos)**: Incluye `div`, `h1`, `p`, `::before`, `::after`. Valor = `0,0,1`.
* **Estilos en línea (Inline Styles)**: Se aplican directamente mediante atributos `style=""` en HTML, anulando las reglas de las hojas de estilo independientemente de la especificidad (conceptualmente posición `1,0,0,0`).
* **Selector universal (`*`) y combinadores (`>`, `+`, `~`, ` `)**: Añaden `(0,0,0)` de especificidad.
* **Pseudoclases funcionales**:
  * `:not()`, `:is()`, `:has()` toman la especificidad de su argumento más específico dentro de la lista de argumentos.
  * `:where()` fuerza la especificidad a `(0,0,0)` independientemente del contenido de su argumento.

#### 3. El algoritmo de cascada de CSS (The CSS Cascade Algorithm)
Cuando múltiples reglas en conflicto coinciden con un solo nodo DOM, la cascada resuelve los valores de propiedad de acuerdo con el siguiente orden de precedencia (de mayor a menor):
1. **Origen e Importancia**: `User Agent !important` > `User !important` > `Author !important` > `Author Normal` > `User Normal` > `User Agent Normal`.
2. **Contexto**: Sobrescribir mediante Transition / Animation.
3. **Especificidad**: El vector `(a, b, c)` más alto gana.
4. **Orden de aparición**: La última regla declarada en el orden del código fuente gana si los vectores de especificidad son iguales.

#### 4. Mecánica de herencia de propiedades
Las propiedades se categorizan como **heredadas** (por ejemplo, `color`, `font-family`, `line-height`, `visibility`) o **no heredadas** (por ejemplo, `margin`, `padding`, `border`, `background`, `display`).
* Palabras clave de control explícito:
  * `inherit`: Fuerza a una propiedad a tomar el valor computado de su nodo padre.
  * `initial`: Restablece la propiedad al valor predeterminado de la especificación CSS.
  * `unset`: Actúa como `inherit` si la propiedad se hereda de forma natural; de lo contrario, actúa como `initial`.
  * `revert`: Revierte el valor en cascada a los valores predeterminados de la hoja de estilo del User Agent o del origen del usuario.

---

### Ejercicios guiados prácticos

#### Ejercicio 1: Selectores estructurales, combinadores y evaluación CSSOM

En este ejercicio, crearás la estructura HTML de un dashboard de estado de producción y probarás la selección exacta de objetivos utilizando combinadores de descendientes, hijos directos, hermanos adyacentes y hermanos generales.

##### Paso 1.1: Crear el entorno de trabajo HTML (HTML Workbench)
Ejecutá el siguiente comando de terminal en tu directorio de trabajo para generar `dashboard.html`:

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

##### Paso 1.2: Construir la hoja de estilo
Creá `styles.css` usando el siguiente fragmento de código:

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

##### Paso 1.3: Diagnosticar elementos coincidentes usando CLI Node.js DOM Parser
Para inspeccionar de forma programática las coincidencias de los selectores CSS tal como las evalúan los motores de navegación en pipelines automatizados de linting en CI/CD, ejecutá el siguiente script:

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

##### Salida esperada:
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

##### Preguntas de verificación — Ejercicio 1

1. **Pregunta 1.1**: ¿Por qué `section.metric-card > p` coincide tanto con `<p class="status-text">` como con `<p class="description">`, pero **no** con ninguna etiqueta `<p>` que pudiera estar ubicada dentro de `<div class="node-list">`? Explicá la distinción explícita entre los combinadores de descendiente (` `) e hijo directo (`>`).
2. **Pregunta 1.2**: Si el marcado se altera de modo que `<span class="badge">Active</span>` se coloque directamente entre `node-01` y `node-02`, ¿cuál es el efecto exacto en `div.node-item.primary + div.node-item` frente a `div.node-item.primary ~ div.node-item`?

---

#### Ejercicio 2: Pseudoclases, gestión de estado y consultas estructurales

En este ejercicio, aplicarás pseudoclases para el seguimiento del estado (`:focus`, `:disabled`, `:checked`) y la coincidencia de posición estructural (`:first-child`, `:last-of-type`, `:nth-child(even)`).

##### Paso 2.1: Agregar formulario y controles de componentes al HTML
Actualizá `dashboard.html` agregando un panel de control de nodos interactivo:

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

##### Paso 2.2: Agregar reglas de pseudoclases a la hoja de estilo
Añadí los siguientes selectores de pseudoclase a `styles.css`:

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

##### Paso 2.3: Ejecutar auditoría CLI para coincidencia de selectores de pseudoclases
Validá el direccionamiento de selectores estructurales usando el script CLI de `jsdom`:

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

##### Salida esperada:
```text
Odd items matched:
 - Server 01 - Online
 - Server 03 - Online
 - Server 05 - Online

Disabled button matched:
 - <button type="submit" class="btn btn-primary" disabled="">Deploy Pod</button>
```

---

##### Preguntas de verificación — Ejercicio 2

1. **Pregunta 2.1**: ¿Cuál es la diferencia entre `:nth-child(2)` y `:nth-of-type(2)` al coincidir nodos dentro de un elemento padre que contiene una secuencia mixta de etiquetas `<h1>`, `<p>`, `<div>` y `<p>`?
2. **Pregunta 2.2**: Calculá el vector de especificidad `(a, b, c)` de `:is(#server-list, #control-panel) button:disabled` frente a `:where(#server-list, #control-panel) button:disabled`. ¿Qué regla sobrescribe a la otra?

---

#### Ejercicio 3: Matriz de especificidad, resolución de cascada y perfilado de herencia

En este ejercicio, resolverás escenarios de colisión de estilos, analizarás el impacto de `!important`, inspeccionarás estilos heredados frente a no heredados y usarás herramientas de linting CLI para auditar la especificidad de los selectores.

##### Paso 3.1: Crear archivo de colisión de especificidad
Creá `cascade_test.html` y `cascade.css`:

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

Creá `cascade.css`:

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

##### Paso 3.2: Inspeccionar estilos computados a través del pipeline CLI de Node.js
Ejecutá un cálculo headless de la resolución de estilo del elemento para rastrear la regla de especificidad ganadora:

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

##### Salida esperada:
```text
Resolved color property: yellow
Resolved border property: 1px solid black
```

##### Paso 3.3: Tabla de auditoría del cálculo del vector de especificidad
Analizá los vectores computados para cada regla declarada en `cascade.css`:

| ID de Regla | Selector Objetivo | Componente `a` (IDs) | Componente `b` (Clases/Attrs) | Componente `c` (Elementos) | Vector Total `(a,b,c)` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Rule A** | `a` | 0 | 0 | 1 | `(0, 0, 1)` |
| **Rule B** | `ul.nav-list a` | 0 | 1 | 2 | `(0, 1, 2)` |
| **Rule C** | `.container .nav-item .nav-link` | 0 | 3 | 0 | `(0, 3, 0)` |
| **Rule D** | `#main-nav .nav-item a` | 1 | 1 | 1 | `(1, 1, 1)` |
| **Rule E** | `#wrapper #home-item a` | 2 | 0 | 1 | `(2, 0, 1)` |
| **Rule F** | `.nav-link` (`!important`) | 0 | 1 | 0 | `(0, 1, 0)` + `!important` |
| **Inline** | `style="color: purple;"` | N/A | N/A | N/A | Origen Inline |

---

##### Preguntas de verificación — Ejercicio 3

1. **Pregunta 3.1**: Si la flag `!important` se elimina de la Rule F (`.nav-link { color: yellow; }`), ¿qué regla dicta el color computado final de la etiqueta `<a>`: el estilo en línea `style="color: purple;"` o la Rule E (`#wrapper #home-item a`)? ¿Por qué?
2. **Pregunta 3.2**: Explicá por qué la propiedad `border` declarada en la Rule A se aplica a la etiqueta `<a>`, pero **no** es heredada por ningún elemento hijo colocado dentro de la etiqueta `<a>`, mientras que `font-size` sí es heredada por los elementos hijos a menos que se anule explícitamente.

---

### Soluciones y explicaciones técnicas

<details>
<summary><strong>Hacé clic para expandir las soluciones del Ejercicio 1</strong></summary>

#### Solución 1.1
* **Combinador de hijo directo (`>`)**: Selecciona elementos que son hijos directos e inmediatos del elemento padre especificado en la jerarquía del árbol DOM. `section.metric-card > p` requiere que `<p>` esté directamente adjunto bajo `<section class="metric-card">`.
* **Combinador de descendiente (` ` espacio)**: Recorre hacia abajo cualquier número de niveles de anidación del DOM. Si el selector hubiera sido `section.metric-card p`, coincidiría tanto con los elementos `<p>` hijos directos como con cualquier elemento `<p>` anidado más profundamente dentro de elementos hijos (como `<div class="node-list">`).

#### Solución 1.2
* **Combinador de hermano adyacente (`+`)**: Coincide con un elemento solo si **sigue inmediatamente** al elemento anterior en el mismo nivel jerárquico del DOM. Si se inserta `<span class="badge">` entre `node-01` y `node-02`, `div.node-item.primary + div.node-item` coincidirá con **0 elementos**, porque el elemento inmediatamente posterior a `node-01` es un `<span>`, no un `div.node-item`.
* **Combinador de hermano general (`~`)**: Coincide con todos los elementos que siguen al elemento anterior en el mismo nivel del DOM, independientemente de que haya elementos intermedios que no coincidan. `div.node-item.primary ~ div.node-item` seguirá coincidiendo tanto con `node-02` como con `node-03`.

</details>

<details>
<summary><strong>Hacé clic para expandir las soluciones del Ejercicio 2</strong></summary>

#### Solución 2.1
* **`:nth-child(n)`**: Evalúa la posición relativa a **todos los elementos hermanos** dentro del padre, independientemente del nombre de la etiqueta. Si el segundo hijo de un padre es un `<h1>`, `p:nth-child(2)` no coincidirá si el elemento en el índice 2 no es un `<p>`.
* **`:nth-of-type(n)`**: Filtra la lista de hermanos para incluir **solo elementos del tipo de elemento coincidente (nombre de etiqueta)** antes de aplicar el conteo de índices. `p:nth-of-type(2)` coincide con la segunda etiqueta `<p>` debajo del contenedor padre, ignorando cualquier hermano que no sea `<p>`.

#### Solución 2.2
* **Especificidad de `:is(#server-list, #control-panel) button:disabled`**:
  * `:is()` toma la especificidad de su **argumento selector más específico**.
  * `#server-list` y `#control-panel` tienen cada uno una especificidad de `(1, 0, 0)`.
  * `button` añade `(0, 0, 1)`.
  * `:disabled` añade `(0, 1, 0)`.
  * **Especificidad Total**: `(1, 0, 0) + (0, 0, 1) + (0, 1, 0) = (1, 1, 1)`.

* **Especificidad de `:where(#server-list, #control-panel) button:disabled`**:
  * `:where()` siempre aporta `(0, 0, 0)` de especificidad, reemplazando la especificidad de sus argumentos por cero.
  * `button` añade `(0, 0, 1)`.
  * `:disabled` añade `(0, 1, 0)`.
  * **Especificidad Total**: `(0, 0, 0) + (0, 0, 1) + (0, 1, 0) = (0, 1, 1)`.

* **Resolución**: La regla `:is()` gana sobre la regla `:where()` porque `(1, 1, 1)` invalida estrictamente a `(0, 1, 1)`.

</details>

<details>
<summary><strong>Hacé clic para expandir las soluciones del Ejercicio 3</strong></summary>

#### Solución 3.1
* Si `!important` se elimina de la Rule F, el **estilo en línea** `style="color: purple;"` gana.
* **Orden del motor de precedencia en cascada**:
  1. Las declaraciones `!important` del autor prevalecen sobre los estilos normales del autor y los estilos en línea.
  2. Los estilos en línea especificados a través del atributo `style` de HTML prevalecen sobre las declaraciones normales de las hojas de estilo, independientemente de la especificidad del selector (los estilos en línea prevalecen sobre el `(2, 0, 1)` de la Rule E).
  3. Las declaraciones normales de la hoja de estilo del autor se evalúan mediante el vector de especificidad `(a, b, c)`.
  4. El orden de aparición resuelve los empates.
* Por lo tanto, eliminar `!important` reduce la Rule F a un estado normal de autor `(0, 1, 0)`, permitiendo que prevalezca el origen del estilo en línea.

#### Solución 3.2
* **Propiedades heredadas**: Las propiedades relacionadas con la tipografía y la presentación del texto (`font-size`, `font-family`, `color`, `line-height`) se propagan automáticamente hacia abajo en el árbol DOM hacia los elementos hijos mediante la mecánica de herencia, a menos que el hijo tenga reglas explícitas que las anulen.
* **Propiedades no heredadas**: Las propiedades que rigen el modelo de caja (box model), la geometría del layout, bordes y fondos (`border`, `margin`, `padding`, `display`, `width`, `height`) se aplican estrictamente al nodo del elemento coincidente y **no** se transmiten automáticamente a los nodos hijos, lo que evita roturas visuales accidentales en las cajas de diseño de los hijos.

</details>