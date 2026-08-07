# LPI 030-100 Tema 3.1: Conceptos Básicos de CSS — Arquitectura de Nivel de Producción y Ejercicios Guiados

**Módulo del Examen:** LPI Web Development Essentials (Examen 030-100, Versión 1.0)  
**Tema:** Tema 3.1 Conceptos Básicos de CSS  
**Ponderación del Examen:** 2.5  

---

## 1. Referencias Oficiales
* **LPI Web Development Essentials Overview:** [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* **W3C CSS Syntax Module Level 3:** [https://www.w3.org/TR/css-syntax-3/](https://www.w3.org/TR/css-syntax-3/)
* **W3C Cascading and Inheritance Level 4:** [https://www.w3.org/TR/css-cascade-4/](https://www.w3.org/TR/css-cascade-4/)
* **MDN Web Docs — CSS Specificity:** [https://developer.mozilla.org/en-US/docs/Web/CSS/Specificity](https://developer.mozilla.org/en-US/docs/Web/CSS/Specificity)

---

## 2. Descripción General de la Arquitectura y Mecánica del Motor

### 2.1 Pipeline de Parseo: Construcción del DOM y CSSOM
Cuando un motor de navegador (ej., Blink, Gecko) renderiza un documento web, el procesamiento sigue dos flujos paralelos antes de la composición:

```
HTML Stream ---> HTML Parser ---> Document Object Model (DOM) \
                                                               ===> Render Tree ---> Layout ---> Paint
CSS Stream  ---> CSS Parser  ---> CSS Object Model (CSSOM)   /
```

1. **Tokenización y Construcción de Árbol:** El parser de CSS recibe bytes crudos, los decodifica (típicamente UTF-8), tokeniza el flujo de entrada en tokens (`IDENT`, `AT-KEYWORD`, `DELIM`, `HASH`, `STRING`, `COLON`, `SEMICOLON`), y construye el **CSS Object Model (CSSOM)**.
2. **Adjunto al Render Tree:** El navegador calcula las reglas coincidentes para cada elemento DOM evaluando el CSSOM contra los nodos DOM. Los nodos del Render Tree contienen solo métricas visuales visibles (los nodos con `display: none` se omiten del Render Tree, mientras que los nodos con `visibility: hidden` permanecen).
3. **Impacto en la Ruta de Renderizado Crítica (Critical Rendering Path - CRP):** Las hojas de estilo externas (`<link rel="stylesheet">`) son **bloqueantes para el renderizado (render-blocking)** por defecto. Hasta que el árbol CSSOM esté completamente construido, el motor pausa el layout y pintura del DOM para evitar repintados y reordenamientos excesivos (Flash of Unstyled Content - FOUC).

### 2.2 El Algoritmo del Motor de Cascada
La cascada determina el valor único ganador para una propiedad CSS entre múltiples reglas de hojas de estilo que compiten. El orden de resolución ocurre en pasos estrictamente secuenciales de prioridad:

1. **Origen e Importancia:**
   * Declaraciones de transición (`transition`)
   * User Agent `!important`
   * User `!important`
   * Author `!important`
   * Declaraciones de animación (`@keyframes`)
   * Author normal (`styles.css`, inline styles)
   * User normal (extensiones de navegador/hojas de estilo de usuario)
   * User Agent normal (hojas de estilo por defecto del navegador)
2. **Comparación de Vector de Especificidad:** Si los orígenes e importancia son iguales, la regla con el puntaje de especificidad más alto gana.
3. **Orden de Aparición:** Si los vectores de especificidad son idénticos, la regla declarada al **final** en el orden de parseo gana.

### 2.3 Vector de Cálculo de Especificidad `(a, b, c, d)`
La especificidad se calcula como una tupla de 4 componentes `(a, b, c, d)` comparando valores de izquierda a derecha:

$$\text{Specificity} = (a,\, b,\, c,\, d)$$

* **Posición $a$ (Inline Styles):** Presencia del atributo `style=""` dentro de los elementos HTML ($a=1$).
* **Posición $b$ (Selectores de ID):** Conteo de selectores `#id` en el selector compuesto.
* **Posición $c$ (Clases, Atributos, Seudoclases):** Conteo de `.class`, `[attr=val]`, y `:hover` / `:first-child` / `:nth-child()`. *(Nota: `:not()`, `:is()`, y `:has()` no agregan especificidad por sí mismos, pero los selectores de sus argumentos sí lo hacen. `:where()` siempre aporta `(0,0,0,0)`)*.
* **Posición $d$ (Elementos y Seudoelementos):** Conteo de etiquetas HTML (`div`, `p`, `h1`) y seudoelementos (`::before`, `::after`).
* **Ignorados:** Selector universal `*`, combinadores (`+`, `>`, `~`, ` `), y envolturas de seudoclases en línea como `:where()`.

---

## 3. Ejercicios Guiados Prácticos

### Ejercicio 1: Estrategias de Integración de CSS, Integridad de Sintaxis y Diagnósticos de Linter por CLI

#### Escenario
Estás desplegando un pipeline de assets para una aplicación web. Necesitas establecer métodos de inclusión de CSS válidos (Inline, Interno y Externo) y validar tu sintaxis de CSS frente a estándares de linting de producción utilizando herramientas automatizadas por CLI.

#### Paso 1.1: Crear la Estructura del Proyecto
Ejecutá los siguientes comandos en tu terminal para configurar el espacio de trabajo:

```bash
mkdir -p ~/lpi-css-lab/css ~/lpi-css-lab/config
cd ~/lpi-css-lab
```

#### Paso 1.2: Construir la Hoja de Estilo Externa
Creá `css/styles.css` utilizando tu editor de texto o comandos estándar de shell:

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

#### Paso 1.3: Construir el Documento HTML
Creá `index.html` haciendo referencia a CSS externo, un bloque `<style>` interno y estilos inline:

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

#### Paso 1.4: Configurar la Validación Automatizada con StyleLint
Creá un archivo `package.json` mínimo y un archivo de configuración de Stylelint para verificar la integridad de la sintaxis de CSS a través de CLI:

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

#### Paso 1.5: Ejecutar la Validación de Sintaxis y Estilo a través de Node/NPM CLI
Instalá las dependencias y ejecutá stylelint sobre el archivo CSS externo:

```bash
npm install --silent
npx stylelint "css/styles.css"
```

*Salida Esperada:*
```text
(No output is returned when zero syntax errors or lint violation warnings exist. Return code is 0).
```

Verificá el código de salida:
```bash
echo $?
```
*Salida Esperada:*
```text
0
```

#### Paso 1.6: Validar la Carga de Recursos a través de un Servidor Web Local
Iniciá un servidor HTTP local para verificar el comportamiento de los encabezados y la carga del CSS:

```bash
npx http-server -p 8080 . &
SERVER_PID=$!
sleep 2
curl -I http://localhost:8080/css/styles.css
kill $SERVER_PID
```

*Salida Esperada:*
```http
HTTP/1.1 200 OK
Content-Type: text/css; charset=UTF-8
Content-Length: 377
...
```

---

### Preguntas de Verificación — Bloque 1

1. **¿Cuál es la principal desventaja arquitectónica de usar inline styles (`style="..."`) sobre hojas de estilo externas (`<link rel="stylesheet">`) en aplicaciones en producción?**
   * A) Los inline styles causan fallas de parseo de sintaxis en validadores estrictos de HTML5.
   * B) Los inline styles rompen la separación de incumbencias (separation of concerns), no pueden ser cacheados independientemente por los navegadores y duplican la carga útil (payload) a través de los nodos del DOM.
   * C) Los inline styles no pueden sobrescribir reglas definidas en archivos CSS externos.
   * D) Los inline styles causan que el navegador construya el CSSOM de forma síncrona antes de construir el DOM.

