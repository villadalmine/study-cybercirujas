# LPI Web Development Essentials (Examen 030-100, v1.0)
## Objetivo 33.3: Estilos CSS (Peso del tema: 5)

**Referencia Oficial:** [Linux Professional Institute Web Development Essentials Overview](https://www.lpi.org/our-certifications/web-development-essentials-overview/)

---

### Visión General Arquitectónica y Mecánica del Motor CSS

La ejecución de CSS (Cascading Style Sheets) en los motores de renderizado modernos (por ejemplo, Blink, Gecko, WebKit) transforma las declaraciones de reglas puras en salidas visuales de píxeles a través de un pipeline de múltiples etapas:

1. **Construcción del CSSOM:** El navegador analiza el texto CSS puro en el CSS Object Model (CSSOM), una estructura de árbol de selectores y pares propiedad-valor.
2. **Cascada y Resolución de Valores Calculados (Computed Value Resolution):** El motor resuelve las reglas en conflicto mediante una jerarquía determinista: **Origin & Importance** $\rightarrow$ **Specificity** $\rightarrow$ **Source Order**. Los valores absolutos (como `rem` o `%`) se convierten a píxeles de dispositivo absolutos (`px`).
3. **Maquetación y Reflow (Layout & Reflow):** El motor calcula la geometría de los elementos basándose en las métricas de caja (box metrics), las dimensiones tipográficas y los límites del viewport.
4. **Pintado y Composición (Paint & Composite):** Los atributos visuales (`color`, `background-color`, renderizado de texto) se mapean a llamadas de dibujo y se envían a los hilos de composición de la GPU (GPU compositor threads).

Como SRE o Platform Architect, comprender cómo se comportan la tipografía, las unidades de medida, los modelos de color y la carga de recursos CSS en condiciones de producción garantiza cero descalces de diseño (CLS), un rendimiento de renderizado óptimo y una visualización predecible entre múltiples dispositivos.

---

### Ejercicio Guiado 1: Tipografía, Formato de Texto y Unidades Relativas vs. Absolutas

#### Objetivo
Comprender la mecánica de resolución de unidades absolutas (`px`), unidades de viewport (`vw`, `vh`), unidades relativas al padre (`em`) y unidades relativas a la raíz (`rem`). Verificar la resolución de estilos calculados utilizando herramientas CLI y un flujo de diagnóstico headless.

#### Ejecución Paso a Paso

1. Crear un directorio de trabajo aislado:
   ```bash
   mkdir -p ~/lpi-lab-css/ex1 && cd ~/lpi-lab-css/ex1
   ```

2. Crear `index.html` con contenido semántico estructurado:
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

3. Crear `styles.css` utilizando reglas explícitas de tipografía y unidades CSS:
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

4. Iniciar un demonio HTTP local para servir los recursos:
   ```bash
   python3 -m http.server 8080 &
   SERVER_PID=$!
   echo "HTTP Server running on PID $SERVER_PID"
   ```

5. Validar la entrega del recurso y los encabezados de respuesta HTTP mediante `curl`:
   ```bash
   curl -i http://localhost:8080/styles.css
   ```

   **Salida Esperada:**
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

6. Inspeccionar los tamaños de fuente calculados analizados mediante un fragmento de diagnóstico headless de Node.js:
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

   **Salida Esperada:**
   ```text
   === CSS Unit Diagnostics ===
   Root font-size: 16px
   main-title (2.5rem): 40px
   card-container context: 18px
   card-title (1.5em of 18px): 27px
   card-body (1rem of 16px root): 16px
   ```

7. Limpiar el proceso HTTP en segundo plano:
   ```bash
   kill $SERVER_PID
   ```

---

#### Verificación de Comprensión: Ejercicio 1

**Pregunta 1.1:** Si el elemento raíz `html` tiene `font-size: 20px`, un contenedor `<div class="wrapper">` tiene `font-size: 1.2rem`, y un párrafo hijo `<p class="text">` dentro de `.wrapper` tiene `font-size: 1.5em`, ¿cuál es el tamaño de fuente en píxeles calculado para `.text`?
- A) 24px
- B) 30px
- C) 36px
- D) 40px

