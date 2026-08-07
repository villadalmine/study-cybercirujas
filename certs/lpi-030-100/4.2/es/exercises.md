# LPI 030-100 Topic 4.2: JavaScript Data Structures

**Certificación:** LPI Web Development Essentials (Examen 030-100, Versión 1.0)  
**Tema:** 4.2 JavaScript Data Structures  
**Peso:** 7.5  

---

## Referencias Oficiales
* **LPI Certification Overview:** [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* **MDN Web Docs — JavaScript Data Structures:** [https://developer.mozilla.org/en-US/docs/Web/JavaScript/Data_structures](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Data_structures)
* **V8 Engine — Elements Kinds in V8:** [https://v8.dev/blog/elements-kinds](https://v8.dev/blog/elements-kinds)
* **Especificación ECMAScript (ECMA-262) — Data Types and Values:** [https://tc39.es/ecma262/#sec-ecmascript-data-types-and-values](https://tc39.es/ecma262/#sec-ecmascript-data-types-and-values)

---

## Análisis Arquitectónico Profundo y Mecánica de V8

Los motores de JavaScript (como Node.js / Chrome V8) tratan las estructuras de datos bajo dos modelos de gestión de memoria distintos: **Primitives** y **Reference Types (Objects)**.

```
                  V8 Engine Memory Allocation
 +-----------------------------------------------------------+
 |                        STACK                              |
 | +-----------------------+-------------------------------+ |
 | | Variable Name         | Value / Pointer               | |
 | +-----------------------+-------------------------------+ |
 | | primitiveNumber       | 42 (Inline Value / SmallInteger)|
 | | primitiveString       | Pointer to String Table       | |
 | | objectRef             | Heap Pointer (0x7ffe420a) ----+-+--+
 | +-----------------------+-------------------------------+ ||
 +-----------------------------------------------------------+|
                                                              ||
                                                              v|
 +-----------------------------------------------------------+|
 |                        HEAP                               ||
 | +-------------------------------------------------------+ ||
 | | Object Header (Shape / Map Pointer)                   | ||
 | +-------------------------------------------------------+ ||
 | | Properties / Elements Array ArrayBuffer               | <+
 | +-------------------------------------------------------+  |
 +------------------------------------------------------------+
```

### 1. Pointer Tagging & Heap Allocation
* **Primitives:** `undefined`, `null`, `boolean`, `number`, `bigint`, `string`, `symbol`. En contextos de ejecución V8 de 64 bits, los enteros pequeños (**SMI**, valores con signo de 31 bits) se almacenan directamente dentro del slot de la variable en el Stack utilizando Pointer Tagging (el bit menos significativo establecido en `0`). Las cadenas de texto (Strings) y los números más grandes se asignan en el V8 Heap, pero los Primitives permanecen *inmutables*.
* **Reference Types:** `Object`, `Array`, `Map`, `Set`, `Function`, `Date`, `RegExp`. Las variables en el Stack almacenan una dirección de memoria (un pointer etiquetado que termina en `1`) que hace referencia al header del objeto en el Heap. Asignar un tipo de referencia copia el *pointer*, no el grafo de objetos subyacente.

### 2. V8 Hidden Classes (Shapes) e Inline Caching
A diferencia de los lenguajes compilados con offsets de memoria fijos, JavaScript agrega propiedades a los objetos de forma dinámica. Para mantener un acceso rápido a las propiedades, V8 construye **Hidden Classes (Shapes)**.
* Agregar propiedades en secuencias idénticas permite que los objetos compartan la misma forma de Hidden Class.
* Agregar propiedades dinámicamente o usar `delete` rompe la compartición de Shapes, forzando a V8 a transicionar el objeto a **Dictionary Mode (Hash Table)**, lo que degrada el rendimiento del acceso a propiedades hasta en un orden de magnitud.

### 3. V8 Array Element Kinds
V8 rastrea los **Element Kinds** internos para optimizar el indexado de arrays:
* `PACKED_SMI_ELEMENTS`: Array denso que contiene solo Small Integers.
* `PACKED_DOUBLE_ELEMENTS`: Array denso que contiene números de punto flotante.
* `PACKED_ELEMENTS`: Array denso que contiene referencias a objetos arbitrarios o tipos mixtos.
* Variantes `HOLEY_*` (`HOLEY_SMI_ELEMENTS`, `HOLEY_ELEMENTS`): Array con índices eliminados o índices faltantes (holes). Leer un hole requiere recorrer la prototype chain.

> [!IMPORTANT]
> **Regla de Transición de Elementos:** Las transiciones de Element Kinds en arrays son de *un solo sentido* (one-way). Un array que transicionó de `PACKED_SMI` a `HOLEY_ELEMENTS` **nunca** puede volver a convertirse de regreso a `PACKED_SMI` por V8 durante la ejecución en runtime.

---

## Ejercicios Guiados Prácticos

### Ejercicio 1: Primitive vs. Reference Types, Heap Mutation e Inspección de V8

En este ejercicio, observarás las diferencias precisas de comportamiento y memoria entre el paso por valor y el paso por referencia, e inspeccionarás las mutaciones de Shape en los objetos.

#### Paso 1: Crear el Script de Análisis de Memoria
Creá un archivo llamado `exercise1_memory.js`:

```javascript
// exercise1_memory.js
const fs = require('fs');

console.log("=== STEP 1: Primitive Pass-by-Value ===");
let countA = 100;
let countB = countA;
countB += 50;

console.log(`countA: ${countA} (Expected: 100)`);
console.log(`countB: ${countB} (Expected: 150)`);

console.log("\n=== STEP 2: Reference Copy & Mutation ===");
const serverConfigA = {
    hostname: "api.production.internal",
    port: 8443,
    active: true
};

const serverConfigB = serverConfigA;
serverConfigB.port = 9000;

console.log(`serverConfigA.port: ${serverConfigA.port} (Mutated via B!)`);
console.log(`serverConfigB.port: ${serverConfigB.port}`);
console.log(`Strict Equality Check (serverConfigA === serverConfigB): ${serverConfigA === serverConfigB}`);

console.log("\n=== STEP 3: Shallow Copy via Object.assign & Spread Operator ===");
const serverConfigC = { ...serverConfigA, port: 443 };
serverConfigC.hostname = "edge.production.internal";

console.log(`serverConfigA.hostname: ${serverConfigA.hostname}`);
console.log(`serverConfigC.hostname: ${serverConfigC.hostname}`);
console.log(`Strict Equality Check (serverConfigA === serverConfigC): ${serverConfigA === serverConfigC}`);
```

#### Paso 2: Ejecutar el Script usando Node.js
Ejecutá el script en tu CLI:

```bash
node exercise1_memory.js
```

#### Salida Esperada:
```text
=== STEP 1: Primitive Pass-by-Value ===
countA: 100 (Expected: 100)
countB: 150 (Expected: 150)

=== STEP 2: Reference Copy & Mutation ===
serverConfigA.port: 9000 (Mutated via B!)
serverConfigB.port: 9000
Strict Equality Check (serverConfigA === serverConfigB): true

=== STEP 3: Shallow Copy via Object.assign & Spread Operator ===
serverConfigA.hostname: api.production.internal
serverConfigC.hostname: edge.production.internal
Strict Equality Check (serverConfigA === serverConfigC): false
```

#### Paso 3: Inspeccionar el Comportamiento de Transición de Hidden Class
Creá un archivo llamado `exercise1_shapes.js` utilizando flags nativos internos de V8:

```javascript
// exercise1_shapes.js
// Run with: node --allow-natives-syntax exercise1_shapes.js

function NodeService(id, ip) {
    this.id = id;
    this.ip = ip;
}

const service1 = new NodeService("srv-01", "10.0.0.1");
const service2 = new NodeService("srv-02", "10.0.0.2");

// Fast Path: Both objects share the same V8 Map/Shape
console.log("Shared shape before modification:");
%HaveSameMap(service1, service2) ? console.log("SUCCESS: Objects share the same Hidden Class (Shape)") : console.log("FAIL");

// Dynamic Property Injection (De-optimizes shape sharing)
service2.clusterRegion = "us-east-1";

console.log("Shape comparison after dynamic property injection:");
%HaveSameMap(service1, service2) ? console.log("SUCCESS: Shared Shape") : console.log("WARNING: Hidden Class split! Objects no longer share the same Shape.");
```

Ejecutá con los nativos de V8 habilitados:

```bash
node --allow-natives-syntax exercise1_shapes.js
```

#### Salida Esperada:
```text
Shared shape before modification:
SUCCESS: Objects share the same Hidden Class (Shape)
Shape comparison after dynamic property injection:
WARNING: Hidden Class split! Objects no longer share the same Shape.
```

---

#### Preguntas de Verificación — Ejercicio 1
1. **Q1.1:** ¿Por qué modificar `serverConfigB.port` alteró `serverConfigA.port`, mientras que modificar `countB` **no** alteró `countA`?
2. **Q1.2:** Si un objeto contiene una referencia anidada (por ejemplo, `serverConfigA.metadata = { region: "eu-west-1" }`), ¿`const shallowCopy = { ...serverConfigA }` protegerá a `metadata.region` de ser mutado cuando se modifique a través de `shallowCopy.metadata.region = "us-central1"`?
3. **Q1.3:** ¿Cuál es la penalización de rendimiento en sistemas de producción de alto rendimiento (high-throughput) cuando los objetos pierden su V8 Hidden Class (Shape) compartida?

---

### Ejercicio 2: Transiciones de Array Elements en V8, Benchmarking y Transformaciones de Pipelines Funcionales

En este ejercicio, construirás código para rastrear la degradación de Element Kinds en V8 Arrays y comparar el rendimiento entre bucles mutantes y métodos de transformación funcional (`map`, `filter`, `reduce`).

#### Paso 1: Crear el Script de Benchmark de Array Elements Kind
Creá un archivo llamado `exercise2_arrays.js`:

```javascript
// exercise2_arrays.js
// Run with: node --allow-natives-syntax exercise2_arrays.js

console.log("=== V8 ARRAY ELEMENT KIND TRANSITIONS ===");

// 1. PACKED_SMI_ELEMENTS
const smiArray = [1, 2, 3, 4, 5];
console.log("1. Initial SMI Array Element Kind:");
%DebugPrint(smiArray);

// 2. Transition to PACKED_DOUBLE_ELEMENTS
smiArray.push(4.24);
console.log("\n2. Element Kind after pushing Float (Double):");
%DebugPrint(smiArray);

// 3. Transition to PACKED_ELEMENTS (Object references)
smiArray.push("production-tag");
console.log("\n3. Element Kind after pushing String:");
%DebugPrint(smiArray);

// 4. Transition to HOLEY_ELEMENTS
smiArray[20] = 100; // Creates indices 6-19 as missing holes!
console.log("\n4. Element Kind after creating Array Hole (Sparse Indexing):");
%DebugPrint(smiArray);
```

Ejecutá usando Node.js:

```bash
node --allow-natives-syntax exercise2_arrays.js
```

#### Fragmento de Salida Esperada (Logs del V8 Heap Inspector):
```text
=== V8 ARRAY ELEMENT KIND TRANSITIONS ===
1. Initial SMI Array Element Kind:
DebugPrint: 0x... <JSArray[5]>
 - elements: 0x... <FixedArray[5]> {
           0: 1
           1: 2
           ...
 }
 - map: 0x... <Map(PACKED_SMI_ELEMENTS)>

2. Element Kind after pushing Float (Double):
 - map: 0x... <Map(PACKED_DOUBLE_ELEMENTS)>

3. Element Kind after pushing String:
 - map: 0x... <Map(PACKED_ELEMENTS)>

4. Element Kind after creating Array Hole (Sparse Indexing):
 - map: 0x... <Map(HOLEY_ELEMENTS)>
```

#### Paso 2: Implementar Procesamiento Funcional Avanzado (`map`, `filter`, `reduce`)
Creá un archivo llamado `exercise2_functional.js`:

```javascript
// exercise2_functional.js
const logTelemetry = [
    { id: "evt-101", latencyMs: 45, status: 200, service: "auth" },
    { id: "evt-102", latencyMs: 520, status: 500, service: "payment" },
    { id: "evt-103", latencyMs: 120, status: 200, service: "auth" },
    { id: "evt-104", latencyMs: 850, status: 503, service: "gateway" },
    { id: "evt-105", latencyMs: 95, status: 200, service: "payment" }
];

console.log("=== FUNCTIONAL TRANSFORMATIONS ===");

// Task A: Filter failed events (status >= 500)
const failedEvents = logTelemetry.filter(evt => evt.status >= 500);
console.log("Failed Events:", JSON.stringify(failedEvents, null, 2));

// Task B: Map latency values into seconds
const latenciesInSeconds = logTelemetry.map(evt => ({
    event: evt.id,
    latencySec: evt.latencyMs / 1000
}));
console.log("Latencies (sec):", latenciesInSeconds);

// Task C: Aggregate total latency for "auth" service using reduce
const authLatencySummary = logTelemetry
    .filter(evt => evt.service === "auth")
    .reduce((acc, current) => {
        acc.totalMs += current.latencyMs;
        acc.count += 1;
        acc.averageMs = acc.totalMs / acc.count;
        return acc;
    }, { totalMs: 0, count: 0, averageMs: 0 });

console.log("Auth Service Latency Summary:", authLatencySummary);
```

Ejecutá el script:

```bash
node exercise2_functional.js
```

#### Salida Esperada:
```text
=== FUNCTIONAL TRANSFORMATIONS ===
Failed Events: [
  {
    "id": "evt-102",
    "latencyMs": 520,
    "status": 500,
    "service": "payment"
  },
  {
    "id": "evt-104",
    "latencyMs": 850,
    "status": 503,
    "service": "gateway"
  }
]
Latencies (sec): [
  { event: 'evt-101', latencySec: 0.045 },
  { event: 'evt-102', latencySec: 0.52 },
  { event: 'evt-103', latencySec: 0.12 },
  { event: 'evt-104', latencySec: 0.85 },
  { event: 'evt-105', latencySec: 0.095 }
]
Auth Service Latency Summary: { totalMs: 165, count: 2, averageMs: 82.5 }
```

---

#### Preguntas de Verificación — Ejercicio 2
1. **Q2.1:** Si eliminás un elemento de un array denso usando `delete arr[1]`, ¿qué sucede con la longitud interna del array y con el V8 Element Kind?
2. **Q2.2:** ¿Cuál es el requisito del valor inicial del parámetro acumulador en `Array.prototype.reduce()` al calcular valores agregados sobre arrays potencialmente vacíos?
3. **Q2.3:** ¿Por qué mutar un array durante la iteración con `.forEach()` se considera un antipatrón en bases de código de producción?

---

### Ejercicio 3: Estructuras de Datos con Claves — Objects vs. Maps, Sets y Garbage Collection con WeakMap

En este ejercicio, medirás las diferencias en el uso de memoria, las capacidades según el tipo de clave, el rendimiento al eliminar propiedades y evaluarás `WeakMap` para la prevención de fugas de memoria (memory leaks).

#### Paso 1: Benchmark de Rendimiento y Capacidades entre Object y Map
Creá un archivo llamado `exercise3_keyed.js`:

```javascript
// exercise3_keyed.js
console.log("=== STEP 1: Key Types (Object vs. Map) ===");

const plainObject = {};
const keyObj = { id: 1 };
const keyFunc = function() {};

plainObject[keyObj] = "Metadata for keyObj";
plainObject[keyFunc] = "Metadata for keyFunc";

console.log("Plain Object keys:", Object.keys(plainObject));
console.log("plainObject['[object Object]'] value:", plainObject["[object Object]"]);

const mapStructure = new Map();
mapStructure.set(keyObj, "Metadata for keyObj");
mapStructure.set(keyFunc, "Metadata for keyFunc");

console.log("\nMap Size:", mapStructure.size);
console.log("Map.get(keyObj):", mapStructure.get(keyObj));
console.log("Map.has(keyFunc):", mapStructure.has(keyFunc));

console.log("\n=== STEP 2: Unique Element Deduplication via Set ===");
const rawIPLogs = ["192.168.1.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "10.0.0.5"];
const uniqueIPs = new Set(rawIPLogs);

uniqueIPs.add("192.168.1.50");
console.log("Set size after adding non-duplicate:", uniqueIPs.size);
console.log("Is 10.0.0.5 present in Set?", uniqueIPs.has("10.0.0.5"));
console.log("Unique IP Array conversion:", Array.from(uniqueIPs));
```

Ejecutá usando Node.js:

```bash
node exercise3_keyed.js
```

#### Salida Esperada:
```text
=== STEP 1: Key Types (Object vs. Map) ===
Plain Object keys: [ '[object Object]', 'function() {}' ]
plainObject['[object Object]'] value: Metadata for keyObj

Map Size: 2
Map.get(keyObj): Metadata for keyObj
Map.has(keyFunc): true

=== STEP 2: Unique Element Deduplication via Set ===
Set size after adding non-duplicate: 4
Is 10.0.0.5 present in Set? true
Unique IP Array conversion: [ '192.168.1.1', '10.0.0.5', '172.16.0.1', '192.168.1.50' ]
```

#### Paso 2: Prevenir Fugas de Memoria usando WeakMap y Rastrear la Garbage Collection de V8
Creá un archivo llamado `exercise3_weakmap.js`:

```javascript
// exercise3_weakmap.js
// Run with: node --expose-gc exercise3_weakmap.js

if (typeof global.gc !== 'function') {
    console.error("ERROR: You must execute this script with node --expose-gc");
    process.exit(1);
}

console.log("=== WEAKMAP GARBAGE COLLECTION TEST ===");

let standardMap = new Map();
let weakMap = new WeakMap();

let sessionUserA = { username: "alice_sre" };
let sessionUserB = { username: "bob_dev" };

standardMap.set(sessionUserA, "Session Data A");
weakMap.set(sessionUserB, "Session Data B");

console.log("1. Initial States:");
console.log("standardMap.has(sessionUserA):", standardMap.has(sessionUserA));
console.log("weakMap.has(sessionUserB):", weakMap.has(sessionUserB));

// Dereference local object variables
sessionUserA = null;
sessionUserB = null;

// Force V8 Garbage Collection
global.gc();

console.log("\n2. Post-Garbage Collection State:");
console.log("standardMap size (Memory Leak retained):", standardMap.size);
console.log("WeakMap automatically dereferenced sessionUserB when reference was dropped!");
```

Ejecutá con la recolección de basura explícita habilitada:

```bash
node --expose-gc exercise3_weakmap.js
```

#### Salida Esperada:
```text
=== WEAKMAP GARBAGE COLLECTION TEST ===
1. Initial States:
standardMap.has(sessionUserA): true
weakMap.has(sessionUserB): true

2. Post-Garbage Collection State:
standardMap size (Memory Leak retained): 1
WeakMap automatically dereferenced sessionUserB when reference was dropped!
```

---

#### Preguntas de Verificación — Ejercicio 3
1. **Q3.1:** ¿Qué transformación fundamental les ocurre a las claves que no son cadenas de texto (por ejemplo, objetos, números) cuando se utilizan como claves de propiedades en Objects estándar de JavaScript?
2. **Q3.2:** ¿Por qué los valores primitivos (`string`, `number`, `symbol`) están **prohibidos** como claves en un `WeakMap`?
3. **Q3.3:** Compará la complejidad temporal ($O(1)$ vs $O(N)$) de verificar la existencia de un valor en un `Array` usando `.includes()` frente a un `Set` usando `.has()`.

---

### Ejercicio 4: Serialización, Copia Profunda (Deep Copying) y Fortalecimiento de Seguridad contra Prototype Pollution

En este ejercicio, analizarás los peligros de seguridad y pérdida de datos de `JSON.parse`/`JSON.stringify`, implementarás `structuredClone()` nativo y escribirás mecanismos de defensa contra ataques de Prototype Pollution.

#### Paso 1: Analizar los Peligros de la Serialización y `structuredClone`
Creá un archivo llamado `exercise4_serialization.js`:

```javascript
// exercise4_serialization.js
const systemMetric = {
    timestamp: new Date(),
    pattern: /error-[0-9]+/gi,
    meta: new Map([["cluster", "primary"]]),
    tags: new Set(["prod", "critical"]),
    handler: function logError() { console.log("logging"); },
    invalidVal: undefined
};

console.log("=== STEP 1: JSON.stringify Data Loss ===");
const jsonSerialized = JSON.parse(JSON.stringify(systemMetric));

console.log("JSON timestamp type:", typeof jsonSerialized.timestamp); // Converted to ISO String!
console.log("JSON pattern key:", jsonSerialized.pattern);            // Empty object {}!
console.log("JSON meta (Map):", jsonSerialized.meta);                // Empty object {}!
console.log("JSON tags (Set):", jsonSerialized.tags);                // Empty object {}!
console.log("JSON handler key:", jsonSerialized.handler);            // undefined (stripped)!
console.log("JSON invalidVal key:", jsonSerialized.invalidVal);      // undefined (stripped)!

console.log("\n=== STEP 2: Native structuredClone Processing ===");
const clonedMetric = structuredClone(systemMetric);

console.log("Cloned timestamp instanceof Date:", clonedMetric.timestamp instanceof Date);
console.log("Cloned pattern instanceof RegExp:", clonedMetric.pattern instanceof RegExp);
console.log("Cloned meta instanceof Map:", clonedMetric.meta instanceof Map);
console.log("Cloned Map value:", clonedMetric.meta.get("cluster"));
```

Ejecutá usando Node.js:

```bash
node exercise4_serialization.js
```

#### Salida Esperada:
```text
=== STEP 1: JSON.stringify Data Loss ===
JSON timestamp type: string
JSON pattern key: {}
JSON meta (Map): {}
JSON tags (Set): {}
JSON handler key: undefined
JSON invalidVal key: undefined

=== STEP 2: Native structuredClone Processing ===
Cloned timestamp instanceof Date: true
Cloned pattern instanceof RegExp: true
Cloned meta instanceof Map: true
Cloned Map value: primary
```

#### Paso 2: Implementar Defensa contra Prototype Pollution al Combinar Objetos (Object Merging)
Creá un archivo llamado `exercise4_security.js`:

```javascript
// exercise4_security.js

// Vulnerable Deep Merge Implementation
function unsafeMerge(target, source) {
    for (let key in source) {
        if (typeof source[key] === 'object' && source[key] !== null) {
            if (!target[key]) target[key] = {};
            unsafeMerge(target[key], source[key]);
        } else {
            target[key] = source[key];
        }
    }
    return target;
}

// Secure Deep Merge Implementation (Hardened)
function secureMerge(target, source) {
    for (let key of Object.keys(source)) {
        // Prevent Prototype Pollution by ignoring restricted keys
        if (key === '__proto__' || key === 'constructor' || key === 'prototype') {
            console.warn(`[SECURITY WARNING] Blocked pollution attempt on key: ${key}`);
            continue;
        }

        if (typeof source[key] === 'object' && source[key] !== null && !Array.isArray(source[key])) {
            if (!target[key] || typeof target[key] !== 'object') {
                target[key] = {};
            }
            secureMerge(target[key], source[key]);
        } else {
            target[key] = source[key];
        }
    }
    return target;
}

console.log("=== TESTING PROTOTYPE POLLUTION DEFENSE ===");

const maliciousPayload = JSON.parse('{"__proto__": {"isAdmin": true}}');
const appConfig = {};

console.log("1. Running Secure Merge...");
secureMerge(appConfig, maliciousPayload);

const testUser = {};
console.log("Is testUser.isAdmin polluted?", testUser.isAdmin); // Expected: undefined

console.log("\n2. Demonstrating Unsafe Merge vulnerability...");
unsafeMerge(appConfig, maliciousPayload);
console.log("Is testUser.isAdmin polluted?", testUser.isAdmin); // Expected: true (Vulnerable!)
```

Ejecutá usando Node.js:

```bash
node exercise4_security.js
```

#### Salida Esperada:
```text
=== TESTING PROTOTYPE POLLUTION DEFENSE ===
1. Running Secure Merge...
[SECURITY WARNING] Blocked pollution attempt on key: __proto__
Is testUser.isAdmin polluted? undefined

2. Demonstrating Unsafe Merge vulnerability...
Is testUser.isAdmin polluted? true
```

---

#### Preguntas de Verificación — Ejercicio 4
1. **Q4.1:** ¿Qué sucede si pasás un objeto que contiene una referencia circular (por ejemplo, `obj.self = obj`) a `JSON.stringify(obj)` en comparación con `structuredClone(obj)`?
2. **Q4.2:** ¿Puede `structuredClone()` clonar objetos función de JavaScript o elementos DOM?
3. **Q4.3:** ¿De qué manera contaminar `Object.prototype` compromete la seguridad a lo largo de todo un proceso del runtime de Node.js?

---

<details>
  <summary>Hacé clic para desplegar las Claves de Respuestas y Explicaciones Arquitectónicas Detalladas</summary>

### Clave de Respuestas del Ejercicio 1

* **A1.1:** Las variables primitivas (`countA`) almacenan sus valores directamente en el Stack (o como SMIs inline). Copiar `countB = countA` copia el valor en bruto. Modificar `countB` opera de forma independiente. Las variables de referencia (`serverConfigA`, `serverConfigB`) almacenan direcciones de memoria (pointers) al objeto en el V8 Heap. `serverConfigB = serverConfigA` copia la dirección del pointer, haciendo que ambas variables hagan referencia a la **misma ubicación exacta de memoria en el Heap**. Mutar los valores de las propiedades a través de cualquiera de los dos pointers altera el objeto subyacente en el Heap.
* **A1.2:** **No.** Los operadores Spread (`{ ...obj }`) y `Object.assign()` realizan una **shallow copy** (copia superficial). Duplican únicamente las propiedades de nivel superior. Los objetos o arrays anidados siguen siendo referencias. Mutar `shallowCopy.metadata.region` muta directamente el objeto compartido en el Heap al que hacen referencia tanto `serverConfigA` como `shallowCopy`.
* **A1.3:** Cuando los objetos pierden sus V8 Hidden Classes (Shapes) compartidas, el motor V8 ya no puede realizar **Inline Caching (IC)** para el acceso a offsets de propiedades. El acceso vuelve a búsquedas de diccionario dinámicas (búsquedas en hash table), incrementando drásticamente el consumo de ciclos de CPU y degradando el throughput en microservicios que ejecutan millones de operaciones por segundo.

---

### Clave de Respuestas del Ejercicio 2

* **A2.1:** Eliminar un índice con `delete arr[1]` crea un **hole** en el índice 1 sin actualizar la propiedad `.length`. V8 transiciona el Element Kind interno del array a una variante **`HOLEY_*`** (por ejemplo, `HOLEY_SMI_ELEMENTS` o `HOLEY_ELEMENTS`). Las búsquedas posteriores de elementos en el índice 1 fallan en la ruta de búsqueda rápida de arrays y fuerzan a V8 a recorrer la prototype chain (`Array.prototype`, `Object.prototype`), introduciendo penalizaciones de latencia.
* **A2.2:** Si se omite un valor inicial en `reduce()`, el primer elemento del array (`arr[0]`) se utiliza como acumulador inicial y la iteración comienza en el índice 1. Si se invoca `reduce()` en un **array vacío** sin proporcionar un parámetro de valor inicial, V8 lanza un error en runtime `TypeError: Reduce of empty array with no initial value`. Siempre debés proporcionar un valor acumulador inicial (por ejemplo, `{}` o `0`).
* **A2.3:** Mutar un array (por ejemplo, usando `.splice()`, `.push()`, o modificando los límites de los índices) mientras se itera dentro de `.forEach()` provoca un **desplazamiento impredecible de índices** (index drift). Los índices de iteración se incrementan linealmente mientras la longitud del array se contrae o expande dinámicamente, omitiendo elementos o evaluando elementos duplicados durante la ejecución en runtime.

---

### Clave de Respuestas del Ejercicio 3

* **A3.1:** En los Objects estándar de JavaScript, las claves de propiedad que no son strings (excluyendo `Symbol`) se convierten implícitamente a cadenas de texto a través de la operación de casting `.toString()`. Pasar un objeto como clave `{ id: 1 }` fuerza a que la clave pase a ser el string `"[object Object]"`. Por consiguiente, usar diferentes instancias de objetos como claves sobreescribe la única entrada de propiedad `"[object Object]"`. `Map` conserva tipos de clave arbitrarios utilizando igualdad estructural (`SameValueZero`).
* **A3.2:** `WeakMap` se basa en los ganchos (hooks) del ciclo de vida de la recolección de basura de los objetos. Los valores primitivos (como números, cadenas de texto o booleanos) son valores inmutables que no tienen identidad en el ciclo de vida del recolector de basura y no se pueden recolectar como basura. Permitir primitivos como claves en un `WeakMap` rompería la mecánica de referencias débiles (weak references).
* **A3.3:**
  * `Array.prototype.includes()` realiza una búsqueda lineal a través de los elementos, lo que resulta en una complejidad temporal de **$O(N)$**.
  * `Set.prototype.has()` evalúa elementos mediante búsquedas internas en una hash table, ejecutándose en una complejidad temporal constante de **$O(1)$** independientemente de la cantidad de elementos.

---

### Clave de Respuestas del Ejercicio 4

* **A4.1:** 
  * `JSON.stringify(obj)` lanza un error no controlado en runtime `TypeError: Converting circular structure to JSON`.
  * `structuredClone(obj)` rastrea nativamente los grafos de identidad de los objetos, manejando con precisión las referencias circulares y clonando la estructura autoreferenciada sin lanzar ningún error.
* **A4.2:** **No.** `structuredClone()` lanza una excepción `DOMException` (DataCloneError) si encuentra objetos `Function` de JavaScript, funciones asignadas a propiedades de objetos, nodos del DOM o accessors getter/setter.
* **A4.3:** Prototype Pollution permite a un atacante inyectar propiedades en `Object.prototype`. Dado que casi todos los objetos en JavaScript heredan de `Object.prototype`, las propiedades inyectadas se propagan instantáneamente a través de cada objeto existente y recién instanciado en el espacio del proceso V8. Esto puede derivar en Ejecución Remota de Código (RCE), evasión de autenticación (authentication bypass) o vulnerabilidades de Denegación de Servicio (DoS) al verificar opciones de configuración de objetos no inicializadas.

</details>