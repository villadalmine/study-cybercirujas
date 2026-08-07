# LPI 030-100 Topic 4.2: JavaScript Data Structures

**Certification:** LPI Web Development Essentials (Exam 030-100, Version 1.0)  
**Topic:** 4.2 JavaScript Data Structures  
**Weight:** 7.5  

---

## Official References
* **LPI Certification Overview:** [https://www.lpi.org/our-certifications/web-development-essentials-overview/](https://www.lpi.org/our-certifications/web-development-essentials-overview/)
* **MDN Web Docs — JavaScript Data Structures:** [https://developer.mozilla.org/en-US/docs/Web/JavaScript/Data_structures](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Data_structures)
* **V8 Engine — Elements Kinds in V8:** [https://v8.dev/blog/elements-kinds](https://v8.dev/blog/elements-kinds)
* **ECMAScript (ECMA-262) Specification — Data Types and Values:** [https://tc39.es/ecma262/#sec-ecmascript-data-types-and-values](https://tc39.es/ecma262/#sec-ecmascript-data-types-and-values)

---

## Architectural Deep Dive & V8 Mechanics

JavaScript engines (such as Node.js / Chrome V8) treat data structures under two distinct memory management models: **Primitives** and **Reference Types (Objects)**.

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
* **Primitives:** `undefined`, `null`, `boolean`, `number`, `bigint`, `string`, `symbol`. In 64-bit V8 execution contexts, small integers (**SMI**, 31-bit signed values) are stored directly inside the stack variable slot using pointer tagging (least significant bit set to `0`). Strings and larger numbers are allocated on the V8 Heap, but primitives remain *immutable*.
* **Reference Types:** `Object`, `Array`, `Map`, `Set`, `Function`, `Date`, `RegExp`. Variables on the stack store a memory address (tagged pointer ending with `1`) referencing the object header on the heap. Assigning a reference type copies the *pointer*, not the underlying object graph.

### 2. V8 Hidden Classes (Shapes) and Inline Caching
Unlike compiled languages with fixed memory offsets, JavaScript dynamically adds properties to objects. To maintain fast property access, V8 constructs **Hidden Classes (Shapes)**.
* Adding properties in identical sequences allows objects to share the same hidden class shape.
* Adding properties dynamically or using `delete` breaks shape sharing, forcing V8 to transition the object into **Dictionary Mode (Hash Table)**, degrading property access performance by up to an order of magnitude.

### 3. V8 Array Element Kinds
V8 tracks internal **Element Kinds** to optimize array indexing:
* `PACKED_SMI_ELEMENTS`: Dense array containing only Small Integers.
* `PACKED_DOUBLE_ELEMENTS`: Dense array containing floating-point numbers.
* `PACKED_ELEMENTS`: Dense array containing arbitrary object references or mixed types.
* `HOLEY_*` Variants (`HOLEY_SMI_ELEMENTS`, `HOLEY_ELEMENTS`): Array with deleted indexes or missing indices (holes). Reading a hole requires traversing the prototype chain.

> [!IMPORTANT]
> **Element Transition Rule:** Array element kind transitions are *one-way*. An array transitioned from `PACKED_SMI` to `HOLEY_ELEMENTS` can **never** be demoted back to `PACKED_SMI` by V8 during runtime execution.

---

## Hands-on Guided Exercises

### Exercise 1: Primitive vs. Reference Types, Heap Mutation, and V8 Inspection

In this exercise, you will observe the precise behavioral and memory differences between value passing and reference passing, and inspect object shape mutations.

#### Step 1: Create the Memory Analysis Script
Create a file named `exercise1_memory.js`:

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

#### Step 2: Execute the Script using Node.js
Run the script in your CLI:

```bash
node exercise1_memory.js
```

#### Expected Output:
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

#### Step 3: Inspect Hidden Class Transition Behavior
Create a file named `exercise1_shapes.js` using V8 internal native flags:

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

Execute with V8 natives enabled:

```bash
node --allow-natives-syntax exercise1_shapes.js
```

#### Expected Output:
```text
Shared shape before modification:
SUCCESS: Objects share the same Hidden Class (Shape)
Shape comparison after dynamic property injection:
WARNING: Hidden Class split! Objects no longer share the same Shape.
```

---

#### Verification Questions — Exercise 1
1. **Q1.1:** Why did modifying `serverConfigB.port` alter `serverConfigA.port`, whereas modifying `countB` did **not** alter `countA`?
2. **Q1.2:** If an object contains a nested reference (e.g., `serverConfigA.metadata = { region: "eu-west-1" }`), will `const shallowCopy = { ...serverConfigA }` protect `metadata.region` from mutation when modified via `shallowCopy.metadata.region = "us-central1"`?
3. **Q1.3:** What is the performance penalty in high-throughput production systems when objects lose their shared V8 Hidden Class (Shape)?

---

### Exercise 2: V8 Array Elements Transitions, Benchmarking, & Functional Pipeline Transformations

In this exercise, you will build code to trace V8 Array element kind degradation and compare performance between mutating loops and functional transformation methods (`map`, `filter`, `reduce`).

#### Step 1: Create the Array Elements Kind Benchmark Script
Create a file named `exercise2_arrays.js`:

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

Run using Node.js:

```bash
node --allow-natives-syntax exercise2_arrays.js
```

#### Expected Output Snippet (V8 Heap Inspector Logs):
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

#### Step 2: Implement Advanced Functional Processing (`map`, `filter`, `reduce`)
Create a file named `exercise2_functional.js`:

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

Execute the script:

```bash
node exercise2_functional.js
```

#### Expected Output:
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

#### Verification Questions — Exercise 2
1. **Q2.1:** If you delete an element from a dense array using `delete arr[1]`, what happens to the array's internal length and V8 Element Kind?
2. **Q2.2:** What is the accumulator parameter's initial value requirement in `Array.prototype.reduce()` when calculating aggregated values over potentially empty arrays?
3. **Q2.3:** Why is mutating an array during `.forEach()` iteration considered an anti-pattern in production codebases?

---

### Exercise 3: Keyed Data Structures — Objects vs. Maps, Sets, & Garbage Collection with WeakMap

In this exercise, you will measure memory footprint differences, key-type capabilities, property deletion performance, and evaluate `WeakMap` for leak prevention.

#### Step 1: Benchmark Object vs. Map Performance and Capability
Create a file named `exercise3_keyed.js`:

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

Run using Node.js:

```bash
node exercise3_keyed.js
```

#### Expected Output:
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

#### Step 2: Prevent Memory Leaks using WeakMap and Trace V8 Garbage Collection
Create a file named `exercise3_weakmap.js`:

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

Execute with explicit garbage collection enabled:

```bash
node --expose-gc exercise3_weakmap.js
```

#### Expected Output:
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

#### Verification Questions — Exercise 3
1. **Q3.1:** What fundamental transformation occurs to non-string keys (e.g., objects, numbers) when used as property keys in standard JavaScript Objects?
2. **Q3.2:** Why are primitive values (`string`, `number`, `symbol`) **forbidden** as keys in a `WeakMap`?
3. **Q3.3:** Compare the time complexity ($O(1)$ vs $O(N)$) of checking value existence in an `Array` using `.includes()` vs a `Set` using `.has()`.

---

### Exercise 4: Serialization, Deep Copying, and Prototype Pollution Security Hardening

In this exercise, you will analyze the security and data loss pitfalls of `JSON.parse`/`JSON.stringify`, implement native `structuredClone()`, and write defense mechanisms against Prototype Pollution attacks.

#### Step 1: Analyze Serialization Pitfalls & `structuredClone`
Create a file named `exercise4_serialization.js`:

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

Run using Node.js:

```bash
node exercise4_serialization.js
```

#### Expected Output:
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

#### Step 2: Implement Prototype Pollution Defense in Object Merging
Create a file named `exercise4_security.js`:

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

Run using Node.js:

```bash
node exercise4_security.js
```

#### Expected Output:
```text
=== TESTING PROTOTYPE POLLUTION DEFENSE ===
1. Running Secure Merge...
[SECURITY WARNING] Blocked pollution attempt on key: __proto__
Is testUser.isAdmin polluted? undefined

2. Demonstrating Unsafe Merge vulnerability...
Is testUser.isAdmin polluted? true
```

---

#### Verification Questions — Exercise 4
1. **Q4.1:** What happens if you pass an object containing a circular reference (e.g., `obj.self = obj`) to `JSON.stringify(obj)` versus `structuredClone(obj)`?
2. **Q4.2:** Can `structuredClone()` clone JavaScript function objects or DOM elements?
3. **Q4.3:** How does polluting `Object.prototype` compromise security across an entire Node.js runtime process?

---

<details>
  <summary>Click to expand Answer Key & Detailed Architectural Explanations</summary>

### Exercise 1 Answer Key

* **A1.1:** Primitive variables (`countA`) store their values directly on the stack (or as inline SMIs). Copying `countB = countA` copies the raw value. Modifying `countB` operates independently. Reference variables (`serverConfigA`, `serverConfigB`) store memory address pointers to the object on the V8 Heap. `serverConfigB = serverConfigA` copies the pointer address, causing both variables to reference the **exact same memory location on the heap**. Mutating property values via either pointer alters the underlying heap object.
* **A1.2:** **No.** Spread operators (`{ ...obj }`) and `Object.assign()` perform a **shallow copy**. They duplicate only top-level properties. Nested objects or arrays remain references. Mutating `shallowCopy.metadata.region` directly mutates the shared heap object referenced by both `serverConfigA` and `shallowCopy`.
* **A1.3:** When objects lose shared V8 Hidden Classes (Shapes), the V8 engine can no longer perform **Inline Caching (IC)** for property offset access. Access reverts to dynamic dictionary lookups (hash table searches), drastically increasing CPU cycle consumption and degrading throughput in microservices executing millions of operations per second.

---

### Exercise 2 Answer Key

* **A2.1:** Deleting an index with `delete arr[1]` creates a **hole** at index 1 without updating the `.length` property. V8 transitions the array's internal element kind to a **`HOLEY_*`** variant (e.g., `HOLEY_SMI_ELEMENTS` or `HOLEY_ELEMENTS`). Subsequent element lookups on index 1 fail the fast array lookup path and force V8 to traverse the prototype chain (`Array.prototype`, `Object.prototype`), introducing latency penalties.
* **A2.2:** If an initial value is omitted in `reduce()`, the array's first element (`arr[0]`) is used as the initial accumulator, and iteration begins at index 1. If `reduce()` is invoked on an **empty array** without providing an initial value parameter, V8 throws a runtime `TypeError: Reduce of empty array with no initial value`. Always provide an initial accumulator value (e.g., `{}` or `0`).
* **A2.3:** Mutating an array (e.g., using `.splice()`, `.push()`, or modifying index boundaries) while iterating inside `.forEach()` causes **unpredictable index drift**. Iteration indices increment linearly while the array length shrinks or expands dynamically, skipping elements or evaluating duplicated elements during runtime execution.

---

### Exercise 3 Answer Key

* **A3.1:** In standard JavaScript Objects, non-string property keys (excluding `Symbol`) are implicitly converted to strings via the `.toString()` casting operation. Passing an object key `{ id: 1 }` coerces the key string to `"[object Object]"`. Consequently, using different object instances as keys overwrites the single property entry `"[object Object]"`. `Map` preserves arbitrary key types using structural equality (`SameValueZero`).
* **A3.2:** `WeakMap` relies on object garbage collection lifecycle hooks. Primitive values (such as numbers, strings, or booleans) are immutable values that carry no garbage collector lifecycle identity and cannot be garbage collected. Allowing primitives as keys in a `WeakMap` would break weak reference mechanics.
* **A3.3:**
  * `Array.prototype.includes()` performs a linear search across elements, yielding **$O(N)$** time complexity.
  * `Set.prototype.has()` evaluates elements using internal hash table lookups, executing in **$O(1)$** constant time complexity regardless of element count.

---

### Exercise 4 Answer Key

* **A4.1:** 
  * `JSON.stringify(obj)` throws a unhandled runtime `TypeError: Converting circular structure to JSON`.
  * `structuredClone(obj)` natively tracks object identity graphs, accurately handling circular references and cloning the self-referencing structure without throwing an error.
* **A4.2:** **No.** `structuredClone()` throws a `DOMException` (DataCloneError) if it encounters JavaScript `Function` objects, functions assigned to object properties, DOM nodes, or getter/setter accessors.
* **A4.3:** Prototype Pollution allows an attacker to inject properties into `Object.prototype`. Because almost all objects in JavaScript inherit from `Object.prototype`, the injected properties instantly propagate across every existing and newly instantiated object in the V8 process space. This can lead to Remote Code Execution (RCE), authentication bypasses, or denial-of-service (DoS) vulnerabilities when checking uninitialized object configuration options.

</details>