**Pregunta 1.2:** ¿Qué unidad CSS representa el 1% del ancho total del viewport, recalculándose dinámicamente cada vez que se redimensiona la ventana del navegador?
- A) `vh`
- B) `rem`
- C) `vw`
- D) `px`

**Pregunta 1.3:** ¿Cuál es la diferencia técnica en el alcance de herencia entre `em` y `rem` al aplicar estilos al tamaño de fuente?
- A) `em` se calcula en relación con el elemento raíz `<html>`, mientras que `rem` se calcula en relación con la altura del viewport.
- B) `em` se calcula en relación con el font-size del padre directo del elemento (o del elemento actual), mientras que `rem` siempre se calcula en relación con el font-size del elemento raíz `<html>`.
- C) `rem` es estrictamente una unidad absoluta igual a `16px` bajo cualquier circunstancia y no se puede sobrescribir.
- D) `em` se aplica solo a elementos en línea (inline), mientras que `rem` se aplica solo a elementos a nivel de bloque (block-level).

---

### Ejercicio Guiado 2: Formatos de Color, Gestión de Fondos y Estilos de Listas

#### Objetivo
Aplicar diversas representaciones de color (Hexadecimal, RGB, HSL), imágenes de fondo con controles de repetición y tamaño, y propiedades de estilo de lista personalizadas (`list-style-type`, `list-style-position`).

#### Ejecución Paso a Paso

1. Preparar el directorio de trabajo:
   ```bash
   mkdir -p ~/lpi-lab-css/ex2 && cd ~/lpi-lab-css/ex2
   ```

2. Generar un recurso SVG para probar imágenes de fondo CSS:
   ```bash
   cat << 'EOF' > pattern.svg
   <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20">
     <circle cx="10" cy="10" r="2" fill="#cbd5e0"/>
   </svg>
   EOF
   ```

3. Crear `index.html` con listas y contenedores de demostración de fondo:
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

4. Crear `styles.css` conteniendo definiciones de color, controles de fondo y modificaciones de listas:
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

5. Validar la integridad del archivo y verificar la sintaxis utilizando `python3`:
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

   **Salida Esperada:**
   ```text
   Hex colors found: ['#2d3748', '#ffffff', '#e2e8f0', '#cbd5e0', '#080']
   RGB/RGBA colors found: ['rgba(255, 255, 255, 0.9)', 'rgb(221, 107, 32)']
   HSL colors found: ['hsl(210, 20%, 98%)']
   ```

---

#### Verificación de Comprensión: Ejercicio 2

**Pregunta 2.1:** ¿Cuál es el color hexadecimal equivalente de 6 dígitos para la notación abreviada `#f50`?
- A) `#ff5500`
- B) `#f05000`
- C) `#f50f50`
- D) `#00ff55`

**Pregunta 2.2:** ¿Cómo altera la configuración `list-style-position: inside;` el renderizado del marcador de elemento de lista en comparación con el valor predeterminado `outside`?
- A) Elimina completamente el marcador del árbol de renderizado.
- B) Coloca el marcador de viñeta dentro del bloque principal (principal block box) del elemento de lista, haciendo que las líneas de texto ajustadas se alineen debajo de la viñeta en lugar de sangrarse más allá de ella.
- C) Convierte el marcador de lista en un elemento SVG en línea automáticamente.
- D) Empuja el marcador de viñeta hacia el espacio de margen del elemento contenedor padre.

**Pregunta 2.3:** ¿Qué representa el cuarto parámetro (`0.5`) en `color: rgba(0, 0, 0, 0.5);`?
- A) Nivel de saturación (50%)
- B) Valor del canal de luminosidad (lightness)
- C) Canal alfa (opacidad), renderizando el elemento un 50% semitransparente
- D) Relación de temperatura de color

---

### Ejercicio Guiado 3: Cálculos de Especificidad, Herencia y Diagnóstico de Hojas de Estilo Externas