2. **¿Qué combinación de elemento HTML y atributos importa correctamente una hoja de estilo CSS externa mientras indica su rol al parser del navegador?**
   * A) `<script src="css/styles.css" type="text/css"></script>`
   * B) `<style href="css/styles.css" rel="stylesheet"></style>`
   * C) `<link rel="stylesheet" href="css/styles.css">`
   * D) `<import type="stylesheet" file="css/styles.css">`

---

### Ejercicio 2: Cálculo de Vectores de Especificidad y Resolución de Cascada en Producción

#### Escenario
Te encontrás con declaraciones de estilo en conflicto en un código base legacy de CSS. Necesitás calcular Vectores de Especificidad exactos $(a, b, c, d)$, analizar la resolución por orden de aparición y refactorizar las reglas de manera determinista sin recurrir a `!important`.

#### Paso 2.1: Analizar la Estructura del Documento en Conflicto
Creá `specificity-lab.html`:

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

#### Paso 2.2: Calcular los Puntajes de Especificidad Manualmente
Calculá el vector de especificidad $(a, b, c, d)$ para cada regla que coincida con `<p id="target-paragraph" class="article-text" data-priority="high">`:

* **Regla 1 (`p`):**
  * $a$ (inline): 0
  * $b$ (IDs): 0
  * $c$ (clases/atributos/seudoclases): 0
  * $d$ (elementos): 1 (`p`)
  * **Vector:** `(0, 0, 0, 1)`

