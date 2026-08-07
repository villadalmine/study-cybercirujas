# Tema 4.3: Estructuras de control y funciones en JavaScript (LPI 030-100 v1.0, Weight: 10)

## Referencias oficiales y especificaciones
* [LPI Web Development Essentials Overview & Objectives](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* [MDN Web Docs: Control Flow and Error Handling](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Control_flow_and_error_handling)
* [MDN Web Docs: Functions](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Functions)
* [ECMAScript Language Specification (ECMA-262)](https://tc39.es/ecma262/)

---

## Análisis arquitectónico profundo: Ejecución en runtime y mecánica del motor

### 1. Contextos de ejecución, Call Stack y Lexical Scope
Cuando un motor de JavaScript (como Google V8) ejecuta código JavaScript, gestiona la ejecución mediante **Execution Contexts** apilados dentro de una **Call Stack** LIFO.

```
+-------------------------------------------------------------+
|                V8 Engine Execution Model                    |
+-------------------------------------------------------------+
| Call Stack                                                  |
| +---------------------------------------------------------+ |
| | Processing Function Context (Lexical Env + Variable Env) | |
| +---------------------------------------------------------+ |
| | Global Execution Context                                | |
| +---------------------------------------------------------+ |
+-------------------------------------------------------------+
| Heap Memory                                                 |
| +---------------------------------------------------------+ |
| | Closures (Outer Lexical Environments preserved on Heap) | |
| | Objects, Functions, Arrays                              | |
| +---------------------------------------------------------+ |
+-------------------------------------------------------------+
```

Cada contexto de ejecución consta de dos componentes internos críticos:
* **LexicalEnvironment**: Contiene identificadores declarados con `let`, `const`, `class`, parámetros de función y vinculaciones (bindings) de ámbito de bloque (block scope).
* **VariableEnvironment**: Contiene vinculaciones (bindings) creadas por sentencias `var` dentro del ámbito de función (function scope).

Cada entorno mantiene una referencia interna `[[OuterEnv]]` que apunta a su Lexical Environment externo envolvente. Esto forma la **Scope Chain**.

### 2. Hoisting y la Temporal Dead Zone (TDZ)
Durante la **Creation Phase** antes de la ejecución del código:
* Las **Function Declarations** (`function foo() {}`) se inicializan completamente en memoria. Pueden ser invocadas en cualquier lugar de su ámbito (scope) antes de su declaración textual.
* Las **Declaraciones de `var`** se registran e inicializan en `undefined`.
* Las **Declaraciones de `let` y `const`** se registran en el registro de ámbito pero permanecen **sin inicializar** (uninitialized). La región desde el inicio del bloque hasta la evaluación de la sentencia de declaración se conoce como la **Temporal Dead Zone (TDZ)**. Acceder a una vinculación sin inicializar en la TDZ dispara un `ReferenceError` en tiempo de ejecución (runtime).

### 3. Closures y ciclo de vida de la memoria
Un **Closure** ocurre cuando una función interna conserva una referencia a su `LexicalEnvironment` externo a través de su ranura (slot) interna `[[Environment]]`, incluso después de que el contexto de ejecución de la función externa haya sido removido (popped off) de la Call Stack. V8 asigna estos entornos léxicos retenidos en el Heap administrado en lugar de descartarlos.

---

## Ejercicios guiados

### Ejercicio 1: Mecánica de ramificación, Truthiness y optimización de Short-Circuit

#### Descripción de la tarea
Investigá la ramificación del control de flujo (`if...else`, `switch`, operadores ternarios) y la evaluación lógica short-circuit (`&&`, `||`, `??`). Observá los patrones de evaluación de V8 y evaluá casos límite en coerciones booleanas.

#### Ejecución paso a paso

**Paso 1.1:** Crea un directorio de trabajo y construye `branching_diagnostics.js`.

```bash
mkdir -p ~/lpi_js_lab && cd ~/lpi_js_lab
cat << 'EOF' > branching_diagnostics.js
/**
 * Production Diagnostic: Branching and Evaluation Pipeline
 */

function evaluateSystemHealth(nodeConfig) {
    console.log("=== 1. Truthiness & Logical Short-Circuiting ===");
    
    // Default fallback assignment using Nullish Coalescing (??) vs Logical OR (||)
    const timeoutSeconds = nodeConfig.timeout || 30;
    const retryLimit = nodeConfig.retries ?? 3;

    console.log(`Configured Timeout: ${timeoutSeconds}s`);
    console.log(`Configured Retries: ${retryLimit}`);

    console.log("\n=== 2. Strict Equality vs Loose Equality ===");
    const statusCode = nodeConfig.statusCode;
    
    if (statusCode == "200") {
        console.log("[WARN] Loose equality matched string '200' to number 200");
    }
    if (statusCode === "200") {
        console.log("[INFO] Strict equality matched string '200'");
    } else {
        console.log("[PASS] Strict equality failed between number 200 and string '200'");
    }

    console.log("\n=== 3. Jump Table Evaluation via switch ===");
    switch (true) {
        case (statusCode >= 200 && statusCode < 300):
            console.log("Status Category: 2xx Success");
            break;
        case (statusCode >= 400 && statusCode < 500):
            console.log("Status Category: 4xx Client Error");
            break;
        default:
            console.log("Status Category: Unknown Status Code");
    }
}

// Input object with intentional zero values and type variances
evaluateSystemHealth({
    timeout: 0,       // Falsy number
    retries: 0,       // Falsy number, but defined
    statusCode: 200   // Number type
});
EOF
```

**Paso 1.2:** Ejecuta el script usando Node.js.

```bash
node branching_diagnostics.js
```

#### Salida de CLI esperada
```text
=== 1. Truthiness & Logical Short-Circuiting ===
Configured Timeout: 30s
Configured Retries: 0

=== 2. Strict Equality vs Loose Equality ===
[WARN] Loose equality matched string '200' to number 200
[PASS] Strict equality failed between number 200 and string '200'

=== 3. Jump Table Evaluation via switch ===
Status Category: 2xx Success
```

#### Preguntas de verificación (Ejercicio 1)

1. ¿Por qué `timeoutSeconds` se resolvió en `30` a pesar de que `nodeConfig.timeout` se definió explícitamente como `0`?
2. ¿Cuál es la diferencia operacional fundamental entre `nodeConfig.val || fallback` y `nodeConfig.val ?? fallback`?
3. En las sentencias `switch(true)`, ¿cómo evalúa el motor la fase de coincidencia de expresiones en comparación con la comparación de igualdad estándar?

---

### Ejercicio 2: Mecánica de iteración de bucles y captura de alcance (Scope Trapping)

#### Descripción de la tarea
Analiza los bucles `for`, `while`, `do...while`, `for...in` y `for...of`. Observa cómo el alcance de las variables de bucle (`var` vs `let`) afecta la captura de closures a través de iteraciones asíncronas.

#### Ejecución paso a paso

**Paso 2.1:** Crea `loop_mechanics.js`.

```bash
cat << 'EOF' > loop_mechanics.js
/**
 * Production Diagnostic: Loop Iteration & Scope Trapping
 */

console.log("=== 1. Scope Trapping: var vs let inside loops ===");

function testVarScope() {
    var varHandlers = [];
    for (var i = 0; i < 3; i++) {
        varHandlers.push(() => i);
    }
    return varHandlers.map(fn => fn());
}

function testLetScope() {
    var letHandlers = [];
    for (let j = 0; j < 3; j++) {
        letHandlers.push(() => j);
    }
    return letHandlers.map(fn => fn());
}

console.log("var loop results:", testVarScope());
console.log("let loop results:", testLetScope());

console.log("\n=== 2. Enumeration: for...in vs for...of ===");

const clusterNodes = ["node-a", "node-b", "node-c"];
clusterNodes.customMetadata = "us-east-1";

console.log("for...in keys:");
for (const key in clusterNodes) {
    console.log(`  key: ${key} (type: ${typeof key})`);
}

console.log("for...of values:");
for (const value of clusterNodes) {
    console.log(`  value: ${value}`);
}

console.log("\n=== 3. Loop Control: break vs continue ===");
let processedCount = 0;
let k = 0;

while (k < 10) {
    k++;
    if (k % 2 === 0) continue; // Skip even numbers
    if (k > 5) break;          // Terminate loop when k > 5
    processedCount++;
    console.log(`  Processed odd number: ${k}`);
}
console.log(`Total processed items: ${processedCount}`);
EOF
```

**Paso 2.2:** Ejecuta el script de diagnóstico.

```bash
node loop_mechanics.js
```

#### Salida de CLI esperada
```text
=== 1. Scope Trapping: var vs let inside loops ===
var loop results: [ 3, 3, 3 ]
let loop results: [ 0, 1, 2 ]

=== 2. Enumeration: for...in vs for...of ===
for...in keys:
  key: 0 (type: string)
  key: 1 (type: string)
  key: 2 (type: string)
  key: customMetadata (type: string)
for...of values:
  value: node-a
  value: node-b
  value: node-c

=== 3. Loop Control: break vs continue ===
  Processed odd number: 1
  Processed odd number: 3
  Processed odd number: 5
Total processed items: 3
```

#### Preguntas de verificación (Ejercicio 2)

1. ¿Por qué `testVarScope()` produce la salida `[3, 3, 3]` mientras que `testLetScope()` produce `[0, 1, 2]`?
2. ¿Qué diferencia estructural hace que `for...in` itere sobre `"customMetadata"` mientras que `for...of` lo ignora?
3. ¿Cómo obtiene `for...of` sus objetivos de iteración por debajo de la cuerda (under the hood)?

---

### Ejercicio 3: Expresiones de función, Arrow Functions, Closures y Scope Chains

#### Descripción de la tarea
Construye un recolector de métricas con estado aprovechando Function Declarations, Function Expressions y Arrow Functions. Compara los comportamientos de vinculación de `this` e investiga la preservación de variables en closures.

#### Ejecución paso a paso

**Paso 3.1:** Crea `function_architecture.js`.

```bash
cat << 'EOF' > function_architecture.js
/**
 * Production Diagnostic: Function Types, Scope, and Dynamic 'this'
 */

console.log("=== 1. Hoisting Behaviour ===");
console.log("Calling declaredFunction before declaration:", declaredFunction());

try {
    expressionFunction();
} catch (err) {
    console.log("Calling expressionFunction before declaration caught error:", err.message);
}

function declaredFunction() {
    return "Function Declaration Hoisted Successfully";
}

var expressionFunction = function() {
    return "Function Expression Invoked";
};

console.log("\n=== 2. Lexical 'this' vs Dynamic 'this' ===");

const systemMonitor = {
    clusterName: "Production-US-East",
    metrics: [10, 20, 30],
    
    // Standard Function Expression: Dynamic 'this'
    printMetricsStandard: function() {
        console.log(`Standard outer this.clusterName: ${this.clusterName}`);
        setTimeout(function() {
            console.log(`Standard inner this.clusterName (uncaptured): ${this ? this.clusterName : undefined}`);
        }, 50);
    },

    // Arrow Function: Lexical 'this'
    printMetricsArrow: function() {
        console.log(`Arrow outer this.clusterName: ${this.clusterName}`);
        setTimeout(() => {
            console.log(`Arrow inner lexical this.clusterName: ${this.clusterName}`);
        }, 100);
    }
};

systemMonitor.printMetricsStandard();
systemMonitor.printMetricsArrow();

console.log("\n=== 3. Stateful Closures and Default/Rest Parameters ===");

function createMetricsCollector(serviceName, initialTag = "default", ...tags) {
    // Retained Lexical State (Closure)
    let totalRequests = 0;
    const allTags = [initialTag, ...tags];

    return {
        recordRequest(count = 1) {
            totalRequests += count;
            console.log(`[${serviceName}] Tags: [${allTags.join(", ")}] | Added: ${count} | Total: ${totalRequests}`);
        },
        getTotal() {
            return totalRequests;
        }
    };
}

const apiMetrics = createMetricsCollector("API-Gateway", "v1", "auth-service", "us-east");
apiMetrics.recordRequest(5);
apiMetrics.recordRequest(10);
console.log("Direct access to closure totalRequests:", apiMetrics.totalRequests); // Should be undefined
EOF
```

**Paso 3.2:** Ejecuta el diagnóstico de arquitectura de funciones.

```bash
node function_architecture.js
```

#### Salida de CLI esperada
```text
=== 1. Hoisting Behaviour ===
Calling declaredFunction before declaration: Function Declaration Hoisted Successfully
Calling expressionFunction before declaration caught error: expressionFunction is not a function

=== 2. Lexical 'this' vs Dynamic 'this' ===
Standard outer this.clusterName: Production-US-East
Arrow outer this.clusterName: Production-US-East
Direct access to closure totalRequests: undefined
Standard inner this.clusterName (uncaptured): undefined
Arrow inner lexical this.clusterName: Production-US-East
```

#### Preguntas de verificación (Ejercicio 3)

1. ¿Por qué invocar `expressionFunction()` antes de su línea de definición arrojó un `TypeError: expressionFunction is not a function` en lugar de un `ReferenceError`?
2. ¿Por qué el callback de función estándar dentro de `setTimeout` pierde el acceso a `this.clusterName`, mientras que la arrow function lo conserva?
3. ¿Cómo protege `createMetricsCollector` la variable `totalRequests` de la modificación externa directa?

---

## Soluciones y explicaciones detalladas

<details>
<summary>Haz clic para expandir las Soluciones y Explicaciones Técnicas</summary>

### Soluciones del Ejercicio 1

1. **Mecanismo de evaluación del OR lógico (`||`):**
   El operador `||` evalúa la truthiness del operando. JavaScript convierte de manera coercitiva `0`, `""` (cadena vacía), `null`, `undefined`, `NaN` y `false` a `false`. Debido a que `nodeConfig.timeout` se estableció en `0` (un valor falsy), `0 || 30` realiza un short-circuit hacia el operando de la derecha (`30`).

2. **Nullish Coalescing (`??`) vs OR lógico (`||`):**
   * `||` devuelve el lado derecho si el lado izquierdo se evalúa como **cualquier valor falsy** (`false`, `0`, `""`, `null`, `undefined`, `NaN`).
   * `??` devuelve el lado derecho **únicamente** si el lado izquierdo se evalúa como `null` o `undefined` (valores nullish). Por lo tanto, `0 ?? 3` conserva `0` como una entrada numérica válida.

3. **Mecánica de evaluación de `switch(true)`:**
   En un patrón `switch(true)`, JavaScript evalúa secuencialmente cada `case (expresión)` de arriba a abajo, calculando el resultado booleano de `(expresión)`. Coincide con el primer `case` cuyo resultado sea estrictamente igual (`===`) al objetivo del switch (`true`).

---

### Soluciones del Ejercicio 2

1. **Alcance (Scoping) de bucle y captura en Closure con `var` vs `let`:**
   * **Alcance con `var`:** `var i` crea una única vinculación (binding) de variable en el entorno de ejecución de la función envolvente. Cada iteración modifica esta misma ubicación de memoria única. Cuando los closures se ejecutan tras completar el bucle, todos leen el valor final de `i` (`3`).
   * **Alcance con `let`:** `let j` crea un **ámbito de bloque por iteración (per-iteration block scope)**. Para cada pasada de iteración, JavaScript crea un nuevo `LexicalEnvironment` que contiene una copia de `j` inicializada con el valor de esa iteración. El closure captura este entorno léxico específico de la iteración.

2. **Mecánica de `for...in` vs `for...of`:**
   * **`for...in`:** Enumera todas las **claves de propiedades enumerables** (enumerable property keys) de un objeto, incluyendo propiedades heredadas del prototipo y propiedades personalizadas adjuntas a los Arrays (`"0"`, `"1"`, `"2"`, `"customMetadata"`). Las claves siempre se convierten a primitivos `string`.
   * **`for...of`:** Invoca el método interno `[Symbol.iterator]` del objeto. Para los Arrays, el iterador por defecto produce secuencialmente los valores de los elementos del array e ignora las propiedades de metadatos no indexadas.

3. **Funcionamiento interno (under the hood) de `for...of`:**
   `for...of` utiliza el protocolo de iteración de ECMAScript (ECMAScript Iteration Protocol). Llama a `[Symbol.iterator]()` en el objeto objetivo para recuperar un objeto iterador y ejecuta repetidamente `.next()` para recibir `{ value: any, done: boolean }` hasta que `done === true`.

---

### Soluciones del Ejercicio 3

1. **Detalles de Hoisting en Function Expressions:**
   `var expressionFunction` se eleva (hoisted) durante la fase de creación como una declaración de variable e inicializada en `undefined`. Cuando se evalúa antes de su asignación, JavaScript intenta ejecutar `undefined()` como una llamada a función, lo que resulta en un error en runtime `TypeError: expressionFunction is not a function` (no un `ReferenceError`, porque el identificador existe en el alcance).

2. **`this` dinámico vs `this` léxico:**
   * Las funciones estándar determinan su vinculación de `this` **de forma dinámica en el momento de la invocación**. Cuando `setTimeout` ejecuta una función estándar, la llama como una llamada a función independiente (standalone), vinculando `this` a `globalThis` (o `undefined` en modo estricto).
   * Las Arrow functions **no crean su propia vinculación de `this`**. En su lugar, vinculan `this` léxicamente al contexto `this` del ámbito envolvente (`systemMonitor`) establecido en el momento de la definición.

3. **Encapsulación de datos mediante Closures:**
   `totalRequests` está definida dentro del `LexicalEnvironment` local de `createMetricsCollector`. Cuando `createMetricsCollector` finaliza su ejecución, `totalRequests` permanece referenciada por los métodos del objeto devuelto (`recordRequest`, `getTotal`) a través de sus propiedades internas `[[Environment]]`. Debido a que `totalRequests` no se expone como una propiedad del objeto, el código externo no puede mutarla directamente, logrando una encapsulación estricta.

</details>