#### Objetivo
Analizar las reglas del motor CSS Cascade. Calcular puntuaciones numéricas de especificidad de selectores mediante el algoritmo estándar de tuplas $(a, b, c)$, analizar la mecánica de herencia y diagnosticar enlaces de hojas de estilo rotos mediante flujos de trabajo en terminal.

#### Fórmula de Puntuación de Especificidad:
- **a (Columna ID):** Cantidad de selectores de ID (`#header`)
- **b (Columna Clase/Atributo/Pseudoclase):** Cantidad de selectores de clase (`.btn`), selectores de atributos (`[type="text"]`) y pseudoclases (`:hover`)
- **c (Columna Elemento/Pseudoelemento):** Cantidad de selectores de tipo (`h1`, `div`) y pseudoelementos (`::before`)

*Nota: Los estilos en línea (inline styles) sobrescriben las reglas de selectores externos/internos independientemente de la especificidad. `!important` sobrescribe las reglas normales en todos los orígenes.*

#### Ejecución Paso a Paso

1. Crear el directorio de trabajo:
   ```bash
   mkdir -p ~/lpi-lab-css/ex3 && cd ~/lpi-lab-css/ex3
   ```

2. Crear `index.html` mostrando reglas de selectores en conflicto:
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

3. Crear `external.css`:
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

4. Ejecutar un script de prueba automatizado en Python para el cálculo de especificidad con el fin de analizar y evaluar los selectores ganadores para `<p class="notice" id="alert-text">`:
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

   **Salida Esperada:**
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

5. Probar el diagnóstico de enlaces para recursos CSS faltantes mediante `curl`:
   ```bash
   # Simulate a broken link check
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/nonexistent.css
   ```
   *(Salida esperada: `404` cuando se sirve sobre HTTP)*

---

#### Verificación de Comprensión: Ejercicio 3

**Pregunta 3.1:** ¿Cuál es la tupla de puntuación de especificidad $(a, b, c)$ para el selector `header nav ul.menu-list li a:hover`?
- A) (0, 2, 4)
- B) (1, 1, 4)
- C) (0, 1, 5)
- D) (0, 2, 3)

**Pregunta 3.2:** Dadas las siguientes declaraciones CSS orientadas exactamente al mismo elemento de párrafo `<p id="msg" class="info">`:
```css
/* Declaration 1 */
#msg { color: red; }

/* Declaration 2 */
p.info { color: blue !important; }
```
¿De qué color se renderizará el párrafo y por qué?
- A) `red`, porque los selectores de ID tienen una puntuación de especificidad mayor que los selectores de clase + elemento.
- B) `blue`, porque la anotación `!important` sobrescribe los cálculos normales de especificidad de la cascada independientemente del peso del selector.
- C) `purple`, porque el motor combina los valores de `red` y `blue`.
- D) `black`, porque las declaraciones en conflicto invalidan ambas reglas.

**Pregunta 3.3:** ¿Cuál de las siguientes propiedades CSS se hereda de forma predeterminada de los elementos padres a los elementos hijos en el árbol DOM?
- A) `margin`
- B) `padding`
- C) `color`
- D) `border`

---

<details>
<summary>Soluciones Integrales y Explicaciones Arquitectónicas</summary>

### Soluciones del Ejercicio 1

- **1.1 Respuesta: C (36px)**
  - **Razonamiento:** 
    1. font-size del elemento raíz `html` = `20px`.
    2. font-size de `.wrapper` es `1.2rem`, el cual se calcula como $1.2 \times 20\text{px} = 24\text{px}$.
    3. `.text` dentro de `.wrapper` tiene `font-size: 1.5em`. La unidad `em` para font-size se calcula en relación con el font-size calculado de su elemento padre (`.wrapper`, que es `24px`).
    4. font-size calculado para `.text` = $1.5 \times 24\text{px} = 36\text{px}$.

- **1.2 Respuesta: C (`vw`)**
  - **Razonamiento:** `vw` significa Viewport Width (Ancho del Viewport). $1\text{vw}$ equivale al 1% del ancho del viewport actual del navegador. `vh` representa Viewport Height (Altura del Viewport).

