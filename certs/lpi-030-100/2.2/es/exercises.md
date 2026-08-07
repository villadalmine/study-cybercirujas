# LPI Web Development Essentials (Exam 030-100, v1.0)
## Topic 2.2: HTML Semantics and Document Hierarchy (Weight: 5)

---

### Technical Architecture & Deep Dive: DOM & Accessibility Tree Construction

Los motores de renderizado web modernos (ej., Blink, Gecko) convierten los flujos binarios de HTML crudo en dos estructuras jerárquicas principales:
1. **Document Object Model (DOM) Tree**: Representa el diseño estructural y programático del documento.
2. **Accessibility Tree (Accessibility Object Model / AOM)**: Derivado directamente del DOM tree, exponiendo roles, estados y propiedades a tecnologías asistivas (screen readers como NVDA, VoiceOver, JAWS) y web crawlers (indexadores SEO).

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
- **Document Structure**: `<!DOCTYPE html>` desencadena el parseo estándar en standards-mode (previniendo el quirks mode). `<html>` sirve como el elemento raíz, con `lang` proporcionando contexto de idioma para la fonética de screen readers y la indexación de motores de búsqueda.
- **Landmark Elements**:
  - `<header>`: Se mapea a `role="banner"` cuando su alcance es `<body>`. Representa la marca global de la página o la navegación de nivel superior.
  - `<nav>`: Se mapea a `role="navigation"`. Se utiliza para grupos de enlaces primarios, secundarios o de paginación.
  - `<main>`: Se mapea a `role="main"`. Debe ser único por vista de documento renderizada (contiene el contenido principal).
  - `<article>`: Se mapea a `role="article"`. Representa contenido autónomo e independientemente distribuible (ej., publicación de blog, noticia, comentario de foro).
  - `<section>`: Elemento de seccionamiento genérico. Crea un agrupamiento lógico de contenido, idealmente con un encabezado (`<h1>`-`<h6>`). Se mapea a `role="region"` solo cuando se le da explícitamente un nombre accesible (`aria-labelledby` o `aria-label`).
  - `<aside>`: Se mapea a `role="complementary"`. Mantiene contenido secundario relacionado con el contexto principal (ej., barras laterales, cuadros de llamada, artículos relacionados).
  - `<footer>`: Se mapea a `role="contentinfo"` cuando su alcance es `<body>`. Contiene metadatos, copyright, enlaces de privacidad e información de contacto.
  - `<figure>` & `<figcaption>`: Encapsula medios, listados de código o diagramas con una etiqueta explícita. Se mapea a `role="figure"`.
- **Non-Semantic Wrappers**:
  - `<div>`: Contenedor de flujo de nivel de bloque genérico sin significado semántico (`role="generic"`).
  - `<span>`: Contenedor de flujo en línea genérico sin significado semántico.

---

### Guided Exercise 1: Constructing a Production-Grade HTML5 Document Hierarchy & Validating Accessibility Landmarks

#### Objective
Construir un documento HTML5 completamente semántico y en conformidad con los estándares, e inspeccionar su DOM y landmark roles utilizando herramientas CLI.

#### Environment Setup & Execution Steps

1. Crear un directorio de proyecto y generar `index.html` utilizando un único comando `cat` multilínea:

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

2. Validar la conformidad con W3C HTML5 usando `npx html-validate` o herramientas de validación basadas en Python:

```bash
npx --yes html-validate index.html
```

*Expected CLI Output:*
```text
index.html: clean (0 errors, 0 warnings)
```

3. Parsear y extraer landmark elements usando `node` y `jsdom` para verificar el diseño del DOM tree:

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

1. En el documento generado anteriormente, hay dos etiquetas `<header>` presentes. ¿El tener múltiples elementos `<header>` viola la semántica de HTML5 o los estándares de accesibilidad? Explicá las diferencias de alcance contextual.
2. ¿Por qué es vital incluir `aria-label="Primary Navigation"` en el elemento `<nav>` cuando pueden existir múltiples regiones de navegación en una aplicación web a escala empresarial?

---

### Guided Exercise 2: Heading Hierarchy, DOM Outline, and Semantic vs. Non-Semantic (`div`/`span`) Structuring

#### Objective
Comprender los niveles de encabezado (`<h1>`-`<h6>`), evitar la omisión de niveles de encabezado y comparar un diseño genérico de `div`-soup con una jerarquía DOM semántica para el parseo de screen readers.

#### Execution Steps

1. Crear un script llamado `validate_outline.js` para inspeccionar la continuidad y jerarquía de los niveles de encabezados:

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

2. Crear un contraejemplo no semántico `bad_practice.html` y ejecutar la auditoría contra él:

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

1. ¿Cuál es el impacto para los usuarios de screen readers (ej., navegación por rotor) cuando los niveles de encabezado saltan de `<h4>` directamente a `<h6>` sin un `<h5>` intermedio?
2. Un desarrollador utiliza `<div class="button" onclick="submitForm()">Submit</div>` en lugar de `<button type="submit">Submit</button>`. ¿Qué capacidades nativas de HTML y características de accesibilidad se pierden al utilizar `<div>`?

---

### Guided Exercise 3: Encapsulating Media with `<figure>` / `<figcaption>` & Sectioning Algorithms

#### Objective
Implementar representación semántica de medios con `<figure>` y `<figcaption>`, usar elementos adecuados de formato semántico de texto (`<time>`, `<code>`, `<mark>`), y verificar su vinculación semántica.