* **Regla 2 (`.article-text`):**
  * $a$: 0, $b$: 0, $c$: 1 (`.article-text`), $d$: 0
  * **Vector:** `(0, 0, 1, 0)`

* **Regla 3 (`#main-content p.article-text`):**
  * $a$: 0, $b$: 1 (`#main-content`), $c$: 1 (`.article-text`), $d$: 1 (`p`)
  * **Vector:** `(0, 1, 1, 1)`

* **Regla 4 (`div#main-content .article-text[data-priority="high"]`):**
  * $a$: 0, $b$: 1 (`#main-content`), $c$: 2 (`.article-text`, `[data-priority="high"]`), $d$: 1 (`div`)
  * **Vector:** `(0, 1, 2, 1)`

* **Regla 5 (`div#main-content p`):**
  * $a$: 0, $b$: 1 (`#main-content`), $c$: 0, $d$: 2 (`div`, `p`)
  * **Vector:** `(0, 1, 0, 2)`

#### Paso 2.3: Determinar la Regla Ganadora
Comparando vectores de izquierda a derecha:
1. Componente $a$: Todas las reglas tienen $a = 0$.
2. Componente $b$: Las Reglas 3, 4 y 5 tienen $b = 1$ (más alto que las Reglas 1 y 2 donde $b = 0$).
3. Componente $c$ entre los candidatos restantes (Reglas 3, 4, 5):
   * Regla 3: $c = 1$
   * Regla 4: $c = 2$
   * Regla 5: $c = 0$
4. **La Regla 4 gana** con `(0, 1, 2, 1)`. El color de texto renderizado en pantalla será **orange**.

#### Paso 2.4: Validar la Matemática de Vectores de Especificidad a través de la Ejecución Headless de Node
Escribí un script rápido de Node para inspeccionar programáticamente la especificidad del selector usando una simulación de cálculo de parseo de código abierto:

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

*Salida Esperada:*
```text
p                                                       => (0, 0, 0, 1)
.article-text                                           => (0, 0, 1, 0)
#main-content p.article-text                            => (0, 1, 1, 1)
div#main-content .article-text[data-priority="high"]    => (0, 1, 2, 1)
div#main-content p                                      => (0, 1, 0, 2)
```

---

### Preguntas de Verificación — Bloque 2

3. **Dadas dos reglas de CSS que coinciden con exactamente el mismo elemento:**
   * Rule A: `body #wrapper ul.nav-list li a:hover`
   * Rule B: `html body div#wrapper header nav ul li a.active`
   **¿Qué regla tiene mayor especificidad?**
   * A) La Rule A con puntaje `(0, 1, 2, 3)` supera a la Rule B con puntaje `(0, 1, 1, 5)`.
   * B) La Rule B con puntaje `(0, 1, 1, 5)` supera a la Rule A porque tiene más selectores de elemento.
   * C) Ambas reglas empatan con igual especificidad.
   * D) La Rule A con puntaje `(0, 1, 3, 3)` supera a la Rule B con puntaje `(0, 1, 1, 5)`.