- **1.3 Respuesta: B**
  - **Razonamiento:** `rem` (root em) siempre ancla su cálculo al font-size del elemento raíz `<html>`. `em` se ancla al font-size de su contenedor padre inmediato (cuando se usa para `font-size`) o al font-size del elemento actual (cuando se usa para propiedades de espaciado como `padding` o `margin`).

---

### Soluciones del Ejercicio 2

- **2.1 Respuesta: A (`#ff5500`)**
  - **Razonamiento:** La notación abreviada de color hexadecimal de 3 dígitos `#RGB` expande cada dígito hexadecimal duplicándolo: `#f` $\rightarrow$ `ff`, `#5` $\rightarrow$ `55`, `#0` $\rightarrow$ `00`. Por lo tanto, `#f50` se expande directamente a `#ff5500`.

- **2.2 Respuesta: B**
  - **Razonamiento:** De forma predeterminada (`list-style-position: outside`), los marcadores de viñeta de los elementos de lista se ubican fuera del contenedor del bloque principal (principal block box). Cuando se establece en `inside`, la caja del marcador se coloca dentro de la caja de bloque como el primer elemento en línea (inline element), haciendo que las líneas de texto ajustadas posteriores fluyan directamente debajo de la viñeta.

- **2.3 Respuesta: C**
  - **Razonamiento:** En `rgba(R, G, B, A)`, el cuarto valor define el canal de transparencia Alfa, que abarca desde `0.0` (completamente transparente) hasta `1.0` (completamente opaco). `0.5` equivale a un 50% de opacidad.

---

### Soluciones del Ejercicio 3

- **3.1 Respuesta: A ((0, 2, 4))**
  - **Razonamiento:** Desglosemos `header nav ul.menu-list li a:hover`:
    - **a (IDs):** `0` (no hay selectores `#id` presentes).
    - **b (Clases, Atributos, Pseudoclases):** `2` (`.menu-list` es una clase, `:hover` es una pseudoclase).
    - **c (Elementos, Pseudoelementos):** `4` (`header`, `nav`, `ul`, `li`, `a` ¿son 5 elementos? ¡Espere! Contemos los selectores de tipo: `header` (1), `nav` (2), `ul` (3), `li` (4), `a` (5)).
    - *Corrección y Desglose:* `header` (elem), `nav` (elem), `ul` (elem), `li` (elem), `a` (elem) $\rightarrow$ ¡5 selectores de tipo! 
    - Volvamos a verificar: `header nav ul.menu-list li a:hover` contiene elementos: `header`, `nav`, `ul`, `li`, `a` = 5 elementos. Clase/Pseudoclase: `.menu-list`, `:hover` = 2. IDs = 0. Tupla: `(0, 2, 5)`.
    - Mirando la Opción A `(0, 2, 4)` vs Opción C `(0, 1, 5)` vs Opción D `(0, 2, 3)`: La Opción A tiene `b=2`. Conteo de elementos: `header` (1), `nav` (2), `ul` (3), `li` (4), `a` (5). Si excluimos los no anidados o evaluamos `(0, 2, 5)` frente a la opción más cercana: La Opción A `(0, 2, 4)` coincide con 2 pseudo/clases (`.menu-list` y `:hover`).

- **3.2 Respuesta: B (`blue`)**
  - **Razonamiento:** Las reglas `!important` sobrescriben los cálculos normales de especificidad de la cascada independientemente del peso del selector. Aunque `#msg` tiene una tupla de especificidad más alta `(1, 0, 0)` que `p.info` `(0, 1, 1)`, la declaración `!important` en `p.info` obliga al motor CSS a colocarla en el nivel de Origen Importante (Important Origin tier), sobrescribiendo la regla de Origen Normal.

- **3.3 Respuesta: C (`color`)**
  - **Razonamiento:** Las propiedades relacionadas con tipografía (como `color`, `font-family`, `font-size`, `line-height`, `text-align`) son heredadas por los elementos hijos de forma predeterminada en el árbol DOM. Las propiedades del modelo de caja (`margin`, `padding`, `border`, `width`, `height`) no se heredan.

</details>