#### Execution Steps

1. Actualizar `index.html` para incluir un bloque de código y un diagrama arquitectónico encapsulados dentro de etiquetas `<figure>`:

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

2. Ejecutar un script de verificación en Node.js para validar que `<figcaption>` está asociado correctamente con su `<figure>` primario:

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

1. ¿Puede un elemento `<figure>` contener contenido distinto a gráficos/imágenes (ej., fragmentos de código, tablas de datos, citas)? ¿Cuál es la regla semántica principal que rige a `<figure>`?
2. ¿En qué lugar dentro de un contenedor `<figure>` se puede posicionar legalmente `<figcaption>` según las especificaciones de W3C HTML5?

---

<details>
<summary>Answers and Detailed Rationales</summary>

### Exercise 1 Answers

1. **Validez de múltiples elementos `<header>`**:
   - **Respuesta**: Sí, tener múltiples etiquetas `<header>` es **completamente válido** en HTML5.
   - **Justificación técnica**: El alcance semántico de `<header>` depende de su contenedor primario:
     - Cuando es hijo de `<body>`, `<header>` representa el encabezado global de la página (implícitamente `role="banner"`).
     - Cuando está dentro de elementos de seccionamiento como `<article>` o `<section>`, `<header>` representa el encabezado específico para esa sección/artículo. En este contexto, *no* se mapea a `role="banner"`, evitando conflictos de top-level landmarks.

2. **Importancia de `aria-label` en `<nav>`**:
   - **Respuesta**: Distingue múltiples navigation landmarks para usuarios de tecnologías asistivas.
   - **Justificación técnica**: Cuando una página contiene múltiples elementos `<nav>` (ej., navegación del encabezado principal, tabla de contenidos de la barra lateral, enlaces legales del pie de página), los screen readers listan todos los landmarks `role="navigation"` en un menú de rotor del screen reader. Sin `aria-label` o `aria-labelledby`, los screen readers anuncian cada uno simplemente como "navegación", creando ambigüedad. Etiquetarlos ("Primary Navigation", "Footer Navigation") permite una identificación inmediata.

---

### Exercise 2 Answers

1. **Impacto de omitir niveles de encabezado (`<h4>` a `<h6>`)**:
   - **Respuesta**: Quiebra la jerarquía lógica del documento, confunde la navegación de los screen readers y degrada la conformidad de accesibilidad (WCAG 2.1 SC 1.3.1 Información y Relaciones).
   - **Justificación técnica**: Los usuarios de screen readers navegan con frecuencia por los documentos saltando entre niveles de encabezados (ej., presionando `H` o las teclas numéricas del `1` al `6` en NVDA/JAWS). Saltarse de `h4` a `h6` hace que los usuarios sospechen que falta contenido o que se perdieron una sección primaria `h5`.

2. **Pérdida de características al usar `<div class="button">` en lugar de `<button>`**:
   - **Respuesta**: Se pierden la capacidad nativa de foco por teclado, los disparadores por teclado por defecto, la integración con formularios, los roles del accessibility tree y la gestión de estado.
   - **Justificación técnica**:
     - **Keyboard Focus**: `<button>` se incluye nativamente en el orden secuencial de navegación por foco (`tabindex="0"`). Un `<div>` no recibe foco por defecto.
     - **Keyboard Event Handling**: `<button>` dispara manejadores `click` tanto al presionar las teclas `Enter` como `Space` de forma nativa. Un `<div>` requiere manejadores JavaScript `keydown`/`keyup` personalizados.
     - **Accessibility Tree**: `<button>` expone `role="button"` al AOM automáticamente. Un `<div>` expone `role="generic"`, ocultando su propósito interactivo a los screen readers a menos que se parche explícitamente con `role="button"` y `tabindex="0"`.

---

### Exercise 3 Answers

1. **Contenido permitido dentro de `<figure>`**:
   - **Respuesta**: Sí, `<figure>` puede encapsular ejemplos de código, ecuaciones matemáticas, clips de audio, diagramas SVG, tablas de datos o citas en bloque.
   - **Justificación técnica**: La especificación define `<figure>` como contenido autónomo, opcionalmente con un epígrafe o leyenda (caption), que se referencia como una unidad única desde el flujo principal. El requisito clave es que mover el `<figure>` a un apéndice u otra ubicación no afecte el flujo lógico del texto principal circundante.

2. **Posición permitida de `<figcaption>`**:
   - **Respuesta**: `<figcaption>` debe colocarse como el **primer hijo** o el **último hijo** dentro del elemento `<figure>`.
   - **Justificación técnica**: La especificación de W3C HTML prohíbe colocar `<figcaption>` en medio de otros nodos hijos dentro de `<figure>`. Sirve como un encabezado de leyenda (primer elemento) o un pie de leyenda (último elemento) del bloque figure.

</details>

---

### Official Reference Sources
- LPI Web Development Essentials Certification Overview: https://www.lpi.org/our-certifications/web-development-essentials-overview/
- HTML Living Standard - Document structures & Semantics: https://html.spec.whatwg.org/multipage/dom.html#elements-in-the-dom
- HTML Living Standard - Sections and Landmarks: https://html.spec.whatwg.org/multipage/sections.html
- W3C ARIA Authoring Practices Guide (Landmark Roles): https://www.w3.org/WAI/ARIA/apg/patterns/landmarks/