4. **Si la Rule X tiene una especificidad de `(0, 0, 2, 1)` y se declara en la línea 10 de `styles.css`, mientras que la Rule Y tiene una especificidad de `(0, 0, 2, 1)` y se declara en la línea 45 de `styles.css`, ¿qué valor aplicará el motor del navegador?**
   * A) Rule X porque las reglas anteriores tienen precedencia en el orden de carga del DOM.
   * B) Rule Y porque cuando la especificidad es igual, el orden de aparición determina la precedencia (la última regla definida gana).
   * C) Ninguna; la especificidad igual genera una advertencia de parseo y los estilos se ignoran.
   * D) El navegador elige aleatoriamente según la secuencia de recorrido del árbol CSSOM.

---

### Ejercicio 3: Herencia de Propiedades, Mecánica de Palabras Clave Initial/Unset e Inspección con DevTools

#### Escenario
No todas las propiedades CSS se heredan automáticamente hacia abajo en el árbol DOM. Debés configurar propiedades heredadas vs no heredadas, controlar los límites de la cascada utilizando palabras clave explícitas de CSS (`inherit`, `initial`, `unset`), y verificar los resultados de estilos calculados (computed styles).

#### Paso 3.1: Crear el Entorno de Prueba de Herencia
Creá `inheritance-lab.html`:

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

#### Paso 3.2: Verificación Programática de Valores Calculados (Computed Values)
Creá un script de Node usando `jsdom` (o emulación del motor DOM estándar) para inspeccionar los estilos calculados finales a través de los límites heredados:

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

*Salida Esperada:*
```text
=== COMPUTED STYLE DIAGNOSTIC LOG ===
Parent Box:            { color: 'rgb(11, 94, 215)', fontFamily: 'monospace', borderTopStyle: 'solid', paddingTop: '20px' }
Child 1 (Default):     { color: 'rgb(11, 94, 215)', fontFamily: 'monospace', borderTopStyle: 'none', paddingTop: '0px' }
Child 2 (Forced):      { color: 'rgb(11, 94, 215)', fontFamily: 'monospace', borderTopStyle: 'solid', paddingTop: '20px' }
```

---

### Preguntas de Verificación — Bloque 3

5. **¿Qué grupo consiste exclusivamente en propiedades CSS naturalmente HEREDADAS (INHERITED)?**
   * A) `margin`, `padding`, `border`, `background-color`
   * B) `color`, `font-family`, `line-height`, `text-align`
   * C) `width`, `height`, `display`, `position`
   * D) `top`, `flex-direction`, `opacity`, `overflow`

6. **¿Cuál es la distinción funcional exacta entre las palabras clave de CSS `initial` e `inherit` cuando se aplican a una propiedad de un elemento?**
   * A) `initial` copia el valor del elemento padre HTML directo, mientras que `inherit` restablece el valor a `#000000`.
   * B) `initial` restablece la propiedad al valor definido por defecto en la especificación W3C para esa propiedad, mientras que `inherit` fuerza explícitamente a la propiedad a tomar el valor calculado (computed value) de su nodo padre.
   * C) `initial` fuerza a la propiedad a usar la definición del archivo CSS externo, mientras que `inherit` fuerza las reglas internas de `<style>`.
   * D) No hay diferencia funcional; ambas palabras clave se comportan de manera idéntica en los navegadores modernos.

---

## 4. Soluciones y Respuestas

<details>
<summary><strong>Hacé clic para desplegar las soluciones a las preguntas de verificación</strong></summary>

### Pregunta 1
* **Respuesta Correcta:** **B**
* **Explicación Detallada:** Los inline styles duplican las declaraciones CSS dentro de elementos HTML individuales, violando el principio arquitectónico de separación de incumbencias (HTML para estructura, CSS para presentación). Dado que los inline styles se incrustan directamente dentro del flujo de marcado HTML, los navegadores no pueden cachearlos como respuestas HTTP de assets estáticos independientes (a diferencia de los archivos `.css` servidos con encabezados `Cache-Control` de larga duración). Además, los inline styles requieren editar manualmente cada elemento HTML para realizar ajustes de estilo globales.
* **Por qué las otras son incorrectas:** 
  * La A es incorrecta porque el CSS inline es sintaxis válida en HTML5 cuando se ubica dentro del atributo `style`.
  * La C es incorrecta porque los inline styles tienen una posición en el vector de especificidad de $a=1$, lo que les permite sobrescribir selectores CSS externos normales.
  * La D es incorrecta porque los inline styles no alteran la secuencia del orden de ejecución del parser de DOM/CSSOM.

