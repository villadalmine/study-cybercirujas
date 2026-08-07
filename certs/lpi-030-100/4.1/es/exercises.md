# Study Guide & Production Hands-On Labs: LPI Web Development Essentials (Exam 030-100)

## Tema 4.1: JavaScript Execution y Sintaxis
**Peso del Examen:** 2.5  
**Audiencia Objetivo:** SREs, Platform Engineers y Web Architects que buscan una comprensión profunda en tiempo de ejecución a nivel de producción y el dominio de la certificación LPI 030-100.

---

### Arquitectura de Referencia y Especificaciones Oficiales
* **Objetivos de LPI Web Development Essentials:** [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* **Especificación del Lenguaje ECMA-262 ECMAScript:** [https://tc39.es/ecma262/](https://tc39.es/ecma262/)
* **MDN Gramática y Tipos de JavaScript:** [https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Grammar_and_types](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Grammar_and_types)
* **Visión General de la Arquitectura del Motor V8 JavaScript:** [https://v8.dev/blog/10-years](https://v8.dev/blog/10-years)

---

### 1. Arquitectura Interna del Motor y Mecánica de Ejecución

Los motores modernos de JavaScript (como Google V8 en Chrome/Node.js, SpiderMonkey en Firefox y JavaScriptCore en Safari) ejecutan el código fuente a través de un pipeline de compilación multietapa:

```
[ JavaScript Source Code ]
           │
           ▼
     [ Scanner / Lexer ] ──► (Tokens)
           │
           ▼
      [ Parser ] ──► (Abstract Syntax Tree / AST)
           │
           ▼
  [ Ignition Interpreter ] ──► (Bytecode Execution)
           │
           ▼ (Hot Code Profiling)
  [ TurboFan JIT Compiler ] ──► (Optimized Native Machine Code)
```

1. **Análisis Léxico y Parsing:** El motor convierte los caracteres del código fuente en tokens y construye un **Abstract Syntax Tree (AST)**. Los errores de sintaxis (`SyntaxError`) ocurren en esta fase de compilación/parsing antes de que se ejecute cualquier sentencia de código.
2. **Creación del Execution Context:** Antes de que el código se ejecute, el motor crea un Execution Context que contiene:
   * **LexicalEnvironment:** Vincula identificadores a valores dentro del scope actual.
   * **VariableEnvironment:** Mantiene las vinculaciones creadas por declaraciones `var`.
   * **Binding de `this`:** Se evalúa según el punto de llamada (call-site) de ejecución.
3. **Gestión de Memoria (Heap vs. Stack):**
   * **Call Stack:** Almacena frames de ejecución, valores primitivos y punteros a objetos en el heap. Opera bajo el principio LIFO (Last-In-First-Out).
   * **Memory Heap:** Pool de memoria no estructurada que asigna objetos de referencia (Objects, Arrays, Functions). Administrado mediante Generational Garbage Collection (Scavenge + Mark-Sweep-Compact).
4. **Parsing de Scripts en el Navegador vs. Ejecución en Runtime:**
   * `<script src="app.js">`: Modo por defecto. Bloquea sincrónicamente el parser de HTML mientras descarga y ejecuta.
   * `<script src="app.js" async>`: Descarga asincrónica; se ejecuta inmediatamente al llegar, orden de ejecución no determinista, bloquea el parser de HTML *solo durante la ejecución*.
   * `<script src="app.js" defer>`: Descarga asincrónica; retrasa la ejecución hasta que finaliza el parsing del DOM (`DOMContentLoaded`), se ejecuta en el orden exacto de inserción en el documento.

---

### 2. Ejercicios Guiados de Producción

#### Ejercicio 1: Call Stack, Hoisting, Scope Chains y la Temporal Dead Zone (TDZ)

**Objetivo:** Inspeccionar cómo V8 parsea las declaraciones de variables (`var`, `let`, `const`), el hoisting de variables, las reglas de scoping y las excepciones en tiempo de ejecución de la TDZ.

##### Paso 1.1: Crear un script de entorno de prueba
Ejecutá el siguiente comando de shell para generar `hoisting_lab.js`:

```bash
cat << 'EOF' > hoisting_lab.js
// Test Case 1: var Hoisting Mechanics
console.log("[1.1] Initial var state:", statusVar);
var statusVar = "System operational";
console.log("[1.2] Post-assignment var state:", statusVar);

// Test Case 2: Lexical Scope vs Block Scope
function scopeTest() {
  if (true) {
    var functionScoped = "Accessible outside block";
    let blockScoped = "Isolated inside block";
    const constScoped = "Immutable isolation";
  }
  console.log("[2.1] var inside function:", functionScoped);
  try {
    console.log("[2.2] let inside function:", blockScoped);
  } catch (err) {
    console.log("[2.2 Exception]:", err.name, "-", err.message);
  }
}
scopeTest();

// Test Case 3: Temporal Dead Zone (TDZ)
try {
  console.log("[3.1] Accessing let before declaration:", systemMetric);
  let systemMetric = 99.99;
} catch (err) {
  console.log("[3.1 Exception]:", err.name, "-", err.message);
}
EOF
```

##### Paso 1.2: Ejecutar el script usando Node.js
Ejecutá el script usando el entorno de ejecución CLI de Node.js:

```bash
node hoisting_lab.js
```

##### Salida de Terminal Esperada:
```text
[1.1] Initial var state: undefined
[1.2] Post-assignment var state: System operational
[2.1] var inside function: Accessible outside block
[2.2 Exception]: ReferenceError - blockScoped is not defined
[3.1 Exception]: ReferenceError - Cannot access 'systemMetric' before initialization
```

##### Preguntas de Verificación (Ejercicio 1)
1. ¿Por qué `console.log(statusVar)` en el Paso 1 imprime `undefined` en lugar de lanzar un `ReferenceError`?
2. ¿Cuál es la diferencia fundamental en la inicialización de memoria entre `var` y `let`/`const` durante la fase de creación del Execution Context de V8?
3. Si una variable declarada con `let` está dentro de un bloque, ¿en qué línea exacta comienza y termina su Temporal Dead Zone (TDZ)?

---

#### Ejercicio 2: Mecánica de Parsing del DOM, Carga de Scripts No Bloqueante (`defer` vs `async`)

**Objetivo:** Simular el comportamiento de parsing de recursos del navegador y observar el impacto operativo de los inline scripts, el bloqueo por scripts externos, `async` y `defer`.

##### Paso 2.1: Construir un benchmark de parsing del DOM en HTML
Creá `index.html` para evaluar los tiempos de ejecución de los scripts en relación con el renderizado de nodos del DOM.

```bash
cat << 'EOF' > index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Script Parsing Mechanics Benchmark</title>
  
  <!-- Synchronous Blocking Script -->
  <script>
    console.log("[Phase 1: Sync Head Script] DOM state:", document.getElementById("app-root"));
  </script>
  
  <!-- Defer Script Simulation -->
  <script>
    document.addEventListener("DOMContentLoaded", () => {
      console.log("[Phase 3: DOMContentLoaded] App Root node:", document.getElementById("app-root").innerText);
    });
  </script>
</head>
<body>
  <h1 id="app-root">Production Microservice Node #01</h1>
  
  <!-- Body Inline Script -->
  <script>
    console.log("[Phase 2: Body Inline Script] App Root node:", document.getElementById("app-root").innerText);
  </script>
</body>
</html>
EOF
```

##### Paso 2.2: Iniciar la verificación headless del navegador a través de Node.js
Ejecutá un diagnóstico headless usando Node.js para cargar y parsear la estructura HTML:

```bash
node -e '
const fs = require("fs");
const html = fs.readFileSync("index.html", "utf8");
console.log("File loaded successfully. Size:", html.length, "bytes");
'
```

##### Paso 2.3: Observar el orden de ejecución en la consola DevTools del navegador
Abrí `index.html` en Chrome/Firefox o inspeccioná la traza del orden de ejecución.

##### Salida de Terminal/Consola Esperada:
```text
[Phase 1: Sync Head Script] DOM state: null
[Phase 2: Body Inline Script] App Root node: Production Microservice Node #01
[Phase 3: DOMContentLoaded] App Root node: Production Microservice Node #01
```

##### Preguntas de Verificación (Ejercicio 2)
1. ¿Por qué `document.getElementById("app-root")` devolvió `null` durante la Fase 1?
2. Si un script externo está marcado con `async`, ¿bajo qué condición de red podría ejecutarse potencialmente **antes** que los scripts del body de la Fase 2?
3. ¿Cuál es la garantía en el orden de ejecución de múltiples scripts cargados con `defer` frente a múltiples scripts cargados con `async`?

---

#### Ejercicio 3: Tipado Dinámico, Tipos Primitivos vs. Referencia y Asignación en Memory Heap

**Objetivo:** Analizar el sistema de tipos dinámico de JavaScript, la mecánica de asignación por valor vs. referencia, las referencias a punteros en el heap y las anomalías operativas de `typeof`.

##### Paso 3.1: Crear un script de evaluación de tipos
Escribí `types_lab.js` para inspeccionar el comportamiento de mutación y la mecánica de verificación de tipos.

```bash
cat << 'EOF' > types_lab.js
// 1. Primitive Copy (Value Semantics)
let originalCpuLoad = 45;
let copiedCpuLoad = originalCpuLoad;
copiedCpuLoad = 85;

console.log("[Primitives] originalCpuLoad:", originalCpuLoad); // Expected: 45
console.log("[Primitives] copiedCpuLoad:", copiedCpuLoad);     // Expected: 85

// 2. Reference Copy (Heap Pointer Semantics)
let nodeConfigA = { cluster: "us-east-1", instances: 4 };
let nodeConfigB = nodeConfigA;
nodeConfigB.instances = 12;

console.log("[Reference] nodeConfigA.instances:", nodeConfigA.instances); // Expected: 12
console.log("[Reference] Equality check (nodeConfigA === nodeConfigB):", nodeConfigA === nodeConfigB); // Expected: true

// 3. typeof Operator Anomalies and Edge Cases
console.log("\n--- typeof Operator Analysis ---");
console.log("typeof 42              =>", typeof 42);
console.log("typeof 'Cluster'       =>", typeof "Cluster");
console.log("typeof true            =>", typeof true);
console.log("typeof undefined       =>", typeof undefined);
console.log("typeof Symbol('id')    =>", typeof Symbol('id'));
console.log("typeof 9007199254740991n =>", typeof 9007199254740991n);
console.log("typeof { a: 1 }        =>", typeof { a: 1 });
console.log("typeof [1, 2, 3]       =>", typeof [1, 2, 3]);
console.log("typeof null            =>", typeof null); // Historical V8/JS Type Bug
console.log("typeof function(){}    =>", typeof function(){});
EOF
```

##### Paso 3.2: Ejecutar el script
Ejecutá `types_lab.js` a través de la CLI de Node.js:

```bash
node types_lab.js
```

##### Salida de Terminal Esperada:
```text
[Primitives] originalCpuLoad: 45
[Primitives] copiedCpuLoad: 85
[Reference] nodeConfigA.instances: 12
[Reference] Equality check (nodeConfigA === nodeConfigB): true

--- typeof Operator Analysis ---
typeof 42              => number
typeof 'Cluster'       => string
typeof true            => boolean
typeof undefined       => undefined
typeof Symbol('id')    => symbol
typeof 9007199254740991n => bigint
typeof { a: 1 }        => object
typeof [1, 2, 3]       => object
typeof null            => object
typeof function(){}    => function
```

##### Preguntas de Verificación (Ejercicio 3)
1. ¿Por qué al modificar `nodeConfigB.instances` se altera directamente `nodeConfigA.instances`?
2. ¿Por qué `typeof null` se evalúa como `"object"` en JavaScript y por qué este comportamiento heredado (legacy) ha persistido en la especificación ECMAScript?
3. ¿Cómo puede un ingeniero probar de forma determinista si un valor es un Array frente a un Object plano, dado que `typeof` devuelve `"object"` para ambos?

---

#### Ejercicio 4: Forzar la Integridad de Ejecución con Strict Mode (`"use strict"`)

**Objetivo:** Inspeccionar cómo la directiva `"use strict"` cambia el comportamiento en runtime de V8 al suprimir fallos silenciosos, prevenir la contaminación de variables globales y aplicar restricciones sintácticas strictly.

##### Paso 4.1: Crear un script de diagnóstico non-strict vs strict
Escribí `strict_mode_lab.js`:

```bash
cat << 'EOF' > strict_mode_lab.js
// Non-strict function execution
function nonStrictPollution() {
  leakedGlobalVariable = "CRITICAL_DATA_LEAK";
}
nonStrictPollution();
console.log("[Non-Strict] Leaked variable in global scope:", global.leakedGlobalVariable);

// Strict function execution
function strictExecution() {
  "use strict";
  try {
    undeclaredStrictVar = "PREVENTED_LEAK";
  } catch (err) {
    console.log("[Strict Mode Exception]:", err.name, "-", err.message);
  }
}
strictExecution();

// Quiet Failure Suppression in Strict Mode
(function testReadOnlyProperty() {
  "use strict";
  const obj = {};
  Object.defineProperty(obj, "readOnlyProp", { value: 100, writable: false });
  
  try {
    obj.readOnlyProp = 200; // Throws TypeError in strict mode
  } catch (err) {
    console.log("[Strict Read-Only Exception]:", err.name, "-", err.message);
  }
})();
EOF
```

##### Paso 4.2: Ejecutar el script de diagnóstico de strict mode
Ejecutá `strict_mode_lab.js` a través de la CLI de Node.js:

```bash
node strict_mode_lab.js
```

##### Salida de Terminal Esperada:
```text
[Non-Strict] Leaked variable in global scope: CRITICAL_DATA_LEAK
[Strict Mode Exception]: ReferenceError - undeclaredStrictVar is not defined
[Strict Read-Only Exception]: TypeError - Cannot assign to read only property 'readOnlyProp' of object '#<Object>'
```

##### Preguntas de Verificación (Ejercicio 4)
1. ¿Qué ocurre en el modo non-strict cuando un desarrollador asigna un valor a un nombre de variable no inicializado (p. ej., `x = 10`) dentro de una función?
2. ¿Dónde debe colocarse la directiva `"use strict";` para aplicar una ejecución estricta en todo un archivo de script frente a dentro de una función individual?
3. Nombrá dos errores sintácticos o fallos silenciosos que el modo estricto transforma en excepciones explícitas.

---

### 3. Respuestas de Verificación y Explicaciones Técnicas

<details>
<summary>Hacé clic para desplegar la Clave de Respuestas y Explicaciones Técnicas Detalladas</summary>

#### Respuestas del Ejercicio 1
1. **Mecánica de Hoisting de Var:** Durante la fase de creación del Execution Context de V8, las declaraciones realizadas con `var` son escaneadas y registradas en memoria con un valor inicial de `undefined`. La asignación de memoria ocurre antes de que se ejecute la línea 1. La asignación `statusVar = "System operational"` solo tiene lugar durante la fase de ejecución cuando el call stack llega a esa línea.
2. **Inicialización de `var` vs `let`/`const`:** Mientras que `var` se inicializa inmediatamente en `undefined` durante la fase de creación, las declaraciones `let` y `const` se registran en la memoria léxica sin inicializar. Intentar leerlas antes de la evaluación de ejecución dispara una excepción de verificación de memoria no inicializada.
3. **Límites de la Temporal Dead Zone (TDZ):** La TDZ para una variable `let`/`const` comienza al ingresar a su scope de bloque contenedor (p. ej., `{`) y finaliza en la línea exacta donde la declaración del identificador es evaluada por el intérprete.

#### Respuestas del Ejercicio 2
1. **Bloqueo del DOM Parser:** En la Fase 1, la etiqueta `<script>` en el `<head>` se ejecutó sincrónicamente durante el parsing HTML inicial. En ese punto, el parser de HTML aún no había llegado al elemento `<body>` ni a la etiqueta `#app-root`, por lo que el árbol DOM no contenía el nodo `#app-root` (`null`).
2. **Tiempo de Ejecución de `async`:** Los scripts cargados con `async` se descargan en paralelo y se ejecutan tan pronto como se completa la descarga de la red, independientemente del estado del DOM. Si la latencia de red es mínima, un script `async` puede completar su descarga y ejecutarse antes de que el parser procese el script inline del `<body>` (Fase 2).
3. **Orden de Ejecución de `defer` vs `async`:**
   * `defer` garantiza la ejecución en el orden exacto en que aparecen los scripts en el documento HTML, ejecutándose estrictamente después de que el DOM se haya parseado por completo y justo antes de `DOMContentLoaded`.
   * `async` no ofrece garantías de orden; los scripts se ejecutan sobre la base de lo primero descargado es lo primero que se ejecuta tan pronto como están disponibles, pudiendo ejecutarse fuera de orden.

#### Respuestas del Ejercicio 3
1. **Semántica de Referencias y Punteros en Memoria:** Los tipos de datos primitivos (`number`, `string`, `boolean`, `symbol`, `bigint`, `null`, `undefined`) se copian por valor. Los tipos por referencia (`objects`, `arrays`, `functions`) residen en el Memory Heap. Las variables `nodeConfigA` y `nodeConfigB` almacenan direcciones de memoria (punteros) idénticas dirigidas al mismo objeto subyacente en el heap. Modificar propiedades a través de cualquiera de las variables muta el objeto subyacente compartido.
2. **Bug Histórico de `typeof null`:** En la implementación original de JavaScript de 1995, los valores se representaban utilizando etiquetas de tipo almacenadas en los bits inferiores. La etiqueta de tipo para objetos era `000`. `null` se representaba como el puntero nulo (dirección de memoria `0x00`), que tenía la etiqueta de tipo `000`. Por lo tanto, `typeof null` devolvía `"object"`. Este comportamiento se conservó en los estándares ECMAScript para mantener la compatibilidad con versiones anteriores de aplicaciones legacy.
3. **Detección del Tipo Array:** Dado que `typeof []` se evalúa como `"object"`, el código de producción utiliza `Array.isArray(val)` (o verifica `Object.prototype.toString.call(val) === "[object Array]"`) para distinguir arreglos de objetos planos estándares.

#### Respuestas del Ejercicio 4
1. **Contaminación del Scope Global:** En modo non-strict, asignar un valor a un identificador no declarado recorre la scope chain hasta el Global Execution Context. Si no se encuentra, V8 vincula implícitamente ese identificador como una propiedad en el objeto global (`window` en navegadores, `global` en Node.js), lo que provoca fugas de estado no deseadas.
2. **Ubicación del Scope de la Directiva Strict:**
   * **Global/Script Scope:** Colocada en la primerísima sentencia del archivo de script (`"use strict";`), aplicándose a todo el código dentro de ese script.
   * **Function Scope:** Colocada en la primera línea dentro del cuerpo de una función, restringiendo la ejecución estricta exclusivamente a esa función y sus funciones internas anidadas.
3. **Fallos Prevenidos por Strict Mode:**
   * Convierte variables globales implícitas en excepciones explícitas `ReferenceError`.
   * Convierte fallos de asignación silenciosos en propiedades de solo lectura, propiedades no escribibles u objetos con solo getter en excepciones `TypeError`.
   * Deshabilita nombres de parámetros duplicados en declaraciones de funciones (`function sum(a, a, c)` lanza `SyntaxError`).
   * Previene la eliminación de propiedades no eliminables (`delete Object.prototype` lanza `TypeError`).

</details>

---

### Checklist Resumen para la Preparación del Examen LPI 030-100

| Característica / Concepto | `var` | `let` | `const` |
| :--- | :--- | :--- | :--- |
| **Scope** | Function / Global | Block Scope | Block Scope |
| **Hoisting** | Sí (inicializado como `undefined`) | Sí (Temporal Dead Zone) | Sí (Temporal Dead Zone) |
| **Re-declaración** | Permitido en el mismo scope | Lanza `SyntaxError` | Lanza `SyntaxError` |
| **Re-asignación** | Permitido | Permitido | Lanza `TypeError` |
| **Binding al Objeto Global** | Se adjunta a `window`/`global` | No se adjunta | No se adjunta |