---

### Pregunta 2
* **Respuesta Correcta:** **C**
* **Explicación Detallada:** El método estándar y sintácticamente válido para incluir una hoja de estilo externa en HTML5 es a través de la etiqueta vacía `<link>` ubicada dentro del `<head>` del documento. Requiere dos atributos principales: `rel="stylesheet"` (que define la relación entre el documento HTML y el recurso enlazado) y `href="path/to/file.css"` (que especifica la ubicación URL del archivo CSS).
* **Por qué las otras son incorrectas:** 
  * La A usa incorrectamente `<script>` (reservado para la ejecución de JavaScript).
  * La B usa incorrectamente `<style>` con un atributo `href` (la etiqueta `<style>` se usa exclusivamente para declaraciones CSS internas de bloque, no para referencias a archivos externos).
  * La D usa `<import>`, que no es un elemento HTML válido.

---

### Pregunta 3
* **Respuesta Correcta:** **A**
* **Explicación Detallada:** Calculemos el vector de especificidad $(a, b, c, d)$ para ambas reglas:
  * **Rule A (`body #wrapper ul.nav-list li a:hover`):**
    * $a$ (inline): `0`
    * $b$ (IDs): `1` (`#wrapper`)
    * $c$ (clases, atributos, seudoclases): `2` (`.nav-list`, `:hover`)
    * $d$ (elementos): `4` (`body`, `ul`, `li`, `a`)
    * **Vector A:** `(0, 1, 2, 4)`
  * **Rule B (`html body div#wrapper header nav ul li a.active`):**
    * $a$ (inline): `0`
    * $b$ (IDs): `1` (`#wrapper`)
    * $c$ (clases, atributos, seudoclases): `1` (`.active`)
    * $d$ (elementos): `7` (`html`, `body`, `div`, `header`, `nav`, `ul`, `li`, `a`)
    * **Vector B:** `(0, 1, 1, 7)`

  Comparando de izquierda a derecha: $a$ empata en `0`, $b$ empata en `1`. En la posición $c$, Rule A tiene `2` mientras que Rule B tiene `1`. Como `2 > 1`, Rule A gana independientemente de cuántos selectores de elemento tenga Rule B en la posición $d$.

---

### Pregunta 4
* **Respuesta Correcta:** **B**
* **Explicación Detallada:** El algoritmo de evaluación de la Cascada de CSS procesa las reglas coincidentes en un orden estricto:
  1. Origen e Importancia
  2. Especificidad
  3. Orden de Aparición

  Cuando dos selectores que coinciden con el mismo elemento dan como resultado Vectores de Especificidad idénticos (en este caso, ambos son `(0, 0, 2, 1)`), el empate se rompe por el **Orden de Aparición**. La regla definida más adelante en el flujo de estilos parseado (línea 45) sobrescribe la regla definida anteriormente (línea 10).

---

### Pregunta 5
* **Respuesta Correcta:** **B**
* **Explicación Detallada:** Las propiedades CSS textuales y tipográficas —como `color`, `font-family`, `font-size`, `font-weight`, `line-height`, `text-align`, `letter-spacing` y `visibility`— se heredan naturalmente desde los elementos DOM padres hacia sus hijos por defecto según la especificación de CSS. Las propiedades de layout, modelo de caja, tamaño y posicionamiento (`margin`, `padding`, `border`, `background-color`, `width`, `height`, `display`, `position`, `flex`, `grid`) no son heredadas.

---

### Pregunta 6
* **Respuesta Correcta:** **B**
* **Explicación Detallada:** 
  * `initial`: Establece el valor de la propiedad al valor por defecto explícito definido en la especificación W3C CSS para esa propiedad específica (por ejemplo, `color` por defecto es `black` o texto de lienzo definido por la implementación, `display` por defecto es `inline`, `border-style` por defecto es `none`).
  * `inherit`: Instruye explícitamente al motor de CSS a recorrer hacia arriba hasta el padre del elemento en el árbol DOM y copiar su valor calculado (computed value) para esa propiedad, sobrescribiendo los comportamientos por defecto de no herencia.

</details>